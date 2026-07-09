// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {DGENFT} from "./DGENFT.sol";
import {PaymentTokenRegistry} from "./PaymentTokenRegistry.sol";
import {Roles} from "./libraries/Roles.sol";

contract SwapEscrow is
    Initializable,
    AccessControlUpgradeable,
    UUPSUpgradeable,
    PausableUpgradeable,
    ReentrancyGuard,
    IERC721Receiver
{
    using SafeERC20 for IERC20;

    struct SwapOffer {
        address proposer;
        uint256 offeredTokenId;
        uint256 requestedTokenId;
        address cashAsset;
        uint256 cashAmount;
        bool proposerPaysCash;
        uint64 expiry;
        bool active;
    }

    DGENFT public nft;
    PaymentTokenRegistry public paymentRegistry;
    uint256 private _nextOfferId;
    mapping(uint256 offerId => SwapOffer) public offers;

    event OfferCreated(
        uint256 indexed offerId,
        address indexed proposer,
        uint256 indexed offeredTokenId,
        uint256 requestedTokenId,
        address cashAsset,
        uint256 cashAmount,
        bool proposerPaysCash,
        uint64 expiry
    );
    event OfferCancelled(uint256 indexed offerId);
    event OfferAccepted(uint256 indexed offerId, address indexed accepter);

    error InvalidAddress();
    error InvalidOffer();
    error NotProposer();
    error Expired();
    error InvalidAmount();
    error TransferFailed();

    function initialize(address admin, DGENFT nft_, PaymentTokenRegistry paymentRegistry_) external initializer {
        if (admin == address(0) || address(nft_) == address(0) || address(paymentRegistry_) == address(0)) {
            revert InvalidAddress();
        }
        __AccessControl_init();
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(Roles.UPGRADER_ROLE, admin);

        nft = nft_;
        paymentRegistry = paymentRegistry_;
        _nextOfferId = 1;
    }

    function createOffer(
        uint256 offeredTokenId,
        uint256 requestedTokenId,
        address cashAsset,
        uint256 cashAmount,
        bool proposerPaysCash,
        uint64 expiry
    ) external payable nonReentrant whenNotPaused returns (uint256 offerId) {
        if (expiry <= block.timestamp || offeredTokenId == requestedTokenId) revert InvalidOffer();
        if (cashAmount != 0) {
            paymentRegistry.quoteTokenToUsd(cashAsset, cashAmount);
        }

        offerId = _nextOfferId++;
        nft.safeTransferFrom(msg.sender, address(this), offeredTokenId);

        if (proposerPaysCash && cashAmount != 0) {
            _collectCash(msg.sender, cashAsset, cashAmount);
        } else if (msg.value != 0) {
            revert InvalidAmount();
        }

        offers[offerId] = SwapOffer({
            proposer: msg.sender,
            offeredTokenId: offeredTokenId,
            requestedTokenId: requestedTokenId,
            cashAsset: cashAsset,
            cashAmount: cashAmount,
            proposerPaysCash: proposerPaysCash,
            expiry: expiry,
            active: true
        });

        emit OfferCreated(
            offerId, msg.sender, offeredTokenId, requestedTokenId, cashAsset, cashAmount, proposerPaysCash, expiry
        );
    }

    function cancelOffer(uint256 offerId) external nonReentrant {
        SwapOffer memory offer = offers[offerId];
        if (!offer.active) revert InvalidOffer();
        if (offer.proposer != msg.sender) revert NotProposer();
        delete offers[offerId];

        nft.safeTransferFrom(address(this), offer.proposer, offer.offeredTokenId);
        if (offer.proposerPaysCash && offer.cashAmount != 0) {
            _sendCash(offer.proposer, offer.cashAsset, offer.cashAmount);
        }
        emit OfferCancelled(offerId);
    }

    function acceptOffer(uint256 offerId) external payable nonReentrant whenNotPaused {
        SwapOffer memory offer = offers[offerId];
        if (!offer.active) revert InvalidOffer();
        if (block.timestamp > offer.expiry) revert Expired();
        delete offers[offerId];

        nft.safeTransferFrom(msg.sender, offer.proposer, offer.requestedTokenId);
        nft.safeTransferFrom(address(this), msg.sender, offer.offeredTokenId);

        if (offer.cashAmount != 0) {
            if (offer.proposerPaysCash) {
                _sendCash(msg.sender, offer.cashAsset, offer.cashAmount);
            } else {
                _collectCash(msg.sender, offer.cashAsset, offer.cashAmount);
                _sendCash(offer.proposer, offer.cashAsset, offer.cashAmount);
            }
        } else if (msg.value != 0) {
            revert InvalidAmount();
        }

        emit OfferAccepted(offerId, msg.sender);
    }

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        if (msg.sender != address(nft)) revert InvalidAddress();
        return IERC721Receiver.onERC721Received.selector;
    }

    function _collectCash(address from, address asset, uint256 amount) private {
        if (asset == address(0)) {
            if (msg.value != amount) revert InvalidAmount();
            return;
        }
        if (msg.value != 0) revert InvalidAmount();
        IERC20(asset).safeTransferFrom(from, address(this), amount);
    }

    function _sendCash(address to, address asset, uint256 amount) private {
        if (asset == address(0)) {
            (bool ok,) = payable(to).call{value: amount}("");
            if (!ok) revert TransferFailed();
            return;
        }
        IERC20(asset).safeTransfer(to, amount);
    }

    receive() external payable {}

    function _authorizeUpgrade(address) internal override onlyRole(Roles.UPGRADER_ROLE) {}
}
