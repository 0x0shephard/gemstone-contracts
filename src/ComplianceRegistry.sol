// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Roles} from "./libraries/Roles.sol";

contract ComplianceRegistry is Initializable, AccessControlUpgradeable, UUPSUpgradeable {
    mapping(address account => bool blocked) public blocked;
    mapping(address account => bool approved) public redemptionApproved;
    bool public redemptionApprovalRequired;

    event BlockedUpdated(address indexed account, bool blocked);
    event RedemptionApprovalUpdated(address indexed account, bool approved);
    event RedemptionApprovalRequiredUpdated(bool required);

    error InvalidAddress();

    constructor() {
        _disableInitializers();
    }

    function initialize(address admin) external initializer {
        if (admin == address(0)) revert InvalidAddress();
        __AccessControl_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(Roles.UPGRADER_ROLE, admin);
        _grantRole(Roles.COMPLIANCE_ROLE, admin);
    }

    function setBlocked(address account, bool blocked_) external onlyRole(Roles.COMPLIANCE_ROLE) {
        if (account == address(0)) revert InvalidAddress();
        blocked[account] = blocked_;
        emit BlockedUpdated(account, blocked_);
    }

    function setRedemptionApproved(address account, bool approved) external onlyRole(Roles.COMPLIANCE_ROLE) {
        if (account == address(0)) revert InvalidAddress();
        redemptionApproved[account] = approved;
        emit RedemptionApprovalUpdated(account, approved);
    }

    function setRedemptionApprovalRequired(bool required) external onlyRole(DEFAULT_ADMIN_ROLE) {
        redemptionApprovalRequired = required;
        emit RedemptionApprovalRequiredUpdated(required);
    }

    function canRedeem(address account) external view returns (bool) {
        if (blocked[account]) return false;
        if (redemptionApprovalRequired && !redemptionApproved[account]) return false;
        return true;
    }

    function _authorizeUpgrade(address) internal override onlyRole(Roles.UPGRADER_ROLE) {}
}
