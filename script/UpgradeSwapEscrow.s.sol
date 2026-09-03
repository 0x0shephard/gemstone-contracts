// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {SwapEscrow} from "../src/SwapEscrow.sol";

/// @notice Upgrades the existing Sepolia UUPS proxy without changing its address or storage.
contract UpgradeSwapEscrow is Script {
    function run() external returns (address implementation) {
        uint256 adminKey = vm.envUint("PRIVATE_KEY");
        address proxy = vm.envAddress("SWAP_ESCROW_ADDRESS");

        vm.startBroadcast(adminKey);
        implementation = address(new SwapEscrow());
        SwapEscrow(payable(proxy)).upgradeToAndCall(implementation, bytes(""));
        vm.stopBroadcast();

        console2.log("SwapEscrow proxy", proxy);
        console2.log("SwapEscrow implementation", implementation);
    }
}
