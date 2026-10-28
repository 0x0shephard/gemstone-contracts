// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Roles} from "../src/libraries/Roles.sol";

/// @notice Moves every role the deployer holds on the ten protocol contracts to `NEW_ADMIN`
///         (the Safe), in two separate runs so the second only happens once the first is checked:
///
///         forge script script/HandoverRoles.s.sol --sig "grant()" --rpc-url $RPC --broadcast
///         forge script script/HandoverRoles.s.sol --sig "renounce()" --rpc-url $RPC --broadcast
///
///         `grant()` gives `NEW_ADMIN` each role the deployer holds. `renounce()` first proves
///         `NEW_ADMIN` holds every one of them, then drops them from the deployer, admin last on each
///         contract. After it, the deployer key can do nothing; the Safe grants operational roles
///         (lister, custodian, verifier, ...) to the wallets that need them.
///
///         When the deployer is also the operator, `KEEP_ROLES` lists the operational roles it keeps,
///         as `CONTRACT_ENV:ROLE_NAME` pairs (e.g. `GEM_REGISTRY_ADDRESS:LISTER_ROLE`). Only the six
///         roles in `_keepable()` qualify: no admin, upgrader, recovery approval, or role that moves
///         funds, so the deployer still loses every power over the contracts and their money.
/// @dev Env: PRIVATE_KEY (deployer), NEW_ADMIN, EXPECTED_CHAIN_ID, and the proxy addresses
///      DGE_NFT_ADDRESS, GEM_REGISTRY_ADDRESS, PAYMENT_TOKEN_REGISTRY_ADDRESS,
///      RESERVE_MANAGER_ADDRESS, COMPLIANCE_REGISTRY_ADDRESS, TREASURY_ADDRESS,
///      PRIMARY_SALE_AUCTION_ADDRESS, REDEMPTION_MANAGER_ADDRESS, MARKETPLACE_ADDRESS,
///      SWAP_ESCROW_ADDRESS. NEW_ADMIN must be a contract (a Safe) unless ALLOW_EOA_ADMIN=true.
contract HandoverRoles is Script {
    string[10] internal CONTRACT_ENVS = [
        "DGE_NFT_ADDRESS",
        "GEM_REGISTRY_ADDRESS",
        "PAYMENT_TOKEN_REGISTRY_ADDRESS",
        "RESERVE_MANAGER_ADDRESS",
        "COMPLIANCE_REGISTRY_ADDRESS",
        "TREASURY_ADDRESS",
        "PRIMARY_SALE_AUCTION_ADDRESS",
        "REDEMPTION_MANAGER_ADDRESS",
        "MARKETPLACE_ADDRESS",
        "SWAP_ESCROW_ADDRESS"
    ];

    function run() external pure {
        revert("Run with --sig \"grant()\", check the result, then --sig \"renounce()\"");
    }

    /// @notice Grants `NEW_ADMIN` every role the deployer holds. Safe to re-run.
    function grant() external {
        (uint256 deployerKey, address deployer, address newAdmin) = _setup();
        vm.startBroadcast(deployerKey);
        for (uint256 c = 0; c < CONTRACT_ENVS.length; c++) {
            IAccessControl target = IAccessControl(vm.envAddress(CONTRACT_ENVS[c]));
            bytes32[] memory roles = _roles();
            for (uint256 r = 0; r < roles.length; r++) {
                if (target.hasRole(roles[r], deployer) && !target.hasRole(roles[r], newAdmin)) {
                    target.grantRole(roles[r], newAdmin);
                    console2.log(CONTRACT_ENVS[c], _roleName(roles[r]), "granted");
                }
            }
        }
        vm.stopBroadcast();
    }

    /// @notice Drops every deployer role, after proving `NEW_ADMIN` holds each one.
    function renounce() external {
        (uint256 deployerKey, address deployer, address newAdmin) = _setup();
        bytes32[] memory roles = _roles();

        // Check everything before sending anything: a partial renounce must not strand a contract.
        for (uint256 c = 0; c < CONTRACT_ENVS.length; c++) {
            IAccessControl target = IAccessControl(vm.envAddress(CONTRACT_ENVS[c]));
            require(
                target.hasRole(bytes32(0), newAdmin), string.concat(CONTRACT_ENVS[c], ": NEW_ADMIN lacks admin role")
            );
            require(
                target.hasRole(Roles.UPGRADER_ROLE, newAdmin),
                string.concat(CONTRACT_ENVS[c], ": NEW_ADMIN lacks upgrader role")
            );
            for (uint256 r = 0; r < roles.length; r++) {
                if (target.hasRole(roles[r], deployer)) {
                    require(
                        target.hasRole(roles[r], newAdmin),
                        string.concat(CONTRACT_ENVS[c], ": NEW_ADMIN lacks ", _roleName(roles[r]))
                    );
                }
            }
        }

        vm.startBroadcast(deployerKey);
        for (uint256 c = 0; c < CONTRACT_ENVS.length; c++) {
            IAccessControl target = IAccessControl(vm.envAddress(CONTRACT_ENVS[c]));
            // roles[0] is the admin role; renounce it last so nothing is left ungoverned midway.
            for (uint256 r = roles.length; r > 0; r--) {
                if (target.hasRole(roles[r - 1], deployer) && !_kept(CONTRACT_ENVS[c], roles[r - 1])) {
                    target.renounceRole(roles[r - 1], deployer);
                    console2.log(CONTRACT_ENVS[c], _roleName(roles[r - 1]), "renounced");
                }
            }
        }
        vm.stopBroadcast();

        for (uint256 c = 0; c < CONTRACT_ENVS.length; c++) {
            IAccessControl target = IAccessControl(vm.envAddress(CONTRACT_ENVS[c]));
            for (uint256 r = 0; r < roles.length; r++) {
                if (_kept(CONTRACT_ENVS[c], roles[r])) continue;
                require(!target.hasRole(roles[r], deployer), "deployer still holds a role");
            }
        }
    }

    /// @dev Whether `KEEP_ROLES` lets the deployer keep `role` on the contract named `contractEnv`.
    function _kept(string memory contractEnv, bytes32 role) private view returns (bool) {
        string[] memory none;
        string[] memory keep = vm.envOr("KEEP_ROLES", ",", none);
        bytes32 entry = keccak256(bytes(string.concat(contractEnv, ":", _roleName(role))));
        for (uint256 i = 0; i < keep.length; i++) {
            if (keccak256(bytes(keep[i])) == entry) return true;
        }
        return false;
    }

    /// @dev The only roles a single deployer/operator wallet may keep: what the edge functions call.
    ///      Nothing that moves funds (reserve operator, settler, minter, burner, locker, redeemer),
    ///      grants power, or approves a recovery burn.
    function _keepable() private pure returns (string[6] memory) {
        return [
            "GEM_REGISTRY_ADDRESS:LISTER_ROLE",
            "GEM_REGISTRY_ADDRESS:CUSTODIAN_ROLE",
            "GEM_REGISTRY_ADDRESS:VERIFIER_ROLE",
            "GEM_REGISTRY_ADDRESS:COMPLIANCE_ROLE",
            "PRIMARY_SALE_AUCTION_ADDRESS:LISTER_ROLE",
            "REDEMPTION_MANAGER_ADDRESS:PROOF_APPROVER_ROLE"
        ];
    }

    /// @dev Every `KEEP_ROLES` entry must be one of `_keepable()`, checked before anything is sent.
    function _checkKeepList() private view {
        string[] memory none;
        string[] memory keep = vm.envOr("KEEP_ROLES", ",", none);
        string[6] memory keepable = _keepable();
        for (uint256 i = 0; i < keep.length; i++) {
            if (bytes(keep[i]).length == 0) continue;
            bool allowed;
            for (uint256 k = 0; k < keepable.length && !allowed; k++) {
                allowed = keccak256(bytes(keep[i])) == keccak256(bytes(keepable[k]));
            }
            require(allowed, string.concat("KEEP_ROLES cannot keep ", keep[i]));
        }
    }

    function _setup() private view returns (uint256 deployerKey, address deployer, address newAdmin) {
        require(block.chainid == vm.envUint("EXPECTED_CHAIN_ID"), "RPC chain does not match EXPECTED_CHAIN_ID");
        deployerKey = vm.envUint("PRIVATE_KEY");
        deployer = vm.addr(deployerKey);
        newAdmin = vm.envAddress("NEW_ADMIN");
        require(newAdmin != address(0) && newAdmin != deployer, "NEW_ADMIN must be a different address");
        require(
            newAdmin.code.length != 0 || vm.envOr("ALLOW_EOA_ADMIN", false), "NEW_ADMIN has no code; expected a Safe"
        );
        _checkKeepList();
    }

    function _roles() private pure returns (bytes32[] memory roles) {
        roles = new bytes32[](15);
        roles[0] = bytes32(0); // DEFAULT_ADMIN_ROLE
        roles[1] = Roles.UPGRADER_ROLE;
        roles[2] = Roles.CUSTODIAN_ROLE;
        roles[3] = Roles.VERIFIER_ROLE;
        roles[4] = Roles.LISTER_ROLE;
        roles[5] = Roles.COMPLIANCE_ROLE;
        roles[6] = Roles.MINTER_ROLE;
        roles[7] = Roles.BURNER_ROLE;
        roles[8] = Roles.LOCKER_ROLE;
        roles[9] = Roles.SETTLER_ROLE;
        roles[10] = Roles.REDEEMER_ROLE;
        roles[11] = Roles.RESERVE_OPERATOR_ROLE;
        roles[12] = Roles.PROOF_APPROVER_ROLE;
        roles[13] = Roles.AUTHORIZER_ROLE;
        roles[14] = Roles.RECOVERY_APPROVER_ROLE;
    }

    function _roleName(bytes32 role) private pure returns (string memory) {
        if (role == bytes32(0)) return "DEFAULT_ADMIN_ROLE";
        if (role == Roles.UPGRADER_ROLE) return "UPGRADER_ROLE";
        if (role == Roles.CUSTODIAN_ROLE) return "CUSTODIAN_ROLE";
        if (role == Roles.VERIFIER_ROLE) return "VERIFIER_ROLE";
        if (role == Roles.LISTER_ROLE) return "LISTER_ROLE";
        if (role == Roles.COMPLIANCE_ROLE) return "COMPLIANCE_ROLE";
        if (role == Roles.MINTER_ROLE) return "MINTER_ROLE";
        if (role == Roles.BURNER_ROLE) return "BURNER_ROLE";
        if (role == Roles.LOCKER_ROLE) return "LOCKER_ROLE";
        if (role == Roles.SETTLER_ROLE) return "SETTLER_ROLE";
        if (role == Roles.REDEEMER_ROLE) return "REDEEMER_ROLE";
        if (role == Roles.RESERVE_OPERATOR_ROLE) return "RESERVE_OPERATOR_ROLE";
        if (role == Roles.PROOF_APPROVER_ROLE) return "PROOF_APPROVER_ROLE";
        if (role == Roles.AUTHORIZER_ROLE) return "AUTHORIZER_ROLE";
        return "RECOVERY_APPROVER_ROLE";
    }
}
