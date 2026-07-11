// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Roles} from "./libraries/Roles.sol";

contract Treasury is Initializable, AccessControlUpgradeable, UUPSUpgradeable, PausableUpgradeable {
    using SafeERC20 for IERC20;

    uint16 public constant BPS_DENOMINATOR = 10_000;

    struct Splits {
        uint16 sellerBps;
        uint16 platformBps;
        uint16 vaultReserveBps;
        uint16 insuranceReserveBps;
        uint16 treasuryReserveBps;
    }

    Splits public splits;
    address public platformRecipient;
    address public vaultReserveRecipient;
    address public insuranceReserveRecipient;
    address public treasuryReserveRecipient;

    event RecipientsUpdated(address platform, address vaultReserve, address insuranceReserve, address treasuryReserve);
    event SplitsUpdated(Splits splits);
    event SaleSettled(address indexed asset, address indexed seller, uint256 amount);
    event Distribution(address indexed asset, address indexed recipient, uint256 grossAmount, uint256 netReceived);

    error InvalidAddress();
    error InvalidSplits();
    error InsufficientBalance();
    error TransferFailed();

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address admin,
        address platformRecipient_,
        address vaultReserveRecipient_,
        address insuranceReserveRecipient_,
        address treasuryReserveRecipient_
    ) external initializer {
        if (
            admin == address(0) || platformRecipient_ == address(0) || vaultReserveRecipient_ == address(0)
                || insuranceReserveRecipient_ == address(0) || treasuryReserveRecipient_ == address(0)
        ) revert InvalidAddress();

        __AccessControl_init();
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(Roles.UPGRADER_ROLE, admin);
        _grantRole(Roles.SETTLER_ROLE, admin);
        _setRecipients(
            platformRecipient_, vaultReserveRecipient_, insuranceReserveRecipient_, treasuryReserveRecipient_
        );
        _setSplits(
            Splits({
                sellerBps: 8000,
                platformBps: 800,
                vaultReserveBps: 600,
                insuranceReserveBps: 400,
                treasuryReserveBps: 200
            })
        );
    }

    function setRecipients(
        address platformRecipient_,
        address vaultReserveRecipient_,
        address insuranceReserveRecipient_,
        address treasuryReserveRecipient_
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setRecipients(
            platformRecipient_, vaultReserveRecipient_, insuranceReserveRecipient_, treasuryReserveRecipient_
        );
    }

    function setSplits(Splits calldata newSplits) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setSplits(newSplits);
    }

    function settleNative(address seller) external payable whenNotPaused onlyRole(Roles.SETTLER_ROLE) {
        _distributeNative(seller, msg.value);
        emit SaleSettled(address(0), seller, msg.value);
    }

    function settleToken(address token, address seller, uint256 amount)
        external
        whenNotPaused
        onlyRole(Roles.SETTLER_ROLE)
    {
        if (seller == address(0) || token == address(0)) revert InvalidAddress();
        if (amount == 0) revert InsufficientBalance();
        uint256 beforeBalance = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(token).balanceOf(address(this)) - beforeBalance;
        if (received == 0) revert InsufficientBalance();
        _distributeToken(token, seller, received);
        emit SaleSettled(token, seller, received);
    }

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    function _setRecipients(
        address platformRecipient_,
        address vaultReserveRecipient_,
        address insuranceReserveRecipient_,
        address treasuryReserveRecipient_
    ) private {
        if (
            platformRecipient_ == address(0) || vaultReserveRecipient_ == address(0)
                || insuranceReserveRecipient_ == address(0) || treasuryReserveRecipient_ == address(0)
        ) revert InvalidAddress();
        platformRecipient = platformRecipient_;
        vaultReserveRecipient = vaultReserveRecipient_;
        insuranceReserveRecipient = insuranceReserveRecipient_;
        treasuryReserveRecipient = treasuryReserveRecipient_;
        emit RecipientsUpdated(
            platformRecipient_, vaultReserveRecipient_, insuranceReserveRecipient_, treasuryReserveRecipient_
        );
    }

    function _setSplits(Splits memory newSplits) private {
        uint256 total = uint256(newSplits.sellerBps) + newSplits.platformBps + newSplits.vaultReserveBps
            + newSplits.insuranceReserveBps + newSplits.treasuryReserveBps;
        if (total != BPS_DENOMINATOR) revert InvalidSplits();
        splits = newSplits;
        emit SplitsUpdated(newSplits);
    }

    function _amount(uint256 total, uint16 bps) private pure returns (uint256) {
        return (total * bps) / BPS_DENOMINATOR;
    }

    function _distributeNative(address seller, uint256 amount) private {
        if (seller == address(0)) revert InvalidAddress();
        Splits memory s = splits;
        uint256 sellerAmount = _amount(amount, s.sellerBps);
        uint256 platformAmount = _amount(amount, s.platformBps);
        uint256 vaultAmount = _amount(amount, s.vaultReserveBps);
        uint256 insuranceAmount = _amount(amount, s.insuranceReserveBps);
        uint256 treasuryAmount = amount - sellerAmount - platformAmount - vaultAmount - insuranceAmount;

        _sendNative(seller, sellerAmount);
        emit Distribution(address(0), seller, sellerAmount, sellerAmount);
        _sendNative(platformRecipient, platformAmount);
        emit Distribution(address(0), platformRecipient, platformAmount, platformAmount);
        _sendNative(vaultReserveRecipient, vaultAmount);
        emit Distribution(address(0), vaultReserveRecipient, vaultAmount, vaultAmount);
        _sendNative(insuranceReserveRecipient, insuranceAmount);
        emit Distribution(address(0), insuranceReserveRecipient, insuranceAmount, insuranceAmount);
        _sendNative(treasuryReserveRecipient, treasuryAmount);
        emit Distribution(address(0), treasuryReserveRecipient, treasuryAmount, treasuryAmount);
    }

    function _distributeToken(address token, address seller, uint256 amount) private {
        if (seller == address(0) || token == address(0)) revert InvalidAddress();
        Splits memory s = splits;
        uint256 sellerAmount = _amount(amount, s.sellerBps);
        uint256 platformAmount = _amount(amount, s.platformBps);
        uint256 vaultAmount = _amount(amount, s.vaultReserveBps);
        uint256 insuranceAmount = _amount(amount, s.insuranceReserveBps);
        uint256 treasuryAmount = amount - sellerAmount - platformAmount - vaultAmount - insuranceAmount;

        _sendToken(token, seller, sellerAmount);
        _sendToken(token, platformRecipient, platformAmount);
        _sendToken(token, vaultReserveRecipient, vaultAmount);
        _sendToken(token, insuranceReserveRecipient, insuranceAmount);
        _sendToken(token, treasuryReserveRecipient, treasuryAmount);
    }

    function _sendToken(address token, address to, uint256 amount) private {
        if (amount == 0) {
            emit Distribution(token, to, 0, 0);
            return;
        }
        uint256 beforeBalance = IERC20(token).balanceOf(to);
        IERC20(token).safeTransfer(to, amount);
        uint256 netReceived = IERC20(token).balanceOf(to) - beforeBalance;
        emit Distribution(token, to, amount, netReceived);
    }

    function _sendNative(address to, uint256 amount) private {
        if (amount == 0) return;
        (bool ok,) = payable(to).call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    receive() external payable {}

    function _authorizeUpgrade(address) internal override onlyRole(Roles.UPGRADER_ROLE) {}
}
