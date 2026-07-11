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

    /// @custom:oz-upgrades-unsafe-allow constructor
    /// @dev Locks the implementation contract so only proxy instances can be initialized.
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes compliance administration roles.
    /// @param admin Account receiving default admin, upgrader, and compliance roles.
    function initialize(address admin) external initializer {
        if (admin == address(0)) revert InvalidAddress();
        __AccessControl_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(Roles.UPGRADER_ROLE, admin);
        _grantRole(Roles.COMPLIANCE_ROLE, admin);
    }

    /// @notice Blocks or unblocks an account for redemption.
    /// @param account Account to update.
    /// @param blocked_ True to block redemption, false to unblock.
    function setBlocked(address account, bool blocked_) external onlyRole(Roles.COMPLIANCE_ROLE) {
        if (account == address(0)) revert InvalidAddress();
        blocked[account] = blocked_;
        emit BlockedUpdated(account, blocked_);
    }

    /// @notice Sets explicit redemption approval for an account.
    /// @param account Account to update.
    /// @param approved Whether the account is approved for redemption when approval mode is enabled.
    function setRedemptionApproved(address account, bool approved) external onlyRole(Roles.COMPLIANCE_ROLE) {
        if (account == address(0)) revert InvalidAddress();
        redemptionApproved[account] = approved;
        emit RedemptionApprovalUpdated(account, approved);
    }

    /// @notice Enables or disables explicit redemption approval mode.
    /// @param required True to require `redemptionApproved`, false to allow any unblocked account.
    function setRedemptionApprovalRequired(bool required) external onlyRole(DEFAULT_ADMIN_ROLE) {
        redemptionApprovalRequired = required;
        emit RedemptionApprovalRequiredUpdated(required);
    }

    /// @notice Returns whether an account can request redemption.
    /// @param account Account to check.
    /// @return True if unblocked and, when required, explicitly approved.
    function canRedeem(address account) external view returns (bool) {
        if (blocked[account]) return false;
        if (redemptionApprovalRequired && !redemptionApproved[account]) return false;
        return true;
    }

    /// @dev Authorizes UUPS upgrades for `UPGRADER_ROLE` holders.
    function _authorizeUpgrade(address) internal override onlyRole(Roles.UPGRADER_ROLE) {}
}
