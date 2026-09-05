// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {Marketplace} from "../src/Marketplace.sol";

/// @notice Upgrades the existing Sepolia UUPS Marketplace proxy in place.
contract UpgradeMarketplace is Script {
    function run() external returns (address implementation) {
        uint256 adminKey = vm.envUint("PRIVATE_KEY");
        address proxy = vm.envAddress("MARKETPLACE_ADDRESS");

        vm.startBroadcast(adminKey);
        implementation = address(new Marketplace());
        Marketplace(payable(proxy)).upgradeToAndCall(implementation, bytes(""));
        vm.stopBroadcast();

        console2.log("Marketplace proxy", proxy);
        console2.log("Marketplace implementation", implementation);
    }
}
