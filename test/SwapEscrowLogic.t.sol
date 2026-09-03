// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SwapEscrow} from "../src/SwapEscrow.sol";
import {BaseTest} from "./BaseTest.t.sol";

contract SwapEscrowLogicTest is BaseTest {
    function _fundSwapReserve(uint256 gemId, address funder, uint256 nativeAmount) private {
        reserveManager.setMinimumReserveUsd(gemId, 1_000e18);
        vm.prank(funder);
        reserveManager.fundNative{value: nativeAmount}(gemId);
    }

    function testSwapAllowsPartialReserveAboveTenPercent() public {
        (uint256 firstGemId, uint256 firstTokenId) = _mintGemTo(buyer, 1_000e18, "ipfs://swap-partial-a");
        (uint256 secondGemId, uint256 secondTokenId) = _mintGemTo(bidder, 1_000e18, "ipfs://swap-partial-b");
        // Native oracle is $2,000: 0.055 ETH is $110, or 11% of $1,000.
        _fundSwapReserve(firstGemId, buyer, 0.055 ether);
        _fundSwapReserve(secondGemId, bidder, 0.055 ether);

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

    function testSwapBlocksReserveAtTenPercent() public {
        (uint256 firstGemId, uint256 firstTokenId) = _mintGemTo(buyer, 1_000e18, "ipfs://swap-threshold-a");
        (uint256 secondGemId, uint256 secondTokenId) = _mintGemTo(bidder, 1_000e18, "ipfs://swap-threshold-b");
        // 0.05 ETH is exactly $100, or 10% of the configured requirement.
        _fundSwapReserve(firstGemId, buyer, 0.05 ether);
        _fundSwapReserve(secondGemId, bidder, 0.055 ether);

        vm.startPrank(buyer);
        nft.approve(address(swapEscrow), firstTokenId);
        vm.expectRevert(abi.encodeWithSelector(SwapEscrow.ReserveCoverageTooLow.selector, firstGemId, 1_000e18, 100e18));
        swapEscrow.createOffer(firstTokenId, secondTokenId, address(0), 0, false, uint64(block.timestamp + 1 days));
        vm.stopPrank();
    }

    function testSwapRechecksTenPercentBoundaryOnAcceptance() public {
        (, uint256 firstTokenId) = _mintGemTo(buyer, 1_000e18, "ipfs://swap-accept-threshold-a");
        (uint256 secondGemId, uint256 secondTokenId) = _mintGemTo(bidder, 1_000e18, "ipfs://swap-accept-threshold-b");

        vm.startPrank(buyer);
        nft.approve(address(swapEscrow), firstTokenId);
        uint256 offerId =
            swapEscrow.createOffer(firstTokenId, secondTokenId, address(0), 0, false, uint64(block.timestamp + 1 days));
        vm.stopPrank();

        // Coverage can move while an offer is open, so acceptance checks again.
        _fundSwapReserve(secondGemId, bidder, 0.05 ether);
        vm.startPrank(bidder);
        nft.approve(address(swapEscrow), secondTokenId);
        vm.expectRevert(
            abi.encodeWithSelector(SwapEscrow.ReserveCoverageTooLow.selector, secondGemId, 1_000e18, 100e18)
        );
        swapEscrow.acceptOffer(offerId);
        vm.stopPrank();
    }

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

    function testProposerPaysBranchRejectsStrayNativeValue() public {
        (, uint256 firstTokenId) = _mintGemTo(buyer, 1_000e18, "ipfs://swap-stray-native-a");
        (, uint256 secondTokenId) = _mintGemTo(bidder, 1_000e18, "ipfs://swap-stray-native-b");

        vm.startPrank(buyer);
        nft.approve(address(swapEscrow), firstTokenId);
        uint256 offerId = swapEscrow.createOffer{value: 0.1 ether}(
            firstTokenId, secondTokenId, address(0), 0.1 ether, true, uint64(block.timestamp + 1 days)
        );
        vm.stopPrank();

        vm.startPrank(bidder);
        nft.approve(address(swapEscrow), secondTokenId);
        vm.expectRevert(SwapEscrow.InvalidAmount.selector);
        swapEscrow.acceptOffer{value: 0.01 ether}(offerId);
        assertEq(nft.ownerOf(firstTokenId), address(swapEscrow));
        assertEq(nft.ownerOf(secondTokenId), bidder);

        swapEscrow.acceptOffer(offerId);
        vm.stopPrank();

        assertEq(address(swapEscrow).balance, 0);
        assertEq(nft.ownerOf(firstTokenId), bidder);
        assertEq(nft.ownerOf(secondTokenId), buyer);
    }
}
