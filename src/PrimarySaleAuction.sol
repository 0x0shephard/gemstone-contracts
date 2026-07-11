// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {DGENFT} from "./DGENFT.sol";
import {GemRegistry} from "./GemRegistry.sol";
import {PaymentTokenRegistry} from "./PaymentTokenRegistry.sol";
import {ReserveManager} from "./ReserveManager.sol";
import {Treasury} from "./Treasury.sol";
import {Roles} from "./libraries/Roles.sol";

contract PrimarySaleAuction is
    Initializable,
    AccessControlUpgradeable,
    UUPSUpgradeable,
    PausableUpgradeable,
    ReentrancyGuard
{
    using SafeERC20 for IERC20;

    struct Auction {
        bool exists;
        bool settled;
        uint64 startTime;
        uint64 endTime;
        uint256 floorUsd;
        address highestBidder;
        address paymentAsset;
        uint256 amount;
        uint256 usdValue;
        uint256 reserveUsd;
    }

    DGENFT public nft;
    GemRegistry public registry;
    PaymentTokenRegistry public paymentRegistry;
    ReserveManager public reserveManager;
    Treasury public treasury;
    uint64 public constant DAILY_AUCTION_DURATION = 1 days;
    uint256 public constant MAX_BATCH_SETTLEMENTS = 50;
    uint256 public constant MIN_BID_INCREMENT_USD = 1e18;

    mapping(uint256 gemId => Auction) public auctions;
    mapping(address account => mapping(address asset => uint256 amount)) public pendingRefunds;

    event BuyNow(
        uint256 indexed gemId,
        uint256 indexed tokenId,
        address indexed buyer,
        address paymentAsset,
        uint256 amount,
        uint256 usdValue
    );
    event AuctionCreated(uint256 indexed gemId, uint256 floorUsd, uint64 startTime, uint64 endTime);
    event BidPlaced(
        uint256 indexed gemId, address indexed bidder, address paymentAsset, uint256 amount, uint256 usdValue
    );
    event AuctionSettled(
        uint256 indexed gemId, uint256 indexed tokenId, address indexed winner, address paymentAsset, uint256 amount
    );
    event AuctionCancelled(uint256 indexed gemId);
    event AuctionSettlementRefunded(
        uint256 indexed gemId, address indexed bidder, address indexed paymentAsset, uint256 amount, bytes32 reasonHash
    );
    event RefundCredited(address indexed account, address indexed asset, uint256 amount);
    event RefundClaimed(address indexed account, address indexed asset, uint256 amount);
    event AuctionSettlementSkipped(uint256 indexed gemId, bytes reason);

    error InvalidAddress();
    error InvalidAmount();
    error InvalidAuction();
    error AuctionActive();
    error AuctionEnded();
    error AuctionNotEnded();
    error BidTooLow();
    error GemNotMintable();
    error TransferFailed();
    error BatchTooLarge();

    /// @custom:oz-upgrades-unsafe-allow constructor
    /// @dev Locks the implementation contract so only proxy instances can be initialized.
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes primary sale dependencies and roles.
    /// @param admin Account receiving default admin, upgrader, and lister roles.
    /// @param nft_ DGE NFT contract.
    /// @param registry_ Gem registry.
    /// @param paymentRegistry_ Payment registry for USD quoting.
    /// @param reserveManager_ Reserve manager.
    /// @param treasury_ Treasury settlement contract.
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
        ) revert InvalidAddress();

        __AccessControl_init();
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(Roles.UPGRADER_ROLE, admin);
        _grantRole(Roles.LISTER_ROLE, admin);

        nft = nft_;
        registry = registry_;
        paymentRegistry = paymentRegistry_;
        reserveManager = reserveManager_;
        treasury = treasury_;
    }

    /// @notice Buys a listed gem immediately and mints its NFT.
    /// @dev Buyer must pay at least gem price plus reserve shortfall.
    /// @param gemId Listed gem id.
    /// @param paymentAsset Payment asset, or address(0) for native ETH.
    /// @param amount Payment amount; must equal `msg.value` for native ETH.
    /// @return tokenId Minted token id.
    function buyNow(uint256 gemId, address paymentAsset, uint256 amount)
        external
        payable
        nonReentrant
        whenNotPaused
        returns (uint256 tokenId)
    {
        if (!registry.canMint(gemId)) revert GemNotMintable();
        reserveManager.requireSolvent();
        GemRegistry.Gem memory gem = registry.getGem(gemId);

        uint256 received = _collectPayment(paymentAsset, amount);
        uint256 usdValue = paymentRegistry.quoteTokenToUsd(paymentAsset, received);
        uint256 reserveUsd = reserveManager.shortfallUsd(gemId, gem.priceUsd);
        if (usdValue < gem.priceUsd + reserveUsd) revert BidTooLow();
        uint256 reserveAmount = _proRataAmountRoundUp(received, reserveUsd, usdValue);
        uint256 saleAmount = received - reserveAmount;
        if (reserveAmount != 0) {
            _fundReserve(gemId, paymentAsset, reserveAmount);
            reserveManager.requireFunded(gemId, gem.priceUsd);
        }

        tokenId = nft.mintTo(msg.sender, gemId, gem.metadataURI);
        registry.markMinted(gemId, tokenId);
        reserveManager.syncProjectedLiabilityUsd(gemId, gem.priceUsd);
        _settle(paymentAsset, gem.seller, saleAmount);

        emit BuyNow(gemId, tokenId, msg.sender, paymentAsset, received, usdValue);
    }

    /// @notice Creates a scheduled primary auction for a listed gem.
    /// @dev Callable only by `LISTER_ROLE`; `floorUsd` must be at least gem price.
    /// @param gemId Listed gem id.
    /// @param floorUsd Auction floor in 18-decimal USD.
    /// @param startTime Auction start timestamp.
    /// @param endTime Auction end timestamp.
    function createAuction(uint256 gemId, uint256 floorUsd, uint64 startTime, uint64 endTime)
        external
        whenNotPaused
        onlyRole(Roles.LISTER_ROLE)
    {
        _createAuction(gemId, floorUsd, startTime, endTime);
    }

    /// @notice Creates a 24-hour auction starting immediately.
    /// @param gemId Listed gem id.
    /// @param floorUsd Auction floor in 18-decimal USD.
    function createDailyAuction(uint256 gemId, uint256 floorUsd) external whenNotPaused onlyRole(Roles.LISTER_ROLE) {
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 startTime = uint64(block.timestamp);
        _createAuction(gemId, floorUsd, startTime, startTime + DAILY_AUCTION_DURATION);
    }

    /// @dev Validates and stores auction state.
    function _createAuction(uint256 gemId, uint256 floorUsd, uint64 startTime, uint64 endTime) private {
        if (!registry.canMint(gemId)) revert GemNotMintable();
        GemRegistry.Gem memory gem = registry.getGem(gemId);
        if (floorUsd == 0 || endTime <= startTime || endTime <= block.timestamp) revert InvalidAuction();
        if (floorUsd < gem.priceUsd) revert InvalidAuction();
        Auction storage auction = auctions[gemId];
        if (auction.exists && !auction.settled) revert InvalidAuction();

        auctions[gemId] = Auction({
            exists: true,
            settled: false,
            startTime: startTime,
            endTime: endTime,
            floorUsd: floorUsd,
            highestBidder: address(0),
            paymentAsset: address(0),
            amount: 0,
            usdValue: 0,
            reserveUsd: 0
        });

        emit AuctionCreated(gemId, floorUsd, startTime, endTime);
    }

    /// @notice Places a bid on an active auction.
    /// @dev Refunds any previous highest bid to pull-based `pendingRefunds`.
    /// @param gemId Auctioned gem id.
    /// @param paymentAsset Payment asset, or address(0) for native ETH.
    /// @param amount Payment amount; must equal `msg.value` for native ETH.
    function bid(uint256 gemId, address paymentAsset, uint256 amount) external payable nonReentrant whenNotPaused {
        Auction storage auction = auctions[gemId];
        if (!auction.exists || auction.settled) revert InvalidAuction();
        if (block.timestamp < auction.startTime) revert InvalidAuction();
        if (block.timestamp >= auction.endTime) revert AuctionEnded();
        reserveManager.requireSolvent();

        uint256 received = _collectPayment(paymentAsset, amount);
        uint256 usdValue = paymentRegistry.quoteTokenToUsd(paymentAsset, received);
        GemRegistry.Gem memory gem = registry.getGem(gemId);
        uint256 reserveUsd = reserveManager.shortfallUsd(gemId, gem.priceUsd);
        if (usdValue < auction.floorUsd + reserveUsd) revert BidTooLow();
        uint256 saleUsd = usdValue - reserveUsd;
        uint256 minimumSaleUsd = auction.usdValue == 0 ? auction.floorUsd : auction.usdValue + MIN_BID_INCREMENT_USD;
        if (saleUsd < minimumSaleUsd) revert BidTooLow();

        address previousBidder = auction.highestBidder;
        address previousAsset = auction.paymentAsset;
        uint256 previousAmount = auction.amount;

        auction.highestBidder = msg.sender;
        auction.paymentAsset = paymentAsset;
        auction.amount = received;
        auction.usdValue = saleUsd;
        auction.reserveUsd = reserveUsd;

        if (previousBidder != address(0)) {
            _creditRefund(previousBidder, previousAsset, previousAmount);
        }

        emit BidPlaced(gemId, msg.sender, paymentAsset, received, saleUsd);
    }

    /// @notice Settles an ended auction or refunds the highest bidder if settlement cannot mint.
    /// @param gemId Auctioned gem id.
    /// @return tokenId Minted token id, or zero when the highest bid was refunded.
    function settleAuction(uint256 gemId) external nonReentrant whenNotPaused returns (uint256 tokenId) {
        Auction storage auction = auctions[gemId];
        if (!auction.exists || auction.settled) revert InvalidAuction();
        if (block.timestamp < auction.endTime) revert AuctionNotEnded();
        if (auction.highestBidder == address(0)) revert InvalidAuction();
        if (!_canMint(gemId)) {
            _refundHighestBid(gemId, keccak256("GEM_NOT_MINTABLE"));
            return 0;
        }

        GemRegistry.Gem memory gem = registry.getGem(gemId);
        uint256 currentReserveUsd = reserveManager.shortfallUsd(gemId, gem.priceUsd);
        uint256 requiredUsd = auction.usdValue + currentReserveUsd;
        (bool quoted, uint256 currentEscrowUsd) = _quotePayment(auction.paymentAsset, auction.amount);
        if (!quoted) {
            _refundHighestBid(gemId, keccak256("PAYMENT_QUOTE_FAILED"));
            return 0;
        }
        if (currentEscrowUsd < requiredUsd) {
            _refundHighestBid(gemId, keccak256("INSUFFICIENT_SETTLEMENT_ESCROW"));
            return 0;
        }

        auction.settled = true;
        auction.reserveUsd = currentReserveUsd;
        uint256 reserveAmount = _proRataAmountRoundUp(auction.amount, currentReserveUsd, currentEscrowUsd);
        uint256 saleAmount = auction.amount - reserveAmount;
        if (reserveAmount != 0) {
            _fundReserve(gemId, auction.paymentAsset, reserveAmount);
        }
        reserveManager.requireFunded(gemId, gem.priceUsd);

        tokenId = nft.mintTo(auction.highestBidder, gemId, gem.metadataURI);
        registry.markMinted(gemId, tokenId);
        reserveManager.syncProjectedLiabilityUsd(gemId, gem.priceUsd);
        _settle(auction.paymentAsset, gem.seller, saleAmount);

        emit AuctionSettled(gemId, tokenId, auction.highestBidder, auction.paymentAsset, auction.amount);
    }

    /// @notice Attempts settlement for a bounded batch of expired auctions.
    /// @dev Failed settlements emit `AuctionSettlementSkipped` and do not revert the batch.
    /// @param gemIds Gem ids to settle.
    /// @return settledCount Number of auctions that minted an NFT.
    function settleExpiredAuctions(uint256[] calldata gemIds) external whenNotPaused returns (uint256 settledCount) {
        if (gemIds.length > MAX_BATCH_SETTLEMENTS) revert BatchTooLarge();
        for (uint256 i = 0; i < gemIds.length; i++) {
            try this.settleAuction(gemIds[i]) returns (uint256) {
                if (nft.tokenForGem(gemIds[i]) != 0) settledCount++;
            } catch (bytes memory reason) {
                emit AuctionSettlementSkipped(gemIds[i], reason);
            }
        }
    }

    /// @notice Cancels an auction and credits a refund if cancellation is allowed.
    /// @dev Live auctions with bids cannot be cancelled while the gem remains mintable.
    /// @param gemId Auctioned gem id.
    function cancelAuction(uint256 gemId) external nonReentrant onlyRole(Roles.LISTER_ROLE) {
        Auction storage auction = auctions[gemId];
        if (!auction.exists || auction.settled) revert InvalidAuction();
        if (auction.highestBidder != address(0) && block.timestamp < auction.endTime && _canMint(gemId)) {
            revert AuctionActive();
        }

        address bidder = auction.highestBidder;
        address asset = auction.paymentAsset;
        uint256 amount = auction.amount;
        delete auctions[gemId];

        if (bidder != address(0)) _creditRefund(bidder, asset, amount);
        emit AuctionCancelled(gemId);
    }

    /// @notice Claims a pending bid refund.
    /// @param asset Refund asset, or address(0) for native ETH.
    function claimRefund(address asset) external nonReentrant {
        uint256 amount = pendingRefunds[msg.sender][asset];
        if (amount == 0) revert InvalidAmount();
        pendingRefunds[msg.sender][asset] = 0;
        _refund(msg.sender, asset, amount);
        emit RefundClaimed(msg.sender, asset, amount);
    }

    /// @notice Pauses buy-now, bidding, and settlement operations.
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /// @notice Unpauses buy-now, bidding, and settlement operations.
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /// @dev Collects native or ERC-20 payment from the caller and returns net received amount.
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

    /// @dev Settles sale proceeds into Treasury.
    function _settle(address paymentAsset, address seller, uint256 amount) private {
        if (amount == 0) return;
        if (paymentAsset == address(0)) {
            treasury.settleNative{value: amount}(seller);
            return;
        }

        IERC20(paymentAsset).forceApprove(address(treasury), amount);
        treasury.settleToken(paymentAsset, seller, amount);
        IERC20(paymentAsset).forceApprove(address(treasury), 0);
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

    /// @dev Sends a pending refund to `to`.
    function _refund(address to, address paymentAsset, uint256 amount) private {
        if (amount == 0) return;
        if (paymentAsset == address(0)) {
            (bool ok,) = payable(to).call{value: amount}("");
            if (!ok) revert TransferFailed();
            return;
        }
        IERC20(paymentAsset).safeTransfer(to, amount);
    }

    /// @dev Credits a pull-based refund.
    function _creditRefund(address to, address paymentAsset, uint256 amount) private {
        if (amount == 0) return;
        pendingRefunds[to][paymentAsset] += amount;
        emit RefundCredited(to, paymentAsset, amount);
    }

    /// @dev Safely attempts payment quoting without reverting the caller.
    function _quotePayment(address paymentAsset, uint256 amount) private view returns (bool ok, uint256 usdValue) {
        try paymentRegistry.quoteTokenToUsd(paymentAsset, amount) returns (uint256 quotedUsdValue) {
            ok = true;
            usdValue = quotedUsdValue;
        } catch {
            ok = false;
            usdValue = 0;
        }
    }

    /// @dev Safely checks whether a gem is currently mintable.
    function _canMint(uint256 gemId) private view returns (bool) {
        try registry.canMint(gemId) returns (bool canMint_) {
            return canMint_;
        } catch {
            return false;
        }
    }

    /// @dev Marks an auction settled and credits the highest bid as a refund.
    function _refundHighestBid(uint256 gemId, bytes32 reasonHash) private {
        Auction storage auction = auctions[gemId];
        address bidder = auction.highestBidder;
        address asset = auction.paymentAsset;
        uint256 amount = auction.amount;
        auction.settled = true;
        auction.highestBidder = address(0);
        auction.amount = 0;
        auction.usdValue = 0;
        auction.reserveUsd = 0;
        _creditRefund(bidder, asset, amount);
        emit AuctionSettlementRefunded(gemId, bidder, asset, amount, reasonHash);
    }

    receive() external payable {}

    /// @dev Authorizes UUPS upgrades for `UPGRADER_ROLE` holders.
    function _authorizeUpgrade(address) internal override onlyRole(Roles.UPGRADER_ROLE) {}
}
