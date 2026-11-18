// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {DGENFT} from "../src/DGENFT.sol";
import {Roles} from "../src/libraries/Roles.sol";
import {SafeUpgrade} from "./SafeUpgrade.sol";
import {UpgradePreflight} from "./UpgradePreflight.sol";

/// @notice Plain upgrade of a DGENFT proxy whose reserve guard is already initialised. Run it
///         last: the new implementation calls `ReserveManager.hasReserveAssets` on every transfer.
/// @dev Once the Safe holds `UPGRADER_ROLE`, run with `IMPLEMENTATION_ONLY=true`: it deploys the
///      implementation and prints the Safe transaction. With `METADATA_EDITOR` set it also prints
///      the `grantRole(METADATA_ROLE, editor)` call the Safe makes so `setTokenURI` can be used.
contract UpgradeDGENFT is Script {
    function run() external returns (address implementation) {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        require(block.chainid == vm.envUint("EXPECTED_CHAIN_ID"), "RPC chain does not match EXPECTED_CHAIN_ID");
        address proxy = vm.envAddress("DGE_NFT_ADDRESS");
        bool implementationOnly = vm.envOr("IMPLEMENTATION_ONLY", false);
        address reserveManager = address(DGENFT(proxy).reserveManager());
        require(reserveManager != address(0), "Reserve guard not initialised; use UpgradeDGENFTReserveGuard");
        UpgradePreflight.requireReserveAssetsView(reserveManager);
        if (!implementationOnly) SafeUpgrade.requireDirectUpgrader(proxy, vm.addr(deployerKey));

        vm.startBroadcast(deployerKey);
        implementation = address(new DGENFT());
        if (!implementationOnly) DGENFT(proxy).upgradeToAndCall(implementation, bytes(""));
        vm.stopBroadcast();

        console2.log("DGENFT proxy", proxy);
        console2.log("DGENFT implementation", implementation);
        if (implementationOnly) SafeUpgrade.logSafeTransaction("DGENFT", proxy, implementation);

        address editor = vm.envOr("METADATA_EDITOR", address(0));
        if (editor != address(0)) {
            console2.log("DGENFT: Safe transaction (value 0) to proxy", proxy);
            console2.log("  data = grantRole(METADATA_ROLE, editor)", editor);
            console2.logBytes(abi.encodeCall(IAccessControl.grantRole, (Roles.METADATA_ROLE, editor)));
        }
    }
}
