// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {DGENFT} from "../src/DGENFT.sol";
import {GemRegistry} from "../src/GemRegistry.sol";
import {Marketplace} from "../src/Marketplace.sol";
import {PaymentTokenRegistry} from "../src/PaymentTokenRegistry.sol";
import {PrimarySaleAuction} from "../src/PrimarySaleAuction.sol";
import {RedemptionManager} from "../src/RedemptionManager.sol";
import {SwapEscrow} from "../src/SwapEscrow.sol";
import {Treasury} from "../src/Treasury.sol";
import {Roles} from "../src/libraries/Roles.sol";

contract DeployDigitalCarat is Script {
    struct Deployment {
        DGENFT nft;
        GemRegistry registry;
        PaymentTokenRegistry payments;
        Treasury treasury;
        PrimarySaleAuction sale;
        RedemptionManager redemption;
        Marketplace marketplace;
        SwapEscrow swapEscrow;
    }

    function run() external returns (Deployment memory deployment) {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address admin = vm.addr(deployerKey);

        address platformRecipient = vm.envOr("PLATFORM_RECIPIENT", admin);
        address vaultReserveRecipient = vm.envOr("VAULT_RESERVE_RECIPIENT", admin);
        address insuranceReserveRecipient = vm.envOr("INSURANCE_RESERVE_RECIPIENT", admin);
        address treasuryReserveRecipient = vm.envOr("TREASURY_RESERVE_RECIPIENT", admin);

        vm.startBroadcast(deployerKey);

        deployment.nft = DGENFT(
            address(
                new ERC1967Proxy(
                    address(new DGENFT()), abi.encodeCall(DGENFT.initialize, (admin, "Digital Carat Gem", "DGE"))
                )
            )
        );
        deployment.registry = GemRegistry(
            address(new ERC1967Proxy(address(new GemRegistry()), abi.encodeCall(GemRegistry.initialize, (admin))))
        );
        deployment.payments = PaymentTokenRegistry(
            address(
                new ERC1967Proxy(
                    address(new PaymentTokenRegistry()), abi.encodeCall(PaymentTokenRegistry.initialize, (admin))
                )
            )
        );
        deployment.treasury = Treasury(
            payable(address(
                    new ERC1967Proxy(
                        address(new Treasury()),
                        abi.encodeCall(
                            Treasury.initialize,
                            (
                                admin,
                                platformRecipient,
                                vaultReserveRecipient,
                                insuranceReserveRecipient,
                                treasuryReserveRecipient
                            )
                        )
                    )
                ))
        );
        deployment.sale = PrimarySaleAuction(
            payable(address(
                    new ERC1967Proxy(
                        address(new PrimarySaleAuction()),
                        abi.encodeCall(
                            PrimarySaleAuction.initialize,
                            (admin, deployment.nft, deployment.registry, deployment.payments, deployment.treasury)
                        )
                    )
                ))
        );
        deployment.redemption = RedemptionManager(
            address(
                new ERC1967Proxy(
                    address(new RedemptionManager()),
                    abi.encodeCall(RedemptionManager.initialize, (admin, deployment.nft, deployment.registry))
                )
            )
        );
        deployment.marketplace = Marketplace(
            payable(address(
                    new ERC1967Proxy(
                        address(new Marketplace()),
                        abi.encodeCall(
                            Marketplace.initialize, (admin, deployment.nft, deployment.payments, deployment.treasury)
                        )
                    )
                ))
        );
        deployment.swapEscrow = SwapEscrow(
            payable(address(
                    new ERC1967Proxy(
                        address(new SwapEscrow()),
                        abi.encodeCall(SwapEscrow.initialize, (admin, deployment.nft, deployment.payments))
                    )
                ))
        );

        deployment.nft.grantRole(Roles.MINTER_ROLE, address(deployment.sale));
        deployment.nft.grantRole(Roles.BURNER_ROLE, address(deployment.redemption));
        deployment.nft.grantRole(Roles.LOCKER_ROLE, address(deployment.redemption));
        deployment.registry.grantRole(Roles.MINTER_ROLE, address(deployment.sale));
        deployment.registry.grantRole(Roles.REDEEMER_ROLE, address(deployment.redemption));
        deployment.treasury.grantRole(Roles.SETTLER_ROLE, address(deployment.sale));
        deployment.treasury.grantRole(Roles.SETTLER_ROLE, address(deployment.marketplace));

        vm.stopBroadcast();
    }
}
