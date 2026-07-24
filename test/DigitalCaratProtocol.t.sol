// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {GemRegistry} from "../src/GemRegistry.sol";
import {DGENFT} from "../src/DGENFT.sol";
import {Marketplace} from "../src/Marketplace.sol";
import {PrimarySaleAuction} from "../src/PrimarySaleAuction.sol";
import {ReserveManager} from "../src/ReserveManager.sol";
import {Roles} from "../src/libraries/Roles.sol";
import {BaseTest} from "./BaseTest.t.sol";

contract DigitalCaratProtocolTest is BaseTest {
    function testBuyNowRequiresMintingGates() public {
        uint256 gemId = registry.registerGem(seller, custodian, "ipfs://gem-1", keccak256("cert-1"));

        vm.prank(buyer);
        vm.expectRevert(PrimarySaleAuction.GemNotMintable.selector);
        sale.buyNow{value: 0.5 ether}(gemId, address(0), 0.5 ether);
    }

    function testBuyNowNativeEthMintsAndSettles() public {
        uint256 gemId = _listedGem(1_000e18, "ipfs://gem-1");

        uint256 sellerBefore = seller.balance;
        vm.prank(buyer);
        uint256 tokenId = sale.buyNow{value: 0.5 ether}(gemId, address(0), 0.5 ether);

        assertEq(nft.ownerOf(tokenId), buyer);
        assertEq(nft.tokenGem(tokenId), gemId);
        assertEq(seller.balance - sellerBefore, 0.4 ether);
        assertEq(platform.balance, 0.04 ether);
        assertEq(vaultReserve.balance, 0.03 ether);
        assertEq(insuranceReserve.balance, 0.02 ether);
        assertEq(treasuryReserve.balance, 0.01 ether);

        GemRegistry.Gem memory gem = registry.getGem(gemId);
        assertEq(uint256(gem.status), uint256(GemRegistry.GemStatus.Minted));
    }

    function testBuyNowRefundsExcessNativeEth() public {
        uint256 gemId = _listedGem(1_000e18, "ipfs://gem-native-refund");
        uint256 buyerBefore = buyer.balance;

        vm.prank(buyer);
        uint256 tokenId = sale.buyNow{value: 0.75 ether}(gemId, address(0), 0.75 ether);

        assertEq(nft.ownerOf(tokenId), buyer);
        assertEq(buyerBefore - buyer.balance, 0.5 ether);
        assertEq(address(sale).balance, 0);
    }

    function testBuyNowRefundsExcessUsdc() public {
        uint256 gemId = _listedGem(1_000e18, "ipfs://gem-usdc-refund");
        uint256 buyerBefore = usdc.balanceOf(buyer);

        vm.startPrank(buyer);
        usdc.approve(address(sale), 1_250e6);
        uint256 tokenId = sale.buyNow(gemId, address(usdc), 1_250e6);
        vm.stopPrank();

        assertEq(nft.ownerOf(tokenId), buyer);
        assertEq(buyerBefore - usdc.balanceOf(buyer), 1_000e6);
        assertEq(usdc.balanceOf(address(sale)), 0);
    }

    function testFeeOnTransferTokenUsesActualReceivedForPricing() public {
        uint256 gemId = _listedGem(900e18, "ipfs://gem-fee");
        uint256 paymentAmount = 1_000e18;

        vm.startPrank(buyer);
        feeToken.approve(address(sale), paymentAmount);
        uint256 tokenId = sale.buyNow(gemId, address(feeToken), paymentAmount);
        vm.stopPrank();

        assertEq(nft.ownerOf(tokenId), buyer);
        assertGt(feeToken.balanceOf(seller), 0);
        assertGt(feeToken.balanceOf(feeCollector), 0);
    }

    function testBuyNowRequiresAndFundsReserveShortfall() public {
        uint256 gemId = _listedGem(1_000e18, "ipfs://gem-reserve");
        reserveManager.setMinimumReserveUsd(gemId, 100e18);

        vm.prank(buyer);
        vm.expectRevert(PrimarySaleAuction.BidTooLow.selector);
        sale.buyNow{value: 0.5 ether}(gemId, address(0), 0.5 ether);

        uint256 sellerBefore = seller.balance;
        vm.prank(buyer);
        uint256 tokenId = sale.buyNow{value: 0.55 ether}(gemId, address(0), 0.55 ether);

        assertEq(nft.ownerOf(tokenId), buyer);
        assertEq(seller.balance - sellerBefore, 0.4 ether);
        assertEq(reserveManager.reserveBalanceUsd(gemId), 100e18);
        assertEq(reserveManager.reserveAssetBalance(gemId, address(0)), 0.05 ether);
    }

    function testReserveBracketsChargeHigherPercentageForLowValueGems() public {
        ReserveManager.ReserveBracket[] memory brackets = new ReserveManager.ReserveBracket[](2);
        brackets[0] = ReserveManager.ReserveBracket({minPriceUsd: 0, maxPriceUsd: 1_000e18, reserveBps: 1_000});
        brackets[1] =
            ReserveManager.ReserveBracket({minPriceUsd: 1_000e18, maxPriceUsd: type(uint256).max, reserveBps: 400});
        reserveManager.setReserveBrackets(brackets);

        assertEq(reserveManager.reserveBpsFor(800e18), 1_000);
        assertEq(reserveManager.reserveBpsFor(2_000e18), 400);
        assertEq(reserveManager.requiredReserveUsd(0, 800e18), 80e18);
        assertEq(reserveManager.requiredReserveUsd(0, 2_000e18), 80e18);

        uint256 gemId = _listedGem(800e18, "ipfs://gem-bracket-low");
        vm.prank(buyer);
        vm.expectRevert(PrimarySaleAuction.BidTooLow.selector);
        sale.buyNow{value: 0.4 ether}(gemId, address(0), 0.4 ether);

        vm.prank(buyer);
        uint256 tokenId = sale.buyNow{value: 0.44 ether}(gemId, address(0), 0.44 ether);

        assertEq(nft.ownerOf(tokenId), buyer);
        assertEq(reserveManager.reserveBalanceUsd(gemId), 80e18);
        assertEq(reserveManager.reserveAssetBalance(gemId, address(0)), 0.04 ether);
    }

    function testInvalidReserveBracketTableReverts() public {
        ReserveManager.ReserveBracket[] memory brackets = new ReserveManager.ReserveBracket[](2);
        brackets[0] = ReserveManager.ReserveBracket({minPriceUsd: 0, maxPriceUsd: 1_000e18, reserveBps: 1_000});
        brackets[1] = ReserveManager.ReserveBracket({minPriceUsd: 2_000e18, maxPriceUsd: 3_000e18, reserveBps: 400});

        vm.expectRevert(ReserveManager.InvalidReserveBracket.selector);
        reserveManager.setReserveBrackets(brackets);
    }

    function testAuctionRefundsPreviousBidAndSettles() public {
        uint256 gemId = _listedGem(1_000e18, "ipfs://gem-auction");
        sale.createAuction(gemId, 1_000e18, uint64(block.timestamp), uint64(block.timestamp + 1 days));

        uint256 buyerBefore = buyer.balance;
        vm.prank(buyer);
        sale.bid{value: 0.5 ether}(gemId, address(0), 0.5 ether);

        vm.prank(bidder);
        sale.bid{value: 0.6 ether}(gemId, address(0), 0.6 ether);

        assertEq(sale.pendingRefunds(buyer, address(0)), 0.5 ether);
        vm.prank(buyer);
        sale.claimRefund(address(0));
        assertEq(buyer.balance, buyerBefore);

        vm.warp(block.timestamp + 1 days);
        ethFeed.updateAnswer(2_000e8);
        uint256 tokenId = sale.settleAuction(gemId);
        assertEq(nft.ownerOf(tokenId), bidder);
        assertEq(seller.balance, 0.48 ether);
    }

    function testAuctionSettlementRechecksReserveShortfall() public {
        uint256 gemId = _listedGem(1_000e18, "ipfs://gem-auction-reserve-recheck");
        sale.createAuction(gemId, 1_000e18, uint64(block.timestamp), uint64(block.timestamp + 1 days));

        uint256 bidderBefore = bidder.balance;
        vm.prank(bidder);
        sale.bid{value: 0.5 ether}(gemId, address(0), 0.5 ether);

        reserveManager.setMinimumReserveUsd(gemId, 100e18);
        vm.warp(block.timestamp + 1 days);

        uint256 tokenId = sale.settleAuction(gemId);
        assertEq(tokenId, 0);
        assertEq(sale.pendingRefunds(bidder, address(0)), 0.5 ether);

        vm.prank(bidder);
        sale.claimRefund(address(0));
        assertEq(bidder.balance, bidderBefore);

        ethFeed.updateAnswer(2_000e8);
        sale.createAuction(gemId, 1_000e18, uint64(block.timestamp), uint64(block.timestamp + 1 days));
        vm.prank(bidder);
        sale.bid{value: 0.55 ether}(gemId, address(0), 0.55 ether);
        vm.warp(block.timestamp + 1 days);
        ethFeed.updateAnswer(2_000e8);

        uint256 settledTokenId = sale.settleAuction(gemId);
        assertEq(nft.ownerOf(settledTokenId), bidder);
        assertEq(reserveManager.reserveBalanceUsd(gemId), 100e18);
    }

    function testAuctionSettlementFundsCurrentReserveShortfallFromEscrow() public {
        uint256 gemId = _listedGem(1_000e18, "ipfs://gem-auction-reserve-funded");
        reserveManager.setMinimumReserveUsd(gemId, 100e18);
        sale.createAuction(gemId, 1_000e18, uint64(block.timestamp), uint64(block.timestamp + 1 days));

        vm.prank(bidder);
        sale.bid{value: 0.6 ether}(gemId, address(0), 0.6 ether);

        vm.warp(block.timestamp + 1 days);
        ethFeed.updateAnswer(2_000e8);
        uint256 tokenId = sale.settleAuction(gemId);

        assertEq(nft.ownerOf(tokenId), bidder);
        assertEq(reserveManager.reserveBalanceUsd(gemId), 100e18);
        assertEq(reserveManager.reserveAssetBalance(gemId, address(0)), 0.05 ether);
    }

    function testExactReserveMinimumDoesNotRevertFromRounding() public {
        uint256 gemId = _listedGem(999e18, "ipfs://gem-rounding");
        reserveManager.setMinimumReserveUsd(gemId, 1e18);

        vm.prank(buyer);
        uint256 tokenId = sale.buyNow{value: 0.5 ether}(gemId, address(0), 0.5 ether);

        assertEq(nft.ownerOf(tokenId), buyer);
        assertGe(reserveManager.reserveBalanceUsd(gemId), 1e18);
    }

    function testDailyAuctionUsesTwentyFourHourDuration() public {
        uint256 gemId = _listedGem(1_000e18, "ipfs://gem-daily-auction");

        sale.createDailyAuction(gemId, 1_000e18);

        (,, uint64 startTime, uint64 endTime,,,,,,) = sale.auctions(gemId);
        assertEq(startTime, uint64(block.timestamp));
        assertEq(endTime, uint64(block.timestamp + 1 days));
    }

    function testBatchSettlementSkipsIneligibleAuctions() public {
        uint256 bidGemId = _listedGem(1_000e18, "ipfs://gem-batch-settle");
        uint256 noBidGemId = _listedGem(1_000e18, "ipfs://gem-batch-skip");
        sale.createDailyAuction(bidGemId, 1_000e18);
        sale.createDailyAuction(noBidGemId, 1_000e18);

        vm.prank(bidder);
        sale.bid{value: 0.5 ether}(bidGemId, address(0), 0.5 ether);

        uint256[] memory gemIds = new uint256[](2);
        gemIds[0] = bidGemId;
        gemIds[1] = noBidGemId;

        vm.warp(block.timestamp + 1 days);
        ethFeed.updateAnswer(2_000e8);
        uint256 settledCount = sale.settleExpiredAuctions(gemIds);

        assertEq(settledCount, 1);
        assertEq(nft.ownerOf(nft.tokenForGem(bidGemId)), bidder);
        (bool exists, bool settled,,,,,,,,) = sale.auctions(noBidGemId);
        assertTrue(exists);
        assertFalse(settled);
    }

    function testBatchSettlementRejectsOversizedInput() public {
        uint256[] memory gemIds = new uint256[](sale.MAX_BATCH_SETTLEMENTS() + 1);

        vm.expectRevert(PrimarySaleAuction.BatchTooLarge.selector);
        sale.settleExpiredAuctions(gemIds);
    }

    function testAuctionOutbidDoesNotDependOnInlineNativeRefund() public {
        uint256 gemId = _listedGem(1_000e18, "ipfs://gem-auction-pin");
        sale.createAuction(gemId, 1_000e18, uint64(block.timestamp), uint64(block.timestamp + 1 days));

        RevertingRefundBidder attacker = new RevertingRefundBidder(sale);
        vm.deal(address(attacker), 1 ether);
        attacker.bid{value: 0.5 ether}(gemId);

        vm.prank(bidder);
        sale.bid{value: 0.6 ether}(gemId, address(0), 0.6 ether);

        assertEq(sale.pendingRefunds(address(attacker), address(0)), 0.5 ether);
    }

    function testCannotCancelAuctionOnceBidExists() public {
        uint256 gemId = _listedGem(1_000e18, "ipfs://gem-auction-cancel");
        sale.createAuction(gemId, 1_000e18, uint64(block.timestamp), uint64(block.timestamp + 1 days));

        vm.prank(buyer);
        sale.bid{value: 0.5 ether}(gemId, address(0), 0.5 ether);

        vm.expectRevert(PrimarySaleAuction.AuctionActive.selector);
        sale.cancelAuction(gemId);

        vm.warp(block.timestamp + 1 days);
        sale.cancelAuction(gemId);
        assertEq(sale.pendingRefunds(buyer, address(0)), 0.5 ether);
    }

    function testAuctionRefundsHighestBidIfGemBecomesUnmintable() public {
        uint256 gemId = _listedGem(1_000e18, "ipfs://gem-auction-withdrawn");
        sale.createAuction(gemId, 1_000e18, uint64(block.timestamp), uint64(block.timestamp + 1 days));

        vm.prank(buyer);
        sale.bid{value: 0.5 ether}(gemId, address(0), 0.5 ether);

        registry.withdrawListedGem(gemId, keccak256("withdraw-during-auction"));
        vm.warp(block.timestamp + 1 days);

        assertEq(sale.settleAuction(gemId), 0);
        assertEq(sale.pendingRefunds(buyer, address(0)), 0.5 ether);
    }

    function testAuctionRefundsHighestBidIfPaymentTokenRemoved() public {
        uint256 gemId = _listedGem(1_000e18, "ipfs://gem-auction-token-removed");
        sale.createAuction(gemId, 1_000e18, uint64(block.timestamp), uint64(block.timestamp + 1 days));

        vm.startPrank(buyer);
        usdc.approve(address(sale), 1_000e6);
        sale.bid(gemId, address(usdc), 1_000e6);
        vm.stopPrank();

        payments.removeToken(address(usdc));
        vm.warp(block.timestamp + 1 days);

        assertEq(sale.settleAuction(gemId), 0);
        assertEq(sale.pendingRefunds(buyer, address(usdc)), 1_000e6);
    }

    function testBuyNowDuringLiveAuctionMintsAndAuctionBidIsRefundable() public {
        uint256 gemId = _listedGem(1_000e18, "ipfs://gem-auction-buy-now-race");
        sale.createAuction(gemId, 1_000e18, uint64(block.timestamp), uint64(block.timestamp + 1 days));

        vm.prank(bidder);
        sale.bid{value: 0.5 ether}(gemId, address(0), 0.5 ether);

        vm.prank(buyer);
        uint256 tokenId = sale.buyNow{value: 0.5 ether}(gemId, address(0), 0.5 ether);
        assertEq(nft.ownerOf(tokenId), buyer);

        vm.warp(block.timestamp + 1 days);
        assertEq(sale.settleAuction(gemId), 0);
        assertEq(sale.pendingRefunds(bidder, address(0)), 0.5 ether);
    }

    function testRedemptionLocksAndBurnsToken() public {
        uint256 gemId = _listedGem(1_000e18, "ipfs://gem-redeem");
        vm.prank(buyer);
        uint256 tokenId = sale.buyNow{value: 0.5 ether}(gemId, address(0), 0.5 ether);

        vm.prank(buyer);
        redemption.requestRedemption(tokenId, keccak256("pickup"));

        vm.prank(buyer);
        vm.expectRevert(DGENFT.TokenLocked.selector);
        nft.transferFrom(buyer, bidder, tokenId);

        vm.prank(custodian);
        redemption.confirmRedemption(tokenId);
        vm.expectRevert();
        nft.ownerOf(tokenId);

        GemRegistry.Gem memory gem = registry.getGem(gemId);
        assertEq(uint256(gem.status), uint256(GemRegistry.GemStatus.Redeemed));
    }

    function testRedemptionRequiresReserveFunding() public {
        uint256 gemId = _listedGem(1_000e18, "ipfs://gem-redeem-reserve");
        vm.prank(buyer);
        uint256 tokenId = sale.buyNow{value: 0.5 ether}(gemId, address(0), 0.5 ether);

        reserveManager.setMinimumReserveUsd(gemId, 100e18);

        vm.prank(buyer);
        vm.expectRevert();
        redemption.requestRedemption(tokenId, keccak256("pickup"));

        vm.prank(buyer);
        reserveManager.fundNative{value: 0.05 ether}(gemId);

        vm.prank(buyer);
        redemption.requestRedemption(tokenId, keccak256("pickup"));

        assertTrue(nft.transferLocked(tokenId));
    }

    function testMarketplaceEscrowsAndSellsDgeNft() public {
        uint256 gemId = _listedGem(1_000e18, "ipfs://gem-market");
        vm.prank(buyer);
        uint256 tokenId = sale.buyNow{value: 0.5 ether}(gemId, address(0), 0.5 ether);

        vm.startPrank(buyer);
        nft.approve(address(marketplace), tokenId);
        marketplace.list(tokenId, 1_000e18);
        vm.stopPrank();

        uint256 buyerUsdcBefore = usdc.balanceOf(buyer);
        vm.startPrank(bidder);
        usdc.approve(address(marketplace), 1_000e6);
        marketplace.buy(tokenId, address(usdc), 1_000e6);
        vm.stopPrank();

        assertEq(nft.ownerOf(tokenId), bidder);
        assertEq(usdc.balanceOf(buyer) - buyerUsdcBefore, 980e6);
        assertEq(usdc.balanceOf(platform), 20e6);
        assertEq(usdc.balanceOf(vaultReserve), 0);
        assertEq(usdc.balanceOf(insuranceReserve), 0);
        assertEq(usdc.balanceOf(treasuryReserve), 0);
    }

    function testMarketplaceRefundsExcessNativeEth() public {
        uint256 gemId = _listedGem(1_000e18, "ipfs://gem-market-native-refund");
        vm.prank(buyer);
        uint256 tokenId = sale.buyNow{value: 0.5 ether}(gemId, address(0), 0.5 ether);

        vm.startPrank(buyer);
        nft.approve(address(marketplace), tokenId);
        marketplace.list(tokenId, 1_000e18);
        vm.stopPrank();

        uint256 bidderBefore = bidder.balance;
        vm.prank(bidder);
        marketplace.buy{value: 0.75 ether}(tokenId, address(0), 0.75 ether);

        assertEq(nft.ownerOf(tokenId), bidder);
        assertEq(bidderBefore - bidder.balance, 0.5 ether);
        assertEq(address(marketplace).balance, 0);
    }

    function testMarketplaceRefundsExcessUsdc() public {
        uint256 gemId = _listedGem(1_000e18, "ipfs://gem-market-usdc-refund");
        vm.prank(buyer);
        uint256 tokenId = sale.buyNow{value: 0.5 ether}(gemId, address(0), 0.5 ether);

        vm.startPrank(buyer);
        nft.approve(address(marketplace), tokenId);
        marketplace.list(tokenId, 1_000e18);
        vm.stopPrank();

        uint256 bidderBefore = usdc.balanceOf(bidder);
        vm.startPrank(bidder);
        usdc.approve(address(marketplace), 1_250e6);
        marketplace.buy(tokenId, address(usdc), 1_250e6);
        vm.stopPrank();

        assertEq(nft.ownerOf(tokenId), bidder);
        assertEq(bidderBefore - usdc.balanceOf(bidder), 1_000e6);
        assertEq(usdc.balanceOf(address(marketplace)), 0);
    }

    function testMarketplaceBuyerFundsReserveShortfall() public {
        uint256 gemId = _listedGem(1_000e18, "ipfs://gem-market-reserve");
        vm.prank(buyer);
        uint256 tokenId = sale.buyNow{value: 0.5 ether}(gemId, address(0), 0.5 ether);
        reserveManager.setMinimumReserveUsd(gemId, 100e18);

        vm.startPrank(buyer);
        nft.approve(address(marketplace), tokenId);
        marketplace.list(tokenId, 1_000e18);
        vm.stopPrank();

        vm.startPrank(bidder);
        usdc.approve(address(marketplace), 1_100e6);
        vm.expectRevert(Marketplace.PriceNotMet.selector);
        marketplace.buy(tokenId, address(usdc), 1_000e6);
        marketplace.buy(tokenId, address(usdc), 1_100e6);
        vm.stopPrank();

        assertEq(nft.ownerOf(tokenId), bidder);
        assertEq(reserveManager.reserveBalanceUsd(gemId), 100e18);
        assertEq(reserveManager.reserveAssetBalance(gemId, address(usdc)), 100e6);
    }

    function testSwapEscrowSwapsDgeOnly() public {
        uint256 firstGemId = _listedGem(1_000e18, "ipfs://gem-swap-a");
        vm.prank(buyer);
        uint256 firstTokenId = sale.buyNow{value: 0.5 ether}(firstGemId, address(0), 0.5 ether);

        uint256 secondGemId = _listedGem(1_000e18, "ipfs://gem-swap-b");
        vm.prank(bidder);
        uint256 secondTokenId = sale.buyNow{value: 0.5 ether}(secondGemId, address(0), 0.5 ether);

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

    function testSwapEscrowWithCashDelta() public {
        uint256 firstGemId = _listedGem(1_000e18, "ipfs://gem-swap-cash-a");
        vm.prank(buyer);
        uint256 firstTokenId = sale.buyNow{value: 0.5 ether}(firstGemId, address(0), 0.5 ether);

        uint256 secondGemId = _listedGem(1_000e18, "ipfs://gem-swap-cash-b");
        vm.prank(bidder);
        uint256 secondTokenId = sale.buyNow{value: 0.5 ether}(secondGemId, address(0), 0.5 ether);

        vm.startPrank(buyer);
        nft.approve(address(swapEscrow), firstTokenId);
        uint256 offerId = swapEscrow.createOffer(
            firstTokenId, secondTokenId, address(usdc), 100e6, false, uint64(block.timestamp + 1 days)
        );
        vm.stopPrank();

        uint256 buyerUsdcBefore = usdc.balanceOf(buyer);
        vm.startPrank(bidder);
        nft.approve(address(swapEscrow), secondTokenId);
        usdc.approve(address(swapEscrow), 100e6);
        swapEscrow.acceptOffer(offerId);
        vm.stopPrank();

        assertEq(nft.ownerOf(firstTokenId), bidder);
        assertEq(nft.ownerOf(secondTokenId), buyer);
        assertEq(usdc.balanceOf(buyer) - buyerUsdcBefore, 100e6);
    }

    function testSwapAcceptRechecksRequestedGemReserve() public {
        uint256 firstGemId = _listedGem(1_000e18, "ipfs://gem-swap-reserve-a");
        vm.prank(buyer);
        uint256 firstTokenId = sale.buyNow{value: 0.5 ether}(firstGemId, address(0), 0.5 ether);

        uint256 secondGemId = _listedGem(1_000e18, "ipfs://gem-swap-reserve-b");
        vm.prank(bidder);
        uint256 secondTokenId = sale.buyNow{value: 0.5 ether}(secondGemId, address(0), 0.5 ether);

        vm.startPrank(buyer);
        nft.approve(address(swapEscrow), firstTokenId);
        uint256 offerId =
            swapEscrow.createOffer(firstTokenId, secondTokenId, address(0), 0, false, uint64(block.timestamp + 1 days));
        vm.stopPrank();

        reserveManager.setMinimumReserveUsd(secondGemId, 100e18);

        vm.startPrank(bidder);
        nft.approve(address(swapEscrow), secondTokenId);
        vm.expectRevert();
        swapEscrow.acceptOffer(offerId);
        vm.stopPrank();
    }

    function testOnlyRecordedCustodianCanConfirmCustody() public {
        address otherCustodian = address(0x351);
        registry.grantRole(Roles.CUSTODIAN_ROLE, otherCustodian);
        uint256 gemId = registry.registerGem(seller, custodian, "ipfs://gem-custody", keccak256("custody"));

        vm.prank(otherCustodian);
        vm.expectRevert(GemRegistry.NotGemCustodian.selector);
        registry.confirmCustody(gemId);

        vm.prank(custodian);
        registry.confirmCustody(gemId);
    }
}

contract RevertingRefundBidder {
    PrimarySaleAuction private immutable _SALE;

    constructor(PrimarySaleAuction sale_) {
        _SALE = sale_;
    }

    function bid(uint256 gemId) external payable {
        _SALE.bid{value: msg.value}(gemId, address(0), msg.value);
    }

    receive() external payable {
        revert("refund blocked");
    }
}
