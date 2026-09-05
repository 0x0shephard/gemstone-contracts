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

    struct ListingSettlement {
        uint256 tokenId;
        uint256 offerId;
        uint256 gemId;
        uint256 gemPriceUsd;
        uint256 reserveUsd;
        uint256 currentEscrowUsd;
    }

    uint16 public constant BPS_DENOMINATOR = 10_000;
    uint64 public constant OFFER_DURATION = 1 days;
    uint256 public constant MIN_BID_INCREMENT_USD = 1e18;

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
    // Appended for UUPS storage compatibility. A qualifying offer on an escrowed
    // listing becomes its 24-hour auction leader and settles without seller
    // approval. Offers on unlisted tokens retain the original manual flow.
    mapping(uint256 tokenId => uint256 offerId) public listingWinningOffer;
    mapping(uint256 tokenId => uint64 endTime) public listingAuctionEnd;
    mapping(address account => mapping(address asset => uint256 amount)) public pendingRefunds;

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
    event ListingAuctionStarted(uint256 indexed tokenId, uint256 indexed offerId, uint64 endTime);
    event ListingBidOutbid(uint256 indexed tokenId, uint256 indexed previousOfferId, uint256 indexed newOfferId);
    event ListingAuctionSettled(
        uint256 indexed tokenId,
        uint256 indexed offerId,
        address indexed winner,
        address paymentAsset,
        uint256 amount,
        uint256 usdValue
    );
    event ListingAuctionRefunded(
        uint256 indexed tokenId, uint256 indexed offerId, address indexed bidder, address paymentAsset, uint256 amount
    );
    event RefundCredited(address indexed account, address indexed asset, uint256 amount);
    event RefundClaimed(address indexed account, address indexed asset, uint256 amount);
    event RefundSent(address indexed account, address indexed asset, uint256 amount);
    event PaymentSurplusRefunded(address indexed account, address indexed asset, uint256 amount);
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
    error AuctionActive();
    error AuctionNotEnded();
    error BidTooLow();

    /// @custom:oz-upgrades-unsafe-allow constructor
    /// @dev Locks the implementation contract so only proxy instances can be initialized.
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes marketplace dependencies and default secondary fee settings.
    /// @param admin Account receiving default admin and upgrader roles.
    /// @param nft_ DGE NFT contract.
    /// @param registry_ Gem registry.
    /// @param paymentRegistry_ Payment registry.
    /// @param reserveManager_ Reserve manager.
    /// @param treasury_ Treasury contract.
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

    /// @notice Escrows and lists a minted DGE NFT for secondary sale.
    /// @dev Listing price cannot be below the gem's primary price.
    /// @param tokenId Token to list.
    /// @param priceUsd Listing price in 18-decimal USD.
    function list(uint256 tokenId, uint256 priceUsd) external nonReentrant whenNotPaused {
        if (priceUsd == 0) revert InvalidPrice();
        uint256 gemId = _requireMintedGem(tokenId);
        GemRegistry.Gem memory gem = registry.getGem(gemId);
        if (priceUsd < gem.priceUsd) revert InvalidPrice();
        nft.safeTransferFrom(msg.sender, address(this), tokenId);
        listings[tokenId] = Listing({seller: msg.sender, priceUsd: priceUsd});
        emit Listed(tokenId, msg.sender, priceUsd);
    }

    /// @notice Cancels an active listing and returns the escrowed NFT.
    /// @param tokenId Listed token id.
    function cancel(uint256 tokenId) external nonReentrant {
        Listing memory listing = listings[tokenId];
        if (listing.seller == address(0)) revert NotListed();
        if (listing.seller != msg.sender) revert NotSeller();
        if (_activeListingBid(tokenId)) revert AuctionActive();
        delete listings[tokenId];
        delete listingAuctionEnd[tokenId];
        delete listingWinningOffer[tokenId];
        nft.safeTransferFrom(address(this), listing.seller, tokenId);
        emit ListingCancelled(tokenId);
    }

    /// @notice Purchases an active listing.
    /// @dev Buyer must pay listing price plus any reserve shortfall.
    /// @param tokenId Listed token id.
    /// @param paymentAsset Payment asset, or address(0) for native ETH.
    /// @param amount Maximum payment amount; must equal `msg.value` for native ETH.
    function buy(uint256 tokenId, address paymentAsset, uint256 amount) external payable nonReentrant whenNotPaused {
        Listing memory listing = listings[tokenId];
        if (listing.seller == address(0)) revert NotListed();
        if (_activeListingBid(tokenId)) revert AuctionActive();
        delete listings[tokenId];
        delete listingAuctionEnd[tokenId];
        delete listingWinningOffer[tokenId];

        reserveManager.requireSolvent();
        uint256 gemId = nft.tokenGem(tokenId);
        _requireMintedGemId(gemId);
        uint256 gemPriceUsd = registry.getGem(gemId).priceUsd;
        uint256 reserveUsd = reserveManager.shortfallUsd(gemId, gemPriceUsd);
        uint256 requiredAmount = _collectFixedPayment(paymentAsset, amount, listing.priceUsd + reserveUsd);

        uint256 reserveAmount = _proRataAmountRoundUp(requiredAmount, reserveUsd, listing.priceUsd + reserveUsd);
        if (reserveAmount != 0) {
            _fundReserve(gemId, paymentAsset, reserveAmount);
            reserveManager.requireFunded(gemId, gemPriceUsd);
        }

        reserveManager.syncProjectedLiabilityUsd(gemId, gemPriceUsd);
        _settleSecondary(paymentAsset, listing.seller, requiredAmount - reserveAmount);
        nft.safeTransferFrom(address(this), msg.sender, tokenId);
        emit Purchased(
            tokenId,
            msg.sender,
            paymentAsset,
            requiredAmount,
            paymentRegistry.quoteTokenToUsd(paymentAsset, requiredAmount)
        );
    }

    function _collectFixedPayment(address paymentAsset, uint256 maximumAmount, uint256 requiredUsd)
        private
        returns (uint256 requiredAmount)
    {
        requiredAmount = paymentRegistry.quoteUsdToToken(paymentAsset, requiredUsd);
        uint256 received = _collectPayment(paymentAsset, maximumAmount);
        if (received < requiredAmount) revert PriceNotMet();
        _refundSurplus(paymentAsset, received, requiredAmount);
    }

    function _refundSurplus(address paymentAsset, uint256 received, uint256 requiredAmount) private {
        uint256 surplus = received - requiredAmount;
        if (surplus == 0) return;
        _sendPayment(msg.sender, paymentAsset, surplus);
        emit PaymentSurplusRefunded(msg.sender, paymentAsset, surplus);
    }

    /// @notice Creates a 24-hour escrowed offer for a minted NFT.
    /// @dev Payment is escrowed in this contract until accepted or expired.
    /// @param tokenId Token receiving the offer.
    /// @param paymentAsset Payment asset, or address(0) for native ETH.
    /// @param amount Offer amount.
    /// @return offerId Newly created offer id.
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
        GemRegistry.Gem memory gem = registry.getGem(gemId);
        uint256 reserveUsd = reserveManager.shortfallUsd(gemId, gem.priceUsd);
        if (usdValue <= reserveUsd) revert PriceNotMet();
        uint256 saleUsdValue = usdValue - reserveUsd;
        Listing memory listing = listings[tokenId];
        if (listing.seller == msg.sender) revert NotSeller();

        uint256 previousOfferId;
        uint64 expiry;
        if (listing.seller != address(0)) {
            previousOfferId = listingWinningOffer[tokenId];
            Offer memory previous = offers[previousOfferId];
            if (previousOfferId == 0 || !previous.active) {
                if (saleUsdValue < listing.priceUsd) revert BidTooLow();
                // forge-lint: disable-next-line(unsafe-typecast)
                expiry = uint64(block.timestamp + OFFER_DURATION);
            } else {
                expiry = listingAuctionEnd[tokenId];
                if (block.timestamp >= expiry) revert Expired();
                if (saleUsdValue < previous.saleUsdValue + MIN_BID_INCREMENT_USD) revert BidTooLow();
            }
        } else {
            // forge-lint: disable-next-line(unsafe-typecast)
            expiry = uint64(block.timestamp + OFFER_DURATION);
        }

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

        if (listing.seller != address(0)) {
            listingWinningOffer[tokenId] = offerId;
            listingAuctionEnd[tokenId] = expiry;
            if (previousOfferId == 0) {
                emit ListingAuctionStarted(tokenId, offerId, expiry);
            } else {
                Offer memory previous = offers[previousOfferId];
                delete offers[previousOfferId];
                _refundOrCredit(previous.bidder, previous.paymentAsset, previous.amount);
                emit OfferCancelled(previousOfferId);
                emit ListingBidOutbid(tokenId, previousOfferId, offerId);
            }
        }
    }

    /// @notice Cancels and refunds an expired offer.
    /// @param offerId Offer id to cancel.
    function cancelExpiredOffer(uint256 offerId) external nonReentrant {
        Offer memory offer = offers[offerId];
        if (!offer.active) revert InvalidOffer();
        if (block.timestamp <= offer.expiry) revert NotExpired();
        if (listingWinningOffer[offer.tokenId] == offerId) revert AuctionActive();
        delete offers[offerId];
        _sendPayment(offer.bidder, offer.paymentAsset, offer.amount);
        emit OfferCancelled(offerId);
    }

    /// @notice Accepts an active offer and transfers the NFT to the bidder.
    /// @dev Seller receives sale proceeds less secondary fee; reserve shortfall is funded first.
    /// @param offerId Offer id to accept.
    function acceptOffer(uint256 offerId) external nonReentrant whenNotPaused {
        Offer memory offer = offers[offerId];
        if (!offer.active) revert InvalidOffer();
        if (listingWinningOffer[offer.tokenId] == offerId) revert AuctionActive();
        if (block.timestamp > offer.expiry) revert Expired();
        if (nft.ownerOf(offer.tokenId) != msg.sender) revert NotSeller();
        delete offers[offerId];

        reserveManager.requireSolvent();
        uint256 gemId = nft.tokenGem(offer.tokenId);
        _requireMintedGemId(gemId);
        GemRegistry.Gem memory gem = registry.getGem(gemId);
        uint256 reserveUsd = reserveManager.shortfallUsd(gemId, gem.priceUsd);
        uint256 requiredUsd = offer.saleUsdValue + reserveUsd;
        uint256 currentEscrowUsd = paymentRegistry.quoteTokenToUsd(offer.paymentAsset, offer.amount);
        if (currentEscrowUsd < requiredUsd) revert PriceNotMet();

        uint256 reserveAmount = _proRataAmountRoundUp(offer.amount, reserveUsd, currentEscrowUsd);
        uint256 saleAmount = offer.amount - reserveAmount;
        if (reserveAmount != 0) {
            _fundReserve(gemId, offer.paymentAsset, reserveAmount);
            reserveManager.requireFunded(gemId, gem.priceUsd);
        }

        reserveManager.syncProjectedLiabilityUsd(gemId, gem.priceUsd);
        _settleSecondary(offer.paymentAsset, msg.sender, saleAmount);
        nft.safeTransferFrom(msg.sender, offer.bidder, offer.tokenId);
        emit OfferAccepted(offerId, msg.sender);
    }

    /// @notice Settles the winning bid on an escrowed listing after 24 hours.
    /// @dev Permissionless so a scheduler or either party may finalize it. If a
    /// fresh oracle quote no longer covers the sale plus reserve shortfall, the
    /// bidder is refunded and the token remains listed for a new auction.
    function settleListingAuction(uint256 tokenId) external nonReentrant whenNotPaused returns (bool sold) {
        Listing memory listing = listings[tokenId];
        if (listing.seller == address(0)) revert NotListed();
        uint256 offerId = listingWinningOffer[tokenId];
        Offer memory offer = offers[offerId];
        if (offerId == 0 || !offer.active) revert InvalidOffer();
        uint64 endTime = listingAuctionEnd[tokenId];
        if (block.timestamp < endTime) revert AuctionNotEnded();

        return _finalizeListingAuction(tokenId, offerId);
    }

    function _finalizeListingAuction(uint256 tokenId, uint256 offerId) private returns (bool sold) {
        Offer memory offer = offers[offerId];
        uint256 gemId = nft.tokenGem(tokenId);
        _requireMintedGemId(gemId);
        GemRegistry.Gem memory gem = registry.getGem(gemId);
        uint256 reserveUsd = reserveManager.shortfallUsd(gemId, gem.priceUsd);
        (bool quoted, uint256 currentEscrowUsd) = _quotePayment(offer.paymentAsset, offer.amount);

        uint256 requiredUsd = offer.saleUsdValue + reserveUsd;
        if (!quoted || currentEscrowUsd < requiredUsd) {
            _refundListingAuction(tokenId, offerId);
            return false;
        }

        _completeListingAuction(
            ListingSettlement({
                tokenId: tokenId,
                offerId: offerId,
                gemId: gemId,
                gemPriceUsd: gem.priceUsd,
                reserveUsd: reserveUsd,
                currentEscrowUsd: currentEscrowUsd
            })
        );
        return true;
    }

    function _completeListingAuction(ListingSettlement memory settlement) private {
        Listing memory listing = listings[settlement.tokenId];
        Offer memory offer = offers[settlement.offerId];
        uint256 reserveAmount = _proRataAmountRoundUp(offer.amount, settlement.reserveUsd, settlement.currentEscrowUsd);
        uint256 saleAmount = offer.amount - reserveAmount;

        delete listings[settlement.tokenId];
        delete offers[settlement.offerId];
        delete listingWinningOffer[settlement.tokenId];
        delete listingAuctionEnd[settlement.tokenId];

        if (reserveAmount != 0) {
            _fundReserve(settlement.gemId, offer.paymentAsset, reserveAmount);
            reserveManager.requireFunded(settlement.gemId, settlement.gemPriceUsd);
        }
        reserveManager.syncProjectedLiabilityUsd(settlement.gemId, settlement.gemPriceUsd);
        _settleSecondary(offer.paymentAsset, listing.seller, saleAmount);
        nft.safeTransferFrom(address(this), offer.bidder, settlement.tokenId);

        emit OfferAccepted(settlement.offerId, listing.seller);
        emit ListingAuctionSettled(
            settlement.tokenId, settlement.offerId, offer.bidder, offer.paymentAsset, offer.amount, offer.saleUsdValue
        );
    }

    function _refundListingAuction(uint256 tokenId, uint256 offerId) private {
        Offer memory offer = offers[offerId];
        delete offers[offerId];
        delete listingWinningOffer[tokenId];
        delete listingAuctionEnd[tokenId];
        _refundOrCredit(offer.bidder, offer.paymentAsset, offer.amount);
        emit ListingAuctionRefunded(tokenId, offerId, offer.bidder, offer.paymentAsset, offer.amount);
    }

    /// @notice Claims a refund that could not be pushed to the wallet.
    function claimRefund(address asset) external nonReentrant {
        uint256 amount = pendingRefunds[msg.sender][asset];
        if (amount == 0) revert InvalidAmount();
        pendingRefunds[msg.sender][asset] = 0;
        _sendPayment(msg.sender, asset, amount);
        emit RefundClaimed(msg.sender, asset, amount);
    }

    /// @notice Sets secondary marketplace fee BPS.
    /// @param feeBps Fee in basis points.
    function setSecondaryFeeBps(uint16 feeBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (feeBps > BPS_DENOMINATOR) revert InvalidFee();
        secondaryFeeBps = feeBps;
        emit SecondaryFeeUpdated(feeBps);
    }

    /// @notice Sets secondary marketplace fee recipient.
    /// @param recipient Fee recipient address.
    function setSecondaryFeeRecipient(address recipient) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (recipient == address(0)) revert InvalidAddress();
        secondaryFeeRecipient = recipient;
        emit SecondaryFeeRecipientUpdated(recipient);
    }

    /// @notice Pauses listing purchases and offer creation/acceptance.
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /// @notice Unpauses marketplace operations.
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /// @notice Accepts safe transfers only from the configured DGE NFT contract.
    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        if (msg.sender != address(nft)) revert InvalidAddress();
        return IERC721Receiver.onERC721Received.selector;
    }

    /// @dev Collects native or ERC-20 payment from caller and returns net received amount.
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

    /// @dev Settles secondary sale proceeds between seller and fee recipient.
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

    /// @dev Transfers reserve funds to ReserveManager and records quoted reserve funding.
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

    /// @dev Calculates a floored pro-rata amount.
    function _proRataAmount(uint256 amount, uint256 shareUsd, uint256 totalUsd) private pure returns (uint256) {
        if (shareUsd == 0) return 0;
        return (amount * shareUsd) / totalUsd;
    }

    /// @dev Calculates a rounded-up pro-rata amount for reserve protection.
    function _proRataAmountRoundUp(uint256 amount, uint256 shareUsd, uint256 totalUsd) private pure returns (uint256) {
        if (shareUsd == 0) return 0;
        return (amount * shareUsd + totalUsd - 1) / totalUsd;
    }

    /// @dev Sends native or ERC-20 payment.
    function _sendPayment(address to, address paymentAsset, uint256 amount) private {
        if (amount == 0) return;
        if (paymentAsset == address(0)) {
            (bool ok,) = payable(to).call{value: amount}("");
            if (!ok) revert TransferFailed();
            return;
        }
        IERC20(paymentAsset).safeTransfer(to, amount);
    }

    /// @dev Pushes losing bids back immediately without letting a hostile
    /// receiver block the higher bid. A failed push remains claimable.
    function _refundOrCredit(address to, address paymentAsset, uint256 amount) private {
        if (amount == 0) return;
        if (_tryPayment(to, paymentAsset, amount)) {
            emit RefundSent(to, paymentAsset, amount);
            return;
        }
        pendingRefunds[to][paymentAsset] += amount;
        emit RefundCredited(to, paymentAsset, amount);
    }

    function _tryPayment(address to, address paymentAsset, uint256 amount) private returns (bool) {
        if (paymentAsset == address(0)) {
            (bool sent,) = payable(to).call{value: amount}("");
            return sent;
        }
        (bool called, bytes memory result) = paymentAsset.call(abi.encodeCall(IERC20.transfer, (to, amount)));
        if (!called) return false;
        if (result.length == 0) return true;
        if (result.length < 32) return false;
        // Do not ABI-decode an untrusted token response here: a non-canonical
        // boolean would itself revert and defeat the pull-credit fallback.
        uint256 returned;
        assembly ("memory-safe") {
            returned := mload(add(result, 32))
        }
        return returned != 0;
    }

    function _activeListingBid(uint256 tokenId) private view returns (bool) {
        uint256 offerId = listingWinningOffer[tokenId];
        return offerId != 0 && offers[offerId].active;
    }

    function _quotePayment(address paymentAsset, uint256 amount) private view returns (bool ok, uint256 usdValue) {
        try paymentRegistry.quoteTokenToUsd(paymentAsset, amount) returns (uint256 quotedUsdValue) {
            ok = true;
            usdValue = quotedUsdValue;
        } catch {
            ok = false;
        }
    }

    /// @dev Returns token's gem id and requires the gem to be in minted status.
    function _requireMintedGem(uint256 tokenId) private view returns (uint256 gemId) {
        gemId = nft.tokenGem(tokenId);
        _requireMintedGemId(gemId);
    }

    /// @dev Reverts unless the gem is in minted status.
    function _requireMintedGemId(uint256 gemId) private view {
        GemRegistry.Gem memory gem = registry.getGem(gemId);
        if (gem.status != GemRegistry.GemStatus.Minted) revert GemNotMinted();
    }

    receive() external payable {}

    /// @dev Authorizes UUPS upgrades for `UPGRADER_ROLE` holders.
    function _authorizeUpgrade(address) internal override onlyRole(Roles.UPGRADER_ROLE) {}
}
