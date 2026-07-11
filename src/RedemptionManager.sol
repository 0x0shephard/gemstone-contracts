// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ComplianceRegistry} from "./ComplianceRegistry.sol";
import {DGENFT} from "./DGENFT.sol";
import {GemRegistry} from "./GemRegistry.sol";
import {ReserveManager} from "./ReserveManager.sol";
import {Roles} from "./libraries/Roles.sol";

contract RedemptionManager is
    Initializable,
    AccessControlUpgradeable,
    UUPSUpgradeable,
    PausableUpgradeable,
    ReentrancyGuard
{
    DGENFT public nft;
    GemRegistry public registry;
    ReserveManager public reserveManager;
    ComplianceRegistry public complianceRegistry;

    event RedemptionOpened(uint256 indexed tokenId, uint256 indexed gemId, address indexed owner, bytes32 requestHash);
    event RedemptionCancelled(uint256 indexed tokenId, uint256 indexed gemId);
    event RedemptionConfirmed(uint256 indexed tokenId, uint256 indexed gemId);

    error InvalidAddress();
    error NotGemCustodian();
    error NotTokenOwner();
    error TokenNotMapped();
    error RedemptionNotAllowed();
    error NotRedemptionCanceller();

    /// @custom:oz-upgrades-unsafe-allow constructor
    /// @dev Locks the implementation contract so only proxy instances can be initialized.
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes redemption dependencies and roles.
    /// @param admin Account receiving default admin, upgrader, and redeemer roles.
    /// @param nft_ DGE NFT contract.
    /// @param registry_ Gem registry.
    /// @param reserveManager_ Reserve manager.
    /// @param complianceRegistry_ Compliance registry.
    function initialize(
        address admin,
        DGENFT nft_,
        GemRegistry registry_,
        ReserveManager reserveManager_,
        ComplianceRegistry complianceRegistry_
    ) external initializer {
        if (
            admin == address(0) || address(nft_) == address(0) || address(registry_) == address(0)
                || address(reserveManager_) == address(0) || address(complianceRegistry_) == address(0)
        ) {
            revert InvalidAddress();
        }
        __AccessControl_init();
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(Roles.UPGRADER_ROLE, admin);
        _grantRole(Roles.REDEEMER_ROLE, admin);

        nft = nft_;
        registry = registry_;
        reserveManager = reserveManager_;
        complianceRegistry = complianceRegistry_;
    }

    /// @notice Opens redemption for a token owned by the caller.
    /// @dev Requires compliance approval, protocol solvency, and fully funded gem reserve.
    /// @param tokenId NFT token id to redeem.
    /// @param requestHash Off-chain redemption request hash.
    function requestRedemption(uint256 tokenId, bytes32 requestHash) external nonReentrant whenNotPaused {
        if (nft.ownerOf(tokenId) != msg.sender) revert NotTokenOwner();
        if (!complianceRegistry.canRedeem(msg.sender)) revert RedemptionNotAllowed();
        uint256 gemId = nft.tokenGem(tokenId);
        if (gemId == 0) revert TokenNotMapped();
        GemRegistry.Gem memory gem = registry.getGem(gemId);
        reserveManager.requireSolvent();
        reserveManager.requireFunded(gemId, gem.priceUsd);
        nft.setTransferLocked(tokenId, true);
        registry.requestRedemption(gemId, requestHash);
        emit RedemptionOpened(tokenId, gemId, msg.sender, requestHash);
    }

    /// @notice Cancels an open redemption request and unlocks transfers.
    /// @dev Callable by the token owner or an account with `REDEEMER_ROLE`.
    /// @param tokenId Token whose redemption should be cancelled.
    function cancelRedemption(uint256 tokenId) external nonReentrant whenNotPaused {
        uint256 gemId = nft.tokenGem(tokenId);
        if (gemId == 0) revert TokenNotMapped();
        address owner = nft.ownerOf(tokenId);
        if (msg.sender != owner && !hasRole(Roles.REDEEMER_ROLE, msg.sender)) revert NotRedemptionCanceller();
        registry.cancelRedemption(gemId);
        nft.setTransferLocked(tokenId, false);
        emit RedemptionCancelled(tokenId, gemId);
    }

    /// @notice Confirms physical redemption, releases reserve assets, and burns the NFT.
    /// @dev Caller must be the gem's recorded custodian.
    /// @param tokenId Token being redeemed.
    function confirmRedemption(uint256 tokenId) external nonReentrant whenNotPaused {
        uint256 gemId = nft.tokenGem(tokenId);
        if (gemId == 0) revert TokenNotMapped();
        GemRegistry.Gem memory gem = registry.getGem(gemId);
        if (msg.sender != gem.custodian) revert NotGemCustodian();
        registry.markRedeemed(gemId);
        reserveManager.clearProjectedLiabilityUsd(gemId);
        reserveManager.releaseAllReserveAssets(gemId, msg.sender, keccak256("REDEMPTION_CONFIRMED"));
        nft.burnFromProtocol(tokenId);
        emit RedemptionConfirmed(tokenId, gemId);
    }

    /// @notice Pauses redemption requests, cancellation, and confirmation.
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /// @notice Unpauses redemption operations.
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /// @dev Authorizes UUPS upgrades for `UPGRADER_ROLE` holders.
    function _authorizeUpgrade(address) internal override onlyRole(Roles.UPGRADER_ROLE) {}
}
