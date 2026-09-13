// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {SepoliaMockUSDC} from "./SepoliaMockUSDC.sol";

/// @notice Permissionless testnet faucet for Digital Carat mUSDC.
/// @dev The faucet must own the mock token before claims can mint successfully.
contract SepoliaMockUSDCFaucet is Ownable, Pausable {
    uint256 public constant CLAIM_AMOUNT = 10_000e6;

    SepoliaMockUSDC public immutable TOKEN;

    event Claimed(address indexed account, uint256 amount);

    error InvalidAddress();

    constructor(address owner_, SepoliaMockUSDC token_) Ownable(owner_) {
        if (address(token_) == address(0)) revert InvalidAddress();
        TOKEN = token_;
    }

    /// @notice Mints exactly 10,000 mUSDC to the caller.
    function claim() external whenNotPaused {
        TOKEN.mint(msg.sender, CLAIM_AMOUNT);
        emit Claimed(msg.sender, CLAIM_AMOUNT);
    }

    /// @notice Temporarily disables public claims.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Re-enables public claims.
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Returns mock-token mint authority to an admin-controlled address.
    function recoverTokenOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert InvalidAddress();
        TOKEN.transferOwnership(newOwner);
    }
}
