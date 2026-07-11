// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
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

contract DeployDigitalCarat is Script {
    struct Deployment {
        DGENFT nft;
        GemRegistry registry;
        PaymentTokenRegistry payments;
        ReserveManager reserveManager;
        ComplianceRegistry compliance;
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
        deployment.reserveManager = ReserveManager(
            payable(address(
                    new ERC1967Proxy(
                        address(new ReserveManager()),
                        abi.encodeCall(ReserveManager.initialize, (admin, deployment.payments))
                    )
                ))
        );
        deployment.compliance = ComplianceRegistry(
            address(
                new ERC1967Proxy(
                    address(new ComplianceRegistry()), abi.encodeCall(ComplianceRegistry.initialize, (admin))
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
                            (
                                admin,
                                deployment.nft,
                                deployment.registry,
                                deployment.payments,
                                deployment.reserveManager,
                                deployment.treasury
                            )
                        )
                    )
                ))
        );
        deployment.redemption = RedemptionManager(
            address(
                new ERC1967Proxy(
                    address(new RedemptionManager()),
                    abi.encodeCall(
                        RedemptionManager.initialize,
                        (admin, deployment.nft, deployment.registry, deployment.reserveManager, deployment.compliance)
                    )
                )
            )
        );
        deployment.marketplace = Marketplace(
            payable(address(
                    new ERC1967Proxy(
                        address(new Marketplace()),
                        abi.encodeCall(
                            Marketplace.initialize,
                            (admin, deployment.nft, deployment.payments, deployment.reserveManager, deployment.treasury)
                        )
                    )
                ))
        );
        deployment.swapEscrow = SwapEscrow(
            payable(address(
                    new ERC1967Proxy(
                        address(new SwapEscrow()),
                        abi.encodeCall(
                            SwapEscrow.initialize,
                            (admin, deployment.nft, deployment.registry, deployment.payments, deployment.reserveManager)
                        )
                    )
                ))
        );

        _configurePayments(deployment.payments);
        _configureReservePolicy(deployment.reserveManager);
        deployment.marketplace.setSecondaryFeeRecipient(platformRecipient);
        uint256 secondaryFeeBps = vm.envOr("SECONDARY_FEE_BPS", uint256(200));
        require(secondaryFeeBps <= 10_000, "SECONDARY_FEE_BPS too high");
        // casting to uint16 is safe because the value is capped at 10_000 above.
        // forge-lint: disable-next-line(unsafe-typecast)
        deployment.marketplace.setSecondaryFeeBps(uint16(secondaryFeeBps));

        deployment.nft.grantRole(Roles.MINTER_ROLE, address(deployment.sale));
        deployment.nft.grantRole(Roles.BURNER_ROLE, address(deployment.redemption));
        deployment.nft.grantRole(Roles.LOCKER_ROLE, address(deployment.redemption));
        deployment.registry.grantRole(Roles.MINTER_ROLE, address(deployment.sale));
        deployment.registry.grantRole(Roles.REDEEMER_ROLE, address(deployment.redemption));
        deployment.treasury.grantRole(Roles.SETTLER_ROLE, address(deployment.sale));
        deployment.treasury.grantRole(Roles.SETTLER_ROLE, address(deployment.marketplace));
        deployment.reserveManager.grantRole(Roles.RESERVE_OPERATOR_ROLE, address(deployment.sale));
        deployment.reserveManager.grantRole(Roles.RESERVE_OPERATOR_ROLE, address(deployment.marketplace));

        vm.stopBroadcast();
    }

    function _configurePayments(PaymentTokenRegistry payments) private {
        uint48 staleAfter = uint48(vm.envUint("PRICE_STALE_AFTER"));
        payments.setToken(address(0), vm.envAddress("ETH_USD_FEED"), staleAfter, true);

        address[] memory empty;
        address[] memory tokens = vm.envOr("PAYMENT_TOKENS", ",", empty);
        address[] memory feeds = vm.envOr("PAYMENT_TOKEN_USD_FEEDS", ",", empty);
        require(tokens.length == feeds.length, "PAYMENT_TOKENS length mismatch");

        for (uint256 i = 0; i < tokens.length; i++) {
            payments.setToken(tokens[i], feeds[i], staleAfter, true);
        }
    }

    function _configureReservePolicy(ReserveManager reserveManager) private {
        uint256 defaultReserveBps = vm.envUint("DEFAULT_RESERVE_BPS");
        require(defaultReserveBps <= 10_000, "DEFAULT_RESERVE_BPS too high");
        // casting to uint16 is safe because the value is capped at 10_000 above.
        // forge-lint: disable-next-line(unsafe-typecast)
        reserveManager.setDefaultReserveBps(uint16(defaultReserveBps));

        uint256[] memory bracketMaxUsd = vm.envUint("RESERVE_BRACKET_MAX_USD", ",");
        uint256[] memory bracketBps = vm.envUint("RESERVE_BRACKET_BPS", ",");
        require(bracketMaxUsd.length == bracketBps.length && bracketMaxUsd.length != 0, "Invalid reserve brackets");

        ReserveManager.ReserveBracket[] memory brackets = new ReserveManager.ReserveBracket[](bracketMaxUsd.length);
        uint256 minPriceUsd;
        for (uint256 i = 0; i < bracketMaxUsd.length; i++) {
            require(bracketMaxUsd[i] > minPriceUsd, "Reserve bracket max not increasing");
            require(bracketBps[i] <= 10_000, "Reserve bracket bps too high");
            // casting to uint16 is safe because the value is capped at 10_000 above.
            // forge-lint: disable-next-line(unsafe-typecast)
            uint16 reserveBps = uint16(bracketBps[i]);
            brackets[i] = ReserveManager.ReserveBracket({
                minPriceUsd: minPriceUsd, maxPriceUsd: bracketMaxUsd[i], reserveBps: reserveBps
            });
            minPriceUsd = bracketMaxUsd[i];
        }
        reserveManager.setReserveBrackets(brackets);
    }
}
