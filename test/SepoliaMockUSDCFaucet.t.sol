// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SepoliaMockUSDC} from "../src/mocks/SepoliaMockUSDC.sol";
import {SepoliaMockUSDCFaucet} from "../src/mocks/SepoliaMockUSDCFaucet.sol";

contract SepoliaMockUSDCFaucetTest is Test {
    SepoliaMockUSDC private token;
    SepoliaMockUSDCFaucet private faucet;

    address private alice = makeAddr("alice");

    function setUp() public {
        token = new SepoliaMockUSDC(address(this), address(this), 1_000_000e6);
        faucet = new SepoliaMockUSDCFaucet(address(this), token);
        token.transferOwnership(address(faucet));
    }

    function testClaimMintsExactlyTenThousandTokensPerCall() public {
        vm.prank(alice);
        faucet.claim();
        assertEq(token.balanceOf(alice), 10_000e6);

        vm.prank(alice);
        faucet.claim();
        assertEq(token.balanceOf(alice), 20_000e6);
    }

    function testClaimEmitsRecipientAndAmount() public {
        vm.expectEmit(true, false, false, true, address(faucet));
        emit SepoliaMockUSDCFaucet.Claimed(alice, 10_000e6);

        vm.prank(alice);
        faucet.claim();
    }

    function testPauseBlocksClaimsUntilUnpaused() public {
        faucet.pause();

        vm.prank(alice);
        vm.expectRevert();
        faucet.claim();

        faucet.unpause();
        vm.prank(alice);
        faucet.claim();
        assertEq(token.balanceOf(alice), 10_000e6);
    }

    function testAdminCanRecoverTokenOwnership() public {
        faucet.recoverTokenOwnership(address(this));
        assertEq(token.owner(), address(this));

        vm.prank(alice);
        vm.expectRevert();
        faucet.claim();
    }

    function testNonOwnerCannotPauseOrRecoverOwnership() public {
        vm.startPrank(alice);
        vm.expectRevert();
        faucet.pause();
        vm.expectRevert();
        faucet.recoverTokenOwnership(alice);
        vm.stopPrank();
    }
}
