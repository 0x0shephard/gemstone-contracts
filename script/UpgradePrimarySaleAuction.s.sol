// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {PrimarySaleAuction} from "../src/PrimarySaleAuction.sol";

/// @notice Upgrades the existing Sepolia UUPS PrimarySaleAuction proxy in place.
contract UpgradePrimarySaleAuction is Script {
    function run() external returns (address implementation) {
        uint256 adminKey = vm.envUint("PRIVATE_KEY");
        address proxy = vm.envAddress("PRIMARY_SALE_ADDRESS");

        vm.startBroadcast(adminKey);
        implementation = address(new PrimarySaleAuction());
        PrimarySaleAuction(payable(proxy)).upgradeToAndCall(implementation, bytes(""));
        vm.stopBroadcast();

        console2.log("PrimarySaleAuction proxy", proxy);
        console2.log("PrimarySaleAuction implementation", implementation);
    }
}
