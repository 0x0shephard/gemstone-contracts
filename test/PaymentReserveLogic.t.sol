// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PaymentTokenRegistry} from "../src/PaymentTokenRegistry.sol";
import {ReserveManager} from "../src/ReserveManager.sol";
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

    function testFeeOnTransferReserveFundingRecordsNetReceived() public {
        vm.startPrank(buyer);
        feeToken.approve(address(reserveManager), 100e18);
        reserveManager.fundToken(1, address(feeToken), 100e18);
        vm.stopPrank();

        assertEq(reserveManager.reserveAssetBalance(1, address(feeToken)), 90e18);
        assertEq(reserveManager.reserveBalanceUsd(1), 90e18);
        assertEq(feeToken.balanceOf(feeCollector), 10e18);
    }

    function testReserveConsumptionRequiresAvailableBalance() public {
        reserveManager.setMinimumReserveUsd(1, 100e18);

        vm.expectRevert(abi.encodeWithSelector(ReserveManager.ReserveShortfall.selector, 1e18, 0));
        reserveManager.consumeReserveUsd(1, 1e18);

        reserveManager.recordModuleFunding{value: 0.05 ether}(1, address(0), 0.05 ether, 100e18);
        reserveManager.consumeReserveUsd(1, 40e18);

        assertEq(reserveManager.reserveBalanceUsd(1), 60e18);
    }

    function testReserveBracketReadApi() public {
        _setTwoTierReservePolicy();

        assertEq(reserveManager.reserveBracketCount(), 2);
        ReserveManager.ReserveBracket memory first = reserveManager.reserveBracket(0);
        assertEq(first.minPriceUsd, 0);
        assertEq(first.maxPriceUsd, 1_000e18);
        assertEq(first.reserveBps, 1_000);
    }
}
