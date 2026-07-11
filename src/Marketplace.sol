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
import {DGENFT} from "./DGENFT.sol";
import {GemRegistry} from "./GemRegistry.sol";
import {PaymentTokenRegistry} from "./PaymentTokenRegistry.sol";
import {ReserveManager} from "./ReserveManager.sol";
import {Treasury} from "./Treasury.sol";
import {Roles} from "./libraries/Roles.sol";

contract Marketplace is
    Initializable,
    AccessControlUpgradeable,
    UUPSUpgradeable,
    PausableUpgradeable,
    ReentrancyGuard,
    IERC721Receiver
{
    using SafeERC20 for IERC20;

    struct Listing {
        address seller;
        uint256 priceUsd;
    }

    struct Offer {
        address bidder;
        uint256 tokenId;
        address paymentAsset;
        uint256 amount;
        uint256 saleUsdValue;
        uint64 expiry;
        bool active;
    }

    uint16 public constant BPS_DENOMINATOR = 10_000;
    uint64 public constant OFFER_DURATION = 1 days;

    DGENFT public nft;
    GemRegistry public registry;
    PaymentTokenRegistry public paymentRegistry;
    ReserveManager public reserveManager;
    Treasury public treasury;
    uint16 public secondaryFeeBps;
    address public secondaryFeeRecipient;
    uint256 private _nextOfferId;
    mapping(uint256 tokenId => Listing) public listings;
    mapping(uint256 offerId => Offer) public offers;

    event Listed(uint256 indexed tokenId, address indexed seller, uint256 priceUsd);
    event ListingCancelled(uint256 indexed tokenId);
    event Purchased(
        uint256 indexed tokenId, address indexed buyer, address paymentAsset, uint256 amount, uint256 usdValue
    );
    event OfferCreated(
        uint256 indexed offerId,
        address indexed bidder,
        uint256 indexed tokenId,
        address paymentAsset,
        uint256 amount,
        uint256 saleUsdValue,
        uint64 expiry
    );
    event OfferCancelled(uint256 indexed offerId);
    event OfferAccepted(uint256 indexed offerId, address indexed seller);
    event SecondaryFeeUpdated(uint16 feeBps);
    event SecondaryFeeRecipientUpdated(address recipient);

    error InvalidAddress();
    error InvalidPrice();
    error NotSeller();
    error NotBidder();
    error NotListed();
    error PriceNotMet();
    error InvalidAmount();
    error InvalidFee();
    error InvalidOffer();
    error Expired();
    error NotExpired();
    error TransferFailed();
    error GemNotMinted();

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address admin,
        DGENFT nft_,
        GemRegistry registry_,
        PaymentTokenRegistry paymentRegistry_,
        ReserveManager reserveManager_,
        Treasury treasury_
    ) external initializer {
        if (
            admin == address(0) || address(nft_) == address(0) || address(registry_) == address(0)
                || address(paymentRegistry_) == address(0) || address(reserveManager_) == address(0)
                || address(treasury_) == address(0)
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
        treasury = treasury_;
        secondaryFeeBps = 200;
        secondaryFeeRecipient = admin;
        _nextOfferId = 1;
    }

    function list(uint256 tokenId, uint256 priceUsd) external nonReentrant whenNotPaused {
        if (priceUsd == 0) revert InvalidPrice();
        _requireMintedGem(tokenId);
        nft.safeTransferFrom(msg.sender, address(this), tokenId);
        listings[tokenId] = Listing({seller: msg.sender, priceUsd: priceUsd});
        emit Listed(tokenId, msg.sender, priceUsd);
    }

    function cancel(uint256 tokenId) external nonReentrant {
        Listing memory listing = listings[tokenId];
        if (listing.seller == address(0)) revert NotListed();
        if (listing.seller != msg.sender) revert NotSeller();
        delete listings[tokenId];
        nft.safeTransferFrom(address(this), listing.seller, tokenId);
        emit ListingCancelled(tokenId);
    }

    function buy(uint256 tokenId, address paymentAsset, uint256 amount) external payable nonReentrant whenNotPaused {
        Listing memory listing = listings[tokenId];
        if (listing.seller == address(0)) revert NotListed();
        delete listings[tokenId];

        reserveManager.requireSolvent();
        uint256 received = _collectPayment(paymentAsset, amount);
        uint256 usdValue = paymentRegistry.quoteTokenToUsd(paymentAsset, received);
        uint256 gemId = nft.tokenGem(tokenId);
        _requireMintedGemId(gemId);
        uint256 reserveUsd = reserveManager.shortfallUsd(gemId, listing.priceUsd);
        if (usdValue < listing.priceUsd + reserveUsd) revert PriceNotMet();
        uint256 reserveAmount = _proRataAmountRoundUp(received, reserveUsd, usdValue);
        uint256 saleAmount = received - reserveAmount;
        if (reserveAmount != 0) {
            _fundReserve(gemId, paymentAsset, reserveAmount);
            reserveManager.requireFunded(gemId, listing.priceUsd);
        }

        reserveManager.syncProjectedLiabilityUsd(gemId, listing.priceUsd);
        _settleSecondary(paymentAsset, listing.seller, saleAmount);
        nft.safeTransferFrom(address(this), msg.sender, tokenId);
        emit Purchased(tokenId, msg.sender, paymentAsset, received, usdValue);
    }

    function createOffer(uint256 tokenId, address paymentAsset, uint256 amount)
        external
        payable
        nonReentrant
        whenNotPaused
        returns (uint256 offerId)
    {
        nft.ownerOf(tokenId);
        _requireMintedGem(tokenId);
        reserveManager.requireSolvent();
        uint256 received = _collectPayment(paymentAsset, amount);
        uint256 usdValue = paymentRegistry.quoteTokenToUsd(paymentAsset, received);
        uint256 gemId = nft.tokenGem(tokenId);
        uint256 reserveUsd = reserveManager.shortfallUsd(gemId, usdValue);
        if (usdValue <= reserveUsd) revert PriceNotMet();
        uint256 saleUsdValue = usdValue - reserveUsd;
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 expiry = uint64(block.timestamp + OFFER_DURATION);

        offerId = _nextOfferId++;
        offers[offerId] = Offer({
            bidder: msg.sender,
            tokenId: tokenId,
            paymentAsset: paymentAsset,
            amount: received,
            saleUsdValue: saleUsdValue,
            expiry: expiry,
            active: true
        });

        emit OfferCreated(offerId, msg.sender, tokenId, paymentAsset, received, saleUsdValue, expiry);
    }

    function cancelExpiredOffer(uint256 offerId) external nonReentrant {
        Offer memory offer = offers[offerId];
        if (!offer.active) revert InvalidOffer();
        if (block.timestamp <= offer.expiry) revert NotExpired();
        delete offers[offerId];
        _sendPayment(offer.bidder, offer.paymentAsset, offer.amount);
        emit OfferCancelled(offerId);
    }

    function acceptOffer(uint256 offerId) external nonReentrant whenNotPaused {
        Offer memory offer = offers[offerId];
        if (!offer.active) revert InvalidOffer();
        if (block.timestamp > offer.expiry) revert Expired();
        if (nft.ownerOf(offer.tokenId) != msg.sender) revert NotSeller();
        delete offers[offerId];

        reserveManager.requireSolvent();
        uint256 gemId = nft.tokenGem(offer.tokenId);
        _requireMintedGemId(gemId);
        uint256 reserveUsd = reserveManager.shortfallUsd(gemId, offer.saleUsdValue);
        uint256 requiredUsd = offer.saleUsdValue + reserveUsd;
        uint256 currentEscrowUsd = paymentRegistry.quoteTokenToUsd(offer.paymentAsset, offer.amount);
        if (currentEscrowUsd < requiredUsd) revert PriceNotMet();

        uint256 reserveAmount = _proRataAmountRoundUp(offer.amount, reserveUsd, requiredUsd);
        uint256 saleAmount = offer.amount - reserveAmount;
        if (reserveAmount != 0) {
            _fundReserve(gemId, offer.paymentAsset, reserveAmount);
            reserveManager.requireFunded(gemId, offer.saleUsdValue);
        }

        reserveManager.syncProjectedLiabilityUsd(gemId, offer.saleUsdValue);
        _settleSecondary(offer.paymentAsset, msg.sender, saleAmount);
        nft.safeTransferFrom(msg.sender, offer.bidder, offer.tokenId);
        emit OfferAccepted(offerId, msg.sender);
    }

    function setSecondaryFeeBps(uint16 feeBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (feeBps > BPS_DENOMINATOR) revert InvalidFee();
        secondaryFeeBps = feeBps;
        emit SecondaryFeeUpdated(feeBps);
    }

    function setSecondaryFeeRecipient(address recipient) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (recipient == address(0)) revert InvalidAddress();
        secondaryFeeRecipient = recipient;
        emit SecondaryFeeRecipientUpdated(recipient);
    }

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        if (msg.sender != address(nft)) revert InvalidAddress();
        return IERC721Receiver.onERC721Received.selector;
    }

    function _collectPayment(address paymentAsset, uint256 amount) private returns (uint256 received) {
        if (paymentAsset == address(0)) {
            if (amount != msg.value || amount == 0) revert InvalidAmount();
            return msg.value;
        }

        if (msg.value != 0 || amount == 0) revert InvalidAmount();
        uint256 beforeBalance = IERC20(paymentAsset).balanceOf(address(this));
        IERC20(paymentAsset).safeTransferFrom(msg.sender, address(this), amount);
        received = IERC20(paymentAsset).balanceOf(address(this)) - beforeBalance;
        if (received == 0) revert InvalidAmount();
    }

    function _settleSecondary(address paymentAsset, address seller, uint256 amount) private {
        if (amount == 0) return;
        uint256 feeAmount = (amount * secondaryFeeBps) / BPS_DENOMINATOR;
        uint256 sellerAmount = amount - feeAmount;
        if (paymentAsset == address(0)) {
            _sendPayment(seller, paymentAsset, sellerAmount);
            _sendPayment(secondaryFeeRecipient, paymentAsset, feeAmount);
            return;
        }

        _sendPayment(seller, paymentAsset, sellerAmount);
        _sendPayment(secondaryFeeRecipient, paymentAsset, feeAmount);
    }

    function _fundReserve(uint256 gemId, address paymentAsset, uint256 amount) private {
        if (paymentAsset == address(0)) {
            uint256 nativeUsdValue = paymentRegistry.quoteTokenToUsd(paymentAsset, amount);
            reserveManager.recordModuleFunding{value: amount}(gemId, paymentAsset, amount, nativeUsdValue);
            return;
        }

        uint256 beforeBalance = IERC20(paymentAsset).balanceOf(address(reserveManager));
        IERC20(paymentAsset).safeTransfer(address(reserveManager), amount);
        uint256 receivedByReserve = IERC20(paymentAsset).balanceOf(address(reserveManager)) - beforeBalance;
        uint256 tokenUsdValue = paymentRegistry.quoteTokenToUsd(paymentAsset, receivedByReserve);
        reserveManager.recordModuleFunding(gemId, paymentAsset, receivedByReserve, tokenUsdValue);
    }

    function _proRataAmount(uint256 amount, uint256 shareUsd, uint256 totalUsd) private pure returns (uint256) {
        if (shareUsd == 0) return 0;
        return (amount * shareUsd) / totalUsd;
    }

    function _proRataAmountRoundUp(uint256 amount, uint256 shareUsd, uint256 totalUsd) private pure returns (uint256) {
        if (shareUsd == 0) return 0;
        return (amount * shareUsd + totalUsd - 1) / totalUsd;
    }

    function _sendPayment(address to, address paymentAsset, uint256 amount) private {
        if (amount == 0) return;
        if (paymentAsset == address(0)) {
            (bool ok,) = payable(to).call{value: amount}("");
            if (!ok) revert TransferFailed();
            return;
        }
        IERC20(paymentAsset).safeTransfer(to, amount);
    }

    function _requireMintedGem(uint256 tokenId) private view returns (uint256 gemId) {
        gemId = nft.tokenGem(tokenId);
        _requireMintedGemId(gemId);
    }

    function _requireMintedGemId(uint256 gemId) private view {
        GemRegistry.Gem memory gem = registry.getGem(gemId);
        if (gem.status != GemRegistry.GemStatus.Minted) revert GemNotMinted();
    }

    receive() external payable {}

    function _authorizeUpgrade(address) internal override onlyRole(Roles.UPGRADER_ROLE) {}
}
