// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {GemRegistry} from "../src/GemRegistry.sol";
import {PrimarySaleAuction} from "../src/PrimarySaleAuction.sol";
import {ReserveManager} from "../src/ReserveManager.sol";
import {Roles} from "../src/libraries/Roles.sol";
import {BaseTest} from "./BaseTest.t.sol";

/// @notice Seller route "mint to my wallet": GemRegistry.SellerMint plus PrimarySaleAuction.mintToSeller.
contract SellerMintTest is BaseTest {
    uint256 internal constant PRICE = 1_000e18;

    function setUp() public override {
        super.setUp();
        vm.deal(seller, 100 ether);
        usdc.mint(seller, 1_000_000e6);
    }

    function _zeroReserve() internal {
        ReserveManager.ReserveBracket[] memory zeroRate = new ReserveManager.ReserveBracket[](1);
        zeroRate[0] = ReserveManager.ReserveBracket({minPriceUsd: 0, maxPriceUsd: type(uint256).max, reserveBps: 0});
        reserveManager.setReserveBrackets(zeroRate);
    }

    function _sellerMintGem(string memory uri) internal returns (uint256) {
        return _listedGemWithMode(PRICE, uri, GemRegistry.PrimarySaleMode.SellerMint);
    }

    // ---------------------------------------------------------------- free path

    function testOperatorMintsToSellerWhenNothingIsDue() public {
        _zeroReserve();
        uint256 gemId = _sellerMintGem("ipfs://seller-mint-free");

        vm.expectEmit(true, false, true, true, address(sale));
        emit PrimarySaleAuction.SellerMinted(gemId, 0, seller, address(0), 0, 0, 0);
        // `admin` holds LISTER_ROLE, standing in for the operator.
        uint256 tokenId = sale.mintToSeller(gemId, address(0), 0);

        assertEq(nft.ownerOf(tokenId), seller);
        GemRegistry.Gem memory gem = registry.getGem(gemId);
        assertEq(uint256(gem.status), uint256(GemRegistry.GemStatus.Minted));
        assertEq(gem.tokenId, tokenId);
    }

    function testSellerMayMintThemselvesWhenNothingIsDue() public {
        _zeroReserve();
        uint256 gemId = _sellerMintGem("ipfs://seller-mint-self");
        vm.prank(seller);
        uint256 tokenId = sale.mintToSeller(gemId, address(0), 0);
        assertEq(nft.ownerOf(tokenId), seller);
    }

    function testStrangerCannotMintAndCannotRedirectTheToken() public {
        _zeroReserve();
        uint256 gemId = _sellerMintGem("ipfs://seller-mint-stranger");
        vm.prank(stranger);
        vm.expectRevert(PrimarySaleAuction.NotSeller.selector);
        sale.mintToSeller(gemId, address(0), 0);
    }

    function testFreeMintRejectsAnyPayment() public {
        _zeroReserve();
        uint256 gemId = _sellerMintGem("ipfs://seller-mint-unexpected-eth");
        vm.prank(seller);
        vm.expectRevert(PrimarySaleAuction.InvalidAmount.selector);
        sale.mintToSeller{value: 1 ether}(gemId, address(0), 1 ether);
    }

    function testCannotMintTwice() public {
        _zeroReserve();
        uint256 gemId = _sellerMintGem("ipfs://seller-mint-twice");
        sale.mintToSeller(gemId, address(0), 0);
        vm.expectRevert(PrimarySaleAuction.GemNotMintable.selector);
        sale.mintToSeller(gemId, address(0), 0);
    }

    // ---------------------------------------------------------------- paid paths

    function testFeeIsPaidBySellerToPlatformWithSurplusRefunded() public {
        _zeroReserve();
        sale.setSellerMintFeeUsd(10e18);
        uint256 gemId = _sellerMintGem("ipfs://seller-mint-fee");

        // With a fee due the operator may no longer mint on the seller's behalf.
        vm.expectRevert(PrimarySaleAuction.NotSeller.selector);
        sale.mintToSeller(gemId, address(0), 0);

        uint256 platformBefore = platform.balance;
        uint256 sellerBefore = seller.balance;
        // $10 at $2,000/ETH is 0.005 ETH; send 0.01 and expect the surplus back.
        vm.prank(seller);
        uint256 tokenId = sale.mintToSeller{value: 0.01 ether}(gemId, address(0), 0.01 ether);

        assertEq(nft.ownerOf(tokenId), seller);
        assertEq(platform.balance - platformBefore, 0.005 ether);
        assertEq(sellerBefore - seller.balance, 0.005 ether);
        assertEq(address(sale).balance, 0);
    }

    function testSellerPaysReserveShortfallAndFeeInUsdc() public {
        _setTwoTierReservePolicy();
        sale.setSellerMintFeeUsd(5e18);
        uint256 gemId = _sellerMintGem("ipfs://seller-mint-reserve");
        uint256 reserveUsd = reserveManager.shortfallUsd(gemId, PRICE);
        assertGt(reserveUsd, 0);

        uint256 dueUsdc = (reserveUsd + 5e18) / 1e12;
        uint256 platformBefore = usdc.balanceOf(platform);
        vm.startPrank(seller);
        usdc.approve(address(sale), dueUsdc);
        uint256 tokenId = sale.mintToSeller(gemId, address(usdc), dueUsdc);
        vm.stopPrank();

        assertEq(nft.ownerOf(tokenId), seller);
        assertEq(reserveManager.shortfallUsd(gemId, PRICE), 0);
        assertEq(usdc.balanceOf(platform) - platformBefore, 5e6);
        assertEq(usdc.balanceOf(address(sale)), 0);
    }

    function testUnderpaymentReverts() public {
        _zeroReserve();
        sale.setSellerMintFeeUsd(10e18);
        uint256 gemId = _sellerMintGem("ipfs://seller-mint-underpaid");
        vm.prank(seller);
        vm.expectRevert(PrimarySaleAuction.BidTooLow.selector);
        sale.mintToSeller{value: 0.001 ether}(gemId, address(0), 0.001 ether);
    }

    function testOnlyAdminSetsTheFee() public {
        bytes32 adminRole = sale.DEFAULT_ADMIN_ROLE();
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, adminRole)
        );
        sale.setSellerMintFeeUsd(1e18);

        vm.expectEmit(address(sale));
        emit PrimarySaleAuction.SellerMintFeeUpdated(1e18);
        sale.setSellerMintFeeUsd(1e18);
        assertEq(sale.sellerMintFeeUsd(), 1e18);
    }

    // ---------------------------------------------------------------- mode isolation

    function testSellerMintGemsCannotBeAuctionedOrBoughtNow() public {
        _zeroReserve();
        uint256 gemId = _sellerMintGem("ipfs://seller-mint-isolated");

        vm.expectRevert(PrimarySaleAuction.WrongPrimarySaleMode.selector);
        sale.createDailyAuction(gemId, PRICE);

        vm.prank(buyer);
        vm.expectRevert(PrimarySaleAuction.WrongPrimarySaleMode.selector);
        sale.buyNow{value: 1 ether}(gemId, address(0), 1 ether);
    }

    function testAuctionAndBuyNowGemsCannotBeSellerMinted() public {
        _zeroReserve();
        uint256 auctionGem = _listedAuctionGem(PRICE, "ipfs://auction-not-mint");
        uint256 buyNowGem = _listedGem(PRICE, "ipfs://buynow-not-mint");

        vm.expectRevert(PrimarySaleAuction.WrongPrimarySaleMode.selector);
        sale.mintToSeller(auctionGem, address(0), 0);
        vm.expectRevert(PrimarySaleAuction.WrongPrimarySaleMode.selector);
        sale.mintToSeller(buyNowGem, address(0), 0);
    }

    // ---------------------------------------------------------------- switching

    function testUnbidAuctionSwitchesToSellerMintAndMints() public {
        _zeroReserve();
        uint256 gemId = _listedAuctionGem(PRICE, "ipfs://switch-after-unbid");
        sale.createDailyAuction(gemId, PRICE);

        // A live round blocks the switch.
        vm.expectRevert(GemRegistry.ActivePrimaryAuction.selector);
        registry.setPrimarySaleMode(gemId, GemRegistry.PrimarySaleMode.SellerMint);

        vm.warp(block.timestamp + 1 days);
        sale.cancelAuction(gemId);

        vm.expectEmit(address(registry));
        emit GemRegistry.PrimarySaleModeUpdated(
            gemId, GemRegistry.PrimarySaleMode.Auction, GemRegistry.PrimarySaleMode.SellerMint
        );
        registry.setPrimarySaleMode(gemId, GemRegistry.PrimarySaleMode.SellerMint);
        assertEq(uint256(registry.primarySaleMode(gemId)), uint256(GemRegistry.PrimarySaleMode.SellerMint));

        // Never back to auction.
        vm.expectRevert(PrimarySaleAuction.WrongPrimarySaleMode.selector);
        sale.createDailyAuction(gemId, PRICE);
        vm.expectRevert(GemRegistry.InvalidPrimarySaleMode.selector);
        registry.setPrimarySaleMode(gemId, GemRegistry.PrimarySaleMode.Auction);

        uint256 tokenId = sale.mintToSeller(gemId, address(0), 0);
        assertEq(nft.ownerOf(tokenId), seller);
    }

    function testAuctionWithABidCannotSwitch() public {
        uint256 gemId = _listedAuctionGem(PRICE, "ipfs://switch-with-bid");
        sale.createDailyAuction(gemId, PRICE);
        vm.prank(bidder);
        sale.bid{value: 1 ether}(gemId, address(0), 1 ether);

        vm.expectRevert(GemRegistry.ActivePrimaryAuction.selector);
        registry.setPrimarySaleMode(gemId, GemRegistry.PrimarySaleMode.SellerMint);
    }

    function testOnlyAuctionToSellerMintIsAllowed() public {
        uint256 buyNowGem = _listedGem(PRICE, "ipfs://switch-buynow");
        vm.expectRevert(GemRegistry.InvalidPrimarySaleMode.selector);
        registry.setPrimarySaleMode(buyNowGem, GemRegistry.PrimarySaleMode.SellerMint);

        uint256 auctionGem = _listedAuctionGem(PRICE, "ipfs://switch-to-buynow");
        vm.expectRevert(GemRegistry.InvalidPrimarySaleMode.selector);
        registry.setPrimarySaleMode(auctionGem, GemRegistry.PrimarySaleMode.BuyNow);
    }

    function testOnlyListerSwitchesMode() public {
        uint256 gemId = _listedAuctionGem(PRICE, "ipfs://switch-unauthorised");
        bytes32 listerRole = Roles.LISTER_ROLE;
        vm.prank(seller);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, seller, listerRole)
        );
        registry.setPrimarySaleMode(gemId, GemRegistry.PrimarySaleMode.SellerMint);
    }
}
