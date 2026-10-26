// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {DGENFT} from "../src/DGENFT.sol";
import {UpgradePreflight} from "./UpgradePreflight.sol";

/// @notice Plain upgrade of a DGENFT proxy whose reserve guard is already initialised. Run it
///         last: the new implementation calls `ReserveManager.hasReserveAssets` on every transfer.
contract UpgradeDGENFT is Script {
    function run() external returns (address implementation) {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        require(block.chainid == vm.envUint("EXPECTED_CHAIN_ID"), "RPC chain does not match EXPECTED_CHAIN_ID");
        address proxy = vm.envAddress("DGE_NFT_ADDRESS");
        address reserveManager = address(DGENFT(proxy).reserveManager());
        require(reserveManager != address(0), "Reserve guard not initialised; use UpgradeDGENFTReserveGuard");
        UpgradePreflight.requireReserveAssetsView(reserveManager);

        vm.startBroadcast(deployerKey);
        implementation = address(new DGENFT());
        DGENFT(proxy).upgradeToAndCall(implementation, bytes(""));
        vm.stopBroadcast();

        console2.log("DGENFT proxy", proxy);
        console2.log("DGENFT implementation", implementation);
    }
}
