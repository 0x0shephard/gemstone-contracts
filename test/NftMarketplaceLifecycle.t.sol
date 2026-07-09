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
}
