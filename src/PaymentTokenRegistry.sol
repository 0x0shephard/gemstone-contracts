// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {
    AggregatorV3Interface
} from "chainlink-brownie-contracts/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {Roles} from "./libraries/Roles.sol";

contract PaymentTokenRegistry is Initializable, AccessControlUpgradeable, UUPSUpgradeable {
    address public constant NATIVE_ETH = address(0);
    uint256 public constant USD_DECIMALS = 1e18;

    struct TokenConfig {
        bool enabled;
        address feed;
        uint48 staleAfter;
        uint8 tokenDecimals;
        int192 minAnswer;
        int192 maxAnswer;
    }

    mapping(address token => TokenConfig) public tokenConfig;

    event PaymentTokenSet(
        address indexed token, address indexed feed, uint48 staleAfter, uint8 tokenDecimals, bool enabled
    );
    event PaymentTokenRemoved(address indexed token);
    event PaymentTokenBoundsSet(address indexed token, int192 minAnswer, int192 maxAnswer);

    error InvalidAddress();
    error InvalidFeed();
    error InvalidBounds();
    error TokenNotEnabled();
    error StalePrice();
    error InvalidPrice();

    constructor() {
        _disableInitializers();
    }

    function initialize(address admin) external initializer {
        if (admin == address(0)) revert InvalidAddress();
        __AccessControl_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(Roles.UPGRADER_ROLE, admin);
    }

    function setToken(address token, address feed, uint48 staleAfter, bool enabled)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (feed == address(0) || staleAfter == 0) revert InvalidFeed();
        uint8 tokenDecimals = token == NATIVE_ETH ? 18 : IERC20Metadata(token).decimals();
        tokenConfig[token] = TokenConfig({
            enabled: enabled,
            feed: feed,
            staleAfter: staleAfter,
            tokenDecimals: tokenDecimals,
            minAnswer: 0,
            maxAnswer: 0
        });
        emit PaymentTokenSet(token, feed, staleAfter, tokenDecimals, enabled);
    }

    function setTokenBounds(address token, int192 minAnswer, int192 maxAnswer) external onlyRole(DEFAULT_ADMIN_ROLE) {
        TokenConfig storage config = tokenConfig[token];
        if (config.feed == address(0)) revert TokenNotEnabled();
        if (minAnswer <= 0 || maxAnswer <= minAnswer) revert InvalidBounds();
        config.minAnswer = minAnswer;
        config.maxAnswer = maxAnswer;
        emit PaymentTokenBoundsSet(token, minAnswer, maxAnswer);
    }

    function removeToken(address token) external onlyRole(DEFAULT_ADMIN_ROLE) {
        delete tokenConfig[token];
        emit PaymentTokenRemoved(token);
    }

    function isEnabled(address token) external view returns (bool) {
        return tokenConfig[token].enabled;
    }

    function quoteTokenToUsd(address token, uint256 amount) public view returns (uint256 usdValue) {
        TokenConfig memory config = tokenConfig[token];
        if (!config.enabled) revert TokenNotEnabled();

        AggregatorV3Interface feed = AggregatorV3Interface(config.feed);
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = feed.latestRoundData();
        if (updatedAt == 0 || answeredInRound < roundId) revert StalePrice();
        if (answer <= 0) revert InvalidPrice();
        if (config.maxAnswer != 0 && (answer < config.minAnswer || answer > config.maxAnswer)) revert InvalidPrice();
        if (block.timestamp - updatedAt > config.staleAfter) revert StalePrice();

        uint8 feedDecimals = feed.decimals();
        // casting to uint256 is safe because non-positive oracle answers are rejected above.
        // forge-lint: disable-next-line(unsafe-typecast)
        usdValue = (amount * uint256(answer) * USD_DECIMALS) / (10 ** config.tokenDecimals) / (10 ** feedDecimals);
    }

    function _authorizeUpgrade(address) internal override onlyRole(Roles.UPGRADER_ROLE) {}
}
