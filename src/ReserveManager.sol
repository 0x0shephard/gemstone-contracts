// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PaymentTokenRegistry} from "./PaymentTokenRegistry.sol";
import {Roles} from "./libraries/Roles.sol";

contract ReserveManager is Initializable, AccessControlUpgradeable, UUPSUpgradeable, PausableUpgradeable {
    using SafeERC20 for IERC20;

    uint16 public constant BPS_DENOMINATOR = 10_000;

    PaymentTokenRegistry public paymentRegistry;
    uint16 public defaultReserveBps;

    mapping(uint256 gemId => uint256 usdAmount) public minimumReserveUsd;
    mapping(uint256 gemId => uint256 usdAmount) public reserveBalanceUsd;
    mapping(uint256 gemId => mapping(address asset => uint256 amount)) public reserveAssetBalance;

    event DefaultReserveBpsUpdated(uint16 reserveBps);
    event MinimumReserveUpdated(uint256 indexed gemId, uint256 minimumReserveUsd);
    event ReserveFunded(uint256 indexed gemId, address indexed asset, uint256 amount, uint256 usdValue);
    event ReserveConsumed(uint256 indexed gemId, uint256 usdValue);

    error InvalidAddress();
    error InvalidAmount();
    error InvalidReserveBps();
    error ReserveShortfall(uint256 requiredUsd, uint256 balanceUsd);

    function initialize(address admin, PaymentTokenRegistry paymentRegistry_) external initializer {
        if (admin == address(0) || address(paymentRegistry_) == address(0)) revert InvalidAddress();
        __AccessControl_init();
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(Roles.UPGRADER_ROLE, admin);
        _grantRole(Roles.RESERVE_OPERATOR_ROLE, admin);

        paymentRegistry = paymentRegistry_;
    }

    function setDefaultReserveBps(uint16 reserveBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (reserveBps > BPS_DENOMINATOR) revert InvalidReserveBps();
        defaultReserveBps = reserveBps;
        emit DefaultReserveBpsUpdated(reserveBps);
    }

    function setMinimumReserveUsd(uint256 gemId, uint256 minimumReserveUsd_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        minimumReserveUsd[gemId] = minimumReserveUsd_;
        emit MinimumReserveUpdated(gemId, minimumReserveUsd_);
    }

    function fundNative(uint256 gemId) external payable whenNotPaused {
        if (msg.value == 0) revert InvalidAmount();
        uint256 usdValue = paymentRegistry.quoteTokenToUsd(address(0), msg.value);
        _recordFunding(gemId, address(0), msg.value, usdValue);
    }

    function fundToken(uint256 gemId, address token, uint256 amount) external whenNotPaused {
        if (token == address(0) || amount == 0) revert InvalidAmount();
        uint256 beforeBalance = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(token).balanceOf(address(this)) - beforeBalance;
        if (received == 0) revert InvalidAmount();
        uint256 usdValue = paymentRegistry.quoteTokenToUsd(token, received);
        _recordFunding(gemId, token, received, usdValue);
    }

    function recordModuleFunding(uint256 gemId, address asset, uint256 amount, uint256 usdValue)
        external
        payable
        whenNotPaused
        onlyRole(Roles.RESERVE_OPERATOR_ROLE)
    {
        if (amount == 0 || usdValue == 0) revert InvalidAmount();
        if (asset == address(0) && msg.value != amount) revert InvalidAmount();
        if (asset != address(0) && msg.value != 0) revert InvalidAmount();
        _recordFunding(gemId, asset, amount, usdValue);
    }

    function consumeReserveUsd(uint256 gemId, uint256 usdValue)
        external
        whenNotPaused
        onlyRole(Roles.RESERVE_OPERATOR_ROLE)
    {
        if (usdValue == 0) revert InvalidAmount();
        uint256 balance = reserveBalanceUsd[gemId];
        if (balance < usdValue) revert ReserveShortfall(usdValue, balance);
        reserveBalanceUsd[gemId] = balance - usdValue;
        emit ReserveConsumed(gemId, usdValue);
    }

    function requiredReserveUsd(uint256 gemId, uint256 referenceValueUsd) public view returns (uint256 requiredUsd) {
        uint256 percentReserve = (referenceValueUsd * defaultReserveBps) / BPS_DENOMINATOR;
        uint256 minimumReserve = minimumReserveUsd[gemId];
        requiredUsd = percentReserve > minimumReserve ? percentReserve : minimumReserve;
    }

    function shortfallUsd(uint256 gemId, uint256 referenceValueUsd) public view returns (uint256) {
        uint256 requiredUsd = requiredReserveUsd(gemId, referenceValueUsd);
        uint256 balanceUsd = reserveBalanceUsd[gemId];
        return balanceUsd >= requiredUsd ? 0 : requiredUsd - balanceUsd;
    }

    function requireFunded(uint256 gemId, uint256 referenceValueUsd) external view {
        uint256 requiredUsd = requiredReserveUsd(gemId, referenceValueUsd);
        uint256 balanceUsd = reserveBalanceUsd[gemId];
        if (balanceUsd < requiredUsd) revert ReserveShortfall(requiredUsd, balanceUsd);
    }

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    function _recordFunding(uint256 gemId, address asset, uint256 amount, uint256 usdValue) private {
        reserveAssetBalance[gemId][asset] += amount;
        reserveBalanceUsd[gemId] += usdValue;
        emit ReserveFunded(gemId, asset, amount, usdValue);
    }

    receive() external payable {}

    function _authorizeUpgrade(address) internal override onlyRole(Roles.UPGRADER_ROLE) {}
}
