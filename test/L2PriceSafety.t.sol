// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {DGENFT} from "../src/DGENFT.sol";
import {PaymentTokenRegistry} from "../src/PaymentTokenRegistry.sol";
import {BaseTest} from "./BaseTest.t.sol";
import {MockV3Aggregator} from "./mocks/MockV3Aggregator.sol";

contract L2PriceSafetyTest is BaseTest {
    MockV3Aggregator internal sequencer;

    /// @dev Chainlink's uptime feed answers 0 when the sequencer is up; startedAt is the last status change.
    function _sequencer(int256 status, uint256 changedAt) private {
        sequencer.setRoundData(2, status, changedAt, 2);
    }

    function _enableSequencerCheck() private {
        vm.warp(30 days);
        ethFeed.updateAnswer(2_000e8);
        usdFeed.updateAnswer(1e8);
        sequencer = new MockV3Aggregator(0, 0);
        _sequencer(0, block.timestamp - 2 hours);
        payments.setSequencerUptimeFeed(address(sequencer), 1 hours);
    }

    function testQuotesAreUnaffectedWhileNoUptimeFeedIsSet() public view {
        assertEq(address(payments.sequencerUptimeFeed()), address(0));
        assertGt(payments.quoteTokenToUsd(address(0), 1 ether), 0);
    }

    function testQuotesRevertWhileTheSequencerIsDownAndDuringGrace() public {
        _enableSequencerCheck();
        assertEq(payments.quoteTokenToUsd(address(0), 1 ether), 2_000e18);

        _sequencer(1, block.timestamp - 10 minutes);
        vm.expectRevert(PaymentTokenRegistry.SequencerDown.selector);
        payments.quoteTokenToUsd(address(0), 1 ether);
        vm.expectRevert(PaymentTokenRegistry.SequencerDown.selector);
        payments.quoteUsdToToken(address(usdc), 100e18);

        // Back up, but inside the grace period: prices may still be stale.
        _sequencer(0, block.timestamp - 30 minutes);
        vm.expectRevert(PaymentTokenRegistry.SequencerGracePeriodNotOver.selector);
        payments.quoteTokenToUsd(address(0), 1 ether);

        // Exactly at the boundary is still inside the grace period.
        _sequencer(0, block.timestamp - 1 hours);
        vm.expectRevert(PaymentTokenRegistry.SequencerGracePeriodNotOver.selector);
        payments.quoteTokenToUsd(address(0), 1 ether);

        _sequencer(0, block.timestamp - 1 hours - 1);
        assertEq(payments.quoteTokenToUsd(address(0), 1 ether), 2_000e18);
    }

    function testSequencerOutageBlocksPurchases() public {
        _enableSequencerCheck();
        uint256 gemId = _listedGem(1_000e18, "ipfs://sequencer-buy");
        _sequencer(1, block.timestamp);

        vm.prank(buyer);
        vm.expectRevert(PaymentTokenRegistry.SequencerDown.selector);
        sale.buyNow{value: 1 ether}(gemId, address(0), 1 ether);
    }

    function testUptimeFeedSetterValidatesItsInput() public {
        vm.warp(30 days);
        MockV3Aggregator feed = new MockV3Aggregator(0, 0);

        vm.expectRevert(PaymentTokenRegistry.InvalidFeed.selector);
        payments.setSequencerUptimeFeed(address(feed), 0);
        vm.expectRevert(PaymentTokenRegistry.InvalidFeed.selector);
        payments.setSequencerUptimeFeed(address(0), 1 hours);

        MockV3Aggregator notAStatusFeed = new MockV3Aggregator(8, 2_000e8);
        vm.expectRevert(PaymentTokenRegistry.InvalidFeed.selector);
        payments.setSequencerUptimeFeed(address(notAStatusFeed), 1 hours);

        vm.expectRevert();
        payments.setSequencerUptimeFeed(address(0xBEEF), 1 hours);

        bytes32 adminRole = payments.DEFAULT_ADMIN_ROLE();
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, adminRole)
        );
        payments.setSequencerUptimeFeed(address(feed), 1 hours);

        payments.setSequencerUptimeFeed(address(feed), 1 hours);
        assertEq(address(payments.sequencerUptimeFeed()), address(feed));
        assertEq(payments.sequencerGracePeriod(), 1 hours);

        payments.setSequencerUptimeFeed(address(0), 0);
        assertEq(address(payments.sequencerUptimeFeed()), address(0));
    }

    function testFundedTokenStillTransfersWhenItsPriceCannotBeRead() public {
        (uint256 gemId, uint256 tokenId) = _mintGemTo(buyer, 1_000e18, "ipfs://outage-transfer");
        _setTwoTierReservePolicy();
        assertGt(reserveManager.reserveBalanceUsd(gemId), 0);

        // A sequencer outage values every reserve at zero; the token still holds its assets.
        _enableSequencerCheck();
        _sequencer(1, block.timestamp);
        assertEq(reserveManager.reserveBalanceUsd(gemId), 0);
        assertTrue(reserveManager.hasReserveAssets(gemId));

        vm.prank(buyer);
        nft.transferFrom(buyer, bidder, tokenId);
        assertEq(nft.ownerOf(tokenId), bidder);
    }

    function testUpgradeKeepsPaymentConfigurationAndAddsTheCheckUnset() public {
        (bool enabledBefore, address feedBefore, uint48 staleBefore,,,) = payments.tokenConfig(address(usdc));
        uint256 countBefore = payments.paymentTokenCount();
        uint256 quoteBefore = payments.quoteTokenToUsd(address(usdc), 100e6);

        payments.upgradeToAndCall(address(new PaymentTokenRegistry()), bytes(""));

        (bool enabledAfter, address feedAfter, uint48 staleAfter,,,) = payments.tokenConfig(address(usdc));
        assertEq(enabledAfter, enabledBefore);
        assertEq(feedAfter, feedBefore);
        assertEq(staleAfter, staleBefore);
        assertEq(payments.paymentTokenCount(), countBefore);
        assertEq(address(payments.sequencerUptimeFeed()), address(0));
        assertEq(payments.sequencerGracePeriod(), 0);
        assertEq(payments.quoteTokenToUsd(address(usdc), 100e6), quoteBefore);
    }

    function testUninitialisedOrFutureStatusRoundsAreNotTrusted() public {
        _enableSequencerCheck();
        // Arbitrum reports startedAt == 0 for a round that has not been initialised.
        _sequencer(0, 0);
        vm.expectRevert(PaymentTokenRegistry.SequencerDown.selector);
        payments.quoteTokenToUsd(address(0), 1 ether);

        _sequencer(0, block.timestamp + 1);
        vm.expectRevert(PaymentTokenRegistry.SequencerGracePeriodNotOver.selector);
        payments.quoteTokenToUsd(address(0), 1 ether);
    }

    function testSetterAcceptsADownFeedButRejectsAPriceFeed() public {
        vm.warp(30 days);
        MockV3Aggregator down = new MockV3Aggregator(0, 1);
        payments.setSequencerUptimeFeed(address(down), 1 hours);
        assertEq(address(payments.sequencerUptimeFeed()), address(down));
        vm.expectRevert(PaymentTokenRegistry.SequencerDown.selector);
        payments.requireSequencerUp();

        // Answers 0 like an uptime feed, but has price-feed decimals.
        MockV3Aggregator zeroPrice = new MockV3Aggregator(8, 0);
        vm.expectRevert(PaymentTokenRegistry.InvalidFeed.selector);
        payments.setSequencerUptimeFeed(address(zeroPrice), 1 hours);
    }

    function testPrimaryAuctionSettlementWaitsOutAnOutageInsteadOfRefundingTheWinner() public {
        _enableSequencerCheck();
        uint256 gemId = _listedAuctionGem(1_000e18, "ipfs://outage-primary-auction");
        sale.createAuction(gemId, 1_000e18, uint64(block.timestamp), uint64(block.timestamp + 1 days));
        vm.prank(bidder);
        sale.bid{value: 0.6 ether}(gemId, address(0), 0.6 ether);

        vm.warp(block.timestamp + 1 days);
        ethFeed.updateAnswer(2_000e8);
        _sequencer(1, block.timestamp);

        vm.expectRevert(PaymentTokenRegistry.SequencerDown.selector);
        sale.settleAuction(gemId);
        // The batch sweep skips it rather than voiding it.
        uint256[] memory gemIds = new uint256[](1);
        gemIds[0] = gemId;
        assertEq(sale.settleExpiredAuctions(gemIds), 0);
        assertEq(sale.pendingRefunds(bidder, address(0)), 0);

        _sequencer(0, block.timestamp - 1 hours - 1);
        uint256 tokenId = sale.settleAuction(gemId);
        assertEq(nft.ownerOf(tokenId), bidder);
    }

    function testListingAuctionSettlementWaitsOutAnOutage() public {
        _enableSequencerCheck();
        (, uint256 tokenId) = _mintGemTo(buyer, 1_000e18, "ipfs://outage-listing-auction");
        vm.startPrank(buyer);
        nft.approve(address(marketplace), tokenId);
        marketplace.list(tokenId, 1_000e18);
        vm.stopPrank();
        vm.prank(bidder);
        marketplace.createOffer{value: 0.6 ether}(tokenId, address(0), 0.6 ether);

        vm.warp(block.timestamp + marketplace.OFFER_DURATION());
        ethFeed.updateAnswer(2_000e8);
        _sequencer(0, block.timestamp - 10 minutes);

        vm.expectRevert(PaymentTokenRegistry.SequencerGracePeriodNotOver.selector);
        marketplace.settleListingAuction(tokenId);
        assertEq(nft.ownerOf(tokenId), address(marketplace));

        vm.warp(block.timestamp + 1 hours);
        ethFeed.updateAnswer(2_000e8);
        assertTrue(marketplace.settleListingAuction(tokenId));
        assertEq(nft.ownerOf(tokenId), bidder);
    }

    function testSolvencyAndSwapChecksReportTheOutageNotAnEmptyReserve() public {
        (uint256 gemId, uint256 tokenId) = _mintGemTo(buyer, 1_000e18, "ipfs://outage-solvency");
        (, uint256 otherTokenId) = _mintGemTo(bidder, 1_000e18, "ipfs://outage-solvency-b");
        _setTwoTierReservePolicy();
        reserveManager.setProjectedLiabilityUsd(gemId, 100e18);
        _enableSequencerCheck();
        _sequencer(1, block.timestamp);

        vm.expectRevert(PaymentTokenRegistry.SequencerDown.selector);
        reserveManager.requireSolvent();

        vm.startPrank(buyer);
        nft.approve(address(swapEscrow), tokenId);
        vm.expectRevert(PaymentTokenRegistry.SequencerDown.selector);
        swapEscrow.createOffer(tokenId, otherTokenId, address(0), 0, false, uint64(block.timestamp + 1 days));
        vm.stopPrank();
    }

    function testEmptiedReserveStillBlocksTransfersUnderARate() public {
        (uint256 gemId, uint256 tokenId) = _mintGemTo(buyer, 1_000e18, "ipfs://emptied-reserve");
        _setTwoTierReservePolicy();
        reserveManager.releaseAllReserveAssets(gemId, buyer, keccak256("TEST_DEPLETION"));
        assertFalse(reserveManager.hasReserveAssets(gemId));

        vm.prank(buyer);
        vm.expectRevert(DGENFT.ZeroReserveTransfer.selector);
        nft.transferFrom(buyer, bidder, tokenId);
    }

    function testSolvencyCheckIgnoresAnOutageWhenNothingIsOwed() public {
        _enableSequencerCheck();
        _sequencer(1, block.timestamp);
        assertEq(reserveManager.totalProjectedLiabilitiesUsd(), 0);
        reserveManager.requireSolvent();
    }

    function testRedemptionRequestReportsTheOutageWhenAReserveIsOwed() public {
        (, uint256 tokenId) = _mintGemTo(buyer, 1_000e18, "ipfs://outage-redemption");
        _setTwoTierReservePolicy();
        reserveManager.setGlobalSolvencyCheckEnabled(false);
        _enableSequencerCheck();
        _sequencer(1, block.timestamp);

        vm.prank(buyer);
        vm.expectRevert(PaymentTokenRegistry.SequencerDown.selector);
        redemption.requestRedemption(tokenId, keccak256("pickup"), keccak256("outage-workflow"));
    }
}
