// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {DGENFT} from "./DGENFT.sol";
import {GemRegistry} from "./GemRegistry.sol";
import {PaymentTokenRegistry} from "./PaymentTokenRegistry.sol";
import {ReserveManager} from "./ReserveManager.sol";
import {Roles} from "./libraries/Roles.sol";

contract SwapEscrow is
    Initializable,
    AccessControlUpgradeable,
    UUPSUpgradeable,
    PausableUpgradeable,
    ReentrancyGuard,
    IERC721Receiver
{
    using SafeERC20 for IERC20;

    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant MIN_SWAP_RESERVE_BPS = 1_000;

    struct SwapOffer {
        address proposer;
        uint256 offeredTokenId;
        uint256 requestedTokenId;
        address cashAsset;
        uint256 cashAmount;
        bool proposerPaysCash;
        uint64 expiry;
        bool active;
    }

    DGENFT public nft;
    GemRegistry public registry;
    PaymentTokenRegistry public paymentRegistry;
    ReserveManager public reserveManager;
    uint256 private _nextOfferId;
    mapping(uint256 offerId => SwapOffer) public offers;

    event OfferCreated(
        uint256 indexed offerId,
        address indexed proposer,
        uint256 indexed offeredTokenId,
        uint256 requestedTokenId,
        address cashAsset,
        uint256 cashAmount,
        bool proposerPaysCash,
        uint64 expiry
    );
    event OfferCancelled(uint256 indexed offerId);
    event OfferAccepted(uint256 indexed offerId, address indexed accepter);

    error InvalidAddress();
    error InvalidOffer();
    error NotProposer();
    error Expired();
    error InvalidAmount();
    error TransferFailed();
    error GemNotMinted();
    error ReserveCoverageTooLow(uint256 gemId, uint256 requiredUsd, uint256 balanceUsd);

    /// @custom:oz-upgrades-unsafe-allow constructor
    /// @dev Locks the implementation contract so only proxy instances can be initialized.
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes swap escrow dependencies and roles.
    /// @param admin Account receiving default admin and upgrader roles.
    /// @param nft_ DGE NFT contract.
    /// @param registry_ Gem registry.
    /// @param paymentRegistry_ Payment registry.
    /// @param reserveManager_ Reserve manager.
    function initialize(
        address admin,
        DGENFT nft_,
        GemRegistry registry_,
        PaymentTokenRegistry paymentRegistry_,
        ReserveManager reserveManager_
    ) external initializer {
        if (
            admin == address(0) || address(nft_) == address(0) || address(registry_) == address(0)
                || address(paymentRegistry_) == address(0) || address(reserveManager_) == address(0)
        ) {
            revert InvalidAddress();
        }
        __AccessControl_init();
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(Roles.UPGRADER_ROLE, admin);

        nft = nft_;
        registry = registry_;
        paymentRegistry = paymentRegistry_;
        reserveManager = reserveManager_;
        _nextOfferId = 1;
    }

    /// @notice Creates an escrowed DGE-for-DGE swap offer, optionally with a cash delta.
    /// @dev Offered token is escrowed immediately; requested token must be a minted DGE NFT.
    /// @param offeredTokenId Token escrowed by proposer.
    /// @param requestedTokenId Token requested from accepter.
    /// @param cashAsset Cash delta asset, or address(0) for native ETH.
    /// @param cashAmount Cash delta amount.
    /// @param proposerPaysCash True if proposer escrows/pays the cash delta.
    /// @param expiry Offer expiry timestamp.
    /// @return offerId Newly created swap offer id.
    function createOffer(
        uint256 offeredTokenId,
        uint256 requestedTokenId,
        address cashAsset,
        uint256 cashAmount,
        bool proposerPaysCash,
        uint64 expiry
    ) external payable nonReentrant whenNotPaused returns (uint256 offerId) {
        if (expiry <= block.timestamp || offeredTokenId == requestedTokenId) revert InvalidOffer();
        if (cashAmount != 0) {
            paymentRegistry.quoteTokenToUsd(cashAsset, cashAmount);
        }
        uint256 requestedGemId = nft.tokenGem(requestedTokenId);
        uint256 offeredGemId = nft.tokenGem(offeredTokenId);
        _requireMintedGem(offeredGemId);
        _requireMintedGem(requestedGemId);
        GemRegistry.Gem memory offeredGem = registry.getGem(offeredGemId);
        GemRegistry.Gem memory requestedGem = registry.getGem(requestedGemId);
        _requireSwapReserve(offeredGemId, offeredGem.priceUsd);
        _requireSwapReserve(requestedGemId, requestedGem.priceUsd);

        offerId = _nextOfferId++;
        nft.safeTransferFrom(msg.sender, address(this), offeredTokenId);

        if (proposerPaysCash && cashAmount != 0) {
            _collectCash(msg.sender, cashAsset, cashAmount);
        } else if (msg.value != 0) {
            revert InvalidAmount();
        }

        offers[offerId] = SwapOffer({
            proposer: msg.sender,
            offeredTokenId: offeredTokenId,
            requestedTokenId: requestedTokenId,
            cashAsset: cashAsset,
            cashAmount: cashAmount,
            proposerPaysCash: proposerPaysCash,
            expiry: expiry,
            active: true
        });

        emit OfferCreated(
            offerId, msg.sender, offeredTokenId, requestedTokenId, cashAsset, cashAmount, proposerPaysCash, expiry
        );
    }

    /// @notice Cancels an active swap offer and returns escrowed assets to proposer.
    /// @param offerId Swap offer id to cancel.
    function cancelOffer(uint256 offerId) external nonReentrant {
        SwapOffer memory offer = offers[offerId];
        if (!offer.active) revert InvalidOffer();
        if (offer.proposer != msg.sender) revert NotProposer();
        delete offers[offerId];

        nft.safeTransferFrom(address(this), offer.proposer, offer.offeredTokenId);
        if (offer.proposerPaysCash && offer.cashAmount != 0) {
            _sendCash(offer.proposer, offer.cashAsset, offer.cashAmount);
        }
        emit OfferCancelled(offerId);
    }

    /// @notice Accepts an active swap offer and exchanges NFTs and any cash delta.
    /// @param offerId Swap offer id to accept.
    function acceptOffer(uint256 offerId) external payable nonReentrant whenNotPaused {
        SwapOffer memory offer = offers[offerId];
        if (!offer.active) revert InvalidOffer();
        if (block.timestamp > offer.expiry) revert Expired();
        if (offer.proposerPaysCash && msg.value != 0) revert InvalidAmount();
        delete offers[offerId];
        uint256 offeredGemId = nft.tokenGem(offer.offeredTokenId);
        uint256 requestedGemId = nft.tokenGem(offer.requestedTokenId);
        _requireMintedGem(offeredGemId);
        _requireMintedGem(requestedGemId);
        GemRegistry.Gem memory offeredGem = registry.getGem(offeredGemId);
        GemRegistry.Gem memory requestedGem = registry.getGem(requestedGemId);
        _requireSwapReserve(offeredGemId, offeredGem.priceUsd);
        _requireSwapReserve(requestedGemId, requestedGem.priceUsd);

        nft.safeTransferFrom(msg.sender, offer.proposer, offer.requestedTokenId);
        nft.safeTransferFrom(address(this), msg.sender, offer.offeredTokenId);

        if (offer.cashAmount != 0) {
            if (offer.proposerPaysCash) {
                _sendCash(msg.sender, offer.cashAsset, offer.cashAmount);
            } else {
                _collectCash(msg.sender, offer.cashAsset, offer.cashAmount);
                _sendCash(offer.proposer, offer.cashAsset, offer.cashAmount);
            }
        } else if (msg.value != 0) {
            revert InvalidAmount();
        }

        emit OfferAccepted(offerId, msg.sender);
    }

    /// @notice Pauses swap creation and acceptance.
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /// @notice Unpauses swap operations.
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /// @notice Accepts safe transfers only from the configured DGE NFT contract.
    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        if (msg.sender != address(nft)) revert InvalidAddress();
        return IERC721Receiver.onERC721Received.selector;
    }

    /// @dev Collects a native or ERC-20 cash delta.
    function _collectCash(address from, address asset, uint256 amount) private {
        if (asset == address(0)) {
            if (msg.value != amount) revert InvalidAmount();
            return;
        }
        if (msg.value != 0) revert InvalidAmount();
        IERC20(asset).safeTransferFrom(from, address(this), amount);
    }

    /// @dev Sends a native or ERC-20 cash delta.
    function _sendCash(address to, address asset, uint256 amount) private {
        if (asset == address(0)) {
            (bool ok,) = payable(to).call{value: amount}("");
            if (!ok) revert TransferFailed();
            return;
        }
        IERC20(asset).safeTransfer(to, amount);
    }

    /// @dev Reverts unless the gem is in minted status.
    function _requireMintedGem(uint256 gemId) private view {
        GemRegistry.Gem memory gem = registry.getGem(gemId);
        if (gem.status != GemRegistry.GemStatus.Minted) revert GemNotMinted();
    }

    /// @dev A swap changes ownership but does not consume reserve. Partial
    ///      coverage is therefore allowed, while ten percent or less is not.
    function _requireSwapReserve(uint256 gemId, uint256 referenceValueUsd) private view {
        uint256 requiredUsd = reserveManager.requiredReserveUsd(gemId, referenceValueUsd);
        if (requiredUsd == 0) return;
        uint256 balanceUsd = reserveManager.reserveBalanceUsd(gemId);
        uint256 coverageBps = Math.mulDiv(balanceUsd, BPS_DENOMINATOR, requiredUsd);
        if (coverageBps <= MIN_SWAP_RESERVE_BPS) {
            revert ReserveCoverageTooLow(gemId, requiredUsd, balanceUsd);
        }
    }

    receive() external payable {}

    /// @dev Authorizes UUPS upgrades for `UPGRADER_ROLE` holders.
    function _authorizeUpgrade(address) internal override onlyRole(Roles.UPGRADER_ROLE) {}
}
