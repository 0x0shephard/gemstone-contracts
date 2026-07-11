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
        uint256 saleAmount = _proRataAmount(received, gem.priceUsd, usdValue);
        uint256 reserveAmount = received - saleAmount;
        if (reserveAmount != 0) {
            _fundReserve(gemId, paymentAsset, reserveAmount);
            reserveManager.requireFunded(gemId, gem.priceUsd);
        }

        tokenId = nft.mintTo(msg.sender, gemId, gem.metadataURI);
        registry.markMinted(gemId, tokenId);
        _settle(paymentAsset, gem.seller, saleAmount);

        emit BuyNow(gemId, tokenId, msg.sender, paymentAsset, received, usdValue);
    }

    function createAuction(uint256 gemId, uint256 floorUsd, uint64 startTime, uint64 endTime)
        external
        whenNotPaused
        onlyRole(Roles.LISTER_ROLE)
    {
        _createAuction(gemId, floorUsd, startTime, endTime);
    }

    function createDailyAuction(uint256 gemId, uint256 floorUsd) external whenNotPaused onlyRole(Roles.LISTER_ROLE) {
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 startTime = uint64(block.timestamp);
        _createAuction(gemId, floorUsd, startTime, startTime + DAILY_AUCTION_DURATION);
    }

    function _createAuction(uint256 gemId, uint256 floorUsd, uint64 startTime, uint64 endTime) private {
        if (!registry.canMint(gemId)) revert GemNotMintable();
        if (floorUsd == 0 || endTime <= startTime || endTime <= block.timestamp) revert InvalidAuction();
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

    function bid(uint256 gemId, address paymentAsset, uint256 amount) external payable nonReentrant whenNotPaused {
        Auction storage auction = auctions[gemId];
        if (!auction.exists || auction.settled) revert InvalidAuction();
        if (block.timestamp < auction.startTime) revert InvalidAuction();
        if (block.timestamp >= auction.endTime) revert AuctionEnded();
        reserveManager.requireSolvent();

        uint256 received = _collectPayment(paymentAsset, amount);
        uint256 usdValue = paymentRegistry.quoteTokenToUsd(paymentAsset, received);
        uint256 reserveUsd = reserveManager.shortfallUsd(gemId, auction.floorUsd);
        if (usdValue < auction.floorUsd + reserveUsd) revert BidTooLow();
        uint256 saleUsd = usdValue - reserveUsd;
        if (saleUsd <= auction.usdValue) revert BidTooLow();

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

    function settleAuction(uint256 gemId) external nonReentrant whenNotPaused returns (uint256 tokenId) {
        Auction storage auction = auctions[gemId];
        if (!auction.exists || auction.settled) revert InvalidAuction();
        if (block.timestamp < auction.endTime) revert AuctionNotEnded();
        if (auction.highestBidder == address(0)) revert InvalidAuction();
        if (!registry.canMint(gemId)) revert GemNotMintable();
        reserveManager.requireSolvent();

        GemRegistry.Gem memory gem = registry.getGem(gemId);
        uint256 currentReserveUsd = reserveManager.shortfallUsd(gemId, auction.floorUsd);
        uint256 requiredUsd = auction.usdValue + currentReserveUsd;
        uint256 currentEscrowUsd = paymentRegistry.quoteTokenToUsd(auction.paymentAsset, auction.amount);
        if (currentEscrowUsd < requiredUsd) revert BidTooLow();

        auction.settled = true;
        auction.reserveUsd = currentReserveUsd;
        uint256 saleAmount = _proRataAmount(auction.amount, auction.usdValue, requiredUsd);
        uint256 reserveAmount = auction.amount - saleAmount;
        if (reserveAmount != 0) {
            _fundReserve(gemId, auction.paymentAsset, reserveAmount);
        }
        reserveManager.requireFunded(gemId, auction.floorUsd);

        tokenId = nft.mintTo(auction.highestBidder, gemId, gem.metadataURI);
        registry.markMinted(gemId, tokenId);
        _settle(auction.paymentAsset, gem.seller, saleAmount);

        emit AuctionSettled(gemId, tokenId, auction.highestBidder, auction.paymentAsset, auction.amount);
    }

    function settleExpiredAuctions(uint256[] calldata gemIds) external whenNotPaused returns (uint256 settledCount) {
        for (uint256 i = 0; i < gemIds.length; i++) {
            try this.settleAuction(gemIds[i]) returns (uint256) {
                settledCount++;
            } catch (bytes memory reason) {
                emit AuctionSettlementSkipped(gemIds[i], reason);
            }
        }
    }

    function cancelAuction(uint256 gemId) external nonReentrant onlyRole(Roles.LISTER_ROLE) {
        Auction storage auction = auctions[gemId];
        if (!auction.exists || auction.settled) revert InvalidAuction();
        if (auction.highestBidder != address(0)) revert AuctionActive();

        address bidder = auction.highestBidder;
        address asset = auction.paymentAsset;
        uint256 amount = auction.amount;
        delete auctions[gemId];

        if (bidder != address(0)) _creditRefund(bidder, asset, amount);
        emit AuctionCancelled(gemId);
    }

    function claimRefund(address asset) external nonReentrant {
        uint256 amount = pendingRefunds[msg.sender][asset];
        if (amount == 0) revert InvalidAmount();
        pendingRefunds[msg.sender][asset] = 0;
        _refund(msg.sender, asset, amount);
        emit RefundClaimed(msg.sender, asset, amount);
    }

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
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

    function _settle(address paymentAsset, address seller, uint256 amount) private {
        if (amount == 0) return;
        if (paymentAsset == address(0)) {
            treasury.settleNative{value: amount}(seller);
            return;
        }

        uint256 beforeBalance = IERC20(paymentAsset).balanceOf(address(treasury));
        IERC20(paymentAsset).safeTransfer(address(treasury), amount);
        uint256 receivedByTreasury = IERC20(paymentAsset).balanceOf(address(treasury)) - beforeBalance;
        treasury.settleToken(paymentAsset, seller, receivedByTreasury);
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

    function _refund(address to, address paymentAsset, uint256 amount) private {
        if (amount == 0) return;
        if (paymentAsset == address(0)) {
            (bool ok,) = payable(to).call{value: amount}("");
            if (!ok) revert TransferFailed();
            return;
        }
        IERC20(paymentAsset).safeTransfer(to, amount);
    }

    function _creditRefund(address to, address paymentAsset, uint256 amount) private {
        if (amount == 0) return;
        pendingRefunds[to][paymentAsset] += amount;
        emit RefundCredited(to, paymentAsset, amount);
    }

    receive() external payable {}

    function _authorizeUpgrade(address) internal override onlyRole(Roles.UPGRADER_ROLE) {}
}
