// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DGENFT} from "../../src/DGENFT.sol";
import {ComplianceRegistry} from "../../src/ComplianceRegistry.sol";
import {GemRegistry} from "../../src/GemRegistry.sol";
import {Marketplace} from "../../src/Marketplace.sol";
import {PrimarySaleAuction} from "../../src/PrimarySaleAuction.sol";
import {RedemptionManager} from "../../src/RedemptionManager.sol";
import {ReserveManager} from "../../src/ReserveManager.sol";
import {SwapEscrow} from "../../src/SwapEscrow.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract DigitalCaratHandler is Test {
    struct Protocol {
        DGENFT nft;
        GemRegistry registry;
        ReserveManager reserveManager;
        ComplianceRegistry compliance;
        PrimarySaleAuction sale;
        RedemptionManager redemption;
        Marketplace marketplace;
        SwapEscrow swapEscrow;
        MockERC20 usdc;
    }

    struct TrackedGem {
        uint256 gemId;
        uint256 tokenId;
        uint256 liabilityUsd;
    }

    struct TrackedOffer {
        uint256 offerId;
        uint256 tokenId;
        uint256 amount;
        bool active;
    }

    struct TrackedSwap {
        uint256 offerId;
        uint256 offeredTokenId;
        bool active;
    }

    uint256 internal constant MAX_GEMS = 12;
    uint256 internal constant MAX_OFFERS = 16;
    uint256 internal constant MAX_SWAPS = 12;

    DGENFT public nft;
    GemRegistry public registry;
    ReserveManager public reserveManager;
    ComplianceRegistry public compliance;
    PrimarySaleAuction public sale;
    RedemptionManager public redemption;
    Marketplace public marketplace;
    SwapEscrow public swapEscrow;
    MockERC20 public usdc;

    address public admin;
    address public seller;
    address public buyer;
    address public bidder;
    address public custodian;
    address public stranger;
    address public extraOne = address(0xA11CE);
    address public extraTwo = address(0xB0B);

    TrackedGem[] internal _gems;
    TrackedOffer[] internal _offers;
    TrackedSwap[] internal _swaps;
    address[] internal _actors;

    constructor(Protocol memory protocol, address[6] memory actors_) {
        nft = protocol.nft;
        registry = protocol.registry;
        reserveManager = protocol.reserveManager;
        compliance = protocol.compliance;
        sale = protocol.sale;
        redemption = protocol.redemption;
        marketplace = protocol.marketplace;
        swapEscrow = protocol.swapEscrow;
        usdc = protocol.usdc;
        admin = actors_[0];
        seller = actors_[1];
        buyer = actors_[2];
        bidder = actors_[3];
        custodian = actors_[4];
        stranger = actors_[5];

        _actors.push(buyer);
        _actors.push(bidder);
        _actors.push(stranger);
        _actors.push(extraOne);
        _actors.push(extraTwo);

        for (uint256 i = 0; i < _actors.length; i++) {
            vm.deal(_actors[i], 10_000 ether);
            usdc.mint(_actors[i], 10_000_000e6);
        }
    }

    function registerListedGem(uint256 priceSeed) external {
        if (_gems.length >= MAX_GEMS) return;

        uint256 priceUsd = bound(priceSeed, 100, 10_000) * 1e18;
        vm.startPrank(admin);
        registry.setSellerApproval(seller, true);
        uint256 gemId = registry.registerGem(
            seller, custodian, string.concat("ipfs://invariant-", vm.toString(_gems.length)), keccak256("invariant")
        );
        vm.stopPrank();
        vm.prank(custodian);
        registry.confirmCustody(gemId);
        vm.startPrank(admin);
        registry.verifyGem(gemId);
        registry.listGem(gemId, priceUsd);
        vm.stopPrank();

        _gems.push(TrackedGem({gemId: gemId, tokenId: 0, liabilityUsd: 0}));
    }

    function withdrawListedGem(uint256 gemSeed) external {
        if (_gems.length == 0) return;
        TrackedGem storage tracked = _gems[bound(gemSeed, 0, _gems.length - 1)];
        GemRegistry.Gem memory gem = registry.getGem(tracked.gemId);
        if (gem.status != GemRegistry.GemStatus.Listed) return;

        vm.prank(admin);
        registry.withdrawListedGem(tracked.gemId, keccak256("invariant-withdraw"));
    }

    function buyNow(uint256 gemSeed, uint256 actorSeed) external {
        if (_gems.length == 0) return;
        TrackedGem storage tracked = _gems[bound(gemSeed, 0, _gems.length - 1)];
        if (!registry.canMint(tracked.gemId)) return;
        address actor = _actor(actorSeed);
        GemRegistry.Gem memory gem = registry.getGem(tracked.gemId);
        uint256 amount = _usdToEth(gem.priceUsd);

        vm.prank(actor);
        uint256 tokenId = sale.buyNow{value: amount}(tracked.gemId, address(0), amount);
        tracked.tokenId = tokenId;
    }

    function createDailyAuction(uint256 gemSeed) external {
        if (_gems.length == 0) return;
        TrackedGem storage tracked = _gems[bound(gemSeed, 0, _gems.length - 1)];
        if (!registry.canMint(tracked.gemId)) return;
        GemRegistry.Gem memory gem = registry.getGem(tracked.gemId);
        if (_auctionExistsAndOpen(tracked.gemId)) return;

        vm.prank(admin);
        sale.createDailyAuction(tracked.gemId, gem.priceUsd);
    }

    function bidAuction(uint256 gemSeed, uint256 actorSeed, uint256 premiumSeed) external {
        if (_gems.length == 0) return;
        TrackedGem storage tracked = _gems[bound(gemSeed, 0, _gems.length - 1)];
        (bool exists, bool settled, uint64 startTime, uint64 endTime, uint256 floorUsd,,,,,) =
            sale.auctions(tracked.gemId);
        if (!exists || settled || block.timestamp < startTime || block.timestamp >= endTime) return;

        uint256 bidUsd = floorUsd + (bound(premiumSeed, 0, 1_000) * 1e18);
        uint256 amount = _usdToEth(bidUsd);
        vm.prank(_actor(actorSeed));
        sale.bid{value: amount}(tracked.gemId, address(0), amount);
    }

    function settleAuction(uint256 gemSeed) external {
        if (_gems.length == 0) return;
        TrackedGem storage tracked = _gems[bound(gemSeed, 0, _gems.length - 1)];
        if (!_auctionReadyToSettle(tracked.gemId)) return;

        uint256[] memory gemIds = new uint256[](1);
        gemIds[0] = tracked.gemId;
        sale.settleExpiredAuctions(gemIds);
        tracked.tokenId = nft.tokenForGem(tracked.gemId);
    }

    function warpForward(uint256 secondsSeed) external {
        vm.warp(block.timestamp + bound(secondsSeed, 1, 2 days));
    }

    function listToken(uint256 gemSeed, uint256 priceSeed) external {
        TrackedGem storage tracked = _mintedGem(gemSeed);
        if (tracked.tokenId == 0 || nft.transferLocked(tracked.tokenId)) return;
        address owner = _safeOwnerOf(tracked.tokenId);
        if (!_isActor(owner)) return;
        if (_isListed(tracked.tokenId) || _isSwapEscrowed(tracked.tokenId)) return;

        uint256 priceUsd = bound(priceSeed, 100, 10_000) * 1e18;
        vm.startPrank(owner);
        nft.approve(address(marketplace), tracked.tokenId);
        marketplace.list(tracked.tokenId, priceUsd);
        vm.stopPrank();
    }

    function cancelListing(uint256 gemSeed) external {
        TrackedGem storage tracked = _mintedGem(gemSeed);
        if (tracked.tokenId == 0) return;
        (address listingSeller,) = marketplace.listings(tracked.tokenId);
        if (listingSeller == address(0)) return;

        vm.prank(listingSeller);
        marketplace.cancel(tracked.tokenId);
    }

    function buyListing(uint256 gemSeed, uint256 actorSeed) external {
        TrackedGem storage tracked = _mintedGem(gemSeed);
        if (tracked.tokenId == 0) return;
        (address listingSeller, uint256 priceUsd) = marketplace.listings(tracked.tokenId);
        address actor = _actor(actorSeed);
        if (listingSeller == address(0) || listingSeller == actor) return;

        uint256 amount = _usdToUsdc(priceUsd + reserveManager.shortfallUsd(tracked.gemId, priceUsd));
        vm.startPrank(actor);
        usdc.approve(address(marketplace), amount);
        marketplace.buy(tracked.tokenId, address(usdc), amount);
        vm.stopPrank();
    }

    function createMarketplaceOffer(uint256 gemSeed, uint256 actorSeed, uint256 priceSeed) external {
        if (_offers.length >= MAX_OFFERS) return;
        TrackedGem storage tracked = _mintedGem(gemSeed);
        if (tracked.tokenId == 0 || nft.transferLocked(tracked.tokenId)) return;
        address owner = _safeOwnerOf(tracked.tokenId);
        address actor = _actor(actorSeed);
        if (!_isActor(owner) || owner == actor || _isListed(tracked.tokenId) || _isSwapEscrowed(tracked.tokenId)) {
            return;
        }

        uint256 priceUsd = bound(priceSeed, 100, 10_000) * 1e18;
        uint256 amount = _usdToUsdc(priceUsd);
        vm.startPrank(actor);
        usdc.approve(address(marketplace), amount);
        uint256 offerId = marketplace.createOffer(tracked.tokenId, address(usdc), amount);
        vm.stopPrank();

        _offers.push(TrackedOffer({offerId: offerId, tokenId: tracked.tokenId, amount: amount, active: true}));
    }

    function acceptMarketplaceOffer(uint256 offerSeed) external {
        if (_offers.length == 0) return;
        TrackedOffer storage tracked = _offers[bound(offerSeed, 0, _offers.length - 1)];
        if (!tracked.active) return;
        (,,,,, uint64 expiry, bool active) = marketplace.offers(tracked.offerId);
        if (!active || block.timestamp > expiry) return;
        address owner = _safeOwnerOf(tracked.tokenId);
        if (!_isActor(owner)) return;

        vm.startPrank(owner);
        nft.approve(address(marketplace), tracked.tokenId);
        marketplace.acceptOffer(tracked.offerId);
        vm.stopPrank();
        tracked.active = false;
    }

    function cancelExpiredMarketplaceOffer(uint256 offerSeed) external {
        if (_offers.length == 0) return;
        TrackedOffer storage tracked = _offers[bound(offerSeed, 0, _offers.length - 1)];
        if (!tracked.active) return;
        (,,,,, uint64 expiry, bool active) = marketplace.offers(tracked.offerId);
        if (!active) {
            tracked.active = false;
            return;
        }
        vm.warp(expiry + 1);
        marketplace.cancelExpiredOffer(tracked.offerId);
        tracked.active = false;
    }

    function fundReserve(uint256 gemSeed, uint256 amountSeed) external {
        if (_gems.length == 0) return;
        TrackedGem storage tracked = _gems[bound(gemSeed, 0, _gems.length - 1)];
        uint256 amount = bound(amountSeed, 1, 5 ether);
        reserveManager.fundNative{value: amount}(tracked.gemId);
    }

    function consumeReserve(uint256 gemSeed, uint256 amountSeed) external {
        if (_gems.length == 0) return;
        TrackedGem storage tracked = _gems[bound(gemSeed, 0, _gems.length - 1)];
        uint256 balance = reserveManager.reserveBalanceUsd(tracked.gemId);
        if (balance == 0) return;
        uint256 amount = bound(amountSeed, 1, balance);
        vm.prank(admin);
        reserveManager.consumeReserveUsdFor(tracked.gemId, amount, keccak256("invariant-consume"));
    }

    function setProjectedLiability(uint256 gemSeed, uint256 liabilitySeed) external {
        if (_gems.length == 0) return;
        TrackedGem storage tracked = _gems[bound(gemSeed, 0, _gems.length - 1)];
        uint256 liability = bound(liabilitySeed, 0, 20_000) * 1e18;
        vm.prank(admin);
        reserveManager.setProjectedLiabilityUsd(tracked.gemId, liability);
        tracked.liabilityUsd = liability;
    }

    function configureSolvency(uint256 coverageSeed, bool enabled) external {
        vm.startPrank(admin);
        reserveManager.setMinimumCoverageBps(uint16(bound(coverageSeed, 0, 20_000)));
        reserveManager.setGlobalSolvencyCheckEnabled(enabled);
        vm.stopPrank();
    }

    function createSwap(uint256 firstSeed, uint256 secondSeed) external {
        if (_swaps.length >= MAX_SWAPS || _gems.length < 2) return;
        TrackedGem storage first = _mintedGem(firstSeed);
        TrackedGem storage second = _mintedGem(secondSeed);
        if (first.tokenId == 0 || second.tokenId == 0 || first.tokenId == second.tokenId) return;
        if (nft.transferLocked(first.tokenId) || nft.transferLocked(second.tokenId)) return;
        address firstOwner = _safeOwnerOf(first.tokenId);
        address secondOwner = _safeOwnerOf(second.tokenId);
        if (!_isActor(firstOwner) || !_isActor(secondOwner) || firstOwner == secondOwner) return;
        if (_isListed(first.tokenId) || _isListed(second.tokenId)) return;
        if (_isSwapEscrowed(first.tokenId) || _isSwapEscrowed(second.tokenId)) return;

        vm.startPrank(firstOwner);
        nft.approve(address(swapEscrow), first.tokenId);
        uint256 offerId = swapEscrow.createOffer(
            first.tokenId, second.tokenId, address(0), 0, false, uint64(block.timestamp + 1 days)
        );
        vm.stopPrank();
        _swaps.push(TrackedSwap({offerId: offerId, offeredTokenId: first.tokenId, active: true}));
    }

    function cancelSwap(uint256 swapSeed) external {
        if (_swaps.length == 0) return;
        TrackedSwap storage tracked = _swaps[bound(swapSeed, 0, _swaps.length - 1)];
        if (!tracked.active) return;
        (address proposer,,,,,,, bool active) = swapEscrow.offers(tracked.offerId);
        if (!active) {
            tracked.active = false;
            return;
        }
        vm.prank(proposer);
        swapEscrow.cancelOffer(tracked.offerId);
        tracked.active = false;
    }

    function acceptSwap(uint256 swapSeed) external {
        if (_swaps.length == 0) return;
        TrackedSwap storage tracked = _swaps[bound(swapSeed, 0, _swaps.length - 1)];
        if (!tracked.active) return;
        (, uint256 offeredTokenId, uint256 requestedTokenId,,,,, bool active) = swapEscrow.offers(tracked.offerId);
        if (!active || offeredTokenId == 0) {
            tracked.active = false;
            return;
        }
        address requestedOwner = _safeOwnerOf(requestedTokenId);
        if (!_isActor(requestedOwner) || nft.transferLocked(requestedTokenId) || _isListed(requestedTokenId)) return;

        vm.startPrank(requestedOwner);
        nft.approve(address(swapEscrow), requestedTokenId);
        swapEscrow.acceptOffer(tracked.offerId);
        vm.stopPrank();
        tracked.active = false;
    }

    function setBlocked(uint256 actorSeed, bool blocked) external {
        vm.prank(admin);
        compliance.setBlocked(_actor(actorSeed), blocked);
    }

    function requestRedemption(uint256 gemSeed) external {
        TrackedGem storage tracked = _mintedGem(gemSeed);
        if (tracked.tokenId == 0 || nft.transferLocked(tracked.tokenId)) return;
        address owner = _safeOwnerOf(tracked.tokenId);
        if (!_isActor(owner) || !compliance.canRedeem(owner) || _isListed(tracked.tokenId)) return;
        if (_isSwapEscrowed(tracked.tokenId)) return;
        GemRegistry.Gem memory gem = registry.getGem(tracked.gemId);
        if (reserveManager.shortfallUsd(tracked.gemId, gem.priceUsd) != 0) return;

        vm.prank(owner);
        redemption.requestRedemption(tracked.tokenId, keccak256("invariant-redemption"));
    }

    function cancelRedemption(uint256 gemSeed) external {
        TrackedGem storage tracked = _mintedGem(gemSeed);
        if (tracked.tokenId == 0 || !nft.transferLocked(tracked.tokenId)) return;
        vm.prank(admin);
        redemption.cancelRedemption(tracked.tokenId);
    }

    function confirmRedemption(uint256 gemSeed) external {
        TrackedGem storage tracked = _mintedGem(gemSeed);
        if (tracked.tokenId == 0 || !nft.transferLocked(tracked.tokenId)) return;
        vm.prank(custodian);
        redemption.confirmRedemption(tracked.tokenId);
        tracked.tokenId = 0;
    }

    function transferToken(uint256 gemSeed, uint256 actorSeed) external {
        TrackedGem storage tracked = _mintedGem(gemSeed);
        if (tracked.tokenId == 0 || nft.transferLocked(tracked.tokenId)) return;
        address owner = _safeOwnerOf(tracked.tokenId);
        address to = _actor(actorSeed);
        if (!_isActor(owner) || owner == to || _isListed(tracked.tokenId) || _isSwapEscrowed(tracked.tokenId)) return;

        vm.prank(owner);
        nft.transferFrom(owner, to, tracked.tokenId);
    }

    function assertRegistryNftConsistency() external view {
        for (uint256 i = 0; i < _gems.length; i++) {
            GemRegistry.Gem memory gem = registry.getGem(_gems[i].gemId);
            if (gem.status == GemRegistry.GemStatus.Minted || gem.status == GemRegistry.GemStatus.RedemptionRequested) {
                uint256 tokenId = nft.tokenForGem(_gems[i].gemId);
                assertGt(tokenId, 0);
                assertEq(nft.tokenGem(tokenId), _gems[i].gemId);
                assertEq(gem.tokenId, tokenId);
            }
            if (gem.status == GemRegistry.GemStatus.Redeemed) {
                assertEq(nft.tokenForGem(_gems[i].gemId), 0);
            }
            if (gem.status == GemRegistry.GemStatus.Withdrawn) {
                assertFalse(registry.canMint(_gems[i].gemId));
            }
            if (gem.status == GemRegistry.GemStatus.Listed) {
                assertGt(gem.priceUsd, 0);
                assertTrue(registry.sellerApproved(gem.seller));
            }
        }
    }

    function assertReserveAccounting() external view {
        uint256 reserveTotal;
        uint256 liabilityTotal;
        for (uint256 i = 0; i < _gems.length; i++) {
            reserveTotal += reserveManager.reserveBalanceUsd(_gems[i].gemId);
            liabilityTotal += _gems[i].liabilityUsd;
        }
        assertEq(reserveManager.totalReserveBalanceUsd(), reserveTotal);
        assertEq(reserveManager.totalProjectedLiabilitiesUsd(), liabilityTotal);
        if (liabilityTotal == 0) {
            assertEq(reserveManager.coverageRatioBps(), type(uint256).max);
        } else {
            assertEq(reserveManager.coverageRatioBps(), (reserveTotal * 10_000) / liabilityTotal);
        }
    }

    function assertEscrowConsistency() external view {
        uint256 activeOfferUsdc;
        for (uint256 i = 0; i < _gems.length; i++) {
            uint256 tokenId = _gems[i].tokenId;
            if (tokenId == 0) continue;
            (address listingSeller,) = marketplace.listings(tokenId);
            if (listingSeller != address(0)) {
                assertEq(nft.ownerOf(tokenId), address(marketplace));
            }
        }

        for (uint256 i = 0; i < _offers.length; i++) {
            (address offerBidder,,, uint256 amount,,, bool active) = marketplace.offers(_offers[i].offerId);
            if (_offers[i].active && active) {
                assertEq(offerBidder, _safeOfferBidder(_offers[i].offerId));
                activeOfferUsdc += amount;
            }
        }
        assertGe(usdc.balanceOf(address(marketplace)), activeOfferUsdc);

        for (uint256 i = 0; i < _swaps.length; i++) {
            (,,,,,,, bool active) = swapEscrow.offers(_swaps[i].offerId);
            if (_swaps[i].active && active) {
                assertEq(nft.ownerOf(_swaps[i].offeredTokenId), address(swapEscrow));
            }
        }
    }

    function gemCount() external view returns (uint256) {
        return _gems.length;
    }

    function _mintedGem(uint256 gemSeed) private view returns (TrackedGem storage tracked) {
        if (_gems.length == 0) revert("no gems");
        tracked = _gems[bound(gemSeed, 0, _gems.length - 1)];
    }

    function _actor(uint256 seed) private view returns (address) {
        return _actors[bound(seed, 0, _actors.length - 1)];
    }

    function _isActor(address account) private view returns (bool) {
        for (uint256 i = 0; i < _actors.length; i++) {
            if (_actors[i] == account) return true;
        }
        return false;
    }

    function _usdToEth(uint256 usdValue) private pure returns (uint256) {
        uint256 amount = usdValue / 2_000;
        return amount == 0 ? 1 : amount;
    }

    function _usdToUsdc(uint256 usdValue) private pure returns (uint256) {
        uint256 amount = usdValue / 1e12;
        return amount == 0 ? 1 : amount;
    }

    function _safeOwnerOf(uint256 tokenId) private view returns (address owner) {
        try nft.ownerOf(tokenId) returns (address owner_) {
            owner = owner_;
        } catch {
            owner = address(0);
        }
    }

    function _isListed(uint256 tokenId) private view returns (bool) {
        (address listingSeller,) = marketplace.listings(tokenId);
        return listingSeller != address(0);
    }

    function _isSwapEscrowed(uint256 tokenId) private view returns (bool) {
        return _safeOwnerOf(tokenId) == address(swapEscrow);
    }

    function _safeOfferBidder(uint256 offerId) private view returns (address bidder_) {
        (bidder_,,,,,,) = marketplace.offers(offerId);
    }

    function _auctionExistsAndOpen(uint256 gemId) private view returns (bool) {
        (bool exists, bool settled,,,,,,,,) = sale.auctions(gemId);
        return exists && !settled;
    }

    function _auctionReadyToSettle(uint256 gemId) private view returns (bool) {
        (bool exists, bool settled,, uint64 endTime,,,,,,) = sale.auctions(gemId);
        return exists && !settled && block.timestamp >= endTime;
    }
}
