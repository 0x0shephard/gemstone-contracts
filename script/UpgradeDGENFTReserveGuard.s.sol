// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {DGENFT} from "../src/DGENFT.sol";
import {ReserveManager} from "../src/ReserveManager.sol";

/// @notice Upgrades DGENFT and atomically enables the reserve guard.
/// @dev Before broadcast, audit every token held by MARKETPLACE_ADDRESS,
///      SWAP_ESCROW_ADDRESS, and GIFT_OPERATOR_ADDRESS. Supply each current token
///      exactly once in LEGACY_ESCROW_TOKEN_IDS with its original depositor in
///      LEGACY_ESCROW_DEPOSITORS. The implementation rejects incomplete inventories,
///      mismatched owners, duplicate token ids, and more than 100 legacy migrations.
contract UpgradeDGENFTReserveGuard is Script {
    function run() external returns (address implementation) {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        require(block.chainid == vm.envUint("EXPECTED_CHAIN_ID"), "RPC chain does not match EXPECTED_CHAIN_ID");
        address proxy = vm.envAddress("DGE_NFT_ADDRESS");
        ReserveManager reserveManager = ReserveManager(payable(vm.envAddress("RESERVE_MANAGER_ADDRESS")));

        address[] memory escrows = new address[](3);
        escrows[0] = vm.envAddress("MARKETPLACE_ADDRESS");
        escrows[1] = vm.envAddress("SWAP_ESCROW_ADDRESS");
        escrows[2] = vm.envAddress("GIFT_OPERATOR_ADDRESS");

        uint256[] memory emptyTokenIds;
        address[] memory emptyDepositors;
        uint256[] memory legacyTokenIds = vm.envOr("LEGACY_ESCROW_TOKEN_IDS", ",", emptyTokenIds);
        address[] memory legacyDepositors = vm.envOr("LEGACY_ESCROW_DEPOSITORS", ",", emptyDepositors);
        require(legacyTokenIds.length == legacyDepositors.length, "Legacy migration length mismatch");
        require(legacyTokenIds.length <= 100, "Legacy migration limit");

        vm.startBroadcast(deployerKey);
        implementation = address(new DGENFT());
        DGENFT(proxy)
            .upgradeToAndCall(
                implementation,
                abi.encodeCall(
                    DGENFT.initializeReserveGuard, (reserveManager, escrows, legacyTokenIds, legacyDepositors)
                )
            );
        vm.stopBroadcast();

        console2.log("DGENFT proxy", proxy);
        console2.log("DGENFT implementation", implementation);
        console2.log("Legacy escrow tokens migrated", legacyTokenIds.length);
    }
}
