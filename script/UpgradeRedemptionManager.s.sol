// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {RedemptionManager} from "../src/RedemptionManager.sol";
import {Roles} from "../src/libraries/Roles.sol";

/// @notice Upgrades the existing UUPS RedemptionManager proxy in place.
contract UpgradeRedemptionManager is Script {
    struct UpgradeConfig {
        address proxy;
        address proofApprover;
        address authorizer;
        address[] recoveryApprovers;
        uint8 recoveryThreshold;
        uint64 recoveryDelay;
        address deployer;
        address[4] wiringBefore;
    }

    function run() external returns (address implementation) {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        require(block.chainid == vm.envUint("EXPECTED_CHAIN_ID"), "RPC chain does not match EXPECTED_CHAIN_ID");
        UpgradeConfig memory config;
        config.proxy = vm.envAddress("REDEMPTION_MANAGER_ADDRESS");
        config.proofApprover = vm.envAddress("REDEMPTION_PROOF_APPROVER");
        config.authorizer = vm.envAddress("REDEMPTION_AUTHORIZER");
        address[] memory noRecoveryApprovers;
        config.recoveryApprovers = vm.envOr("REDEMPTION_RECOVERY_APPROVERS", ",", noRecoveryApprovers);
        uint256 recoveryThresholdValue = vm.envOr("REDEMPTION_RECOVERY_THRESHOLD", uint256(2));
        uint256 recoveryDelayValue = vm.envOr("REDEMPTION_RECOVERY_DELAY", uint256(7 days));
        require(recoveryThresholdValue <= type(uint8).max, "Recovery threshold too high");
        require(recoveryDelayValue <= type(uint64).max, "Recovery delay too high");
        config.recoveryThreshold = uint8(recoveryThresholdValue);
        config.recoveryDelay = uint64(recoveryDelayValue);
        config.deployer = vm.addr(deployerKey);
        RedemptionManager current = RedemptionManager(config.proxy);
        require(current.hasRole(current.DEFAULT_ADMIN_ROLE(), config.deployer), "Deployer is not redemption admin");
        require(current.hasRole(Roles.UPGRADER_ROLE, config.deployer), "Deployer is not redemption upgrader");
        config.wiringBefore = [
            address(current.nft()),
            address(current.registry()),
            address(current.reserveManager()),
            address(current.complianceRegistry())
        ];
        require(
            config.wiringBefore[0] != address(0) && config.wiringBefore[1] != address(0)
                && config.wiringBefore[2] != address(0) && config.wiringBefore[3] != address(0),
            "Invalid redemption proxy wiring"
        );

        vm.startBroadcast(deployerKey);
        implementation = address(new RedemptionManager());
        RedemptionManager(config.proxy)
            .upgradeToAndCall(
                implementation,
                abi.encodeCall(
                    RedemptionManager.initializeV2,
                    (
                        config.proofApprover,
                        config.authorizer,
                        config.recoveryApprovers,
                        config.recoveryThreshold,
                        config.recoveryDelay
                    )
                )
            );
        vm.stopBroadcast();

        _assertPostUpgrade(config);

        console2.log("RedemptionManager proxy", config.proxy);
        console2.log("RedemptionManager implementation", implementation);
    }

    function _assertPostUpgrade(UpgradeConfig memory config) private view {
        RedemptionManager upgraded = RedemptionManager(config.proxy);
        require(upgraded.redemptionV2Initialized(), "Redemption V2 initialization failed");
        require(address(upgraded.nft()) == config.wiringBefore[0], "NFT wiring changed");
        require(address(upgraded.registry()) == config.wiringBefore[1], "Registry wiring changed");
        require(address(upgraded.reserveManager()) == config.wiringBefore[2], "Reserve manager wiring changed");
        require(address(upgraded.complianceRegistry()) == config.wiringBefore[3], "Compliance registry wiring changed");
        require(upgraded.hasRole(upgraded.DEFAULT_ADMIN_ROLE(), config.deployer), "Redemption admin role changed");
        require(upgraded.hasRole(Roles.UPGRADER_ROLE, config.deployer), "Redemption upgrader role changed");
        require(upgraded.hasRole(Roles.PROOF_APPROVER_ROLE, config.proofApprover), "Proof approver not configured");
        require(upgraded.hasRole(Roles.AUTHORIZER_ROLE, config.authorizer), "Authorizer not configured");
        for (uint256 i = 0; i < config.recoveryApprovers.length; ++i) {
            require(
                upgraded.hasRole(Roles.RECOVERY_APPROVER_ROLE, config.recoveryApprovers[i]),
                "Recovery approver not configured"
            );
        }
        require(upgraded.recoveryApprovalThreshold() == config.recoveryThreshold, "Recovery threshold mismatch");
        require(upgraded.recoveryDelay() == config.recoveryDelay, "Recovery delay mismatch");
    }
}
