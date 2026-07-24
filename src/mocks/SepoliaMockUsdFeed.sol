// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Owner-operated, Chainlink-compatible USD feed for Sepolia testing.
/// @dev This mock is intentionally unsuitable for production networks.
contract SepoliaMockUsdFeed is Ownable {
    uint8 private constant FEED_DECIMALS = 8;
    string private constant FEED_DESCRIPTION = "Digital Carat Mock USDC / USD";
    uint256 private constant FEED_VERSION = 1;

    int256 private _answer;
    uint256 private _updatedAt;
    uint80 private _roundId;

    error InvalidAnswer();

    constructor(address owner_, int256 initialAnswer) Ownable(owner_) {
        _setAnswer(initialAnswer);
    }

    function setAnswer(int256 answer_) external onlyOwner {
        _setAnswer(answer_);
    }

    function refresh() external onlyOwner {
        _updatedAt = block.timestamp;
        unchecked {
            ++_roundId;
        }
    }

    function decimals() external pure returns (uint8) {
        return FEED_DECIMALS;
    }

    function description() external pure returns (string memory) {
        return FEED_DESCRIPTION;
    }

    function version() external pure returns (uint256) {
        return FEED_VERSION;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (_roundId, _answer, _updatedAt, _updatedAt, _roundId);
    }

    function _setAnswer(int256 answer_) private {
        if (answer_ <= 0) revert InvalidAnswer();
        _answer = answer_;
        _updatedAt = block.timestamp;
        unchecked {
            ++_roundId;
        }
    }
}
