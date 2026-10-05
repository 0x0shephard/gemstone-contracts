// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {DGENFT} from "../src/DGENFT.sol";
import {GemRegistry} from "../src/GemRegistry.sol";
import {PrimarySaleAuction} from "../src/PrimarySaleAuction.sol";
import {RedemptionManager} from "../src/RedemptionManager.sol";
import {ReserveManager} from "../src/ReserveManager.sol";
import {BaseTest} from "./BaseTest.t.sol";

contract RegistryRedemptionLogicTest is BaseTest {
    function testCanMintTracksApprovalStatusAndLifecycle() public {
        registry.setSellerApproval(seller, true);
        uint256 gemId = registry.registerGem(seller, custodian, "ipfs://mint-state", keccak256("mint-state"));

        assertFalse(registry.canMint(gemId));

        vm.prank(custodian);
        registry.confirmCustody(gemId);
        registry.verifyGem(gemId, keccak256("valuation"), keccak256("matrix-v1"), 1_000e18);
        registry.listGem(gemId, 1_000e18, GemRegistry.PrimarySaleMode.BuyNow);
        assertTrue(registry.canMint(gemId));

        registry.setSellerApproval(seller, false);
        assertFalse(registry.canMint(gemId));
    }

    function testRegistryRejectsInvalidListingTransitions() public {
        uint256 gemId = registry.registerGem(seller, custodian, "ipfs://bad-transition", keccak256("bad-transition"));

        vm.expectRevert(abi.encodeWithSelector(GemRegistry.InvalidStatus.selector, GemRegistry.GemStatus.Registered));
        registry.verifyGem(gemId, keccak256("valuation"), keccak256("matrix-v1"), 1_000e18);

        vm.prank(custodian);
        registry.confirmCustody(gemId);

        vm.expectRevert(GemRegistry.InvalidPrice.selector);
        registry.listGem(gemId, 0, GemRegistry.PrimarySaleMode.BuyNow);

        vm.expectRevert(
            abi.encodeWithSelector(GemRegistry.InvalidStatus.selector, GemRegistry.GemStatus.CustodyConfirmed)
        );
        registry.listGem(gemId, 1_000e18, GemRegistry.PrimarySaleMode.BuyNow);

        registry.verifyGem(gemId, keccak256("valuation"), keccak256("matrix-v1"), 1_000e18);
        registry.setSellerApproval(seller, false);
        vm.expectRevert(GemRegistry.SellerNotApproved.selector);
        registry.listGem(gemId, 1_000e18, GemRegistry.PrimarySaleMode.BuyNow);
    }

    function testRegistryPauseBlocksStateChangingLifecycleCalls() public {
        registry.pause();

        vm.expectRevert();
        registry.registerGem(seller, custodian, "ipfs://paused", keccak256("paused"));

        registry.unpause();
        uint256 gemId = registry.registerGem(seller, custodian, "ipfs://unpaused", keccak256("unpaused"));

        registry.pause();
        vm.prank(custodian);
        vm.expectRevert();
        registry.confirmCustody(gemId);
    }

    function testListerCanWithdrawUnsoldListedGem() public {
        uint256 gemId = _listedGem(1_000e18, "ipfs://withdraw-listed");

        registry.withdrawListedGem(gemId, keccak256("seller-returned"));

        GemRegistry.Gem memory gem = registry.getGem(gemId);
        assertEq(uint256(gem.status), uint256(GemRegistry.GemStatus.Withdrawn));
        assertFalse(registry.canMint(gemId));

        vm.prank(buyer);
        vm.expectRevert(PrimarySaleAuction.GemNotMintable.selector);
        sale.buyNow{value: 0.5 ether}(gemId, address(0), 0.5 ether);
    }

    function testWithdrawalRequiresListedUnmintedGem() public {
        (uint256 gemId,) = _mintGemTo(buyer, 1_000e18, "ipfs://withdraw-minted");

        vm.expectRevert(abi.encodeWithSelector(GemRegistry.InvalidStatus.selector, GemRegistry.GemStatus.Minted));
        registry.withdrawListedGem(gemId, keccak256("bad-withdraw"));
    }

    function testCancelRedemptionUnlocksTokenAndRestoresMintedStatus() public {
        (uint256 gemId, uint256 tokenId) = _mintGemTo(buyer, 1_000e18, "ipfs://cancel-redemption");

        vm.prank(buyer);
        redemption.requestRedemption(tokenId, keccak256("cancel"), keccak256("cancel-workflow"));
        assertTrue(nft.transferLocked(tokenId));

        vm.prank(buyer);
        redemption.cancelRedemption(tokenId);

        assertFalse(nft.transferLocked(tokenId));
        GemRegistry.Gem memory gem = registry.getGem(gemId);
        assertEq(uint256(gem.status), uint256(GemRegistry.GemStatus.Minted));
        assertEq(gem.redemptionRequestHash, bytes32(0));
    }

    function testRecordedCustodianAndRedeemerCanCancelButStrangerCannot() public {
        (, uint256 custodianTokenId) = _mintGemTo(buyer, 1_000e18, "ipfs://custodian-cancel");
        vm.prank(buyer);
        redemption.requestRedemption(
            custodianTokenId, keccak256("custodian-cancel"), keccak256("custodian-cancel-workflow")
        );

        vm.prank(stranger);
        vm.expectRevert(RedemptionManager.NotRedemptionCanceller.selector);
        redemption.cancelRedemption(custodianTokenId);

        vm.prank(custodian);
        redemption.cancelRedemption(custodianTokenId);
        assertFalse(nft.transferLocked(custodianTokenId));

        (, uint256 redeemerTokenId) = _mintGemTo(buyer, 1_000e18, "ipfs://redeemer-cancel");
        vm.prank(buyer);
        redemption.requestRedemption(
            redeemerTokenId, keccak256("redeemer-cancel"), keccak256("redeemer-cancel-workflow")
        );
        redemption.cancelRedemption(redeemerTokenId);
        assertFalse(nft.transferLocked(redeemerTokenId));
    }

    function testRedemptionRejectsNonOwnerAndWrongCustodian() public {
        (, uint256 tokenId) = _mintGemTo(buyer, 1_000e18, "ipfs://redeem-auth");

        vm.prank(stranger);
        vm.expectRevert(RedemptionManager.NotTokenOwner.selector);
        redemption.requestRedemption(tokenId, keccak256("not-owner"), keccak256("not-owner-workflow"));

        vm.prank(buyer);
        redemption.requestRedemption(tokenId, keccak256("owner"), keccak256("owner-workflow"));

        vm.prank(stranger);
        vm.expectRevert(RedemptionManager.NotGemCustodian.selector);
        redemption.startFulfillment(tokenId);
    }

    function testBlockedWalletCannotRedeemButCanStillTransfer() public {
        (, uint256 tokenId) = _mintGemTo(buyer, 1_000e18, "ipfs://redeem-blocked");
        compliance.setBlocked(buyer, true);

        vm.prank(buyer);
        nft.transferFrom(buyer, bidder, tokenId);
        assertEq(nft.ownerOf(tokenId), bidder);

        vm.prank(bidder);
        nft.transferFrom(bidder, buyer, tokenId);

        vm.prank(buyer);
        vm.expectRevert(RedemptionManager.RedemptionNotAllowed.selector);
        redemption.requestRedemption(tokenId, keccak256("blocked"), keccak256("blocked-workflow"));
    }

    function testRedemptionApprovalRequiredMode() public {
        (, uint256 tokenId) = _mintGemTo(buyer, 1_000e18, "ipfs://redeem-approval");
        compliance.setRedemptionApprovalRequired(true);

        vm.prank(buyer);
        vm.expectRevert(RedemptionManager.RedemptionNotAllowed.selector);
        redemption.requestRedemption(tokenId, keccak256("unapproved"), keccak256("unapproved-workflow"));

        compliance.setRedemptionApproved(buyer, true);
        vm.prank(buyer);
        redemption.requestRedemption(tokenId, keccak256("approved"), keccak256("approved-workflow"));

        assertTrue(nft.transferLocked(tokenId));
    }

    function testRedemptionPauseBlocksRequests() public {
        (, uint256 tokenId) = _mintGemTo(buyer, 1_000e18, "ipfs://paused-redemption");

        redemption.pause();
        vm.prank(buyer);
        vm.expectRevert();
        redemption.requestRedemption(tokenId, keccak256("paused"), keccak256("paused-workflow"));
    }

    function testNftMintBurnAndRoyaltyGuards() public {
        uint256 gemId = _listedGem(1_000e18, "ipfs://nft-guards");

        vm.expectRevert(DGENFT.InvalidAddress.selector);
        nft.mintTo(address(0), gemId, "ipfs://zero");

        uint256 tokenId = nft.mintTo(buyer, gemId, "ipfs://direct-mint");
        vm.expectRevert(DGENFT.GemAlreadyMinted.selector);
        nft.mintTo(bidder, gemId, "ipfs://duplicate");

        nft.deleteDefaultRoyalty();
        vm.prank(address(redemption));
        nft.burnFromProtocol(tokenId);
        assertEq(nft.tokenForGem(gemId), 0);
        assertEq(nft.tokenGem(tokenId), 0);
    }

    function testReserveDefaultBpsAndMinimumReserveOverride() public {
        uint256 gemId = _listedGem(1_000e18, "ipfs://reserve-minimum");
        reserveManager.setDefaultReserveBps(250);
        reserveManager.setMinimumReserveUsd(gemId, 100e18);

        assertEq(reserveManager.reserveBpsFor(10_000e18), 250);
        assertEq(reserveManager.requiredReserveUsd(gemId, 1_000e18), 100e18);

        vm.expectRevert(ReserveManager.InvalidReserveBps.selector);
        reserveManager.setDefaultReserveBps(10_001);
    }

    function testRedemptionNeedsTwentyPercentOfTheRequiredReserve() public {
        (uint256 gemId, uint256 tokenId) = _mintGemTo(buyer, 1_000e18, "ipfs://redeem-twenty");
        reserveManager.setMinimumReserveUsd(gemId, 1_000e18);
        uint256 requiredUsd = reserveManager.requiredReserveUsd(gemId, 1_000e18);
        uint256 twentyPercent = requiredUsd * 2_000 / 10_000;

        // Top up to one dollar short of 20% (ETH is $2,000 in the test oracle).
        uint256 balanceUsd = reserveManager.reserveBalanceUsd(gemId);
        vm.prank(buyer);
        reserveManager.fundNative{value: (twentyPercent - balanceUsd - 1e18) / 2_000}(gemId);
        balanceUsd = reserveManager.reserveBalanceUsd(gemId);
        assertLt(balanceUsd, twentyPercent);

        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(RedemptionManager.RedemptionReserveTooLow.selector, requiredUsd, balanceUsd)
        );
        redemption.requestRedemption(tokenId, keccak256("below-twenty"), keccak256("below-twenty-workflow"));

        // A partial reserve at 20% is enough; full funding is no longer required.
        vm.prank(buyer);
        reserveManager.fundNative{value: 2e18 / 2_000}(gemId);
        assertGe(reserveManager.reserveBalanceUsd(gemId), twentyPercent);
        assertLt(reserveManager.reserveBalanceUsd(gemId), requiredUsd);
        vm.prank(buyer);
        redemption.requestRedemption(tokenId, keccak256("at-twenty"), keccak256("at-twenty-workflow"));
        assertTrue(nft.transferLocked(tokenId));
    }
}
