// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DGENFT} from "../src/DGENFT.sol";
import {GemRegistry} from "../src/GemRegistry.sol";
import {Marketplace} from "../src/Marketplace.sol";
import {PaymentTokenRegistry} from "../src/PaymentTokenRegistry.sol";
import {PrimarySaleAuction} from "../src/PrimarySaleAuction.sol";
import {RedemptionManager} from "../src/RedemptionManager.sol";
import {SwapEscrow} from "../src/SwapEscrow.sol";
import {Treasury} from "../src/Treasury.sol";
import {Roles} from "../src/libraries/Roles.sol";
import {MockV3Aggregator} from "./mocks/MockV3Aggregator.sol";
import {FeeOnTransferERC20, MockERC20} from "./mocks/MockERC20.sol";

contract DigitalCaratProtocolTest is Test {
    DGENFT private nft;
    GemRegistry private registry;
    PaymentTokenRegistry private payments;
    Treasury private treasury;
    PrimarySaleAuction private sale;
    RedemptionManager private redemption;
    Marketplace private marketplace;
    SwapEscrow private swapEscrow;

    MockV3Aggregator private ethFeed;
    MockV3Aggregator private usdFeed;
    MockERC20 private usdc;
    FeeOnTransferERC20 private feeToken;

    address private seller = address(0x100);
    address private buyer = address(0x200);
    address private bidder = address(0x300);
    address private platform = address(0x400);
    address private vaultReserve = address(0x500);
    address private insuranceReserve = address(0x600);
    address private treasuryReserve = address(0x700);
    address private feeCollector = address(0x800);

    function setUp() public {
        nft = new DGENFT();
        registry = new GemRegistry();
        payments = new PaymentTokenRegistry();
        treasury = new Treasury();
        sale = new PrimarySaleAuction();
        redemption = new RedemptionManager();
        marketplace = new Marketplace();
        swapEscrow = new SwapEscrow();

        nft.initialize(address(this), "Digital Carat Gem", "DGE");
        registry.initialize(address(this));
        payments.initialize(address(this));
        treasury.initialize(address(this), platform, vaultReserve, insuranceReserve, treasuryReserve);
        sale.initialize(address(this), nft, registry, payments, treasury);
        redemption.initialize(address(this), nft, registry);
        marketplace.initialize(address(this), nft, payments, treasury);
        swapEscrow.initialize(address(this), nft, payments);

        nft.grantRole(Roles.MINTER_ROLE, address(sale));
        nft.grantRole(Roles.BURNER_ROLE, address(redemption));
        nft.grantRole(Roles.LOCKER_ROLE, address(redemption));
        registry.grantRole(Roles.MINTER_ROLE, address(sale));
        registry.grantRole(Roles.REDEEMER_ROLE, address(redemption));
        treasury.grantRole(Roles.SETTLER_ROLE, address(sale));
        treasury.grantRole(Roles.SETTLER_ROLE, address(marketplace));

        ethFeed = new MockV3Aggregator(8, 2_000e8);
        usdFeed = new MockV3Aggregator(8, 1e8);
        payments.setToken(address(0), address(ethFeed), 1 days, true);

        usdc = new MockERC20("USD Coin", "USDC", 6);
        feeToken = new FeeOnTransferERC20(1_000, feeCollector);
        payments.setToken(address(usdc), address(usdFeed), 1 days, true);
        payments.setToken(address(feeToken), address(usdFeed), 1 days, true);

        vm.deal(buyer, 100 ether);
        vm.deal(bidder, 100 ether);
        usdc.mint(buyer, 1_000_000e6);
        usdc.mint(bidder, 1_000_000e6);
        feeToken.mint(buyer, 1_000_000e18);
    }

    function testBuyNowRequiresMintingGates() public {
        uint256 gemId = registry.registerGem(seller, address(0xCAFE), "ipfs://gem-1", keccak256("cert-1"));

        vm.prank(buyer);
        vm.expectRevert(PrimarySaleAuction.GemNotMintable.selector);
        sale.buyNow{value: 0.5 ether}(gemId, address(0), 0.5 ether);
    }

    function testBuyNowNativeEthMintsAndSettles() public {
        uint256 gemId = _listedGem(1_000e18, "ipfs://gem-1");

        uint256 sellerBefore = seller.balance;
        vm.prank(buyer);
        uint256 tokenId = sale.buyNow{value: 0.5 ether}(gemId, address(0), 0.5 ether);

        assertEq(nft.ownerOf(tokenId), buyer);
        assertEq(nft.tokenGem(tokenId), gemId);
        assertEq(seller.balance - sellerBefore, 0.4 ether);
        assertEq(platform.balance, 0.04 ether);
        assertEq(vaultReserve.balance, 0.03 ether);
        assertEq(insuranceReserve.balance, 0.02 ether);
        assertEq(treasuryReserve.balance, 0.01 ether);

        GemRegistry.Gem memory gem = registry.getGem(gemId);
        assertEq(uint256(gem.status), uint256(GemRegistry.GemStatus.Minted));
    }

    function testFeeOnTransferTokenUsesActualReceivedForPricing() public {
        uint256 gemId = _listedGem(900e18, "ipfs://gem-fee");
        uint256 paymentAmount = 1_000e18;

        vm.startPrank(buyer);
        feeToken.approve(address(sale), paymentAmount);
        uint256 tokenId = sale.buyNow(gemId, address(feeToken), paymentAmount);
        vm.stopPrank();

        assertEq(nft.ownerOf(tokenId), buyer);
        assertGt(feeToken.balanceOf(seller), 0);
        assertGt(feeToken.balanceOf(feeCollector), 0);
    }

    function testAuctionRefundsPreviousBidAndSettles() public {
        uint256 gemId = _listedGem(1_000e18, "ipfs://gem-auction");
        sale.createAuction(gemId, 1_000e18, uint64(block.timestamp), uint64(block.timestamp + 1 days));

        uint256 buyerBefore = buyer.balance;
        vm.prank(buyer);
        sale.bid{value: 0.5 ether}(gemId, address(0), 0.5 ether);

        vm.prank(bidder);
        sale.bid{value: 0.6 ether}(gemId, address(0), 0.6 ether);

        assertEq(buyer.balance, buyerBefore);

        vm.warp(block.timestamp + 1 days);
        uint256 tokenId = sale.settleAuction(gemId);
        assertEq(nft.ownerOf(tokenId), bidder);
        assertEq(seller.balance, 0.48 ether);
    }

    function testRedemptionLocksAndBurnsToken() public {
        uint256 gemId = _listedGem(1_000e18, "ipfs://gem-redeem");
        vm.prank(buyer);
        uint256 tokenId = sale.buyNow{value: 0.5 ether}(gemId, address(0), 0.5 ether);

        vm.prank(buyer);
        redemption.requestRedemption(tokenId, keccak256("pickup"));

        vm.prank(buyer);
        vm.expectRevert(DGENFT.TokenLocked.selector);
        nft.transferFrom(buyer, bidder, tokenId);

        redemption.confirmRedemption(tokenId);
        vm.expectRevert();
        nft.ownerOf(tokenId);

        GemRegistry.Gem memory gem = registry.getGem(gemId);
        assertEq(uint256(gem.status), uint256(GemRegistry.GemStatus.Redeemed));
    }

    function testMarketplaceEscrowsAndSellsDgeNft() public {
        uint256 gemId = _listedGem(1_000e18, "ipfs://gem-market");
        vm.prank(buyer);
        uint256 tokenId = sale.buyNow{value: 0.5 ether}(gemId, address(0), 0.5 ether);

        vm.startPrank(buyer);
        nft.approve(address(marketplace), tokenId);
        marketplace.list(tokenId, 1_000e18);
        vm.stopPrank();

        uint256 buyerUsdcBefore = usdc.balanceOf(buyer);
        vm.startPrank(bidder);
        usdc.approve(address(marketplace), 1_000e6);
        marketplace.buy(tokenId, address(usdc), 1_000e6);
        vm.stopPrank();

        assertEq(nft.ownerOf(tokenId), bidder);
        assertEq(usdc.balanceOf(buyer) - buyerUsdcBefore, 800e6);
        assertEq(usdc.balanceOf(platform), 80e6);
        assertEq(usdc.balanceOf(vaultReserve), 60e6);
        assertEq(usdc.balanceOf(insuranceReserve), 40e6);
        assertEq(usdc.balanceOf(treasuryReserve), 20e6);
    }

    function testSwapEscrowSwapsDgeOnly() public {
        uint256 firstGemId = _listedGem(1_000e18, "ipfs://gem-swap-a");
        vm.prank(buyer);
        uint256 firstTokenId = sale.buyNow{value: 0.5 ether}(firstGemId, address(0), 0.5 ether);

        uint256 secondGemId = _listedGem(1_000e18, "ipfs://gem-swap-b");
        vm.prank(bidder);
        uint256 secondTokenId = sale.buyNow{value: 0.5 ether}(secondGemId, address(0), 0.5 ether);

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

    function _listedGem(uint256 priceUsd, string memory uri) private returns (uint256 gemId) {
        registry.setSellerApproval(seller, true);
        gemId = registry.registerGem(seller, address(0xCAFE), uri, keccak256(bytes(uri)));
        registry.confirmCustody(gemId);
        registry.verifyGem(gemId);
        registry.listGem(gemId, priceUsd);
    }
}
