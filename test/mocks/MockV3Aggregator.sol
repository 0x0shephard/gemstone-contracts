// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract MockV3Aggregator {
    uint8 private immutable _DECIMALS;
    int256 private _answer;
    uint256 private _updatedAt;

    constructor(uint8 decimals_, int256 answer_) {
        _DECIMALS = decimals_;
        _answer = answer_;
        _updatedAt = block.timestamp;
    }

    function updateAnswer(int256 answer_) external {
        _answer = answer_;
        _updatedAt = block.timestamp;
    }

    function setUpdatedAt(uint256 updatedAt_) external {
        _updatedAt = updatedAt_;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (1, _answer, _updatedAt, _updatedAt, 1);
    }

    function decimals() external view returns (uint8) {
        return _DECIMALS;
    }
}
