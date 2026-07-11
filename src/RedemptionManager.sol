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

    function cancelRedemption(uint256 tokenId) external nonReentrant whenNotPaused onlyRole(Roles.REDEEMER_ROLE) {
        uint256 gemId = nft.tokenGem(tokenId);
        if (gemId == 0) revert TokenNotMapped();
        registry.cancelRedemption(gemId);
        nft.setTransferLocked(tokenId, false);
        emit RedemptionCancelled(tokenId, gemId);
    }

    function confirmRedemption(uint256 tokenId) external nonReentrant whenNotPaused {
        uint256 gemId = nft.tokenGem(tokenId);
        if (gemId == 0) revert TokenNotMapped();
        GemRegistry.Gem memory gem = registry.getGem(gemId);
        if (msg.sender != gem.custodian) revert NotGemCustodian();
        registry.markRedeemed(gemId);
        nft.burnFromProtocol(tokenId);
        emit RedemptionConfirmed(tokenId, gemId);
    }

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    function _authorizeUpgrade(address) internal override onlyRole(Roles.UPGRADER_ROLE) {}
}
