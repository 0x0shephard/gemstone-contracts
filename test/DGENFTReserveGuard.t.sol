// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {DGENFT} from "../src/DGENFT.sol";
import {SwapEscrow} from "../src/SwapEscrow.sol";
import {BaseTest} from "./BaseTest.t.sol";

contract DGENFTReserveGuardTest is BaseTest {
    function _mintAtZero(address owner, string memory uri) private returns (uint256 gemId, uint256 tokenId) {
        gemId = _listedGem(1_000e18, uri);
        vm.prank(owner);
        tokenId = sale.buyNow{value: 0.5 ether}(gemId, address(0), 0.5 ether);
        assertEq(reserveManager.reserveBalanceUsd(gemId), 0);
    }

    function _fundOneWei(uint256 gemId, address funder) private {
        vm.prank(funder);
        reserveManager.fundNative{value: 1}(gemId);
        assertGt(reserveManager.reserveBalanceUsd(gemId), 0);
    }

    function _deplete(uint256 gemId, address recipient) private {
        reserveManager.releaseAllReserveAssets(gemId, recipient, keccak256("TEST_DEPLETION"));
        assertEq(reserveManager.reserveBalanceUsd(gemId), 0);
    }

    function testTinyPositiveReserveAllowsTransferAndZeroBlocksEveryTransferVariant() public {
        (uint256 positiveGemId, uint256 positiveTokenId) = _mintAtZero(buyer, "ipfs://tiny-positive");
        _fundOneWei(positiveGemId, buyer);

        vm.prank(buyer);
        nft.transferFrom(buyer, bidder, positiveTokenId);
        assertEq(nft.ownerOf(positiveTokenId), bidder);

        (, uint256 zeroTokenId) = _mintAtZero(buyer, "ipfs://exact-zero");
        vm.startPrank(buyer);
        nft.approve(stranger, zeroTokenId);
        nft.setApprovalForAll(stranger, true);

        vm.expectRevert(DGENFT.ZeroReserveTransfer.selector);
        nft.transferFrom(buyer, bidder, zeroTokenId);
        vm.expectRevert(DGENFT.ZeroReserveTransfer.selector);
        nft.safeTransferFrom(buyer, bidder, zeroTokenId);
        vm.expectRevert(DGENFT.ZeroReserveTransfer.selector);
        nft.safeTransferFrom(buyer, bidder, zeroTokenId, hex"1234");
        vm.stopPrank();

        vm.startPrank(stranger);
        vm.expectRevert(DGENFT.ZeroReserveTransfer.selector);
        nft.transferFrom(buyer, bidder, zeroTokenId);
        vm.expectRevert(DGENFT.ZeroReserveTransfer.selector);
        nft.safeTransferFrom(buyer, bidder, zeroTokenId);
        vm.stopPrank();

        assertEq(nft.ownerOf(zeroTokenId), buyer);
        assertEq(nft.getApproved(zeroTokenId), stranger);
    }

    function testMarketplaceAtZeroCanOnlyReturnToRecordedSeller() public {
        (uint256 gemId, uint256 tokenId) = _mintAtZero(buyer, "ipfs://marketplace-return");
        _fundOneWei(gemId, buyer);

        vm.startPrank(buyer);
        nft.approve(address(marketplace), tokenId);
        marketplace.list(tokenId, 1_000e18);
        vm.stopPrank();
        assertEq(nft.escrowDepositor(tokenId), buyer);

        _deplete(gemId, buyer);

        vm.prank(address(marketplace));
        vm.expectRevert(DGENFT.ZeroReserveTransfer.selector);
        nft.safeTransferFrom(address(marketplace), stranger, tokenId);

        vm.prank(bidder);
        vm.expectRevert(DGENFT.ZeroReserveTransfer.selector);
        marketplace.buy{value: 0.5 ether}(tokenId, address(0), 0.5 ether);

        vm.prank(buyer);
        marketplace.cancel(tokenId);
        assertEq(nft.ownerOf(tokenId), buyer);
        assertEq(nft.escrowDepositor(tokenId), address(0));
    }

    function testSwapAtZeroCanCancelButCannotSettleToAccepter() public {
        (uint256 firstGemId, uint256 firstTokenId) = _mintAtZero(buyer, "ipfs://swap-return-a");
        (uint256 secondGemId, uint256 secondTokenId) = _mintAtZero(bidder, "ipfs://swap-return-b");
        _fundOneWei(firstGemId, buyer);
        _fundOneWei(secondGemId, bidder);

        vm.startPrank(buyer);
        nft.approve(address(swapEscrow), firstTokenId);
        uint256 offerId =
            swapEscrow.createOffer(firstTokenId, secondTokenId, address(0), 0, false, uint64(block.timestamp + 1 days));
        vm.stopPrank();
        assertEq(nft.escrowDepositor(firstTokenId), buyer);

        _deplete(firstGemId, buyer);
        vm.startPrank(bidder);
        nft.approve(address(swapEscrow), secondTokenId);
        vm.expectRevert(DGENFT.ZeroReserveTransfer.selector);
        swapEscrow.acceptOffer(offerId);
        vm.stopPrank();

        vm.prank(buyer);
        swapEscrow.cancelOffer(offerId);
        assertEq(nft.ownerOf(firstTokenId), buyer);
        assertEq(nft.escrowDepositor(firstTokenId), address(0));
    }

    function testGiftOperatorAtZeroReturnsOnlyToDepositorAndSelfTransferCannotOverwrite() public {
        (uint256 gemId, uint256 tokenId) = _mintAtZero(buyer, "ipfs://gift-return");
        _fundOneWei(gemId, buyer);

        vm.prank(buyer);
        nft.transferFrom(buyer, giftOperator, tokenId);
        assertEq(nft.escrowDepositor(tokenId), buyer);

        vm.prank(giftOperator);
        nft.transferFrom(giftOperator, giftOperator, tokenId);
        assertEq(nft.escrowDepositor(tokenId), buyer);

        _deplete(gemId, buyer);
        vm.prank(giftOperator);
        vm.expectRevert(DGENFT.ZeroReserveTransfer.selector);
        nft.transferFrom(giftOperator, stranger, tokenId);
        vm.prank(giftOperator);
        vm.expectRevert(DGENFT.ZeroReserveTransfer.selector);
        nft.transferFrom(giftOperator, giftOperator, tokenId);

        vm.prank(giftOperator);
        nft.transferFrom(giftOperator, buyer, tokenId);
        assertEq(nft.ownerOf(tokenId), buyer);
        assertEq(nft.escrowDepositor(tokenId), address(0));
    }

    function testMintAndBurnRemainExemptWhileRedemptionLockStillWins() public {
        uint256 gemId = _listedGem(1_000e18, "ipfs://mint-burn-exempt");
        uint256 tokenId = nft.mintTo(buyer, gemId, "ipfs://mint-burn-exempt");
        assertEq(nft.ownerOf(tokenId), buyer);

        vm.prank(address(redemption));
        nft.setTransferLocked(tokenId, true);
        _fundOneWei(gemId, buyer);
        vm.prank(buyer);
        vm.expectRevert(DGENFT.TokenLocked.selector);
        nft.transferFrom(buyer, bidder, tokenId);

        vm.prank(address(redemption));
        nft.burnFromProtocol(tokenId);
        vm.expectRevert();
        nft.ownerOf(tokenId);
    }

    function testUpgradeRetainsIdsOwnersApprovalsAndBootstrapsCompleteLegacyEscrow() public {
        DGENFT legacyProxy = DGENFT(
            address(
                new ERC1967Proxy(
                    address(new DGENFT()), abi.encodeCall(DGENFT.initialize, (admin, "Legacy Digital Carat", "LDGE"))
                )
            )
        );
        uint256 ownerTokenId = legacyProxy.mintTo(buyer, 11, "ipfs://legacy-owner");
        uint256 escrowTokenId = legacyProxy.mintTo(giftOperator, 12, "ipfs://legacy-escrow");
        vm.prank(buyer);
        legacyProxy.approve(stranger, ownerTokenId);

        address[] memory escrows = new address[](3);
        escrows[0] = address(marketplace);
        escrows[1] = address(swapEscrow);
        escrows[2] = giftOperator;
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = escrowTokenId;
        address[] memory depositors = new address[](1);
        depositors[0] = bidder;

        address newImplementation = address(new DGENFT());
        legacyProxy.upgradeToAndCall(
            newImplementation,
            abi.encodeCall(DGENFT.initializeReserveGuard, (reserveManager, escrows, tokenIds, depositors))
        );

        assertEq(legacyProxy.ownerOf(ownerTokenId), buyer);
        assertEq(legacyProxy.ownerOf(escrowTokenId), giftOperator);
        assertEq(legacyProxy.tokenGem(ownerTokenId), 11);
        assertEq(legacyProxy.tokenForGem(12), escrowTokenId);
        assertEq(legacyProxy.getApproved(ownerTokenId), stranger);
        assertEq(legacyProxy.escrowDepositor(escrowTokenId), bidder);
        assertEq(legacyProxy.mintTo(buyer, 13, "ipfs://next-id"), 3);
    }

    function testLegacyBootstrapRejectsIncompleteInventoryAndMigrationOverLimit() public {
        DGENFT legacyProxy = DGENFT(
            address(
                new ERC1967Proxy(
                    address(new DGENFT()), abi.encodeCall(DGENFT.initialize, (admin, "Legacy Digital Carat", "LDGE"))
                )
            )
        );
        legacyProxy.mintTo(giftOperator, 21, "ipfs://unreported-legacy-escrow");

        address[] memory escrows = new address[](1);
        escrows[0] = giftOperator;
        vm.expectRevert(abi.encodeWithSelector(DGENFT.IncompleteLegacyEscrowMigration.selector, giftOperator, 1, 0));
        legacyProxy.initializeReserveGuard(reserveManager, escrows, new uint256[](0), new address[](0));

        uint256[] memory tooManyTokenIds = new uint256[](101);
        address[] memory tooManyDepositors = new address[](101);
        vm.expectRevert(DGENFT.LegacyMigrationLimitExceeded.selector);
        legacyProxy.initializeReserveGuard(reserveManager, escrows, tooManyTokenIds, tooManyDepositors);
    }

    function testSelfOwnedSwapIsRejected() public {
        (uint256 firstGemId, uint256 firstTokenId) = _mintAtZero(buyer, "ipfs://self-swap-a");
        (uint256 secondGemId, uint256 secondTokenId) = _mintAtZero(buyer, "ipfs://self-swap-b");
        _fundOneWei(firstGemId, buyer);
        _fundOneWei(secondGemId, buyer);

        vm.startPrank(buyer);
        nft.approve(address(swapEscrow), firstTokenId);
        vm.expectRevert(SwapEscrow.SelfSwap.selector);
        swapEscrow.createOffer(firstTokenId, secondTokenId, address(0), 0, false, uint64(block.timestamp + 1 days));
        vm.stopPrank();
    }
}
