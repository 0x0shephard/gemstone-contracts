// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {DGENFT} from "../src/DGENFT.sol";
import {Marketplace} from "../src/Marketplace.sol";
import {BaseTest} from "./BaseTest.t.sol";

contract NftMarketplaceLifecycleTest is BaseTest {
    function testRoyaltyCanBeConfigured() public {
        nft.setDefaultRoyalty(platform, 500);

        (address receiver, uint256 royaltyAmount) = nft.royaltyInfo(1, 10_000e18);

        assertEq(receiver, platform);
        assertEq(royaltyAmount, 500e18);
    }

    function testOpenTransferWorksUntilRedemptionLock() public {
        (, uint256 tokenId) = _mintGemTo(buyer, 1_000e18, "ipfs://transferable");

        vm.prank(buyer);
        nft.transferFrom(buyer, bidder, tokenId);
        assertEq(nft.ownerOf(tokenId), bidder);

        vm.prank(bidder);
        redemption.requestRedemption(tokenId, keccak256("redeem"));

        vm.prank(bidder);
        vm.expectRevert(DGENFT.TokenLocked.selector);
        nft.transferFrom(bidder, buyer, tokenId);
    }

    function testMarketplaceCancelReturnsEscrowedNft() public {
        (, uint256 tokenId) = _mintGemTo(buyer, 1_000e18, "ipfs://cancel-listing");

        vm.startPrank(buyer);
        nft.approve(address(marketplace), tokenId);
        marketplace.list(tokenId, 1_000e18);
        marketplace.cancel(tokenId);
        vm.stopPrank();

        assertEq(nft.ownerOf(tokenId), buyer);
    }

    function testOnlySellerCanCancelMarketplaceListing() public {
        (, uint256 tokenId) = _mintGemTo(buyer, 1_000e18, "ipfs://cancel-listing-auth");

        vm.startPrank(buyer);
        nft.approve(address(marketplace), tokenId);
        marketplace.list(tokenId, 1_000e18);
        vm.stopPrank();

        vm.prank(stranger);
        vm.expectRevert(Marketplace.NotSeller.selector);
        marketplace.cancel(tokenId);
    }

    function testMarketplaceRejectsInvalidListAndBuyInputs() public {
        (, uint256 tokenId) = _mintGemTo(buyer, 1_000e18, "ipfs://market-invalid");

        vm.startPrank(buyer);
        nft.approve(address(marketplace), tokenId);
        vm.expectRevert(Marketplace.InvalidPrice.selector);
        marketplace.list(tokenId, 0);
        marketplace.list(tokenId, 1_000e18);
        vm.stopPrank();

        vm.expectRevert(Marketplace.NotListed.selector);
        marketplace.buy(999, address(0), 1 ether);

        vm.prank(bidder);
        vm.expectRevert(Marketplace.InvalidAmount.selector);
        marketplace.buy{value: 0.5 ether}(tokenId, address(0), 0.4 ether);
    }

    function testMarketplaceRejectsNativeValueWithTokenPayment() public {
        (, uint256 tokenId) = _mintGemTo(buyer, 1_000e18, "ipfs://market-token-value");

        vm.startPrank(buyer);
        nft.approve(address(marketplace), tokenId);
        marketplace.list(tokenId, 1_000e18);
        vm.stopPrank();

        vm.startPrank(bidder);
        usdc.approve(address(marketplace), 1_000e6);
        vm.expectRevert(Marketplace.InvalidAmount.selector);
        marketplace.buy{value: 1}(tokenId, address(usdc), 1_000e6);
        vm.stopPrank();
    }

    function testEscrowedOfferCanBeAcceptedWithSecondaryFee() public {
        (, uint256 tokenId) = _mintGemTo(buyer, 1_000e18, "ipfs://market-offer");

        uint256 sellerBefore = usdc.balanceOf(buyer);
        vm.startPrank(bidder);
        usdc.approve(address(marketplace), 1_000e6);
        uint256 offerId = marketplace.createOffer(tokenId, address(usdc), 1_000e6);
        vm.stopPrank();

        vm.startPrank(buyer);
        nft.approve(address(marketplace), tokenId);
        marketplace.acceptOffer(offerId);
        vm.stopPrank();

        assertEq(nft.ownerOf(tokenId), bidder);
        assertEq(usdc.balanceOf(buyer) - sellerBefore, 980e6);
        assertEq(usdc.balanceOf(platform), 20e6);
    }

    function testExpiredNativeOfferCanBeRefunded() public {
        (, uint256 tokenId) = _mintGemTo(buyer, 1_000e18, "ipfs://market-offer-refund");

        uint256 bidderBefore = bidder.balance;
        vm.prank(bidder);
        uint256 offerId = marketplace.createOffer{value: 0.5 ether}(tokenId, address(0), 0.5 ether);

        vm.warp(block.timestamp + 1 days + 1);
        marketplace.cancelExpiredOffer(offerId);

        assertEq(bidder.balance, bidderBefore);
    }

    function testOfferAcceptanceFundsReserveShortfall() public {
        (uint256 gemId, uint256 tokenId) = _mintGemTo(buyer, 1_000e18, "ipfs://market-offer-reserve");
        reserveManager.setMinimumReserveUsd(gemId, 100e18);

        vm.startPrank(bidder);
        usdc.approve(address(marketplace), 1_100e6);
        uint256 offerId = marketplace.createOffer(tokenId, address(usdc), 1_100e6);
        vm.stopPrank();

        uint256 sellerBefore = usdc.balanceOf(buyer);
        vm.startPrank(buyer);
        nft.approve(address(marketplace), tokenId);
        marketplace.acceptOffer(offerId);
        vm.stopPrank();

        assertEq(nft.ownerOf(tokenId), bidder);
        assertEq(usdc.balanceOf(buyer) - sellerBefore, 980e6);
        assertEq(usdc.balanceOf(platform), 20e6);
        assertEq(reserveManager.reserveBalanceUsd(gemId), 100e18);
        assertEq(reserveManager.reserveAssetBalance(gemId, address(usdc)), 100e6);
    }

    function testSecondaryFeeIsConfigurable() public {
        marketplace.setSecondaryFeeBps(500);
        marketplace.setSecondaryFeeRecipient(stranger);

        (, uint256 tokenId) = _mintGemTo(buyer, 1_000e18, "ipfs://market-fee");
        vm.startPrank(buyer);
        nft.approve(address(marketplace), tokenId);
        marketplace.list(tokenId, 1_000e18);
        vm.stopPrank();

        vm.startPrank(bidder);
        usdc.approve(address(marketplace), 1_000e6);
        marketplace.buy(tokenId, address(usdc), 1_000e6);
        vm.stopPrank();

        assertEq(usdc.balanceOf(buyer), 1_000_950e6);
        assertEq(usdc.balanceOf(stranger), 1_000_050e6);

        vm.expectRevert(Marketplace.InvalidFee.selector);
        marketplace.setSecondaryFeeBps(10_001);
    }
}
