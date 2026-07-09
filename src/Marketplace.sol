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
import {ReserveManager} from "./ReserveManager.sol";
import {Treasury} from "./Treasury.sol";
import {Roles} from "./libraries/Roles.sol";

contract Marketplace is
    Initializable,
    AccessControlUpgradeable,
    UUPSUpgradeable,
    PausableUpgradeable,
    ReentrancyGuard,
    IERC721Receiver
{
    using SafeERC20 for IERC20;

    struct Listing {
        address seller;
        uint256 priceUsd;
    }

    DGENFT public nft;
    PaymentTokenRegistry public paymentRegistry;
    ReserveManager public reserveManager;
    Treasury public treasury;
    mapping(uint256 tokenId => Listing) public listings;

    event Listed(uint256 indexed tokenId, address indexed seller, uint256 priceUsd);
    event ListingCancelled(uint256 indexed tokenId);
    event Purchased(
        uint256 indexed tokenId, address indexed buyer, address paymentAsset, uint256 amount, uint256 usdValue
    );

    error InvalidAddress();
    error InvalidPrice();
    error NotSeller();
    error NotListed();
    error PriceNotMet();
    error InvalidAmount();

    function initialize(
        address admin,
        DGENFT nft_,
        PaymentTokenRegistry paymentRegistry_,
        ReserveManager reserveManager_,
        Treasury treasury_
    ) external initializer {
        if (
            admin == address(0) || address(nft_) == address(0) || address(paymentRegistry_) == address(0)
                || address(reserveManager_) == address(0) || address(treasury_) == address(0)
        ) {
            revert InvalidAddress();
        }
        __AccessControl_init();
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(Roles.UPGRADER_ROLE, admin);

        nft = nft_;
        paymentRegistry = paymentRegistry_;
        reserveManager = reserveManager_;
        treasury = treasury_;
    }

    function list(uint256 tokenId, uint256 priceUsd) external nonReentrant whenNotPaused {
        if (priceUsd == 0) revert InvalidPrice();
        nft.safeTransferFrom(msg.sender, address(this), tokenId);
        listings[tokenId] = Listing({seller: msg.sender, priceUsd: priceUsd});
        emit Listed(tokenId, msg.sender, priceUsd);
    }

    function cancel(uint256 tokenId) external nonReentrant {
        Listing memory listing = listings[tokenId];
        if (listing.seller == address(0)) revert NotListed();
        if (listing.seller != msg.sender) revert NotSeller();
        delete listings[tokenId];
        nft.safeTransferFrom(address(this), listing.seller, tokenId);
        emit ListingCancelled(tokenId);
    }

    function buy(uint256 tokenId, address paymentAsset, uint256 amount) external payable nonReentrant whenNotPaused {
        Listing memory listing = listings[tokenId];
        if (listing.seller == address(0)) revert NotListed();
        delete listings[tokenId];

        uint256 received = _collectPayment(paymentAsset, amount);
        uint256 usdValue = paymentRegistry.quoteTokenToUsd(paymentAsset, received);
        uint256 gemId = nft.tokenGem(tokenId);
        uint256 reserveUsd = reserveManager.shortfallUsd(gemId, listing.priceUsd);
        if (usdValue < listing.priceUsd + reserveUsd) revert PriceNotMet();
        uint256 saleAmount = _proRataAmount(received, listing.priceUsd, usdValue);
        uint256 reserveAmount = received - saleAmount;
        if (reserveAmount != 0) {
            _fundReserve(gemId, paymentAsset, reserveAmount);
            reserveManager.requireFunded(gemId, listing.priceUsd);
        }

        _settle(paymentAsset, listing.seller, saleAmount);
        nft.safeTransferFrom(address(this), msg.sender, tokenId);
        emit Purchased(tokenId, msg.sender, paymentAsset, received, usdValue);
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

    function _collectPayment(address paymentAsset, uint256 amount) private returns (uint256 received) {
        if (paymentAsset == address(0)) {
            if (amount != msg.value || amount == 0) revert InvalidAmount();
            return msg.value;
        }

        if (msg.value != 0 || amount == 0) revert InvalidAmount();
        uint256 beforeBalance = IERC20(paymentAsset).balanceOf(address(this));
        IERC20(paymentAsset).safeTransferFrom(msg.sender, address(this), amount);
        received = IERC20(paymentAsset).balanceOf(address(this)) - beforeBalance;
        if (received == 0) revert InvalidAmount();
    }

    function _settle(address paymentAsset, address seller, uint256 amount) private {
        if (amount == 0) return;
        if (paymentAsset == address(0)) {
            treasury.settleNative{value: amount}(seller);
            return;
        }

        uint256 beforeBalance = IERC20(paymentAsset).balanceOf(address(treasury));
        IERC20(paymentAsset).safeTransfer(address(treasury), amount);
        uint256 receivedByTreasury = IERC20(paymentAsset).balanceOf(address(treasury)) - beforeBalance;
        treasury.settleToken(paymentAsset, seller, receivedByTreasury);
    }

    function _fundReserve(uint256 gemId, address paymentAsset, uint256 amount) private {
        if (paymentAsset == address(0)) {
            uint256 nativeUsdValue = paymentRegistry.quoteTokenToUsd(paymentAsset, amount);
            reserveManager.recordModuleFunding{value: amount}(gemId, paymentAsset, amount, nativeUsdValue);
            return;
        }

        uint256 beforeBalance = IERC20(paymentAsset).balanceOf(address(reserveManager));
        IERC20(paymentAsset).safeTransfer(address(reserveManager), amount);
        uint256 receivedByReserve = IERC20(paymentAsset).balanceOf(address(reserveManager)) - beforeBalance;
        uint256 tokenUsdValue = paymentRegistry.quoteTokenToUsd(paymentAsset, receivedByReserve);
        reserveManager.recordModuleFunding(gemId, paymentAsset, receivedByReserve, tokenUsdValue);
    }

    function _proRataAmount(uint256 amount, uint256 shareUsd, uint256 totalUsd) private pure returns (uint256) {
        if (shareUsd == 0) return 0;
        return (amount * shareUsd) / totalUsd;
    }

    receive() external payable {}

    function _authorizeUpgrade(address) internal override onlyRole(Roles.UPGRADER_ROLE) {}
}
