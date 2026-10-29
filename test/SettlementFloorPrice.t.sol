// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Marketplace} from "../src/Marketplace.sol";
import {PaymentTokenRegistry} from "../src/PaymentTokenRegistry.sol";
import {PrimarySaleAuction} from "../src/PrimarySaleAuction.sol";
import {BaseTest} from "./BaseTest.t.sol";
import {MockV3Aggregator} from "./mocks/MockV3Aggregator.sol";

/// @dev Settlement used to require the escrow to still be worth its bid-time USD value, so any
///      downward feed tick between bid and settlement voided the sale (and let a binding bidder
///      escape by settling during a dip). Settlement now requires only the floor or ask plus the
///      current reserve shortfall; acceptOffer requires only the reserve shortfall.
contract SettlementFloorPriceTest is BaseTest {
    /// @dev ETH/USD down one cent from the 2,000.00 the bids were placed at.
    int256 internal constant ETH_ONE_CENT_DIP = 1_999_99_000_000;
    /// @dev USDC/USD down one basis point from 1.0000.
    int256 internal constant USDC_ONE_BP_DIP = 99_990_000;

    event AuctionSettlementRefunded(
        uint256 indexed gemId, address indexed bidder, address indexed paymentAsset, uint256 amount, bytes32 reasonHash
    );
    event ListingAuctionRefunded(
        uint256 indexed tokenId, uint256 indexed offerId, address indexed bidder, address paymentAsset, uint256 amount
    );

    // ---------------------------------------------------------------- helpers

    function _feeds(int256 ethUsd, int256 usdcUsd) private {
        ethFeed.updateAnswer(ethUsd);
        usdFeed.updateAnswer(usdcUsd);
    }

    function _auctionWithEthBid(string memory uri, uint256 floorUsd, uint256 bidWei) private returns (uint256 gemId) {
        gemId = _listedAuctionGem(1_000e18, uri);
        sale.createDailyAuction(gemId, floorUsd);
        vm.prank(bidder);
        sale.bid{value: bidWei}(gemId, address(0), bidWei);
        vm.warp(block.timestamp + sale.DAILY_AUCTION_DURATION());
    }

    function _auctionWithUsdcBid(string memory uri, uint256 floorUsd, uint256 bidUsdc) private returns (uint256 gemId) {
        gemId = _listedAuctionGem(1_000e18, uri);
        sale.createDailyAuction(gemId, floorUsd);
        vm.startPrank(bidder);
        usdc.approve(address(sale), bidUsdc);
        sale.bid(gemId, address(usdc), bidUsdc);
        vm.stopPrank();
        vm.warp(block.timestamp + sale.DAILY_AUCTION_DURATION());
    }

    function _listFromBuyer(string memory uri, uint256 askUsd) private returns (uint256 gemId, uint256 tokenId) {
        (gemId, tokenId) = _mintGemTo(buyer, 1_000e18, uri);
        vm.startPrank(buyer);
        nft.approve(address(marketplace), tokenId);
        marketplace.list(tokenId, askUsd);
        vm.stopPrank();
    }

    function _endListingAuction(uint256 tokenId) private {
        vm.warp(marketplace.listingAuctionEnd(tokenId));
    }

    function _assertPrimarySold(uint256 gemId, uint256 tokenId) private view {
        assertGt(tokenId, 0, "auction must mint");
        assertEq(nft.ownerOf(tokenId), bidder);
        assertEq(nft.tokenForGem(gemId), tokenId);
        (, bool settled,,,, address highestBidder,,,,) = sale.auctions(gemId);
        assertTrue(settled);
        assertEq(highestBidder, bidder);
    }

    // ------------------------------------------------- primary auction settle

    function testPrimaryAuctionSettlesAfterOneCentEthDip() public {
        // $1,200 bid on a $1,000 floor. The old rule required the full $1,200 at settlement.
        uint256 gemId = _auctionWithEthBid("ipfs://floor-eth-dip", 1_000e18, 0.6 ether);
        _feeds(ETH_ONE_CENT_DIP, 1e8);

        // The leading bidder settling during the dip can no longer escape a binding bid.
        vm.prank(bidder);
        uint256 tokenId = sale.settleAuction(gemId);

        _assertPrimarySold(gemId, tokenId);
        assertEq(sale.pendingRefunds(bidder, address(0)), 0);
        assertEq(address(sale).balance, 0);
    }

    function testPrimaryAuctionSettlesAfterOneBpUsdcDip() public {
        uint256 gemId = _auctionWithUsdcBid("ipfs://floor-usdc-dip", 1_000e18, 1_200e6);
        _feeds(2_000e8, USDC_ONE_BP_DIP);

        uint256 tokenId = sale.settleAuction(gemId);

        _assertPrimarySold(gemId, tokenId);
        assertEq(usdc.balanceOf(address(sale)), 0);
        assertEq(usdc.balanceOf(seller), 960e6);
    }

    function testPrimaryBatchSweepSettlesAfterADip() public {
        uint256 gemId = _auctionWithEthBid("ipfs://floor-eth-dip-batch", 1_000e18, 0.6 ether);
        _feeds(ETH_ONE_CENT_DIP, 1e8);

        uint256[] memory gemIds = new uint256[](1);
        gemIds[0] = gemId;
        assertEq(sale.settleExpiredAuctions(gemIds), 1);
        assertEq(nft.ownerOf(nft.tokenForGem(gemId)), bidder);
    }

    function testPrimaryAuctionRefundsWhenEscrowFallsBelowTheFloor() public {
        // Bid exactly at the floor: one cent down is now below it.
        uint256 gemId = _auctionWithEthBid("ipfs://floor-eth-below", 1_000e18, 0.5 ether);
        _feeds(ETH_ONE_CENT_DIP, 1e8);
        uint256 bidderBefore = bidder.balance;

        vm.expectEmit(true, true, true, true, address(sale));
        emit AuctionSettlementRefunded(
            gemId, bidder, address(0), 0.5 ether, keccak256("INSUFFICIENT_SETTLEMENT_ESCROW")
        );
        assertEq(sale.settleAuction(gemId), 0);

        assertEq(bidder.balance - bidderBefore, 0.5 ether);
        assertEq(nft.tokenForGem(gemId), 0);
        assertTrue(registry.canMint(gemId));
    }

    function testPrimaryAuctionRefundsOnALargeDropBelowTheFloor() public {
        // $1,200 bid; ETH falls 20% so the escrow is worth $960 against a $1,000 floor.
        uint256 gemId = _auctionWithEthBid("ipfs://floor-eth-crash", 1_000e18, 0.6 ether);
        _feeds(1_600e8, 1e8);

        assertEq(sale.settleAuction(gemId), 0);
        assertEq(nft.tokenForGem(gemId), 0);
        assertEq(address(sale).balance, 0);
    }

    function testPrimaryAuctionUsesTheAuctionFloorNotTheGemPrice() public {
        // Floor above the gem price: $1,150 floor, $1,200 bid, ETH -5% => $1,140 escrow.
        uint256 gemId = _auctionWithEthBid("ipfs://floor-above-price", 1_150e18, 0.6 ether);
        _feeds(1_900e8, 1e8);

        assertEq(sale.settleAuction(gemId), 0, "below the auction floor even though above gem price");
        assertEq(nft.tokenForGem(gemId), 0);
    }

    function testPrimaryAuctionStillEnforcesTheReserveShortfall() public {
        _setTwoTierReservePolicy(); // $1,000 gem => 4% => $40 reserve owed at settlement.
        // $1,060 bid on a $1,000 floor. A one-cent dip still covers $1,040.
        uint256 gemId = _auctionWithEthBid("ipfs://floor-reserve-ok", 1_000e18, 0.53 ether);
        _feeds(ETH_ONE_CENT_DIP, 1e8);
        assertEq(reserveManager.shortfallUsd(gemId, 1_000e18), 40e18);

        uint256 tokenId = sale.settleAuction(gemId);
        _assertPrimarySold(gemId, tokenId);
        assertGe(reserveManager.reserveBalanceUsd(gemId), 40e18);
    }

    function testPrimaryAuctionRefundsWhenEscrowCoversTheFloorButNotTheReserve() public {
        _setTwoTierReservePolicy();
        // $1,060 bid; ETH -5% => $1,007: above the $1,000 floor, short of floor + $40 reserve.
        uint256 gemId = _auctionWithEthBid("ipfs://floor-reserve-short", 1_000e18, 0.53 ether);
        _feeds(1_900e8, 1e8);

        assertEq(sale.settleAuction(gemId), 0);
        assertEq(nft.tokenForGem(gemId), 0);
        assertEq(reserveManager.reserveBalanceUsd(gemId), 0);
    }

    // ------------------------------------------------- listing auction settle

    function testListingAuctionSettlesAfterOneCentEthDip() public {
        // $1,200 bid on a $1,100 ask. The old rule required the full $1,200 at settlement.
        (, uint256 tokenId) = _listFromBuyer("ipfs://ask-eth-dip", 1_100e18);
        vm.prank(bidder);
        uint256 offerId = marketplace.createOffer{value: 0.6 ether}(tokenId, address(0), 0.6 ether);
        _endListingAuction(tokenId);
        _feeds(ETH_ONE_CENT_DIP, 1e8);

        vm.prank(bidder);
        assertTrue(marketplace.settleListingAuction(tokenId));

        assertEq(nft.ownerOf(tokenId), bidder);
        assertEq(marketplace.listingWinningOffer(tokenId), 0);
        (,,,,,, bool active) = marketplace.offers(offerId);
        assertFalse(active);
        (address listedSeller,) = marketplace.listings(tokenId);
        assertEq(listedSeller, address(0));
    }

    function testListingAuctionSettlesAfterOneBpUsdcDip() public {
        (, uint256 tokenId) = _listFromBuyer("ipfs://ask-usdc-dip", 1_100e18);
        vm.startPrank(bidder);
        usdc.approve(address(marketplace), 1_200e6);
        marketplace.createOffer(tokenId, address(usdc), 1_200e6);
        vm.stopPrank();
        _endListingAuction(tokenId);
        _feeds(2_000e8, USDC_ONE_BP_DIP);
        uint256 sellerBefore = usdc.balanceOf(buyer);

        assertTrue(marketplace.settleListingAuction(tokenId));

        assertEq(nft.ownerOf(tokenId), bidder);
        assertEq(usdc.balanceOf(buyer) - sellerBefore, 1_176e6);
        assertEq(usdc.balanceOf(address(marketplace)), 0);
    }

    function testListingAuctionRefundsWhenEscrowFallsBelowTheAsk() public {
        // $1,200 bid on a $1,100 ask; ETH -10% => $1,080.
        (, uint256 tokenId) = _listFromBuyer("ipfs://ask-eth-below", 1_100e18);
        vm.prank(bidder);
        uint256 offerId = marketplace.createOffer{value: 0.6 ether}(tokenId, address(0), 0.6 ether);
        _endListingAuction(tokenId);
        _feeds(1_800e8, 1e8);
        uint256 bidderBefore = bidder.balance;

        vm.expectEmit(true, true, true, true, address(marketplace));
        emit ListingAuctionRefunded(tokenId, offerId, bidder, address(0), 0.6 ether);
        assertFalse(marketplace.settleListingAuction(tokenId));

        assertEq(bidder.balance - bidderBefore, 0.6 ether);
        assertEq(nft.ownerOf(tokenId), address(marketplace));
        (address listedSeller, uint256 ask) = marketplace.listings(tokenId);
        assertEq(listedSeller, buyer);
        assertEq(ask, 1_100e18);
    }

    function testListingAuctionStillEnforcesTheReserveShortfall() public {
        (uint256 gemId, uint256 tokenId) = _listFromBuyer("ipfs://ask-reserve-ok", 1_100e18);
        _setTwoTierReservePolicy(); // ~$40 reserve shortfall on a $1,000 gem.
        uint256 reserveUsd = reserveManager.shortfallUsd(gemId, 1_000e18);
        assertGt(reserveUsd, 39e18);

        // $1,160 escrow: $1,120 sale over a $1,100 ask. A one-cent dip still covers $1,140.
        vm.prank(bidder);
        marketplace.createOffer{value: 0.58 ether}(tokenId, address(0), 0.58 ether);
        _endListingAuction(tokenId);
        _feeds(ETH_ONE_CENT_DIP, 1e8);

        assertTrue(marketplace.settleListingAuction(tokenId));
        assertEq(nft.ownerOf(tokenId), bidder);
        assertGe(reserveManager.reserveBalanceUsd(gemId), 40e18);
    }

    function testListingAuctionRefundsWhenEscrowCoversTheAskButNotTheReserve() public {
        (uint256 gemId, uint256 tokenId) = _listFromBuyer("ipfs://ask-reserve-short", 1_100e18);
        _setTwoTierReservePolicy();
        vm.prank(bidder);
        marketplace.createOffer{value: 0.58 ether}(tokenId, address(0), 0.58 ether);
        _endListingAuction(tokenId);
        // $1,131: above the $1,100 ask, short of ask + ~$40 reserve.
        _feeds(1_950e8, 1e8);

        assertFalse(marketplace.settleListingAuction(tokenId));
        assertEq(nft.ownerOf(tokenId), address(marketplace));
        assertLt(reserveManager.reserveBalanceUsd(gemId), 1e18);
    }

    // ---------------------------------------------------------- acceptOffer

    function _offerFromBidder(uint256 tokenId, uint256 ethAmount) private returns (uint256 offerId) {
        vm.prank(bidder);
        offerId = marketplace.createOffer{value: ethAmount}(tokenId, address(0), ethAmount);
    }

    function _acceptAsBuyer(uint256 tokenId, uint256 offerId) private {
        vm.startPrank(buyer);
        nft.approve(address(marketplace), tokenId);
        marketplace.acceptOffer(offerId);
        vm.stopPrank();
    }

    function testAcceptOfferWorksAfterOneCentEthDip() public {
        (, uint256 tokenId) = _mintGemTo(buyer, 1_000e18, "ipfs://accept-eth-dip");
        uint256 offerId = _offerFromBidder(tokenId, 0.55 ether);
        _feeds(ETH_ONE_CENT_DIP, 1e8);
        uint256 sellerBefore = buyer.balance;

        _acceptAsBuyer(tokenId, offerId);

        assertEq(nft.ownerOf(tokenId), bidder);
        assertEq(buyer.balance - sellerBefore, 0.539 ether);
        assertEq(address(marketplace).balance, 0);
    }

    function testAcceptOfferWorksAfterOneBpUsdcDip() public {
        (, uint256 tokenId) = _mintGemTo(buyer, 1_000e18, "ipfs://accept-usdc-dip");
        vm.startPrank(bidder);
        usdc.approve(address(marketplace), 1_000e6);
        uint256 offerId = marketplace.createOffer(tokenId, address(usdc), 1_000e6);
        vm.stopPrank();
        _feeds(2_000e8, USDC_ONE_BP_DIP);
        uint256 sellerBefore = usdc.balanceOf(buyer);

        _acceptAsBuyer(tokenId, offerId);

        assertEq(nft.ownerOf(tokenId), bidder);
        assertEq(usdc.balanceOf(buyer) - sellerBefore, 980e6);
    }

    function testAcceptOfferIsTheOwnersCallEvenAfterALargeDrop() public {
        (, uint256 tokenId) = _mintGemTo(buyer, 1_000e18, "ipfs://accept-eth-crash");
        uint256 offerId = _offerFromBidder(tokenId, 0.55 ether);
        _feeds(1_200e8, 1e8); // The offer is now worth $660.

        _acceptAsBuyer(tokenId, offerId);
        assertEq(nft.ownerOf(tokenId), bidder);
    }

    function testAcceptOfferAfterADipStillFundsTheReserveShortfall() public {
        (uint256 gemId, uint256 tokenId) = _mintGemTo(buyer, 1_000e18, "ipfs://accept-reserve-ok");
        reserveManager.setMinimumReserveUsd(gemId, 100e18);
        vm.startPrank(bidder);
        usdc.approve(address(marketplace), 1_100e6);
        uint256 offerId = marketplace.createOffer(tokenId, address(usdc), 1_100e6);
        vm.stopPrank();
        _feeds(2_000e8, USDC_ONE_BP_DIP);

        _acceptAsBuyer(tokenId, offerId);

        assertEq(nft.ownerOf(tokenId), bidder);
        assertGe(reserveManager.reserveBalanceUsd(gemId), 100e18);
    }

    function testAcceptOfferRevertsWhenEscrowCannotFundTheReserveShortfall() public {
        (uint256 gemId, uint256 tokenId) = _mintGemTo(buyer, 1_000e18, "ipfs://accept-reserve-short");
        vm.startPrank(bidder);
        usdc.approve(address(marketplace), 50e6);
        uint256 offerId = marketplace.createOffer(tokenId, address(usdc), 50e6);
        vm.stopPrank();
        // A $100 reserve requirement now applies; the $50 escrow cannot fund it.
        reserveManager.setMinimumReserveUsd(gemId, 100e18);

        vm.startPrank(buyer);
        nft.approve(address(marketplace), tokenId);
        vm.expectRevert(Marketplace.PriceNotMet.selector);
        marketplace.acceptOffer(offerId);
        vm.stopPrank();

        assertEq(nft.ownerOf(tokenId), buyer);
        (,,,,,, bool active) = marketplace.offers(offerId);
        assertTrue(active, "a reverted accept leaves the offer in place");
    }

    // ------------------------------------------------------------- SwapEscrow

    function testReserveFreeSwapIsNotBlockedBySequencerOutage() public {
        (uint256 firstGemId, uint256 firstTokenId) = _mintGemTo(buyer, 1_000e18, "ipfs://swap-outage-a");
        (uint256 secondGemId, uint256 secondTokenId) = _mintGemTo(bidder, 1_000e18, "ipfs://swap-outage-b");
        assertEq(reserveManager.requiredReserveUsd(firstGemId, 1_000e18), 0);
        assertEq(reserveManager.requiredReserveUsd(secondGemId, 1_000e18), 0);

        MockV3Aggregator sequencer = new MockV3Aggregator(0, 0);
        vm.warp(30 days);
        sequencer.setRoundData(2, 0, block.timestamp - 2 hours, 2);
        payments.setSequencerUptimeFeed(address(sequencer), 1 hours);
        sequencer.setRoundData(2, 1, block.timestamp, 2); // sequencer down
        vm.expectRevert(PaymentTokenRegistry.SequencerDown.selector);
        payments.requireSequencerUp();

        vm.startPrank(buyer);
        nft.approve(address(swapEscrow), firstTokenId);
        uint256 offerId =
            swapEscrow.createOffer(firstTokenId, secondTokenId, address(0), 0, false, uint64(block.timestamp + 1 days));
        vm.stopPrank();

        vm.startPrank(bidder);
        nft.approve(address(swapEscrow), secondTokenId);
        swapEscrow.acceptOffer(offerId);
        vm.stopPrank();

        assertEq(nft.ownerOf(firstTokenId), bidder);
        assertEq(nft.ownerOf(secondTokenId), buyer);
    }

    // ------------------------------------------------------ unchanged ordering

    function testBidOrderingStillUsesBidTimeValue() public {
        uint256 gemId = _listedAuctionGem(1_000e18, "ipfs://ordering");
        sale.createDailyAuction(gemId, 1_000e18);
        vm.prank(buyer);
        sale.bid{value: 0.6 ether}(gemId, address(0), 0.6 ether);
        (,,,,,,,, uint256 leadUsd,) = sale.auctions(gemId);
        assertEq(leadUsd, 1_200e18);

        // Under $1 more than the recorded $1,200 lead is still too low.
        vm.prank(bidder);
        vm.expectRevert(PrimarySaleAuction.BidTooLow.selector);
        sale.bid{value: 0.6004 ether}(gemId, address(0), 0.6004 ether);
    }
}
