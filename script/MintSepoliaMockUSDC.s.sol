// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {SepoliaMockUSDC} from "../src/mocks/SepoliaMockUSDC.sol";

contract MintSepoliaMockUSDC is Script {
    function run() external {
        uint256 ownerKey = vm.envUint("PRIVATE_KEY");
        SepoliaMockUSDC token = SepoliaMockUSDC(vm.envAddress("MOCK_USDC_ADDRESS"));
        address recipient = vm.envAddress("MOCK_USDC_RECIPIENT");
        uint256 amount = vm.envOr("MOCK_USDC_AMOUNT", uint256(10_000e6));

        require(recipient != address(0), "MOCK_USDC_RECIPIENT missing");
        require(amount != 0, "MOCK_USDC_AMOUNT missing");

        vm.startBroadcast(ownerKey);
        token.mint(recipient, amount);
        vm.stopBroadcast();

        console2.log("Mock USDC minted");
        console2.log("recipient", recipient);
        console2.log("amount", amount);
    }
}
