// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
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
                        abi.encodeCall(ReserveManager.initialize, (admin, deployment.payments, deployment.registry))
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
        deployment.nft.revokeRole(Roles.BURNER_ROLE, admin);
        deployment.nft.revokeRole(Roles.LOCKER_ROLE, admin);
        deployment.registry.grantRole(Roles.MINTER_ROLE, address(deployment.sale));
        deployment.registry.grantRole(Roles.REDEEMER_ROLE, address(deployment.redemption));
        deployment.treasury.grantRole(Roles.SETTLER_ROLE, address(deployment.sale));
        deployment.treasury.grantRole(Roles.SETTLER_ROLE, address(deployment.marketplace));
        deployment.reserveManager.grantRole(Roles.RESERVE_OPERATOR_ROLE, address(deployment.sale));
        deployment.reserveManager.grantRole(Roles.RESERVE_OPERATOR_ROLE, address(deployment.marketplace));
        deployment.reserveManager.grantRole(Roles.RESERVE_OPERATOR_ROLE, address(deployment.redemption));

        vm.stopBroadcast();

        _logDeployment(admin, deployment);
    }

    function _logDeployment(address admin, Deployment memory deployment) private view {
        console2.log("Digital Carat deployment");
        console2.log("chainId", block.chainid);
        console2.log("admin", admin);
        console2.log("DGENFT", address(deployment.nft));
        console2.log("GemRegistry", address(deployment.registry));
        console2.log("PaymentTokenRegistry", address(deployment.payments));
        console2.log("ReserveManager", address(deployment.reserveManager));
        console2.log("ComplianceRegistry", address(deployment.compliance));
        console2.log("Treasury", address(deployment.treasury));
        console2.log("PrimarySaleAuction", address(deployment.sale));
        console2.log("RedemptionManager", address(deployment.redemption));
        console2.log("Marketplace", address(deployment.marketplace));
        console2.log("SwapEscrow", address(deployment.swapEscrow));
    }

    function _configurePayments(PaymentTokenRegistry payments) private {
        uint48 staleAfter = uint48(vm.envUint("PRICE_STALE_AFTER"));
        _configurePaymentToken(
            payments,
            address(0),
            vm.envAddress("ETH_USD_FEED"),
            staleAfter,
            vm.envInt("ETH_USD_MIN_ANSWER"),
            vm.envInt("ETH_USD_MAX_ANSWER")
        );

        address[] memory empty;
        int256[] memory emptyInt;
        address[] memory tokens = vm.envOr("PAYMENT_TOKENS", ",", empty);
        address[] memory feeds = vm.envOr("PAYMENT_TOKEN_USD_FEEDS", ",", empty);
        int256[] memory minAnswers = vm.envOr("PAYMENT_TOKEN_MIN_ANSWERS", ",", emptyInt);
        int256[] memory maxAnswers = vm.envOr("PAYMENT_TOKEN_MAX_ANSWERS", ",", emptyInt);
        require(
            tokens.length == feeds.length && tokens.length == minAnswers.length && tokens.length == maxAnswers.length,
            "PAYMENT_TOKENS configuration length mismatch"
        );

        for (uint256 i = 0; i < tokens.length; i++) {
            _configurePaymentToken(payments, tokens[i], feeds[i], staleAfter, minAnswers[i], maxAnswers[i]);
        }
    }

    function _configurePaymentToken(
        PaymentTokenRegistry payments,
        address token,
        address feed,
        uint48 staleAfter,
        int256 minAnswer,
        int256 maxAnswer
    ) private {
        require(
            minAnswer > 0 && maxAnswer > minAnswer && maxAnswer <= type(int192).max,
            "Invalid payment-token oracle bounds"
        );
        payments.setToken(token, feed, staleAfter, false);
        // casts are safe because both values are validated against the positive int192 range above.
        // forge-lint: disable-next-line(unsafe-typecast)
        int192 minAnswer192 = int192(minAnswer);
        // forge-lint: disable-next-line(unsafe-typecast)
        int192 maxAnswer192 = int192(maxAnswer);
        payments.setTokenBounds(token, minAnswer192, maxAnswer192);
        payments.setToken(token, feed, staleAfter, true);
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
