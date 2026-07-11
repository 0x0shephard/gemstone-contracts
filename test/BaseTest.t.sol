// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ComplianceRegistry} from "../src/ComplianceRegistry.sol";
import {DGENFT} from "../src/DGENFT.sol";
import {GemRegistry} from "../src/GemRegistry.sol";
import {Marketplace} from "../src/Marketplace.sol";
import {PaymentTokenRegistry} from "../src/PaymentTokenRegistry.sol";
import {PrimarySaleAuction} from "../src/PrimarySaleAuction.sol";
import {RedemptionManager} from "../src/RedemptionManager.sol";
import {ReserveManager} from "../src/ReserveManager.sol";
import {SwapEscrow} from "../src/SwapEscrow.sol";
import {Treasury} from "../src/Treasury.sol";
import {Roles} from "../src/libraries/Roles.sol";
import {MockV3Aggregator} from "./mocks/MockV3Aggregator.sol";
import {FeeOnTransferERC20, MockERC20} from "./mocks/MockERC20.sol";

abstract contract BaseTest is Test {
    DGENFT internal nft;
    GemRegistry internal registry;
    PaymentTokenRegistry internal payments;
    Treasury internal treasury;
    ReserveManager internal reserveManager;
    ComplianceRegistry internal compliance;
    PrimarySaleAuction internal sale;
    RedemptionManager internal redemption;
    Marketplace internal marketplace;
    SwapEscrow internal swapEscrow;

    MockV3Aggregator internal ethFeed;
    MockV3Aggregator internal usdFeed;
    MockERC20 internal usdc;
    FeeOnTransferERC20 internal feeToken;

    address internal admin = address(this);
    address internal seller = address(0x100);
    address internal buyer = address(0x200);
    address internal bidder = address(0x300);
    address internal custodian = address(0x350);
    address internal platform = address(0x400);
    address internal vaultReserve = address(0x500);
    address internal insuranceReserve = address(0x600);
    address internal treasuryReserve = address(0x700);
    address internal feeCollector = address(0x800);
    address internal stranger = address(0x900);

    function setUp() public virtual {
        _deployProtocol();
        _configureDefaultRoles();
        _configureDefaultPayments();
        _fundDefaultActors();
    }

    function _deployProtocol() internal {
        nft = new DGENFT();
        registry = new GemRegistry();
        payments = new PaymentTokenRegistry();
        treasury = new Treasury();
        reserveManager = new ReserveManager();
        compliance = new ComplianceRegistry();
        sale = new PrimarySaleAuction();
        redemption = new RedemptionManager();
        marketplace = new Marketplace();
        swapEscrow = new SwapEscrow();

        nft.initialize(admin, "Digital Carat Gem", "DGE");
        registry.initialize(admin);
        payments.initialize(admin);
        reserveManager.initialize(admin, payments);
        compliance.initialize(admin);
        treasury.initialize(admin, platform, vaultReserve, insuranceReserve, treasuryReserve);
        sale.initialize(admin, nft, registry, payments, reserveManager, treasury);
        redemption.initialize(admin, nft, registry, reserveManager, compliance);
        marketplace.initialize(admin, nft, payments, reserveManager, treasury);
        marketplace.setSecondaryFeeRecipient(platform);
        swapEscrow.initialize(admin, nft, registry, payments, reserveManager);
    }

    function _configureDefaultRoles() internal {
        nft.grantRole(Roles.MINTER_ROLE, address(sale));
        nft.grantRole(Roles.BURNER_ROLE, address(redemption));
        nft.grantRole(Roles.LOCKER_ROLE, address(redemption));
        registry.grantRole(Roles.MINTER_ROLE, address(sale));
        registry.grantRole(Roles.REDEEMER_ROLE, address(redemption));
        registry.grantRole(Roles.CUSTODIAN_ROLE, custodian);
        treasury.grantRole(Roles.SETTLER_ROLE, address(sale));
        treasury.grantRole(Roles.SETTLER_ROLE, address(marketplace));
        reserveManager.grantRole(Roles.RESERVE_OPERATOR_ROLE, address(sale));
        reserveManager.grantRole(Roles.RESERVE_OPERATOR_ROLE, address(marketplace));
    }

    function _configureDefaultPayments() internal {
        ethFeed = new MockV3Aggregator(8, 2_000e8);
        usdFeed = new MockV3Aggregator(8, 1e8);
        payments.setToken(address(0), address(ethFeed), 1 days, true);

        usdc = new MockERC20("USD Coin", "USDC", 6);
        feeToken = new FeeOnTransferERC20(1_000, feeCollector);
        payments.setToken(address(usdc), address(usdFeed), 1 days, true);
        payments.setToken(address(feeToken), address(usdFeed), 1 days, true);
    }

    function _fundDefaultActors() internal {
        vm.deal(buyer, 100 ether);
        vm.deal(bidder, 100 ether);
        vm.deal(stranger, 100 ether);
        usdc.mint(buyer, 1_000_000e6);
        usdc.mint(bidder, 1_000_000e6);
        usdc.mint(stranger, 1_000_000e6);
        feeToken.mint(buyer, 1_000_000e18);
    }

    function _listedGem(uint256 priceUsd, string memory uri) internal returns (uint256 gemId) {
        registry.setSellerApproval(seller, true);
        gemId = registry.registerGem(seller, custodian, uri, keccak256(bytes(uri)));
        vm.prank(custodian);
        registry.confirmCustody(gemId);
        registry.verifyGem(gemId);
        registry.listGem(gemId, priceUsd);
    }

    function _mintGemTo(address owner, uint256 priceUsd, string memory uri)
        internal
        returns (uint256 gemId, uint256 tokenId)
    {
        gemId = _listedGem(priceUsd, uri);
        vm.prank(owner);
        tokenId = sale.buyNow{value: (priceUsd / 2_000)}(gemId, address(0), priceUsd / 2_000);
    }

    function _setTwoTierReservePolicy() internal {
        ReserveManager.ReserveBracket[] memory brackets = new ReserveManager.ReserveBracket[](2);
        brackets[0] = ReserveManager.ReserveBracket({minPriceUsd: 0, maxPriceUsd: 1_000e18, reserveBps: 1_000});
        brackets[1] =
            ReserveManager.ReserveBracket({minPriceUsd: 1_000e18, maxPriceUsd: type(uint256).max, reserveBps: 400});
        reserveManager.setReserveBrackets(brackets);
    }
}
