// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
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
import {BaseTest} from "./BaseTest.t.sol";
import {MockV3Aggregator} from "./mocks/MockV3Aggregator.sol";

contract DigitalCaratDeploymentTest is BaseTest {
    function testProxyDeploymentWiringAndConfiguredBuyNow() public {
        DGENFT nft = DGENFT(
            address(
                new ERC1967Proxy(
                    address(new DGENFT()), abi.encodeCall(DGENFT.initialize, (admin, "Digital Carat Gem", "DGE"))
                )
            )
        );
        GemRegistry registry = GemRegistry(
            address(new ERC1967Proxy(address(new GemRegistry()), abi.encodeCall(GemRegistry.initialize, (admin))))
        );
        PaymentTokenRegistry payments = PaymentTokenRegistry(
            address(
                new ERC1967Proxy(
                    address(new PaymentTokenRegistry()), abi.encodeCall(PaymentTokenRegistry.initialize, (admin))
                )
            )
        );
        ReserveManager reserveManager = ReserveManager(
            payable(address(
                    new ERC1967Proxy(
                        address(new ReserveManager()),
                        abi.encodeCall(ReserveManager.initialize, (admin, payments, registry))
                    )
                ))
        );
        ComplianceRegistry compliance = ComplianceRegistry(
            address(
                new ERC1967Proxy(
                    address(new ComplianceRegistry()), abi.encodeCall(ComplianceRegistry.initialize, (admin))
                )
            )
        );
        Treasury treasury = Treasury(
            payable(address(
                    new ERC1967Proxy(
                        address(new Treasury()),
                        abi.encodeCall(
                            Treasury.initialize, (admin, platform, vaultReserve, insuranceReserve, treasuryReserve)
                        )
                    )
                ))
        );
        PrimarySaleAuction sale = PrimarySaleAuction(
            payable(address(
                    new ERC1967Proxy(
                        address(new PrimarySaleAuction()),
                        abi.encodeCall(
                            PrimarySaleAuction.initialize, (admin, nft, registry, payments, reserveManager, treasury)
                        )
                    )
                ))
        );
        RedemptionManager redemption = RedemptionManager(
            address(
                new ERC1967Proxy(
                    address(new RedemptionManager()),
                    abi.encodeCall(RedemptionManager.initialize, (admin, nft, registry, reserveManager, compliance))
                )
            )
        );
        Marketplace marketplace = Marketplace(
            payable(address(
                    new ERC1967Proxy(
                        address(new Marketplace()),
                        abi.encodeCall(
                            Marketplace.initialize, (admin, nft, registry, payments, reserveManager, treasury)
                        )
                    )
                ))
        );
        SwapEscrow swapEscrow = SwapEscrow(
            payable(address(
                    new ERC1967Proxy(
                        address(new SwapEscrow()),
                        abi.encodeCall(SwapEscrow.initialize, (admin, nft, registry, payments, reserveManager))
                    )
                ))
        );

        nft.grantRole(Roles.MINTER_ROLE, address(sale));
        nft.grantRole(Roles.BURNER_ROLE, address(redemption));
        nft.grantRole(Roles.LOCKER_ROLE, address(redemption));
        nft.revokeRole(Roles.BURNER_ROLE, admin);
        nft.revokeRole(Roles.LOCKER_ROLE, admin);
        registry.grantRole(Roles.MINTER_ROLE, address(sale));
        registry.grantRole(Roles.REDEEMER_ROLE, address(redemption));
        registry.grantRole(Roles.CUSTODIAN_ROLE, custodian);
        treasury.grantRole(Roles.SETTLER_ROLE, address(sale));
        treasury.grantRole(Roles.SETTLER_ROLE, address(marketplace));
        reserveManager.grantRole(Roles.RESERVE_OPERATOR_ROLE, address(sale));
        reserveManager.grantRole(Roles.RESERVE_OPERATOR_ROLE, address(marketplace));
        reserveManager.grantRole(Roles.RESERVE_OPERATOR_ROLE, address(redemption));
        marketplace.setSecondaryFeeRecipient(platform);

        payments.setToken(address(0), address(new MockV3Aggregator(8, 2_000e8)), 1 days, true);
        reserveManager.setDefaultReserveBps(500);
        ReserveManager.ReserveBracket[] memory brackets = new ReserveManager.ReserveBracket[](1);
        brackets[0] = ReserveManager.ReserveBracket({minPriceUsd: 0, maxPriceUsd: type(uint256).max, reserveBps: 500});
        reserveManager.setReserveBrackets(brackets);

        registry.setSellerApproval(seller, true);
        uint256 gemId = registry.registerGem(seller, custodian, "ipfs://proxy-gem", keccak256("proxy"));
        vm.prank(custodian);
        registry.confirmCustody(gemId);
        registry.verifyGem(gemId);
        registry.listGem(gemId, 1_000e18);

        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        uint256 tokenId = sale.buyNow{value: 0.525 ether}(gemId, address(0), 0.525 ether);

        assertEq(nft.ownerOf(tokenId), buyer);
        assertEq(reserveManager.reserveBalanceUsd(gemId), 50e18);
        assertTrue(swapEscrow.hasRole(Roles.UPGRADER_ROLE, admin));
        assertTrue(compliance.hasRole(Roles.COMPLIANCE_ROLE, admin));
    }
}
