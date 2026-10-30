// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {SafeUpgrade} from "./SafeUpgrade.sol";
import {GemRegistry} from "../src/GemRegistry.sol";

/// @notice Upgrades an existing UUPS GemRegistry proxy in place.
/// @dev By default the broadcaster deploys and upgrades, which needs `UPGRADER_ROLE`. With
///      `IMPLEMENTATION_ONLY=true` it only deploys the implementation and prints the Safe call.
contract UpgradeGemRegistry is Script {
    function run() external returns (address implementation) {
        uint256 adminKey = vm.envUint("PRIVATE_KEY");
        address proxy = vm.envAddress("GEM_REGISTRY_ADDRESS");
        return upgrade(adminKey, proxy, vm.envOr("IMPLEMENTATION_ONLY", false));
    }

    /// @notice Deploys the implementation and, unless `implementationOnly`, upgrades `proxy` to it.
    function upgrade(uint256 adminKey, address proxy, bool implementationOnly) public returns (address implementation) {
        if (!implementationOnly) SafeUpgrade.requireDirectUpgrader(proxy, vm.addr(adminKey));

        vm.startBroadcast(adminKey);
        implementation = address(new GemRegistry());
        if (!implementationOnly) GemRegistry(proxy).upgradeToAndCall(implementation, bytes(""));
        vm.stopBroadcast();

        console2.log("GemRegistry proxy", proxy);
        console2.log("GemRegistry implementation", implementation);
        if (implementationOnly) SafeUpgrade.logSafeTransaction("GemRegistry", proxy, implementation);
    }
}
