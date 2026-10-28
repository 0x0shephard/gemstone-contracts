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

    function run() external virtual returns (Deployment memory deployment) {
        deployment = deploy();
    }

    /// @dev Public so a script can inherit the deployment instead of creating this
    ///      contract: a nested creation carrying every implementation's initcode
    ///      exceeds the 30M gas forge gives a nested call (DeployLocalE2E).
    function deploy() public returns (Deployment memory deployment) {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address admin = vm.addr(deployerKey);
        uint256 expectedChainId = vm.envOr("EXPECTED_CHAIN_ID", block.chainid);
        bool productionDeployment = vm.envOr("PRODUCTION_DEPLOYMENT", false);
        require(block.chainid == expectedChainId, "RPC chain does not match EXPECTED_CHAIN_ID");

        address platformRecipient = vm.envOr("PLATFORM_RECIPIENT", admin);
        address vaultReserveRecipient = vm.envOr("VAULT_RESERVE_RECIPIENT", admin);
        address insuranceReserveRecipient = vm.envOr("INSURANCE_RESERVE_RECIPIENT", admin);
        address treasuryReserveRecipient = vm.envOr("TREASURY_RESERVE_RECIPIENT", admin);
        address giftOperator = vm.envAddress("GIFT_OPERATOR_ADDRESS");
        require(giftOperator != address(0), "GIFT_OPERATOR_ADDRESS missing");
        if (productionDeployment) {
            require(block.chainid != 11155111, "Production cannot target Sepolia");
            require(
                platformRecipient != admin && vaultReserveRecipient != admin && insuranceReserveRecipient != admin
                    && treasuryReserveRecipient != admin,
                "Production recipients must not default to deployer"
            );
        }

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
        _initializeRedemptionV2(deployment.redemption);
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

        _initializeNftReserveGuard(deployment, giftOperator);

        _configurePayments(deployment.payments, productionDeployment);
        _configureReservePolicy(deployment.reserveManager, productionDeployment);
        deployment.marketplace.setSecondaryFeeRecipient(platformRecipient);
        uint256 secondaryFeeBps = vm.envOr("SECONDARY_FEE_BPS", uint256(200));
        require(secondaryFeeBps <= deployment.marketplace.MAX_SECONDARY_FEE_BPS(), "SECONDARY_FEE_BPS too high");
        // casting to uint16 is safe because the value is capped at MAX_SECONDARY_FEE_BPS above.
        // forge-lint: disable-next-line(unsafe-typecast)
        deployment.marketplace.setSecondaryFeeBps(uint16(secondaryFeeBps));

        deployment.nft.grantRole(Roles.MINTER_ROLE, address(deployment.sale));
        deployment.nft.grantRole(Roles.BURNER_ROLE, address(deployment.redemption));
        deployment.nft.grantRole(Roles.LOCKER_ROLE, address(deployment.redemption));
        deployment.nft.revokeRole(Roles.BURNER_ROLE, admin);
        deployment.nft.revokeRole(Roles.LOCKER_ROLE, admin);
        // In production only the primary sale mints; test networks keep admin minting for fixtures.
        if (productionDeployment) deployment.nft.revokeRole(Roles.MINTER_ROLE, admin);
        _configureCollection(deployment.nft, admin, productionDeployment);
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

    function _initializeRedemptionV2(RedemptionManager redemption) private {
        address[] memory noRecoveryApprovers;
        address[] memory recoveryApprovers = vm.envOr("REDEMPTION_RECOVERY_APPROVERS", ",", noRecoveryApprovers);
        uint256 threshold = vm.envOr("REDEMPTION_RECOVERY_THRESHOLD", uint256(2));
        uint256 delay = vm.envOr("REDEMPTION_RECOVERY_DELAY", uint256(7 days));
        require(threshold <= type(uint8).max, "Recovery threshold too high");
        require(delay <= type(uint64).max, "Recovery delay too high");
        redemption.initializeV2(
            vm.envAddress("REDEMPTION_PROOF_APPROVER"),
            vm.envAddress("REDEMPTION_AUTHORIZER"),
            recoveryApprovers,
            uint8(threshold),
            uint64(delay)
        );
    }

    function _initializeNftReserveGuard(Deployment memory deployment, address giftOperator) private {
        address[] memory trustedEscrows = new address[](3);
        trustedEscrows[0] = address(deployment.marketplace);
        trustedEscrows[1] = address(deployment.swapEscrow);
        trustedEscrows[2] = giftOperator;
        deployment.nft
            .initializeReserveGuard(deployment.reserveManager, trustedEscrows, new uint256[](0), new address[](0));
    }

    function _configurePayments(PaymentTokenRegistry payments, bool productionDeployment) private {
        // Each feed has its own heartbeat (Arbitrum's ETH/USD and USDC/USD update at least
        // daily), so staleness is set per feed; PRICE_STALE_AFTER is the default for all.
        uint256 defaultStaleAfter = vm.envUint("PRICE_STALE_AFTER");
        _configurePaymentToken(
            payments,
            address(0),
            vm.envAddress("ETH_USD_FEED"),
            _staleAfter(vm.envOr("ETH_USD_STALE_AFTER", defaultStaleAfter)),
            vm.envInt("ETH_USD_MIN_ANSWER"),
            vm.envInt("ETH_USD_MAX_ANSWER")
        );

        address[] memory empty;
        int256[] memory emptyInt;
        uint256[] memory emptyUint;
        address[] memory tokens = vm.envOr("PAYMENT_TOKENS", ",", empty);
        address[] memory feeds = vm.envOr("PAYMENT_TOKEN_USD_FEEDS", ",", empty);
        int256[] memory minAnswers = vm.envOr("PAYMENT_TOKEN_MIN_ANSWERS", ",", emptyInt);
        int256[] memory maxAnswers = vm.envOr("PAYMENT_TOKEN_MAX_ANSWERS", ",", emptyInt);
        uint256[] memory staleAfters = vm.envOr("PAYMENT_TOKEN_STALE_AFTERS", ",", emptyUint);
        require(
            tokens.length == feeds.length && tokens.length == minAnswers.length && tokens.length == maxAnswers.length,
            "PAYMENT_TOKENS configuration length mismatch"
        );
        require(
            staleAfters.length == 0 || staleAfters.length == tokens.length, "PAYMENT_TOKEN_STALE_AFTERS length mismatch"
        );
        if (productionDeployment) require(tokens.length != 0, "Production stablecoin missing");

        for (uint256 i = 0; i < tokens.length; i++) {
            require(tokens[i] != address(0), "PAYMENT_TOKENS cannot contain native asset");
            uint48 staleAfter = _staleAfter(staleAfters.length == 0 ? defaultStaleAfter : staleAfters[i]);
            _configurePaymentToken(payments, tokens[i], feeds[i], staleAfter, minAnswers[i], maxAnswers[i]);
        }

        address uptimeFeed = vm.envOr("SEQUENCER_UPTIME_FEED", address(0));
        if (productionDeployment && _isSequencerL2(block.chainid)) {
            require(uptimeFeed != address(0), "SEQUENCER_UPTIME_FEED required on this L2");
        }
        if (uptimeFeed != address(0)) {
            uint256 gracePeriod = vm.envOr("SEQUENCER_GRACE_PERIOD", uint256(1 hours));
            require(gracePeriod != 0 && gracePeriod <= 1 days, "SEQUENCER_GRACE_PERIOD out of range");
            // casting to uint48 is safe because the value is capped at one day above.
            // forge-lint: disable-next-line(unsafe-typecast)
            payments.setSequencerUptimeFeed(uptimeFeed, uint48(gracePeriod));
        }
    }

    /// @dev Marketplace-facing collection settings, all optional: the owner OpenSea lets edit the
    ///      collection page, the ERC-7572 metadata URI, and the ERC-2981 royalty.
    function _configureCollection(DGENFT nft, address admin, bool productionDeployment) private {
        address collectionOwner = vm.envOr("COLLECTION_OWNER", address(0));
        if (collectionOwner != address(0)) {
            if (productionDeployment) require(collectionOwner != admin, "COLLECTION_OWNER must not be the deployer");
            nft.setCollectionOwner(collectionOwner);
        }

        string memory uri = vm.envOr("CONTRACT_URI", string(""));
        if (bytes(uri).length != 0) nft.setContractURI(uri);

        uint256 royaltyBps = vm.envOr("ROYALTY_BPS", uint256(0));
        require(royaltyBps <= nft.MAX_ROYALTY_BPS(), "ROYALTY_BPS above 10%");
        if (royaltyBps != 0) {
            address receiver = vm.envAddress("ROYALTY_RECEIVER");
            require(receiver != address(0), "ROYALTY_RECEIVER missing");
            if (productionDeployment) require(receiver != admin, "ROYALTY_RECEIVER must not be the deployer");
            // casting to uint96 is safe because the value is capped at DGENFT.MAX_ROYALTY_BPS above.
            // forge-lint: disable-next-line(unsafe-typecast)
            nft.setDefaultRoyalty(receiver, uint96(royaltyBps));
        }
    }

    /// @dev Rollups with a single sequencer and a Chainlink uptime feed: Arbitrum One and Nova,
    ///      OP Mainnet, Base.
    function _isSequencerL2(uint256 chainId) private pure returns (bool) {
        return chainId == 42161 || chainId == 42170 || chainId == 10 || chainId == 8453;
    }

    function _staleAfter(uint256 seconds_) private pure returns (uint48) {
        require(seconds_ != 0 && seconds_ <= 7 days, "Price staleness out of range");
        // casting to uint48 is safe because the value is capped at seven days above.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint48(seconds_);
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

    function _configureReservePolicy(ReserveManager reserveManager, bool productionDeployment) private {
        // At the contract default of 100% there is no headroom: once reserves are on, a 0.05% dip in
        // the ETH price held as reserve halts every purchase. Production must choose a floor.
        uint256 minimumCoverageBps = productionDeployment
            ? vm.envUint("MINIMUM_COVERAGE_BPS")
            : vm.envOr("MINIMUM_COVERAGE_BPS", uint256(10_000));
        require(minimumCoverageBps >= 9_000 && minimumCoverageBps <= 10_000, "MINIMUM_COVERAGE_BPS out of range");
        // casting to uint16 is safe because the value is capped at 10_000 above.
        // forge-lint: disable-next-line(unsafe-typecast)
        reserveManager.setMinimumCoverageBps(uint16(minimumCoverageBps));

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
