// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SwapEscrow} from "../src/SwapEscrow.sol";
import {BaseTest} from "./BaseTest.t.sol";

contract SwapEscrowLogicTest is BaseTest {
    function testCreateOfferRejectsExpiredAndSameTokenOffers() public {
        (, uint256 firstTokenId) = _mintGemTo(buyer, 1_000e18, "ipfs://swap-invalid-a");
        (, uint256 secondTokenId) = _mintGemTo(bidder, 1_000e18, "ipfs://swap-invalid-b");

        vm.startPrank(buyer);
        nft.approve(address(swapEscrow), firstTokenId);

        vm.expectRevert(SwapEscrow.InvalidOffer.selector);
        swapEscrow.createOffer(firstTokenId, firstTokenId, address(0), 0, false, uint64(block.timestamp + 1 days));

        vm.expectRevert(SwapEscrow.InvalidOffer.selector);
        swapEscrow.createOffer(firstTokenId, secondTokenId, address(0), 0, false, uint64(block.timestamp));
        vm.stopPrank();
    }

    function testCreateOfferRejectsUnexpectedNativeValue() public {
        (, uint256 firstTokenId) = _mintGemTo(buyer, 1_000e18, "ipfs://swap-native-a");
        (, uint256 secondTokenId) = _mintGemTo(bidder, 1_000e18, "ipfs://swap-native-b");

        vm.startPrank(buyer);
        nft.approve(address(swapEscrow), firstTokenId);
        vm.expectRevert(SwapEscrow.InvalidAmount.selector);
        swapEscrow.createOffer{value: 0.01 ether}(
            firstTokenId, secondTokenId, address(0), 0, false, uint64(block.timestamp + 1 days)
        );
        vm.stopPrank();
    }

    function testCancelOfferReturnsEscrowedNftAndNativeCash() public {
        (, uint256 firstTokenId) = _mintGemTo(buyer, 1_000e18, "ipfs://swap-cancel-a");
        (, uint256 secondTokenId) = _mintGemTo(bidder, 1_000e18, "ipfs://swap-cancel-b");

        uint256 buyerBefore = buyer.balance;
        vm.startPrank(buyer);
        nft.approve(address(swapEscrow), firstTokenId);
        uint256 offerId = swapEscrow.createOffer{value: 0.1 ether}(
            firstTokenId, secondTokenId, address(0), 0.1 ether, true, uint64(block.timestamp + 1 days)
        );
        assertEq(nft.ownerOf(firstTokenId), address(swapEscrow));

        swapEscrow.cancelOffer(offerId);
        vm.stopPrank();

        assertEq(nft.ownerOf(firstTokenId), buyer);
        assertEq(buyer.balance, buyerBefore);
    }

    function testOnlyProposerCanCancelActiveOffer() public {
        (, uint256 firstTokenId) = _mintGemTo(buyer, 1_000e18, "ipfs://swap-cancel-auth-a");
        (, uint256 secondTokenId) = _mintGemTo(bidder, 1_000e18, "ipfs://swap-cancel-auth-b");

        vm.startPrank(buyer);
        nft.approve(address(swapEscrow), firstTokenId);
        uint256 offerId =
            swapEscrow.createOffer(firstTokenId, secondTokenId, address(0), 0, false, uint64(block.timestamp + 1 days));
        vm.stopPrank();

        vm.prank(stranger);
        vm.expectRevert(SwapEscrow.NotProposer.selector);
        swapEscrow.cancelOffer(offerId);
    }

    function testAcceptOfferRejectsExpiredOfferWithoutDeletingIt() public {
        (, uint256 firstTokenId) = _mintGemTo(buyer, 1_000e18, "ipfs://swap-expired-a");
        (, uint256 secondTokenId) = _mintGemTo(bidder, 1_000e18, "ipfs://swap-expired-b");

        vm.startPrank(buyer);
        nft.approve(address(swapEscrow), firstTokenId);
        uint256 offerId =
            swapEscrow.createOffer(firstTokenId, secondTokenId, address(0), 0, false, uint64(block.timestamp + 1 days));
        vm.stopPrank();

        vm.warp(block.timestamp + 2 days);
        vm.startPrank(bidder);
        nft.approve(address(swapEscrow), secondTokenId);
        vm.expectRevert(SwapEscrow.Expired.selector);
        swapEscrow.acceptOffer(offerId);
        vm.stopPrank();

        (, uint256 offeredTokenId,,,,,, bool active) = swapEscrow.offers(offerId);
        assertEq(offeredTokenId, firstTokenId);
        assertTrue(active);
    }

    function testAccepterPaysNativeCashDelta() public {
        (, uint256 firstTokenId) = _mintGemTo(buyer, 1_000e18, "ipfs://swap-native-delta-a");
        (, uint256 secondTokenId) = _mintGemTo(bidder, 1_000e18, "ipfs://swap-native-delta-b");

        vm.startPrank(buyer);
        nft.approve(address(swapEscrow), firstTokenId);
        uint256 offerId = swapEscrow.createOffer(
            firstTokenId, secondTokenId, address(0), 0.1 ether, false, uint64(block.timestamp + 1 days)
        );
        vm.stopPrank();

        uint256 buyerBefore = buyer.balance;
        vm.startPrank(bidder);
        nft.approve(address(swapEscrow), secondTokenId);
        vm.expectRevert(SwapEscrow.InvalidAmount.selector);
        swapEscrow.acceptOffer{value: 0.05 ether}(offerId);

        swapEscrow.acceptOffer{value: 0.1 ether}(offerId);
        vm.stopPrank();

        assertEq(nft.ownerOf(firstTokenId), bidder);
        assertEq(nft.ownerOf(secondTokenId), buyer);
        assertEq(buyer.balance - buyerBefore, 0.1 ether);
    }

    function testProposerPaysTokenCashDeltaToAccepter() public {
        (, uint256 firstTokenId) = _mintGemTo(buyer, 1_000e18, "ipfs://swap-token-delta-a");
        (, uint256 secondTokenId) = _mintGemTo(bidder, 1_000e18, "ipfs://swap-token-delta-b");

        uint256 bidderBefore = usdc.balanceOf(bidder);
        vm.startPrank(buyer);
        nft.approve(address(swapEscrow), firstTokenId);
        usdc.approve(address(swapEscrow), 100e6);
        uint256 offerId = swapEscrow.createOffer(
            firstTokenId, secondTokenId, address(usdc), 100e6, true, uint64(block.timestamp + 1 days)
        );
        vm.stopPrank();

        vm.startPrank(bidder);
        nft.approve(address(swapEscrow), secondTokenId);
        swapEscrow.acceptOffer(offerId);
        vm.stopPrank();

        assertEq(nft.ownerOf(firstTokenId), bidder);
        assertEq(nft.ownerOf(secondTokenId), buyer);
        assertEq(usdc.balanceOf(bidder) - bidderBefore, 100e6);
    }
}
