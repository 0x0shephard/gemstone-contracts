// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {RedemptionManager} from "../src/RedemptionManager.sol";

/// @notice Migrates only explicitly audited V1 requests after the atomic V2 upgrade.
/// @dev Every token is re-verified by RedemptionManager against its current NFT
///      owner, transfer lock, registry status, and original request hash.
contract MigrateOpenRedemptions is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        require(block.chainid == vm.envUint("EXPECTED_CHAIN_ID"), "RPC chain does not match EXPECTED_CHAIN_ID");
        RedemptionManager redemption = RedemptionManager(vm.envAddress("REDEMPTION_MANAGER_ADDRESS"));
        uint256[] memory tokenIds = vm.envUint("LEGACY_REDEMPTION_TOKEN_IDS", ",");
        bytes32[] memory workflowIdHashes = vm.envBytes32("LEGACY_REDEMPTION_WORKFLOW_HASHES", ",");
        uint256[] memory requestedAtValues = vm.envUint("LEGACY_REDEMPTION_REQUESTED_AT", ",");
        require(tokenIds.length != 0, "No audited legacy requests supplied");
        require(
            tokenIds.length == workflowIdHashes.length && tokenIds.length == requestedAtValues.length,
            "Legacy migration length mismatch"
        );

        vm.startBroadcast(deployerKey);
        for (uint256 i = 0; i < tokenIds.length; ++i) {
            require(requestedAtValues[i] <= type(uint64).max, "Legacy requestedAt too high");
            // casting is safe after the explicit upper-bound check.
            // forge-lint: disable-next-line(unsafe-typecast)
            redemption.migrateOpenRedemption(tokenIds[i], workflowIdHashes[i], uint64(requestedAtValues[i]));
            console2.log("Migrated redemption token", tokenIds[i]);
        }
        vm.stopBroadcast();
    }
}
