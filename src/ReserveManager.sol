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
    mapping(uint256 gemId => uint256 usdAmount) private _recordedReserveBalanceUsd;
    mapping(uint256 gemId => mapping(address asset => uint256 amount)) public reserveAssetBalance;
    mapping(uint256 gemId => address[] assets) private _reserveAssets;
    mapping(uint256 gemId => mapping(address asset => bool tracked)) private _reserveAssetTracked;
    mapping(uint256 gemId => uint256 usdAmount) public projectedLiabilityUsd;
    mapping(uint256 gemId => bool underfunded) private _underfundedGem;
    uint256 private _recordedTotalReserveBalanceUsd;
    uint256 public totalProjectedLiabilitiesUsd;
    uint256 public underfundedGemCount;
    uint16 public minimumCoverageBps;
    bool public globalSolvencyCheckEnabled;
    mapping(address asset => uint256 amount) public totalReserveAssetBalance;
    address[] private _reserveAssetTypes;
    mapping(address asset => bool tracked) private _reserveAssetTypeTracked;

    event DefaultReserveBpsUpdated(uint16 reserveBps);
    event ReserveBracketsUpdated();
    event MinimumReserveUpdated(uint256 indexed gemId, uint256 minimumReserveUsd);
    event ReserveFunded(uint256 indexed gemId, address indexed asset, uint256 amount, uint256 usdValue);
    event ReserveConsumed(uint256 indexed gemId, uint256 usdValue);
    event ReserveConsumedFor(uint256 indexed gemId, uint256 usdValue, bytes32 indexed reasonHash);
    event ReserveReleased(
        uint256 indexed gemId,
        address indexed asset,
        address indexed recipient,
        uint256 amount,
        uint256 usdValue,
        bytes32 reasonHash
    );
    event ProjectedLiabilityUpdated(uint256 indexed gemId, uint256 liabilityUsd);
    event UnderfundedGemUpdated(uint256 indexed gemId, bool underfunded);
    event MinimumCoverageBpsUpdated(uint16 minimumCoverageBps);
    event GlobalSolvencyCheckUpdated(bool enabled);

    error InvalidAddress();
    error InvalidAmount();
    error InvalidReserveBracket();
    error InvalidReserveBps();
    error ReserveShortfall(uint256 requiredUsd, uint256 balanceUsd);
    error LiabilityShortfall(uint256 requiredUsd, uint256 liabilityUsd);
    error Insolvent(uint256 coverageBps, uint256 minimumCoverageBps);
    error UnderfundedReserves(uint256 underfundedGemCount);

    /// @custom:oz-upgrades-unsafe-allow constructor
    /// @dev Locks the implementation contract so only proxy instances can be initialized.
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes reserve accounting, registry dependency, and solvency defaults.
    /// @param admin Account receiving admin, upgrader, and reserve operator roles.
    /// @param paymentRegistry_ Payment registry used for USD quoting.
    /// @param registry_ Gem registry used to validate gem ids.
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

    /// @notice Sets fallback reserve BPS when no bracket matches.
    /// @param reserveBps Reserve percentage in basis points.
    function setDefaultReserveBps(uint16 reserveBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (reserveBps > BPS_DENOMINATOR) revert InvalidReserveBps();
        defaultReserveBps = reserveBps;
        emit DefaultReserveBpsUpdated(reserveBps);
    }

    /// @notice Sets a per-gem absolute minimum reserve.
    /// @param gemId Existing gem id.
    /// @param minimumReserveUsd_ Minimum reserve in 18-decimal USD.
    function setMinimumReserveUsd(uint256 gemId, uint256 minimumReserveUsd_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _requireExistingGem(gemId);
        minimumReserveUsd[gemId] = minimumReserveUsd_;
        emit MinimumReserveUpdated(gemId, minimumReserveUsd_);
    }

    /// @notice Manually sets projected reserve liability for a gem.
    /// @param gemId Existing gem id.
    /// @param liabilityUsd Liability in 18-decimal USD.
    function setProjectedLiabilityUsd(uint256 gemId, uint256 liabilityUsd) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _requireExistingGem(gemId);
        _setProjectedLiabilityUsd(gemId, liabilityUsd);
    }

    /// @notice Syncs projected liability to current required reserve for a reference value.
    /// @dev Callable only by `RESERVE_OPERATOR_ROLE` modules after mint or secondary settlement.
    /// @param gemId Existing gem id.
    /// @param referenceValueUsd Reference value used for reserve bracket calculation.
    function syncProjectedLiabilityUsd(uint256 gemId, uint256 referenceValueUsd)
        external
        onlyRole(Roles.RESERVE_OPERATOR_ROLE)
    {
        _requireExistingGem(gemId);
        _setProjectedLiabilityUsd(gemId, requiredReserveUsd(gemId, referenceValueUsd));
    }

    /// @notice Clears projected liability for a gem.
    /// @dev Callable only by `RESERVE_OPERATOR_ROLE`, normally during completed redemption.
    /// @param gemId Existing gem id.
    function clearProjectedLiabilityUsd(uint256 gemId) external onlyRole(Roles.RESERVE_OPERATOR_ROLE) {
        _requireExistingGem(gemId);
        _setProjectedLiabilityUsd(gemId, 0);
    }

    /// @dev Updates liability aggregates and underfunded tracking.
    function _setProjectedLiabilityUsd(uint256 gemId, uint256 liabilityUsd) private {
        uint256 previous = projectedLiabilityUsd[gemId];
        projectedLiabilityUsd[gemId] = liabilityUsd;
        totalProjectedLiabilitiesUsd = totalProjectedLiabilitiesUsd - previous + liabilityUsd;
        _refreshUnderfundedGem(gemId);
        emit ProjectedLiabilityUpdated(gemId, liabilityUsd);
    }

    /// @notice Sets the minimum aggregate reserve coverage ratio.
    /// @param minimumCoverageBps_ Minimum coverage in basis points.
    function setMinimumCoverageBps(uint16 minimumCoverageBps_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        minimumCoverageBps = minimumCoverageBps_;
        emit MinimumCoverageBpsUpdated(minimumCoverageBps_);
    }

    /// @notice Enables or disables aggregate solvency checks.
    /// @param enabled True to enforce `minimumCoverageBps`.
    function setGlobalSolvencyCheckEnabled(bool enabled) external onlyRole(DEFAULT_ADMIN_ROLE) {
        globalSolvencyCheckEnabled = enabled;
        emit GlobalSolvencyCheckUpdated(enabled);
    }

    /// @notice Replaces the reserve bracket table.
    /// @dev Brackets must be contiguous from 0 and the last bracket must end at `type(uint256).max`.
    /// @param brackets Ordered reserve brackets.
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

    /// @notice Returns the number of configured reserve brackets.
    function reserveBracketCount() external view returns (uint256) {
        return _reserveBrackets.length;
    }

    /// @notice Returns a reserve bracket by index.
    /// @param index Bracket index.
    function reserveBracket(uint256 index) external view returns (ReserveBracket memory) {
        return _reserveBrackets[index];
    }

    /// @notice Funds a gem reserve with native ETH.
    /// @param gemId Existing gem id to credit.
    function fundNative(uint256 gemId) external payable whenNotPaused {
        _requireExistingGem(gemId);
        if (msg.value == 0) revert InvalidAmount();
        uint256 usdValue = paymentRegistry.quoteTokenToUsd(address(0), msg.value);
        _recordFunding(gemId, address(0), msg.value, usdValue);
    }

    /// @notice Funds a gem reserve with an ERC-20 token.
    /// @param gemId Existing gem id to credit.
    /// @param token ERC-20 asset used for funding.
    /// @param amount Amount to transfer from caller.
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

    /// @notice Records reserve funding made by a trusted protocol module.
    /// @dev Re-quotes `amount` through PaymentTokenRegistry instead of trusting caller-supplied USD value.
    /// @param gemId Existing gem id to credit.
    /// @param asset Asset funded, or address(0) for native ETH.
    /// @param amount Asset amount funded.
    /// @param usdValue Caller-supplied USD value retained for interface compatibility; ignored after validation.
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
        uint256 quotedUsdValue = paymentRegistry.quoteTokenToUsd(asset, amount);
        if (quotedUsdValue == 0) revert InvalidAmount();
        _recordFunding(gemId, asset, amount, quotedUsdValue);
    }

    /// @notice Records that part of a gem's projected reserve liability has been discharged.
    /// @dev This USD-only operation does not move assets. Use `releaseReserveAsset` for an on-chain payout.
    /// @param gemId Existing gem id to debit.
    /// @param usdValue 18-decimal USD liability amount to discharge.
    function consumeReserveUsd(uint256 gemId, uint256 usdValue)
        external
        whenNotPaused
        onlyRole(Roles.RESERVE_OPERATOR_ROLE)
    {
        _consumeReserveUsd(gemId, usdValue, bytes32(0));
    }

    /// @notice Records a reasoned discharge of projected reserve liability.
    /// @dev This USD-only operation does not move assets. Use `releaseReserveAsset` for an on-chain payout.
    /// @param gemId Existing gem id to debit.
    /// @param usdValue 18-decimal USD liability amount to discharge.
    /// @param reasonHash Off-chain reason hash.
    function consumeReserveUsdFor(uint256 gemId, uint256 usdValue, bytes32 reasonHash)
        external
        whenNotPaused
        onlyRole(Roles.RESERVE_OPERATOR_ROLE)
    {
        _consumeReserveUsd(gemId, usdValue, reasonHash);
    }

    /// @notice Releases a specific reserve asset from a gem.
    /// @dev Callable only by `RESERVE_OPERATOR_ROLE`; debits USD accounting using current oracle quote.
    /// @param gemId Existing gem id.
    /// @param asset Asset to release, or address(0) for native ETH.
    /// @param amount Asset amount to release.
    /// @param recipient Destination for released assets.
    /// @param reasonHash Off-chain release reason hash.
    /// @return usdValue USD accounting value debited.
    function releaseReserveAsset(uint256 gemId, address asset, uint256 amount, address recipient, bytes32 reasonHash)
        external
        whenNotPaused
        onlyRole(Roles.RESERVE_OPERATOR_ROLE)
        returns (uint256 usdValue)
    {
        _requireExistingGem(gemId);
        if (recipient == address(0) || amount == 0) revert InvalidAmount();
        uint256 balance = reserveAssetBalance[gemId][asset];
        if (balance < amount) revert InvalidAmount();

        usdValue = paymentRegistry.quoteTokenToUsd(asset, amount);
        if (usdValue == 0) revert InvalidAmount();
        reserveAssetBalance[gemId][asset] = balance - amount;
        totalReserveAssetBalance[asset] -= amount;
        _decreaseReserveBalanceUsd(gemId, usdValue);
        _sendAsset(asset, recipient, amount);
        emit ReserveReleased(gemId, asset, recipient, amount, usdValue, reasonHash);
    }

    /// @notice Releases all tracked reserve assets for a gem.
    /// @dev Used on completed redemption; clears all remaining USD reserve accounting for the gem.
    /// @param gemId Existing gem id.
    /// @param recipient Destination for released assets.
    /// @param reasonHash Off-chain release reason hash.
    /// @return releasedCount Number of non-zero asset balances released.
    function releaseAllReserveAssets(uint256 gemId, address recipient, bytes32 reasonHash)
        external
        whenNotPaused
        onlyRole(Roles.RESERVE_OPERATOR_ROLE)
        returns (uint256 releasedCount)
    {
        _requireExistingGem(gemId);
        if (recipient == address(0)) revert InvalidAmount();

        address[] storage assets = _reserveAssets[gemId];
        for (uint256 i = 0; i < assets.length; i++) {
            address asset = assets[i];
            uint256 amount = reserveAssetBalance[gemId][asset];
            if (amount == 0) continue;
            reserveAssetBalance[gemId][asset] = 0;
            totalReserveAssetBalance[asset] -= amount;
            _sendAsset(asset, recipient, amount);
            emit ReserveReleased(gemId, asset, recipient, amount, 0, reasonHash);
            releasedCount++;
        }

        uint256 usdBalance = _recordedReserveBalanceUsd[gemId];
        if (usdBalance != 0) {
            _recordedReserveBalanceUsd[gemId] = 0;
            _recordedTotalReserveBalanceUsd -= usdBalance;
            _refreshUnderfundedGem(gemId);
        }
    }

    /// @notice Returns the current oracle-valued reserve balance for a gem.
    /// @dev Assets whose quote is unavailable are conservatively valued at zero.
    function reserveBalanceUsd(uint256 gemId) public view returns (uint256 usdValue) {
        address[] storage assets = _reserveAssets[gemId];
        for (uint256 i = 0; i < assets.length; i++) {
            usdValue += _safeQuote(assets[i], reserveAssetBalance[gemId][assets[i]]);
        }
    }

    /// @notice Returns the current oracle-valued aggregate reserve balance.
    /// @dev Assets whose quote is unavailable are conservatively valued at zero.
    function totalReserveBalanceUsd() public view returns (uint256 usdValue) {
        for (uint256 i = 0; i < _reserveAssetTypes.length; i++) {
            address asset = _reserveAssetTypes[i];
            usdValue += _safeQuote(asset, totalReserveAssetBalance[asset]);
        }
    }

    /// @notice Returns the historical USD ledger for a gem before live revaluation.
    function recordedReserveBalanceUsd(uint256 gemId) external view returns (uint256) {
        return _recordedReserveBalanceUsd[gemId];
    }

    /// @notice Returns the historical aggregate USD ledger before live revaluation.
    function recordedTotalReserveBalanceUsd() external view returns (uint256) {
        return _recordedTotalReserveBalanceUsd;
    }

    /// @notice Returns aggregate live reserve coverage ratio in basis points.
    /// @return Coverage ratio, or max uint256 when liabilities are zero.
    function coverageRatioBps() public view returns (uint256) {
        if (totalProjectedLiabilitiesUsd == 0) return type(uint256).max;
        return (totalReserveBalanceUsd() * BPS_DENOMINATOR) / totalProjectedLiabilitiesUsd;
    }

    /// @notice Reverts if aggregate solvency check is enabled and below the configured minimum.
    function requireSolvent() external view {
        if (!globalSolvencyCheckEnabled) return;
        uint256 coverage = coverageRatioBps();
        if (coverage < minimumCoverageBps) revert Insolvent(coverage, minimumCoverageBps);
    }

    /// @dev Discharges an equal amount of projected liability without moving underlying assets.
    function _consumeReserveUsd(uint256 gemId, uint256 usdValue, bytes32 reasonHash) private {
        _requireExistingGem(gemId);
        if (usdValue == 0) revert InvalidAmount();
        uint256 liability = projectedLiabilityUsd[gemId];
        if (liability < usdValue) revert LiabilityShortfall(usdValue, liability);
        _setProjectedLiabilityUsd(gemId, liability - usdValue);
        emit ReserveConsumed(gemId, usdValue);
        emit ReserveConsumedFor(gemId, usdValue, reasonHash);
    }

    /// @notice Returns required reserve for a gem at a reference value.
    /// @param gemId Gem id whose absolute minimum reserve is considered.
    /// @param referenceValueUsd 18-decimal USD reference value.
    /// @return requiredUsd Required reserve in 18-decimal USD.
    function requiredReserveUsd(uint256 gemId, uint256 referenceValueUsd) public view returns (uint256 requiredUsd) {
        uint256 percentReserve = (referenceValueUsd * reserveBpsFor(referenceValueUsd)) / BPS_DENOMINATOR;
        uint256 minimumReserve = minimumReserveUsd[gemId];
        requiredUsd = percentReserve > minimumReserve ? percentReserve : minimumReserve;
    }

    /// @notice Returns reserve BPS for a reference value.
    /// @param referenceValueUsd 18-decimal USD reference value.
    function reserveBpsFor(uint256 referenceValueUsd) public view returns (uint16) {
        for (uint256 i = 0; i < _reserveBrackets.length; i++) {
            ReserveBracket memory bracket = _reserveBrackets[i];
            if (referenceValueUsd >= bracket.minPriceUsd && referenceValueUsd < bracket.maxPriceUsd) {
                return bracket.reserveBps;
            }
        }
        return defaultReserveBps;
    }

    /// @notice Returns current reserve shortfall for a gem at a reference value.
    /// @param gemId Gem id to check.
    /// @param referenceValueUsd 18-decimal USD reference value.
    function shortfallUsd(uint256 gemId, uint256 referenceValueUsd) public view returns (uint256) {
        uint256 requiredUsd = requiredReserveUsd(gemId, referenceValueUsd);
        uint256 balanceUsd = reserveBalanceUsd(gemId);
        return balanceUsd >= requiredUsd ? 0 : requiredUsd - balanceUsd;
    }

    /// @notice Reverts unless a gem's reserve meets its requirement at a reference value.
    /// @param gemId Gem id to check.
    /// @param referenceValueUsd 18-decimal USD reference value.
    function requireFunded(uint256 gemId, uint256 referenceValueUsd) external view {
        _requireExistingGem(gemId);
        uint256 requiredUsd = requiredReserveUsd(gemId, referenceValueUsd);
        uint256 balanceUsd = reserveBalanceUsd(gemId);
        if (balanceUsd < requiredUsd) revert ReserveShortfall(requiredUsd, balanceUsd);
    }

    /// @notice Pauses reserve funding, release, and consumption operations.
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /// @notice Unpauses reserve funding, release, and consumption operations.
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /// @dev Records asset and USD accounting for reserve funding.
    function _recordFunding(uint256 gemId, address asset, uint256 amount, uint256 usdValue) private {
        if (usdValue == 0) revert InvalidAmount();
        if (!_reserveAssetTracked[gemId][asset]) {
            _reserveAssetTracked[gemId][asset] = true;
            _reserveAssets[gemId].push(asset);
        }
        if (!_reserveAssetTypeTracked[asset]) {
            _reserveAssetTypeTracked[asset] = true;
            _reserveAssetTypes.push(asset);
        }
        reserveAssetBalance[gemId][asset] += amount;
        totalReserveAssetBalance[asset] += amount;
        _recordedReserveBalanceUsd[gemId] += usdValue;
        _recordedTotalReserveBalanceUsd += usdValue;
        _refreshUnderfundedGem(gemId);
        emit ReserveFunded(gemId, asset, amount, usdValue);
    }

    /// @dev Decreases USD reserve accounting, clamped to the recorded balance.
    function _decreaseReserveBalanceUsd(uint256 gemId, uint256 usdValue) private {
        uint256 balance = _recordedReserveBalanceUsd[gemId];
        uint256 debit = usdValue > balance ? balance : usdValue;
        _recordedReserveBalanceUsd[gemId] = balance - debit;
        _recordedTotalReserveBalanceUsd -= debit;
        _refreshUnderfundedGem(gemId);
    }

    /// @dev Reverts unless `gemId` exists in the registry.
    function _requireExistingGem(uint256 gemId) private view {
        registry.getGem(gemId);
    }

    /// @notice Returns whether a gem's reserve is below its projected liability.
    /// @param gemId Gem id to query.
    function isUnderfunded(uint256 gemId) external view returns (bool) {
        return projectedLiabilityUsd[gemId] != 0 && reserveBalanceUsd(gemId) < projectedLiabilityUsd[gemId];
    }

    /// @notice Returns count of tracked reserve asset types for a gem.
    /// @param gemId Gem id to query.
    function reserveAssetCount(uint256 gemId) external view returns (uint256) {
        return _reserveAssets[gemId].length;
    }

    /// @notice Returns a tracked reserve asset address for a gem.
    /// @param gemId Gem id to query.
    /// @param index Asset index.
    function reserveAssetAt(uint256 gemId, uint256 index) external view returns (address) {
        return _reserveAssets[gemId][index];
    }

    /// @dev Sends native ETH or ERC-20 assets to a recipient.
    function _sendAsset(address asset, address recipient, uint256 amount) private {
        if (asset == address(0)) {
            (bool ok,) = payable(recipient).call{value: amount}("");
            if (!ok) revert InvalidAmount();
            return;
        }
        IERC20(asset).safeTransfer(recipient, amount);
    }

    /// @dev Returns a conservative live quote, valuing unavailable or invalid feeds at zero.
    function _safeQuote(address asset, uint256 amount) private view returns (uint256 usdValue) {
        if (amount == 0) return 0;
        try paymentRegistry.quoteTokenToUsd(asset, amount) returns (uint256 quotedUsdValue) {
            usdValue = quotedUsdValue;
        } catch {
            usdValue = 0;
        }
    }

    /// @dev Refreshes underfunded-gem tracking after reserve or liability changes.
    function _refreshUnderfundedGem(uint256 gemId) private {
        bool underfunded = projectedLiabilityUsd[gemId] != 0 && reserveBalanceUsd(gemId) < projectedLiabilityUsd[gemId];
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

    /// @dev Authorizes UUPS upgrades for `UPGRADER_ROLE` holders.
    function _authorizeUpgrade(address) internal override onlyRole(Roles.UPGRADER_ROLE) {}
}
