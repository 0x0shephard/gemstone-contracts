// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {PaymentTokenRegistry} from "../src/PaymentTokenRegistry.sol";

/// @notice Upgrades an existing UUPS payment registry and backfills its enumerable assets.
contract UpgradePaymentTokenRegistry is Script {
    function run() external returns (address implementation) {
        uint256 adminKey = vm.envUint("PRIVATE_KEY");
        address proxy = vm.envAddress("PAYMENT_TOKEN_REGISTRY_ADDRESS");
        address[] memory empty;
        address[] memory existingTokens = vm.envOr("PAYMENT_TOKEN_BACKFILL", ",", empty);
        require(existingTokens.length != 0, "PAYMENT_TOKEN_BACKFILL missing");

        vm.startBroadcast(adminKey);
        implementation = address(new PaymentTokenRegistry());
        PaymentTokenRegistry(proxy)
            .upgradeToAndCall(implementation, abi.encodeCall(PaymentTokenRegistry.initializeV2, (existingTokens)));
        vm.stopBroadcast();

        console2.log("PaymentTokenRegistry proxy", proxy);
        console2.log("PaymentTokenRegistry implementation", implementation);
        console2.log("Tracked payment assets", existingTokens.length);
    }
}
