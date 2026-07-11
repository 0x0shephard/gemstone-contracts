// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GemRegistry} from "./GemRegistry.sol";
import {PaymentTokenRegistry} from "./PaymentTokenRegistry.sol";
import {Roles} from "./libraries/Roles.sol";

contract ReserveManager is Initializable, AccessControlUpgradeable, UUPSUpgradeable, PausableUpgradeable {
    using SafeERC20 for IERC20;

    uint16 public constant BPS_DENOMINATOR = 10_000;

    struct ReserveBracket {
        uint256 minPriceUsd;
        uint256 maxPriceUsd;
        uint16 reserveBps;
    }

    PaymentTokenRegistry public paymentRegistry;
    GemRegistry public registry;
    uint16 public defaultReserveBps;
    ReserveBracket[] private _reserveBrackets;

    mapping(uint256 gemId => uint256 usdAmount) public minimumReserveUsd;
    mapping(uint256 gemId => uint256 usdAmount) public reserveBalanceUsd;
    mapping(uint256 gemId => mapping(address asset => uint256 amount)) public reserveAssetBalance;
    mapping(uint256 gemId => uint256 usdAmount) public projectedLiabilityUsd;
    mapping(uint256 gemId => bool underfunded) private _underfundedGem;
    uint256 public totalReserveBalanceUsd;
    uint256 public totalProjectedLiabilitiesUsd;
    uint256 public underfundedGemCount;
    uint16 public minimumCoverageBps;
    bool public globalSolvencyCheckEnabled;

    event DefaultReserveBpsUpdated(uint16 reserveBps);
    event ReserveBracketsUpdated();
    event MinimumReserveUpdated(uint256 indexed gemId, uint256 minimumReserveUsd);
    event ReserveFunded(uint256 indexed gemId, address indexed asset, uint256 amount, uint256 usdValue);
    event ReserveConsumed(uint256 indexed gemId, uint256 usdValue);
    event ReserveConsumedFor(uint256 indexed gemId, uint256 usdValue, bytes32 indexed reasonHash);
    event ProjectedLiabilityUpdated(uint256 indexed gemId, uint256 liabilityUsd);
    event UnderfundedGemUpdated(uint256 indexed gemId, bool underfunded);
    event MinimumCoverageBpsUpdated(uint16 minimumCoverageBps);
    event GlobalSolvencyCheckUpdated(bool enabled);

    error InvalidAddress();
    error InvalidAmount();
    error InvalidReserveBracket();
    error InvalidReserveBps();
    error ReserveShortfall(uint256 requiredUsd, uint256 balanceUsd);
    error Insolvent(uint256 coverageBps, uint256 minimumCoverageBps);
    error UnderfundedReserves(uint256 underfundedGemCount);

    constructor() {
        _disableInitializers();
    }

    function initialize(address admin, PaymentTokenRegistry paymentRegistry_, GemRegistry registry_)
        external
        initializer
    {
        if (admin == address(0) || address(paymentRegistry_) == address(0) || address(registry_) == address(0)) {
            revert InvalidAddress();
        }
        __AccessControl_init();
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(Roles.UPGRADER_ROLE, admin);
        _grantRole(Roles.RESERVE_OPERATOR_ROLE, admin);

        paymentRegistry = paymentRegistry_;
        registry = registry_;
        globalSolvencyCheckEnabled = true;
        minimumCoverageBps = BPS_DENOMINATOR;
    }

    function setDefaultReserveBps(uint16 reserveBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (reserveBps > BPS_DENOMINATOR) revert InvalidReserveBps();
        defaultReserveBps = reserveBps;
        emit DefaultReserveBpsUpdated(reserveBps);
    }

    function setMinimumReserveUsd(uint256 gemId, uint256 minimumReserveUsd_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _requireExistingGem(gemId);
        minimumReserveUsd[gemId] = minimumReserveUsd_;
        emit MinimumReserveUpdated(gemId, minimumReserveUsd_);
    }

    function setProjectedLiabilityUsd(uint256 gemId, uint256 liabilityUsd) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _requireExistingGem(gemId);
        _setProjectedLiabilityUsd(gemId, liabilityUsd);
    }

    function syncProjectedLiabilityUsd(uint256 gemId, uint256 referenceValueUsd)
        external
        onlyRole(Roles.RESERVE_OPERATOR_ROLE)
    {
        _requireExistingGem(gemId);
        _setProjectedLiabilityUsd(gemId, requiredReserveUsd(gemId, referenceValueUsd));
    }

    function clearProjectedLiabilityUsd(uint256 gemId) external onlyRole(Roles.RESERVE_OPERATOR_ROLE) {
        _requireExistingGem(gemId);
        _setProjectedLiabilityUsd(gemId, 0);
    }

    function _setProjectedLiabilityUsd(uint256 gemId, uint256 liabilityUsd) private {
        uint256 previous = projectedLiabilityUsd[gemId];
        projectedLiabilityUsd[gemId] = liabilityUsd;
        totalProjectedLiabilitiesUsd = totalProjectedLiabilitiesUsd - previous + liabilityUsd;
        _refreshUnderfundedGem(gemId);
        emit ProjectedLiabilityUpdated(gemId, liabilityUsd);
    }

    function setMinimumCoverageBps(uint16 minimumCoverageBps_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        minimumCoverageBps = minimumCoverageBps_;
        emit MinimumCoverageBpsUpdated(minimumCoverageBps_);
    }

    function setGlobalSolvencyCheckEnabled(bool enabled) external onlyRole(DEFAULT_ADMIN_ROLE) {
        globalSolvencyCheckEnabled = enabled;
        emit GlobalSolvencyCheckUpdated(enabled);
    }

    function setReserveBrackets(ReserveBracket[] calldata brackets) external onlyRole(DEFAULT_ADMIN_ROLE) {
        delete _reserveBrackets;

        uint256 previousMax;
        for (uint256 i = 0; i < brackets.length; i++) {
            ReserveBracket calldata bracket = brackets[i];
            if (
                bracket.minPriceUsd != previousMax || bracket.maxPriceUsd <= bracket.minPriceUsd
                    || bracket.reserveBps > BPS_DENOMINATOR
            ) {
                revert InvalidReserveBracket();
            }
            _reserveBrackets.push(bracket);
            previousMax = bracket.maxPriceUsd;
        }
        if (brackets.length != 0 && previousMax != type(uint256).max) revert InvalidReserveBracket();

        emit ReserveBracketsUpdated();
    }

    function reserveBracketCount() external view returns (uint256) {
        return _reserveBrackets.length;
    }

    function reserveBracket(uint256 index) external view returns (ReserveBracket memory) {
        return _reserveBrackets[index];
    }

    function fundNative(uint256 gemId) external payable whenNotPaused {
        _requireExistingGem(gemId);
        if (msg.value == 0) revert InvalidAmount();
        uint256 usdValue = paymentRegistry.quoteTokenToUsd(address(0), msg.value);
        _recordFunding(gemId, address(0), msg.value, usdValue);
    }

    function fundToken(uint256 gemId, address token, uint256 amount) external whenNotPaused {
        _requireExistingGem(gemId);
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
        _requireExistingGem(gemId);
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
        _consumeReserveUsd(gemId, usdValue, bytes32(0));
    }

    function consumeReserveUsdFor(uint256 gemId, uint256 usdValue, bytes32 reasonHash)
        external
        whenNotPaused
        onlyRole(Roles.RESERVE_OPERATOR_ROLE)
    {
        _consumeReserveUsd(gemId, usdValue, reasonHash);
    }

    function coverageRatioBps() public view returns (uint256) {
        if (totalProjectedLiabilitiesUsd == 0) return type(uint256).max;
        return (totalReserveBalanceUsd * BPS_DENOMINATOR) / totalProjectedLiabilitiesUsd;
    }

    function requireSolvent() external view {
        if (!globalSolvencyCheckEnabled) return;
        uint256 coverage = coverageRatioBps();
        if (coverage < minimumCoverageBps) revert Insolvent(coverage, minimumCoverageBps);
        if (underfundedGemCount != 0) revert UnderfundedReserves(underfundedGemCount);
    }

    function _consumeReserveUsd(uint256 gemId, uint256 usdValue, bytes32 reasonHash) private {
        _requireExistingGem(gemId);
        if (usdValue == 0) revert InvalidAmount();
        uint256 balance = reserveBalanceUsd[gemId];
        if (balance < usdValue) revert ReserveShortfall(usdValue, balance);
        reserveBalanceUsd[gemId] = balance - usdValue;
        totalReserveBalanceUsd -= usdValue;
        _refreshUnderfundedGem(gemId);
        emit ReserveConsumed(gemId, usdValue);
        emit ReserveConsumedFor(gemId, usdValue, reasonHash);
    }

    function requiredReserveUsd(uint256 gemId, uint256 referenceValueUsd) public view returns (uint256 requiredUsd) {
        uint256 percentReserve = (referenceValueUsd * reserveBpsFor(referenceValueUsd)) / BPS_DENOMINATOR;
        uint256 minimumReserve = minimumReserveUsd[gemId];
        requiredUsd = percentReserve > minimumReserve ? percentReserve : minimumReserve;
    }

    function reserveBpsFor(uint256 referenceValueUsd) public view returns (uint16) {
        for (uint256 i = 0; i < _reserveBrackets.length; i++) {
            ReserveBracket memory bracket = _reserveBrackets[i];
            if (referenceValueUsd >= bracket.minPriceUsd && referenceValueUsd < bracket.maxPriceUsd) {
                return bracket.reserveBps;
            }
        }
        return defaultReserveBps;
    }

    function shortfallUsd(uint256 gemId, uint256 referenceValueUsd) public view returns (uint256) {
        uint256 requiredUsd = requiredReserveUsd(gemId, referenceValueUsd);
        uint256 balanceUsd = reserveBalanceUsd[gemId];
        return balanceUsd >= requiredUsd ? 0 : requiredUsd - balanceUsd;
    }

    function requireFunded(uint256 gemId, uint256 referenceValueUsd) external view {
        _requireExistingGem(gemId);
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
        totalReserveBalanceUsd += usdValue;
        _refreshUnderfundedGem(gemId);
        emit ReserveFunded(gemId, asset, amount, usdValue);
    }

    function _requireExistingGem(uint256 gemId) private view {
        registry.getGem(gemId);
    }

    function isUnderfunded(uint256 gemId) external view returns (bool) {
        return _underfundedGem[gemId];
    }

    function _refreshUnderfundedGem(uint256 gemId) private {
        bool underfunded = projectedLiabilityUsd[gemId] != 0 && reserveBalanceUsd[gemId] < projectedLiabilityUsd[gemId];
        bool previous = _underfundedGem[gemId];
        if (underfunded == previous) return;
        _underfundedGem[gemId] = underfunded;
        if (underfunded) {
            underfundedGemCount++;
        } else {
            underfundedGemCount--;
        }
        emit UnderfundedGemUpdated(gemId, underfunded);
    }

    receive() external payable {}

    function _authorizeUpgrade(address) internal override onlyRole(Roles.UPGRADER_ROLE) {}
}
