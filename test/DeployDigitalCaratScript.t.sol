// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {DeployDigitalCarat} from "../script/DeployDigitalCarat.s.sol";
import {HandoverRoles} from "../script/HandoverRoles.s.sol";
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
        vm.setEnv("MINIMUM_COVERAGE_BPS", "9500");
        vm.setEnv("COLLECTION_OWNER", vm.toString(address(0x8001)));
        vm.setEnv("CONTRACT_URI", "https://digitalcarat.io/collection.json");
        vm.setEnv("ROYALTY_RECEIVER", vm.toString(address(0x8002)));
        vm.setEnv("ROYALTY_BPS", "250");
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
        vm.expectRevert(bytes("SEQUENCER_UPTIME_FEED required on this L2"));
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

        // Production refuses the deployer as collection owner or royalty receiver.
        address deployer = vm.addr(DEPLOYER_KEY);
        _expectDeployRevert("COLLECTION_OWNER", vm.toString(deployer), "COLLECTION_OWNER must not be the deployer");
        vm.setEnv("COLLECTION_OWNER", vm.toString(address(0x8001)));
        _expectDeployRevert("ROYALTY_RECEIVER", vm.toString(deployer), "ROYALTY_RECEIVER must not be the deployer");
        _expectDeployRevert("ROYALTY_RECEIVER", vm.toString(address(0)), "ROYALTY_RECEIVER missing");
        vm.setEnv("ROYALTY_RECEIVER", vm.toString(address(0x8002)));

        // Royalties are capped at 10%.
        vm.setEnv("ROYALTY_BPS", "1001");
        DeployDigitalCarat greedy = new DeployDigitalCarat();
        vm.expectRevert(bytes("ROYALTY_BPS above 10%"));
        greedy.run();
        vm.stopBroadcast();
        vm.setEnv("ROYALTY_BPS", "250");

        // The solvency floor stays within 90-100%, and the platform fee within 10%.
        _expectDeployRevert("MINIMUM_COVERAGE_BPS", "8999", "MINIMUM_COVERAGE_BPS out of range");
        _expectDeployRevert("MINIMUM_COVERAGE_BPS", "10001", "MINIMUM_COVERAGE_BPS out of range");
        vm.setEnv("MINIMUM_COVERAGE_BPS", "9500");
        _expectDeployRevert("SECONDARY_FEE_BPS", "1001", "SECONDARY_FEE_BPS too high");
        vm.setEnv("SECONDARY_FEE_BPS", "200");

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

        // Outside marketplaces see the collection owner, metadata and royalty.
        assertEq(deployment.nft.owner(), address(0x8001));
        assertEq(deployment.nft.contractURI(), "https://digitalcarat.io/collection.json");
        (address royaltyReceiver, uint256 royalty) = deployment.nft.royaltyInfo(1, 10_000);
        assertEq(royaltyReceiver, address(0x8002));
        assertEq(royalty, 250);

        // Headroom below full coverage, so a small price move does not halt purchases.
        assertEq(deployment.reserveManager.minimumCoverageBps(), 9500);
        assertEq(deployment.marketplace.secondaryFeeBps(), 200);

        // The reserve-free policy charges nothing.
        assertEq(deployment.reserveManager.reserveBpsFor(500e18), 0);
        assertEq(deployment.reserveManager.reserveBpsFor(5_000e18), 0);

        _handOverRolesToSafe(deployment);

        // A Sepolia (non-production) deployment needs none of the L2 or production settings and
        // keeps the testnet behaviour: no uptime check, admin minting for fixtures.
        vm.chainId(11155111);
        vm.setEnv("EXPECTED_CHAIN_ID", "11155111");
        vm.setEnv("PRODUCTION_DEPLOYMENT", "false");
        vm.setEnv("SEQUENCER_UPTIME_FEED", vm.toString(address(0)));
        vm.setEnv("COLLECTION_OWNER", vm.toString(address(0)));
        vm.setEnv("CONTRACT_URI", "");
        vm.setEnv("ROYALTY_BPS", "0");
        vm.setEnv("ETH_USD_STALE_AFTER", "3600");
        vm.setEnv("PAYMENT_TOKEN_STALE_AFTERS", "3600");
        DeployDigitalCarat.Deployment memory testnet = new DeployDigitalCarat().run();
        assertEq(address(testnet.payments.sequencerUptimeFeed()), address(0));
        assertTrue(testnet.nft.hasRole(Roles.MINTER_ROLE, admin));
        assertEq(testnet.nft.owner(), address(0));
        assertEq(testnet.nft.contractURI(), "");
        ethFeed.updateAnswer(2_000e8);
        assertEq(testnet.payments.quoteTokenToUsd(address(0), 1 ether), 2_000e18);
        testnet.reserveManager.requireSolvent();
    }

    function _expectDeployRevert(string memory name, string memory value, string memory reason) private {
        vm.setEnv(name, value);
        DeployDigitalCarat script = new DeployDigitalCarat();
        vm.expectRevert(bytes(reason));
        script.run();
        vm.stopBroadcast(); // a reverted run leaves its broadcast open
    }

    /// @dev The deployer's roles move to a Safe in two runs; the second refuses until the first is done.
    function _handOverRolesToSafe(DeployDigitalCarat.Deployment memory d) private {
        address safe = address(0x5AFE);
        vm.etch(safe, hex"00"); // a contract, as a Safe is
        vm.setEnv("NEW_ADMIN", vm.toString(safe));
        vm.setEnv("DGE_NFT_ADDRESS", vm.toString(address(d.nft)));
        vm.setEnv("GEM_REGISTRY_ADDRESS", vm.toString(address(d.registry)));
        vm.setEnv("PAYMENT_TOKEN_REGISTRY_ADDRESS", vm.toString(address(d.payments)));
        vm.setEnv("RESERVE_MANAGER_ADDRESS", vm.toString(address(d.reserveManager)));
        vm.setEnv("COMPLIANCE_REGISTRY_ADDRESS", vm.toString(address(d.compliance)));
        vm.setEnv("TREASURY_ADDRESS", vm.toString(address(d.treasury)));
        vm.setEnv("PRIMARY_SALE_AUCTION_ADDRESS", vm.toString(address(d.sale)));
        vm.setEnv("REDEMPTION_MANAGER_ADDRESS", vm.toString(address(d.redemption)));
        vm.setEnv("MARKETPLACE_ADDRESS", vm.toString(address(d.marketplace)));
        vm.setEnv("SWAP_ESCROW_ADDRESS", vm.toString(address(d.swapEscrow)));
        address deployer = vm.addr(DEPLOYER_KEY);
        IAccessControl[10] memory targets = [
            IAccessControl(address(d.nft)),
            IAccessControl(address(d.registry)),
            IAccessControl(address(d.payments)),
            IAccessControl(address(d.reserveManager)),
            IAccessControl(address(d.compliance)),
            IAccessControl(address(d.treasury)),
            IAccessControl(address(d.sale)),
            IAccessControl(address(d.redemption)),
            IAccessControl(address(d.marketplace)),
            IAccessControl(address(d.swapEscrow))
        ];

        HandoverRoles handover = new HandoverRoles();
        vm.expectRevert(bytes("DGE_NFT_ADDRESS: NEW_ADMIN lacks admin role"));
        handover.renounce();

        handover.grant();
        handover.renounce();

        for (uint256 i = 0; i < targets.length; i++) {
            assertTrue(targets[i].hasRole(bytes32(0), safe));
            assertTrue(targets[i].hasRole(Roles.UPGRADER_ROLE, safe));
            assertFalse(targets[i].hasRole(bytes32(0), deployer));
            assertFalse(targets[i].hasRole(Roles.UPGRADER_ROLE, deployer));
        }
        // Operational roles the deployer held moved too, for the Safe to re-delegate.
        assertTrue(d.registry.hasRole(Roles.LISTER_ROLE, safe));
        assertFalse(d.registry.hasRole(Roles.LISTER_ROLE, deployer));
        assertTrue(d.treasury.hasRole(Roles.SETTLER_ROLE, safe));
    }
}
