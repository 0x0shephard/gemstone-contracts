// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DeployDigitalCarat} from "../script/DeployDigitalCarat.s.sol";
import {Roles} from "../src/libraries/Roles.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV3Aggregator} from "./mocks/MockV3Aggregator.sol";

/// @dev Runs the real deploy script down its production Arbitrum path against mock feeds.
contract DeployDigitalCaratScriptTest is Test {
    uint256 private constant DEPLOYER_KEY = 0xA11CE;
    MockV3Aggregator private ethFeed;
    MockV3Aggregator private usdcFeed;
    MockV3Aggregator private sequencer;
    MockERC20 private usdc;

    function setUp() public {
        vm.chainId(42161);
        vm.warp(30 days);
        ethFeed = new MockV3Aggregator(8, 2_000e8);
        usdcFeed = new MockV3Aggregator(8, 1e8);
        sequencer = new MockV3Aggregator(0, 0);
        sequencer.setRoundData(1, 0, block.timestamp - 7 days, 1);
        usdc = new MockERC20("USD Coin", "USDC", 6);

        vm.setEnv("PRIVATE_KEY", vm.toString(DEPLOYER_KEY));
        vm.setEnv("GIFT_OPERATOR_ADDRESS", vm.toString(address(0x6151)));
        vm.setEnv("EXPECTED_CHAIN_ID", "42161");
        vm.setEnv("PRODUCTION_DEPLOYMENT", "true");
        vm.setEnv("PLATFORM_RECIPIENT", vm.toString(address(0x5001)));
        vm.setEnv("VAULT_RESERVE_RECIPIENT", vm.toString(address(0x5002)));
        vm.setEnv("INSURANCE_RESERVE_RECIPIENT", vm.toString(address(0x5003)));
        vm.setEnv("TREASURY_RESERVE_RECIPIENT", vm.toString(address(0x5004)));
        vm.setEnv("ETH_USD_FEED", vm.toString(address(ethFeed)));
        vm.setEnv("ETH_USD_MIN_ANSWER", "50000000000");
        vm.setEnv("ETH_USD_MAX_ANSWER", "1000000000000");
        vm.setEnv("PRICE_STALE_AFTER", "3600");
        vm.setEnv("ETH_USD_STALE_AFTER", "90000");
        vm.setEnv("PAYMENT_TOKENS", vm.toString(address(usdc)));
        vm.setEnv("PAYMENT_TOKEN_USD_FEEDS", vm.toString(address(usdcFeed)));
        vm.setEnv("PAYMENT_TOKEN_MIN_ANSWERS", "80000000");
        vm.setEnv("PAYMENT_TOKEN_MAX_ANSWERS", "120000000");
        vm.setEnv("PAYMENT_TOKEN_STALE_AFTERS", "90000");
        vm.setEnv("SEQUENCER_UPTIME_FEED", vm.toString(address(sequencer)));
        vm.setEnv("SEQUENCER_GRACE_PERIOD", "3600");
        // Reserve-free launch policy.
        vm.setEnv("DEFAULT_RESERVE_BPS", "0");
        vm.setEnv(
            "RESERVE_BRACKET_MAX_USD",
            "1000000000000000000000,115792089237316195423570985008687907853269984665640564039457584007913129639935"
        );
        vm.setEnv("RESERVE_BRACKET_BPS", "0,0");
        vm.setEnv("REDEMPTION_PROOF_APPROVER", vm.toString(address(0x7001)));
        vm.setEnv("REDEMPTION_AUTHORIZER", vm.toString(address(0x7002)));
        vm.setEnv(
            "REDEMPTION_RECOVERY_APPROVERS",
            string.concat(vm.toString(address(0x7003)), ",", vm.toString(address(0x7004)))
        );
    }

    /// @dev One test on purpose: environment variables are process-wide and forge runs tests in
    ///      parallel, so every scenario that changes them runs here in sequence.
    function testProductionArbitrumDeployment() public {
        // The sequencer feed is mandatory for a production Arbitrum deployment.
        vm.setEnv("SEQUENCER_UPTIME_FEED", vm.toString(address(0)));
        DeployDigitalCarat missingFeed = new DeployDigitalCarat();
        vm.expectRevert(bytes("SEQUENCER_UPTIME_FEED required on Arbitrum"));
        missingFeed.run();
        vm.stopBroadcast(); // a reverted run leaves its broadcast open
        vm.setEnv("SEQUENCER_UPTIME_FEED", vm.toString(address(sequencer)));

        // A per-token staleness list must line up with the tokens.
        vm.setEnv("PAYMENT_TOKEN_STALE_AFTERS", "90000,90000");
        DeployDigitalCarat mismatched = new DeployDigitalCarat();
        vm.expectRevert(bytes("PAYMENT_TOKEN_STALE_AFTERS length mismatch"));
        mismatched.run();
        vm.stopBroadcast();
        vm.setEnv("PAYMENT_TOKEN_STALE_AFTERS", "90000");

        DeployDigitalCarat.Deployment memory deployment = new DeployDigitalCarat().run();
        address admin = vm.addr(DEPLOYER_KEY);

        // Only the primary sale can mint.
        assertFalse(deployment.nft.hasRole(Roles.MINTER_ROLE, admin));
        assertTrue(deployment.nft.hasRole(Roles.MINTER_ROLE, address(deployment.sale)));

        // Per-feed staleness and the sequencer check.
        (,, uint48 ethStaleAfter,,,) = deployment.payments.tokenConfig(address(0));
        (,, uint48 usdcStaleAfter,,,) = deployment.payments.tokenConfig(address(usdc));
        assertEq(ethStaleAfter, 90000);
        assertEq(usdcStaleAfter, 90000);
        assertEq(address(deployment.payments.sequencerUptimeFeed()), address(sequencer));
        assertEq(deployment.payments.sequencerGracePeriod(), 3600);

        // A USDC price a day old still quotes; it would not under a one-hour window.
        vm.warp(block.timestamp + 23 hours);
        assertEq(deployment.payments.quoteTokenToUsd(address(usdc), 100e6), 100e18);

        // The reserve-free policy charges nothing.
        assertEq(deployment.reserveManager.reserveBpsFor(500e18), 0);
        assertEq(deployment.reserveManager.reserveBpsFor(5_000e18), 0);
    }
}
