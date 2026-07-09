// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    uint8 private immutable _DECIMALS;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _DECIMALS = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _DECIMALS;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract FeeOnTransferERC20 is MockERC20 {
    uint16 public immutable FEE_BPS;
    address public immutable FEE_RECIPIENT;

    constructor(uint16 feeBps_, address feeRecipient_) MockERC20("Fee Token", "FEE", 18) {
        FEE_BPS = feeBps_;
        FEE_RECIPIENT = feeRecipient_;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) || to == address(0) || FEE_BPS == 0) {
            super._update(from, to, value);
            return;
        }

        uint256 fee = (value * FEE_BPS) / 10_000;
        uint256 net = value - fee;
        super._update(from, FEE_RECIPIENT, fee);
        super._update(from, to, net);
    }
}
