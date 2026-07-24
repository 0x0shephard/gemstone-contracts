// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {SepoliaMockUSDC} from "../src/mocks/SepoliaMockUSDC.sol";
import {SepoliaMockUsdFeed} from "../src/mocks/SepoliaMockUsdFeed.sol";

contract DeploySepoliaMocks is Script {
    function run() external returns (SepoliaMockUSDC mockUsdc, SepoliaMockUsdFeed mockUsdFeed) {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address initialHolder = vm.envOr("MOCK_USDC_INITIAL_HOLDER", deployer);
        uint256 initialSupply = vm.envOr("MOCK_USDC_INITIAL_SUPPLY", uint256(1_000_000e6));
        int256 initialAnswer = vm.envOr("MOCK_USDC_USD_ANSWER", int256(1e8));

        vm.startBroadcast(deployerKey);
        mockUsdc = new SepoliaMockUSDC(deployer, initialHolder, initialSupply);
        mockUsdFeed = new SepoliaMockUsdFeed(deployer, initialAnswer);
        vm.stopBroadcast();

        console2.log("Digital Carat Sepolia mocks");
        console2.log("chainId", block.chainid);
        console2.log("owner", deployer);
        console2.log("PAYMENT_TOKENS", address(mockUsdc));
        console2.log("PAYMENT_TOKEN_USD_FEEDS", address(mockUsdFeed));
        console2.log("PAYMENT_TOKEN_MIN_ANSWERS", uint256(80_000_000));
        console2.log("PAYMENT_TOKEN_MAX_ANSWERS", uint256(120_000_000));
    }
}
