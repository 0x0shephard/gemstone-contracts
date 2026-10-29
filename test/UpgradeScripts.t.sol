// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {UpgradeMarketplace} from "../script/UpgradeMarketplace.s.sol";
import {UpgradePrimarySaleAuction} from "../script/UpgradePrimarySaleAuction.s.sol";
import {UpgradeSwapEscrow} from "../script/UpgradeSwapEscrow.s.sol";
import {Roles} from "../src/libraries/Roles.sol";
import {BaseTest} from "./BaseTest.t.sol";

/// @dev Production upgrades go through the Safe, which holds `UPGRADER_ROLE`. The scripts must be
///      able to deploy an implementation without upgrading, and refuse a direct upgrade they could
///      not complete. Calls `upgrade` directly: `run()` only reads environment variables, which are
///      process-wide and shared with the deploy and handover script tests running in parallel.
contract UpgradeScriptsTest is BaseTest {
    uint256 private constant DEPLOYER_KEY = 0xDE9107;

    function _implementation(address proxy) private view returns (address) {
        return address(uint160(uint256(vm.load(proxy, ERC1967Utils.IMPLEMENTATION_SLOT))));
    }

    function _upgradeAll(bool implementationOnly)
        private
        returns (address primaryImpl, address marketImpl, address swapImpl)
    {
        primaryImpl = new UpgradePrimarySaleAuction().upgrade(DEPLOYER_KEY, address(sale), implementationOnly);
        marketImpl = new UpgradeMarketplace().upgrade(DEPLOYER_KEY, address(marketplace), implementationOnly);
        swapImpl = new UpgradeSwapEscrow().upgrade(DEPLOYER_KEY, address(swapEscrow), implementationOnly);
    }

    function testUpgradeScriptsDeployOnlyForTheSafeAndRefuseADirectUpgradeWithoutTheRole() public {
        address deployer = vm.addr(DEPLOYER_KEY);
        assertFalse(sale.hasRole(Roles.UPGRADER_ROLE, deployer));

        address primaryBefore = _implementation(address(sale));
        address marketBefore = _implementation(address(marketplace));
        address swapBefore = _implementation(address(swapEscrow));

        // Implementation-only: deploys, leaves every proxy where it was.
        (address primaryImpl, address marketImpl, address swapImpl) = _upgradeAll(true);
        assertGt(primaryImpl.code.length, 0);
        assertGt(marketImpl.code.length, 0);
        assertGt(swapImpl.code.length, 0);
        assertEq(_implementation(address(sale)), primaryBefore);
        assertEq(_implementation(address(marketplace)), marketBefore);
        assertEq(_implementation(address(swapEscrow)), swapBefore);

        // The printed Safe calldata upgrades the proxy when the upgrader sends it.
        (bool ok,) = address(sale).call(abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (primaryImpl, bytes(""))));
        assertTrue(ok);
        assertEq(_implementation(address(sale)), primaryImpl);

        // Direct upgrade without the role: refused before broadcasting.
        UpgradePrimarySaleAuction primaryScript = new UpgradePrimarySaleAuction();
        vm.expectRevert(
            bytes("Broadcaster lacks UPGRADER_ROLE (the Safe holds it): rerun with IMPLEMENTATION_ONLY=true")
        );
        primaryScript.upgrade(DEPLOYER_KEY, address(sale), false);

        // Direct upgrade with the role (the pre-handover Sepolia path) still works.
        sale.grantRole(Roles.UPGRADER_ROLE, deployer);
        marketplace.grantRole(Roles.UPGRADER_ROLE, deployer);
        swapEscrow.grantRole(Roles.UPGRADER_ROLE, deployer);
        (primaryImpl, marketImpl, swapImpl) = _upgradeAll(false);
        assertEq(_implementation(address(sale)), primaryImpl);
        assertEq(_implementation(address(marketplace)), marketImpl);
        assertEq(_implementation(address(swapEscrow)), swapImpl);
        assertEq(marketplace.secondaryFeeBps(), 200);
    }
}
