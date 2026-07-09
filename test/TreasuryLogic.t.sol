// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Treasury} from "../src/Treasury.sol";
import {BaseTest} from "./BaseTest.t.sol";

contract TreasuryLogicTest is BaseTest {
    function testAdminCanUpdateSplitsAndRecipients() public {
        treasury.setSplits(
            Treasury.Splits({
                sellerBps: 7_500,
                platformBps: 1_000,
                vaultReserveBps: 700,
                insuranceReserveBps: 500,
                treasuryReserveBps: 300
            })
        );

        address newPlatform = address(0xA01);
        treasury.setRecipients(newPlatform, vaultReserve, insuranceReserve, treasuryReserve);

        uint256 gemId = _listedGem(1_000e18, "ipfs://custom-splits");
        vm.prank(buyer);
        sale.buyNow{value: 0.5 ether}(gemId, address(0), 0.5 ether);

        assertEq(seller.balance, 0.375 ether);
        assertEq(newPlatform.balance, 0.05 ether);
        assertEq(vaultReserve.balance, 0.035 ether);
        assertEq(insuranceReserve.balance, 0.025 ether);
        assertEq(treasuryReserve.balance, 0.015 ether);
    }

    function testInvalidTreasurySplitsRevert() public {
        vm.expectRevert(Treasury.InvalidSplits.selector);
        treasury.setSplits(
            Treasury.Splits({
                sellerBps: 8_000,
                platformBps: 800,
                vaultReserveBps: 600,
                insuranceReserveBps: 400,
                treasuryReserveBps: 199
            })
        );
    }

    function testZeroRecipientReverts() public {
        vm.expectRevert(Treasury.InvalidAddress.selector);
        treasury.setRecipients(address(0), vaultReserve, insuranceReserve, treasuryReserve);
    }

    function testNonSettlerCannotSettleTreasury() public {
        vm.prank(stranger);
        vm.expectRevert();
        treasury.settleNative{value: 1 ether}(seller);
    }

    function testSettleNativeRejectsZeroSeller() public {
        vm.expectRevert(Treasury.InvalidAddress.selector);
        treasury.settleNative{value: 1 ether}(address(0));
    }

    function testSettleTokenRejectsZeroSeller() public {
        usdc.mint(address(treasury), 1e6);

        vm.expectRevert(Treasury.InvalidAddress.selector);
        treasury.settleToken(address(usdc), address(0), 1e6);
    }

    function testSettleTokenRequiresTreasuryBalance() public {
        vm.expectRevert(Treasury.InsufficientBalance.selector);
        treasury.settleToken(address(usdc), seller, 1e6);
    }

    function testZeroValueTokenDistributionStillSettles() public {
        usdc.mint(address(treasury), 1);
        treasury.setSplits(
            Treasury.Splits({
                sellerBps: 0, platformBps: 10_000, vaultReserveBps: 0, insuranceReserveBps: 0, treasuryReserveBps: 0
            })
        );

        treasury.settleToken(address(usdc), seller, 1);

        assertEq(usdc.balanceOf(seller), 0);
        assertEq(usdc.balanceOf(platform), 1);
    }
}
