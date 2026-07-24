// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Six-decimal test token for Digital Carat Sepolia deployments.
/// @dev This is not Circle USDC and has no value. Only the owner can mint.
contract SepoliaMockUSDC is ERC20, Ownable {
    uint8 public constant TOKEN_DECIMALS = 6;

    constructor(address owner_, address initialHolder_, uint256 initialSupply)
        ERC20("Digital Carat Mock USDC", "mUSDC")
        Ownable(owner_)
    {
        _mint(initialHolder_, initialSupply);
    }

    function decimals() public pure override returns (uint8) {
        return TOKEN_DECIMALS;
    }

    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }
}
