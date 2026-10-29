// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {SafeUpgrade} from "./SafeUpgrade.sol";
import {UpgradePreflight} from "./UpgradePreflight.sol";
import {Marketplace} from "../src/Marketplace.sol";

/// @notice Upgrades an existing UUPS Marketplace proxy in place.
/// @dev By default the broadcaster deploys and upgrades, which needs `UPGRADER_ROLE`. With
///      `IMPLEMENTATION_ONLY=true` it only deploys the implementation and prints the Safe call.
contract UpgradeMarketplace is Script {
    function run() external returns (address implementation) {
        uint256 adminKey = vm.envUint("PRIVATE_KEY");
        address proxy = vm.envAddress("MARKETPLACE_ADDRESS");
        return upgrade(adminKey, proxy, vm.envOr("IMPLEMENTATION_ONLY", false));
    }

    /// @notice Deploys the implementation and, unless `implementationOnly`, upgrades `proxy` to it.
    function upgrade(uint256 adminKey, address proxy, bool implementationOnly) public returns (address implementation) {
        UpgradePreflight.requireSequencerAwareRegistry(address(Marketplace(payable(proxy)).paymentRegistry()));
        // The new cap is enforced only when the fee is next set, so check the stored value now.
        require(
            Marketplace(payable(proxy)).secondaryFeeBps() <= 1_000,
            "secondaryFeeBps above the new 10% cap; lower it first"
        );

        if (!implementationOnly) SafeUpgrade.requireDirectUpgrader(proxy, vm.addr(adminKey));

        vm.startBroadcast(adminKey);
        implementation = address(new Marketplace());
        if (!implementationOnly) Marketplace(payable(proxy)).upgradeToAndCall(implementation, bytes(""));
        vm.stopBroadcast();

        console2.log("Marketplace proxy", proxy);
        console2.log("Marketplace implementation", implementation);
        if (implementationOnly) SafeUpgrade.logSafeTransaction("Marketplace", proxy, implementation);
    }
}
