// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {RedemptionManager} from "../src/RedemptionManager.sol";

/// @notice Upgrades the existing UUPS RedemptionManager proxy in place.
contract UpgradeRedemptionManager is Script {
    function run() external returns (address implementation) {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        require(block.chainid == vm.envUint("EXPECTED_CHAIN_ID"), "RPC chain does not match EXPECTED_CHAIN_ID");
        address proxy = vm.envAddress("REDEMPTION_MANAGER_ADDRESS");

        vm.startBroadcast(deployerKey);
        implementation = address(new RedemptionManager());
        RedemptionManager(proxy).upgradeToAndCall(implementation, bytes(""));
        vm.stopBroadcast();

        console2.log("RedemptionManager proxy", proxy);
        console2.log("RedemptionManager implementation", implementation);
    }
}
