// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PaymentTokenRegistry} from "../src/PaymentTokenRegistry.sol";
import {ReserveManager} from "../src/ReserveManager.sol";
import {GemRegistry} from "../src/GemRegistry.sol";
import {BaseTest} from "./BaseTest.t.sol";

contract PaymentReserveLogicTest is BaseTest {
    function testRemovedPaymentTokenCannotBeQuotedOrUsed() public {
        payments.removeToken(address(usdc));

        vm.expectRevert(PaymentTokenRegistry.TokenNotEnabled.selector);
        payments.quoteTokenToUsd(address(usdc), 1_000e6);

        uint256 gemId = _listedGem(1_000e18, "ipfs://removed-token");
        vm.startPrank(buyer);
        usdc.approve(address(sale), 1_000e6);
        vm.expectRevert(PaymentTokenRegistry.TokenNotEnabled.selector);
        sale.buyNow(gemId, address(usdc), 1_000e6);
        vm.stopPrank();
    }

    function testStaleOracleRevertsPricing() public {
        vm.warp(10 days);

        vm.expectRevert(PaymentTokenRegistry.StalePrice.selector);
        payments.quoteTokenToUsd(address(0), 1 ether);
    }

    function testNegativeOracleAnswerRevertsPricing() public {
        ethFeed.updateAnswer(-1);

        vm.expectRevert(PaymentTokenRegistry.InvalidPrice.selector);
        payments.quoteTokenToUsd(address(0), 1 ether);
    }

    function testIncompleteOracleRoundAndBoundsRevertPricing() public {
        ethFeed.setRoundData(2, 2_000e8, block.timestamp, 1);
        vm.expectRevert(PaymentTokenRegistry.StalePrice.selector);
        payments.quoteTokenToUsd(address(0), 1 ether);

        ethFeed.setRoundData(2, 2_000e8, 0, 2);
        vm.expectRevert(PaymentTokenRegistry.StalePrice.selector);
        payments.quoteTokenToUsd(address(0), 1 ether);

        ethFeed.setRoundData(3, 2_000e8, block.timestamp, 3);
        payments.setTokenBounds(address(0), 1_500e8, 2_500e8);
        assertEq(payments.quoteTokenToUsd(address(0), 1 ether), 2_000e18);

        ethFeed.updateAnswer(3_000e8);
        vm.expectRevert(PaymentTokenRegistry.InvalidPrice.selector);
        payments.quoteTokenToUsd(address(0), 1 ether);
    }

    function testFeeOnTransferReserveFundingRecordsNetReceived() public {
        uint256 gemId = _listedGem(1_000e18, "ipfs://fee-reserve");
        vm.startPrank(buyer);
        feeToken.approve(address(reserveManager), 100e18);
        reserveManager.fundToken(gemId, address(feeToken), 100e18);
        vm.stopPrank();

        assertEq(reserveManager.reserveAssetBalance(gemId, address(feeToken)), 90e18);
        assertEq(reserveManager.reserveBalanceUsd(gemId), 90e18);
        assertEq(feeToken.balanceOf(feeCollector), 10e18);
    }

    function testReserveFundingRejectsUnknownGemIds() public {
        vm.prank(buyer);
        vm.expectRevert(GemRegistry.InvalidGem.selector);
        reserveManager.fundNative{value: 1 ether}(999);

        vm.expectRevert(GemRegistry.InvalidGem.selector);
        reserveManager.recordModuleFunding{value: 1 ether}(999, address(0), 1 ether, 2_000e18);
    }

    function testReserveConsumptionRequiresAvailableBalance() public {
        uint256 gemId = _listedGem(1_000e18, "ipfs://consume-reserve");
        reserveManager.setMinimumReserveUsd(gemId, 100e18);

        vm.expectRevert(abi.encodeWithSelector(ReserveManager.ReserveShortfall.selector, 1e18, 0));
        reserveManager.consumeReserveUsd(gemId, 1e18);

        reserveManager.recordModuleFunding{value: 0.05 ether}(gemId, address(0), 0.05 ether, 100e18);
        reserveManager.consumeReserveUsd(gemId, 40e18);

        assertEq(reserveManager.reserveBalanceUsd(gemId), 60e18);
    }

    function testReasonedReserveConsumptionUpdatesAggregateBalance() public {
        uint256 gemId = _listedGem(1_000e18, "ipfs://reasoned-consume");
        reserveManager.recordModuleFunding{value: 0.05 ether}(gemId, address(0), 0.05 ether, 100e18);

        reserveManager.consumeReserveUsdFor(gemId, 25e18, keccak256("vault-fee"));

        assertEq(reserveManager.reserveBalanceUsd(gemId), 75e18);
        assertEq(reserveManager.totalReserveBalanceUsd(), 75e18);
    }

    function testCoverageRatioAndSolvencyGuard() public {
        uint256 trackedGemId = _listedGem(1_000e18, "ipfs://tracked-liability");
        reserveManager.recordModuleFunding{value: 0.05 ether}(trackedGemId, address(0), 0.05 ether, 100e18);
        reserveManager.setProjectedLiabilityUsd(trackedGemId, 200e18);

        assertEq(reserveManager.coverageRatioBps(), 5_000);

        reserveManager.setMinimumCoverageBps(6_000);
        reserveManager.setGlobalSolvencyCheckEnabled(true);

        uint256 gemId = _listedGem(1_000e18, "ipfs://insolvent");
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(ReserveManager.Insolvent.selector, 5_000, 6_000));
        sale.buyNow{value: 0.5 ether}(gemId, address(0), 0.5 ether);

        reserveManager.setGlobalSolvencyCheckEnabled(false);
        vm.prank(buyer);
        uint256 tokenId = sale.buyNow{value: 0.5 ether}(gemId, address(0), 0.5 ether);
        assertEq(nft.ownerOf(tokenId), buyer);
    }

    function testSolvencyRejectsCrossSubsidizedUnderfundedGem() public {
        uint256 overfundedGemId = _listedGem(1_000e18, "ipfs://overfunded");
        uint256 underfundedGemId = _listedGem(1_000e18, "ipfs://underfunded");

        reserveManager.recordModuleFunding{value: 0.1 ether}(overfundedGemId, address(0), 0.1 ether, 200e18);
        reserveManager.setProjectedLiabilityUsd(overfundedGemId, 100e18);
        reserveManager.setProjectedLiabilityUsd(underfundedGemId, 100e18);

        assertEq(reserveManager.coverageRatioBps(), 10_000);
        assertTrue(reserveManager.isUnderfunded(underfundedGemId));
        vm.expectRevert(abi.encodeWithSelector(ReserveManager.UnderfundedReserves.selector, 1));
        reserveManager.requireSolvent();

        reserveManager.recordModuleFunding{value: 0.05 ether}(underfundedGemId, address(0), 0.05 ether, 100e18);
        reserveManager.requireSolvent();
    }

    function testMintSyncsProjectedLiabilityAndRedemptionClearsIt() public {
        _setTwoTierReservePolicy();
        uint256 gemId = _listedGem(1_000e18, "ipfs://liability-sync");

        vm.prank(buyer);
        uint256 tokenId = sale.buyNow{value: 0.52 ether}(gemId, address(0), 0.52 ether);

        assertEq(reserveManager.projectedLiabilityUsd(gemId), 40e18);
        assertEq(reserveManager.totalProjectedLiabilitiesUsd(), 40e18);

        vm.prank(buyer);
        redemption.requestRedemption(tokenId, keccak256("liability-clear"));
        vm.prank(custodian);
        redemption.confirmRedemption(tokenId);

        assertEq(reserveManager.projectedLiabilityUsd(gemId), 0);
        assertEq(reserveManager.totalProjectedLiabilitiesUsd(), 0);
    }

    function testReserveBracketReadApi() public {
        _setTwoTierReservePolicy();

        assertEq(reserveManager.reserveBracketCount(), 2);
        ReserveManager.ReserveBracket memory first = reserveManager.reserveBracket(0);
        assertEq(first.minPriceUsd, 0);
        assertEq(first.maxPriceUsd, 1_000e18);
        assertEq(first.reserveBps, 1_000);
    }

    function testReserveBracketTableMustCoverTopRange() public {
        ReserveManager.ReserveBracket[] memory brackets = new ReserveManager.ReserveBracket[](1);
        brackets[0] = ReserveManager.ReserveBracket({minPriceUsd: 0, maxPriceUsd: 1_000e18, reserveBps: 1_000});

        vm.expectRevert(ReserveManager.InvalidReserveBracket.selector);
        reserveManager.setReserveBrackets(brackets);
    }
}
