// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {SafeUpgrade} from "./SafeUpgrade.sol";
import {UpgradePreflight} from "./UpgradePreflight.sol";
import {SwapEscrow} from "../src/SwapEscrow.sol";

/// @notice Upgrades an existing UUPS SwapEscrow proxy in place.
/// @dev By default the broadcaster deploys and upgrades, which needs `UPGRADER_ROLE`. With
///      `IMPLEMENTATION_ONLY=true` it only deploys the implementation and prints the Safe call.
contract UpgradeSwapEscrow is Script {
    function run() external returns (address implementation) {
        uint256 adminKey = vm.envUint("PRIVATE_KEY");
        require(block.chainid == vm.envUint("EXPECTED_CHAIN_ID"), "RPC chain does not match EXPECTED_CHAIN_ID");
        address proxy = vm.envAddress("SWAP_ESCROW_ADDRESS");
        return upgrade(adminKey, proxy, vm.envOr("IMPLEMENTATION_ONLY", false));
    }

    /// @notice Deploys the implementation and, unless `implementationOnly`, upgrades `proxy` to it.
    function upgrade(uint256 adminKey, address proxy, bool implementationOnly) public returns (address implementation) {
        UpgradePreflight.requireSequencerAwareRegistry(address(SwapEscrow(payable(proxy)).paymentRegistry()));

        if (!implementationOnly) SafeUpgrade.requireDirectUpgrader(proxy, vm.addr(adminKey));

        vm.startBroadcast(adminKey);
        implementation = address(new SwapEscrow());
        if (!implementationOnly) SwapEscrow(payable(proxy)).upgradeToAndCall(implementation, bytes(""));
        vm.stopBroadcast();

        console2.log("SwapEscrow proxy", proxy);
        console2.log("SwapEscrow implementation", implementation);
        if (implementationOnly) SafeUpgrade.logSafeTransaction("SwapEscrow", proxy, implementation);
    }
}
