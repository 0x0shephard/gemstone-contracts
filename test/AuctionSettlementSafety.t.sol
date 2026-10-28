// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {BaseTest} from "./BaseTest.t.sol";
import {Marketplace} from "../src/Marketplace.sol";
import {PrimarySaleAuction} from "../src/PrimarySaleAuction.sol";

/// @dev A wallet contract that can refuse ETH (optionally with a huge revert payload) and
///      refuse ERC-721 safe transfers, to stand in for a hostile or broken counterparty.
contract HostileWallet {
    bool public rejectEth;
    bool public bombEth;
    bool public rejectNft;

    function configure(bool rejectEth_, bool bombEth_, bool rejectNft_) external {
        rejectEth = rejectEth_;
        bombEth = bombEth_;
        rejectNft = rejectNft_;
    }

    function list(Marketplace m, uint256 tokenId, uint256 priceUsd) external {
        m.list(tokenId, priceUsd);
    }

    function offer(Marketplace m, uint256 tokenId) external payable returns (uint256) {
        return m.createOffer{value: msg.value}(tokenId, address(0), msg.value);
    }

    function cancelOffer(Marketplace m, uint256 offerId) external {
        m.cancelOffer(offerId);
    }

    function bid(PrimarySaleAuction s, uint256 gemId) external payable {
        s.bid{value: msg.value}(gemId, address(0), msg.value);
    }

    function cancelBid(PrimarySaleAuction s, uint256 gemId) external {
        s.cancelBid(gemId);
    }

    function claim(Marketplace m) external {
        m.claimRefund(address(0));
    }

    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        if (rejectNft) revert("no NFTs");
        return IERC721Receiver.onERC721Received.selector;
    }

    receive() external payable {
        if (bombEth) {
            assembly {
                revert(0, 1000000)
            }
        }
        if (rejectEth) revert("no ETH");
    }
}

contract AuctionSettlementSafetyTest is BaseTest {
    function _listFrom(HostileWallet wallet, string memory uri) private returns (uint256 tokenId) {
        (, tokenId) = _mintGemTo(buyer, 2_000e18, uri);
        vm.prank(buyer);
        nft.safeTransferFrom(buyer, address(wallet), tokenId);
        vm.prank(address(wallet));
        nft.setApprovalForAll(address(marketplace), true);
        wallet.list(marketplace, tokenId, 2_000e18);
    }

    function _listFromBuyer(string memory uri) private returns (uint256 tokenId) {
        (, tokenId) = _mintGemTo(buyer, 2_000e18, uri);
        vm.startPrank(buyer);
        nft.setApprovalForAll(address(marketplace), true);
        marketplace.list(tokenId, 2_000e18);
        vm.stopPrank();
    }

    function _endAuction(uint256 tokenId) private {
        vm.warp(marketplace.listingAuctionEnd(tokenId));
        ethFeed.updateAnswer(2_000e8);
    }

    // H-2: a seller that cannot receive ETH must not lock the winner's escrow.
    function testSettlementCreditsASellerThatRejectsEth() public {
        HostileWallet seller = new HostileWallet();
        uint256 tokenId = _listFrom(seller, "ipfs://seller-rejects");
        vm.prank(bidder);
        marketplace.createOffer{value: 1.1 ether}(tokenId, address(0), 1.1 ether);
        seller.configure(true, false, false);
        _endAuction(tokenId);

        assertTrue(marketplace.settleListingAuction(tokenId));
        assertEq(nft.ownerOf(tokenId), bidder);
        uint256 owed = marketplace.pendingRefunds(address(seller), address(0));
        assertGt(owed, 0);

        // The seller collects once it can receive again.
        seller.configure(false, false, false);
        seller.claim(marketplace);
        assertEq(address(seller).balance, owed);
    }

    // H-2 with a return bomb: the seller's huge revert payload must not cost the settler.
    function testSettlementSurvivesASellerReturnBomb() public {
        HostileWallet seller = new HostileWallet();
        uint256 tokenId = _listFrom(seller, "ipfs://seller-bombs");
        vm.prank(bidder);
        marketplace.createOffer{value: 1.1 ether}(tokenId, address(0), 1.1 ether);
        seller.configure(true, true, false);
        _endAuction(tokenId);

        (bool ok,) =
            address(marketplace).call{gas: 4_000_000}(abi.encodeCall(Marketplace.settleListingAuction, (tokenId)));
        assertTrue(ok, "settlement must not pay for the receiver's revert data");
        assertEq(nft.ownerOf(tokenId), bidder);
        assertGt(marketplace.pendingRefunds(address(seller), address(0)), 0);
    }

    // H-2: a winner contract that rejects safe transfers must not lock the seller's token.
    function testSettlementDeliversToABidderThatRejectsSafeTransfers() public {
        uint256 tokenId = _listFromBuyer("ipfs://bidder-rejects");
        HostileWallet winner = new HostileWallet();
        uint256 sellerBefore = buyer.balance;
        winner.offer{value: 1.1 ether}(marketplace, tokenId);
        winner.configure(false, false, true);
        _endAuction(tokenId);

        assertTrue(marketplace.settleListingAuction(tokenId));
        assertEq(nft.ownerOf(tokenId), address(winner));
        assertGt(buyer.balance, sellerBefore);
    }

    // M-1: withdraw-and-rebid restarted the 24 hours forever while the seller could not cancel.
    function testLeadingListingBidCannotBeCycledToHoldAListing() public {
        uint256 tokenId = _listFromBuyer("ipfs://perpetual-lock");
        vm.prank(stranger);
        uint256 offerId = marketplace.createOffer{value: 1 ether}(tokenId, address(0), 1 ether);
        uint256 withdrawableAt = marketplace.listingAuctionEnd(tokenId) + marketplace.SETTLEMENT_GRACE();

        vm.warp(marketplace.listingAuctionEnd(tokenId) - 1);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Marketplace.BidLocked.selector, withdrawableAt));
        marketplace.cancelOffer(offerId);

        // So the auction ends on schedule and settles.
        _endAuction(tokenId);
        assertTrue(marketplace.settleListingAuction(tokenId));
        assertEq(nft.ownerOf(tokenId), stranger);
    }

    // An outbid listing bidder with a return bomb must not block the higher bid.
    function testOutbidListingRefundSurvivesAReturnBomb() public {
        uint256 tokenId = _listFromBuyer("ipfs://outbid-bomb");
        HostileWallet first = new HostileWallet();
        first.offer{value: 1.1 ether}(marketplace, tokenId);
        first.configure(true, true, false);

        vm.prank(bidder);
        (bool ok,) = address(marketplace).call{value: 2 ether, gas: 4_000_000}(
            abi.encodeCall(Marketplace.createOffer, (tokenId, address(0), 2 ether))
        );
        assertTrue(ok, "outbid must not pay for the previous bidder's revert data");
        assertEq(marketplace.pendingRefunds(address(first), address(0)), 1.1 ether);
    }

    // M-2: a shielding bid pulled at the last second left the gem to a floor-price confederate.
    function testPrimaryAuctionShieldCannotBePulledBeforeTheClose() public {
        uint256 gemId = _listedAuctionGem(2_000e18, "ipfs://shield");
        sale.createDailyAuction(gemId, 2_000e18);
        (,,, uint64 endTime,,,,,,) = sale.auctions(gemId);
        HostileWallet shield = new HostileWallet();
        shield.bid{value: 50 ether}(sale, gemId);

        vm.warp(endTime - 1);
        vm.expectRevert(
            abi.encodeWithSelector(PrimarySaleAuction.BidLocked.selector, uint256(endTime) + sale.SETTLEMENT_GRACE())
        );
        shield.cancelBid(sale, gemId);

        // The shield is the winning bid and pays for it.
        vm.warp(endTime);
        ethFeed.updateAnswer(2_000e8);
        uint256 tokenId = sale.settleAuction(gemId);
        assertEq(nft.ownerOf(tokenId), address(shield));
    }

    // An outbid primary bidder with a return bomb must not block the higher bid.
    function testOutbidPrimaryRefundSurvivesAReturnBomb() public {
        uint256 gemId = _listedAuctionGem(2_000e18, "ipfs://primary-bomb");
        sale.createDailyAuction(gemId, 2_000e18);
        HostileWallet first = new HostileWallet();
        first.bid{value: 1 ether}(sale, gemId);
        first.configure(true, true, false);

        vm.prank(bidder);
        (bool ok,) = address(sale).call{value: 2 ether, gas: 4_000_000}(
            abi.encodeCall(PrimarySaleAuction.bid, (gemId, address(0), 2 ether))
        );
        assertTrue(ok, "outbid must not pay for the previous bidder's revert data");
        assertEq(sale.pendingRefunds(address(first), address(0)), 1 ether);
    }
}
