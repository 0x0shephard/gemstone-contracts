// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
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
}
