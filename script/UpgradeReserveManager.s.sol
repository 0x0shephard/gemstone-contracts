// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {ReserveManager} from "../src/ReserveManager.sol";

/// @notice Upgrades the existing UUPS ReserveManager proxy in place.
/// @dev Must be completed before upgrading RedemptionManager to the pull-credit implementation.
contract UpgradeReserveManager is Script {
    function run() external returns (address implementation) {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        require(block.chainid == vm.envUint("EXPECTED_CHAIN_ID"), "RPC chain does not match EXPECTED_CHAIN_ID");
        address proxy = vm.envAddress("RESERVE_MANAGER_ADDRESS");

        vm.startBroadcast(deployerKey);
        implementation = address(new ReserveManager());
        ReserveManager(payable(proxy)).upgradeToAndCall(implementation, bytes(""));
        vm.stopBroadcast();

        console2.log("ReserveManager proxy", proxy);
        console2.log("ReserveManager implementation", implementation);
    }
}
