// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

library Roles {
    bytes32 internal constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 internal constant CUSTODIAN_ROLE = keccak256("CUSTODIAN_ROLE");
    bytes32 internal constant VERIFIER_ROLE = keccak256("VERIFIER_ROLE");
    bytes32 internal constant LISTER_ROLE = keccak256("LISTER_ROLE");
    bytes32 internal constant COMPLIANCE_ROLE = keccak256("COMPLIANCE_ROLE");
    bytes32 internal constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 internal constant BURNER_ROLE = keccak256("BURNER_ROLE");
    bytes32 internal constant LOCKER_ROLE = keccak256("LOCKER_ROLE");
    bytes32 internal constant SETTLER_ROLE = keccak256("SETTLER_ROLE");
    bytes32 internal constant REDEEMER_ROLE = keccak256("REDEEMER_ROLE");
}
