// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {SepoliaMockUSDC} from "../src/mocks/SepoliaMockUSDC.sol";
import {SepoliaMockUSDCFaucet} from "../src/mocks/SepoliaMockUSDCFaucet.sol";

contract DeploySepoliaMockUSDCFaucet is Script {
    function run() external returns (SepoliaMockUSDCFaucet faucet) {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        SepoliaMockUSDC token = SepoliaMockUSDC(vm.envAddress("MOCK_USDC_ADDRESS"));

        require(token.owner() == deployer, "Deployer must own mUSDC");

        vm.startBroadcast(deployerKey);
        faucet = new SepoliaMockUSDCFaucet(deployer, token);
        token.transferOwnership(address(faucet));
        vm.stopBroadcast();

        require(token.owner() == address(faucet), "Faucet ownership transfer failed");

        console2.log("Digital Carat Sepolia mUSDC faucet");
        console2.log("chainId", block.chainid);
        console2.log("admin", deployer);
        console2.log("token", address(token));
        console2.log("faucet", address(faucet));
        console2.log("claimAmount", faucet.CLAIM_AMOUNT());
    }
}
