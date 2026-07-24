// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
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

    /// @custom:oz-upgrades-unsafe-allow constructor
    /// @dev Locks the implementation contract so only proxy instances can be initialized.
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes payment-token administration.
    /// @param admin Account receiving default admin and upgrader roles.
    function initialize(address admin) external initializer {
        if (admin == address(0)) revert InvalidAddress();
        __AccessControl_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(Roles.UPGRADER_ROLE, admin);
    }

    /// @notice Adds or updates a payment token and its USD oracle feed.
    /// @dev Preserves any previously configured oracle answer bounds for `token`.
    /// @param token Payment token address, or address(0) for native ETH.
    /// @param feed Chainlink-compatible USD feed.
    /// @param staleAfter Maximum allowed oracle age in seconds.
    /// @param enabled Whether the token can be used for protocol payments.
    function setToken(address token, address feed, uint48 staleAfter, bool enabled)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (feed == address(0) || staleAfter == 0) revert InvalidFeed();
        uint8 tokenDecimals = token == NATIVE_ETH ? 18 : IERC20Metadata(token).decimals();
        TokenConfig memory previous = tokenConfig[token];
        tokenConfig[token] = TokenConfig({
            enabled: enabled,
            feed: feed,
            staleAfter: staleAfter,
            tokenDecimals: tokenDecimals,
            minAnswer: previous.minAnswer,
            maxAnswer: previous.maxAnswer
        });
        emit PaymentTokenSet(token, feed, staleAfter, tokenDecimals, enabled);
    }

    /// @notice Sets optional sanity bounds for a token's oracle answer.
    /// @param token Payment token whose feed bounds are updated.
    /// @param minAnswer Minimum accepted oracle answer.
    /// @param maxAnswer Maximum accepted oracle answer.
    function setTokenBounds(address token, int192 minAnswer, int192 maxAnswer) external onlyRole(DEFAULT_ADMIN_ROLE) {
        TokenConfig storage config = tokenConfig[token];
        if (config.feed == address(0)) revert TokenNotEnabled();
        if (minAnswer <= 0 || maxAnswer <= minAnswer) revert InvalidBounds();
        config.minAnswer = minAnswer;
        config.maxAnswer = maxAnswer;
        emit PaymentTokenBoundsSet(token, minAnswer, maxAnswer);
    }

    /// @notice Removes a token from accepted payment assets.
    /// @param token Payment token address to remove.
    function removeToken(address token) external onlyRole(DEFAULT_ADMIN_ROLE) {
        delete tokenConfig[token];
        emit PaymentTokenRemoved(token);
    }

    /// @notice Returns whether a token is enabled for payments.
    /// @param token Token address, or address(0) for native ETH.
    function isEnabled(address token) external view returns (bool) {
        return tokenConfig[token].enabled;
    }

    /// @notice Quotes a token amount into 18-decimal USD.
    /// @dev Reverts on disabled tokens, invalid/stale/incomplete oracle rounds, out-of-bounds answers, or zero-USD dust.
    /// @param token Payment token address, or address(0) for native ETH.
    /// @param amount Token amount in the token's native decimals.
    /// @return usdValue 18-decimal USD value.
    function quoteTokenToUsd(address token, uint256 amount) public view returns (uint256 usdValue) {
        TokenConfig memory config = tokenConfig[token];
        (uint256 answer, uint8 feedDecimals) = _validatedPrice(config);
        usdValue = Math.mulDiv(amount, answer * USD_DECIMALS, (10 ** config.tokenDecimals) * (10 ** feedDecimals));
        if (usdValue == 0) revert InvalidPrice();
    }

    /// @notice Returns the minimum token amount whose oracle quote covers a USD value.
    /// @dev Rounds up so fixed-price callers never underpay because of integer truncation.
    /// @param token Payment token address, or address(0) for native ETH.
    /// @param usdValue Required 18-decimal USD value.
    /// @return tokenAmount Minimum amount in the token's native decimals.
    function quoteUsdToToken(address token, uint256 usdValue) public view returns (uint256 tokenAmount) {
        if (usdValue == 0) revert InvalidPrice();
        TokenConfig memory config = tokenConfig[token];
        (uint256 answer, uint8 feedDecimals) = _validatedPrice(config);
        tokenAmount = Math.mulDiv(
            usdValue, (10 ** config.tokenDecimals) * (10 ** feedDecimals), answer * USD_DECIMALS, Math.Rounding.Ceil
        );
        if (tokenAmount == 0) revert InvalidPrice();
    }

    function _validatedPrice(TokenConfig memory config) private view returns (uint256 answer, uint8 feedDecimals) {
        if (!config.enabled) revert TokenNotEnabled();

        AggregatorV3Interface feed = AggregatorV3Interface(config.feed);
        (uint80 roundId, int256 signedAnswer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            feed.latestRoundData();
        if (roundId == 0 || startedAt == 0 || updatedAt == 0 || answeredInRound < roundId) revert StalePrice();
        if (signedAnswer <= 0) revert InvalidPrice();
        if (config.maxAnswer != 0 && (signedAnswer < config.minAnswer || signedAnswer > config.maxAnswer)) {
            revert InvalidPrice();
        }
        if (block.timestamp - updatedAt >= config.staleAfter) revert StalePrice();

        // casting is safe because non-positive oracle answers are rejected above.
        // forge-lint: disable-next-line(unsafe-typecast)
        answer = uint256(signedAnswer);
        feedDecimals = feed.decimals();
    }

    /// @dev Authorizes UUPS upgrades for `UPGRADER_ROLE` holders.
    function _authorizeUpgrade(address) internal override onlyRole(Roles.UPGRADER_ROLE) {}
}
