// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {console2} from "forge-std/console2.sol";
import {Roles} from "../src/libraries/Roles.sol";

/// @notice Shared upgrade paths for the in-place UUPS upgrade scripts.
/// @dev Once `HandoverRoles` has run, `UPGRADER_ROLE` sits with the Safe, so the deployer can no
///      longer call `upgradeToAndCall`. With `IMPLEMENTATION_ONLY=true` a script deploys the new
///      implementation from the deployer and prints the transaction the Safe must execute.
library SafeUpgrade {
    /// @dev Reverts before anything is broadcast when the deployer could not complete a direct upgrade.
    function requireDirectUpgrader(address proxy, address broadcaster) internal view {
        require(
            IAccessControl(proxy).hasRole(Roles.UPGRADER_ROLE, broadcaster),
            "Broadcaster lacks UPGRADER_ROLE (the Safe holds it): rerun with IMPLEMENTATION_ONLY=true"
        );
    }

    /// @notice Calldata for `proxy.upgradeToAndCall(implementation, "")`.
    function upgradeCalldata(address implementation) internal pure returns (bytes memory) {
        return abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (implementation, bytes("")));
    }

    /// @notice Prints the Safe Transaction Builder entry for one upgrade.
    function logSafeTransaction(string memory name, address proxy, address implementation) internal pure {
        console2.log(string.concat(name, ": Safe transaction (value 0) to proxy"), proxy);
        console2.log("  data = upgradeToAndCall(implementation, 0x)");
        console2.logBytes(upgradeCalldata(implementation));
    }
}
