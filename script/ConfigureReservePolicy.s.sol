// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {ReserveManager} from "../src/ReserveManager.sol";

/// @notice Applies a deployment-specific reserve schedule without replacing the proxy.
contract ConfigureReservePolicy is Script {
    function run() external {
        uint256 adminKey = vm.envUint("PRIVATE_KEY");
        ReserveManager reserveManager = ReserveManager(payable(vm.envAddress("RESERVE_MANAGER_ADDRESS")));
        uint256 defaultReserveBps = vm.envUint("DEFAULT_RESERVE_BPS");
        uint256[] memory bracketMaxUsd = vm.envUint("RESERVE_BRACKET_MAX_USD", ",");
        uint256[] memory bracketBps = vm.envUint("RESERVE_BRACKET_BPS", ",");

        require(defaultReserveBps <= 10_000, "DEFAULT_RESERVE_BPS too high");
        // Optional; unset leaves the floor as it is. Set it before turning reserves on: at the
        // 100% default a small fall in the reserve's ETH price halts every purchase.
        uint256 minimumCoverageBps = vm.envOr("MINIMUM_COVERAGE_BPS", uint256(0));
        require(
            minimumCoverageBps == 0 || (minimumCoverageBps >= 9_000 && minimumCoverageBps <= 10_000),
            "MINIMUM_COVERAGE_BPS out of range"
        );
        require(bracketMaxUsd.length == bracketBps.length && bracketMaxUsd.length != 0, "Invalid reserve brackets");

        ReserveManager.ReserveBracket[] memory brackets = new ReserveManager.ReserveBracket[](bracketMaxUsd.length);
        uint256 minPriceUsd;
        for (uint256 i = 0; i < bracketMaxUsd.length; i++) {
            require(bracketMaxUsd[i] > minPriceUsd, "Reserve bracket max not increasing");
            require(bracketBps[i] <= 10_000, "Reserve bracket bps too high");
            // forge-lint: disable-next-line(unsafe-typecast)
            brackets[i] = ReserveManager.ReserveBracket({
                minPriceUsd: minPriceUsd, maxPriceUsd: bracketMaxUsd[i], reserveBps: uint16(bracketBps[i])
            });
            minPriceUsd = bracketMaxUsd[i];
        }

        vm.startBroadcast(adminKey);
        // forge-lint: disable-next-line(unsafe-typecast)
        reserveManager.setDefaultReserveBps(uint16(defaultReserveBps));
        reserveManager.setReserveBrackets(brackets);
        // forge-lint: disable-next-line(unsafe-typecast)
        if (minimumCoverageBps != 0) reserveManager.setMinimumCoverageBps(uint16(minimumCoverageBps));
        vm.stopBroadcast();

        console2.log("ReserveManager", address(reserveManager));
        console2.log("Reserve brackets", brackets.length);
        console2.log("Minimum coverage bps", reserveManager.minimumCoverageBps());
    }
}
