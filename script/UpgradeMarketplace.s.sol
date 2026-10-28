// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {UpgradePreflight} from "./UpgradePreflight.sol";
import {Marketplace} from "../src/Marketplace.sol";

/// @notice Upgrades the existing Sepolia UUPS Marketplace proxy in place.
contract UpgradeMarketplace is Script {
    function run() external returns (address implementation) {
        uint256 adminKey = vm.envUint("PRIVATE_KEY");
        address proxy = vm.envAddress("MARKETPLACE_ADDRESS");
        UpgradePreflight.requireSequencerAwareRegistry(address(Marketplace(payable(proxy)).paymentRegistry()));
        // The new cap is enforced only when the fee is next set, so check the stored value now.
        require(
            Marketplace(payable(proxy)).secondaryFeeBps() <= 1_000,
            "secondaryFeeBps above the new 10% cap; lower it first"
        );

        vm.startBroadcast(adminKey);
        implementation = address(new Marketplace());
        Marketplace(payable(proxy)).upgradeToAndCall(implementation, bytes(""));
        vm.stopBroadcast();

        console2.log("Marketplace proxy", proxy);
        console2.log("Marketplace implementation", implementation);
    }
}
