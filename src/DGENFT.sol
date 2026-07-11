// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {
    ERC721RoyaltyUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721RoyaltyUpgradeable.sol";
import {
    ERC721URIStorageUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721URIStorageUpgradeable.sol";
import {Roles} from "./libraries/Roles.sol";

contract DGENFT is
    Initializable,
    ERC721URIStorageUpgradeable,
    ERC721RoyaltyUpgradeable,
    AccessControlUpgradeable,
    UUPSUpgradeable
{
    uint256 private _nextTokenId;

    mapping(uint256 tokenId => uint256 gemId) public tokenGem;
    mapping(uint256 gemId => uint256 tokenId) public tokenForGem;
    mapping(uint256 tokenId => bool locked) public transferLocked;

    event DgeMinted(uint256 indexed tokenId, uint256 indexed gemId, address indexed to, string uri);
    event TransferLockUpdated(uint256 indexed tokenId, bool locked);

    error InvalidAddress();
    error GemAlreadyMinted();
    error TokenLocked();

    constructor() {
        _disableInitializers();
    }

    function initialize(address admin, string calldata name_, string calldata symbol_) external initializer {
        if (admin == address(0)) revert InvalidAddress();
        __ERC721_init(name_, symbol_);
        __ERC721URIStorage_init();
        __ERC721Royalty_init();
        __AccessControl_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(Roles.UPGRADER_ROLE, admin);
        _grantRole(Roles.MINTER_ROLE, admin);
        _grantRole(Roles.BURNER_ROLE, admin);
        _grantRole(Roles.LOCKER_ROLE, admin);
        _nextTokenId = 1;
    }

    function mintTo(address to, uint256 gemId, string calldata uri)
        external
        onlyRole(Roles.MINTER_ROLE)
        returns (uint256 tokenId)
    {
        if (to == address(0)) revert InvalidAddress();
        if (tokenForGem[gemId] != 0) revert GemAlreadyMinted();

        tokenId = _nextTokenId++;
        tokenGem[tokenId] = gemId;
        tokenForGem[gemId] = tokenId;
        _safeMint(to, tokenId);
        _setTokenURI(tokenId, uri);
        emit DgeMinted(tokenId, gemId, to, uri);
    }

    function setTransferLocked(uint256 tokenId, bool locked) external onlyRole(Roles.LOCKER_ROLE) {
        _requireOwned(tokenId);
        transferLocked[tokenId] = locked;
        emit TransferLockUpdated(tokenId, locked);
    }

    function burnFromProtocol(uint256 tokenId) external onlyRole(Roles.BURNER_ROLE) {
        _requireOwned(tokenId);
        uint256 gemId = tokenGem[tokenId];
        delete transferLocked[tokenId];
        delete tokenGem[tokenId];
        delete tokenForGem[gemId];
        _burn(tokenId);
    }

    function setDefaultRoyalty(address receiver, uint96 feeNumerator) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setDefaultRoyalty(receiver, feeNumerator);
    }

    function deleteDefaultRoyalty() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _deleteDefaultRoyalty();
    }

    function _update(address to, uint256 tokenId, address auth)
        internal
        override(ERC721Upgradeable)
        returns (address previousOwner)
    {
        previousOwner = _ownerOf(tokenId);
        if (previousOwner != address(0) && to != address(0) && transferLocked[tokenId]) revert TokenLocked();
        return super._update(to, tokenId, auth);
    }

    function tokenURI(uint256 tokenId)
        public
        view
        override(ERC721Upgradeable, ERC721URIStorageUpgradeable)
        returns (string memory)
    {
        return super.tokenURI(tokenId);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721URIStorageUpgradeable, ERC721RoyaltyUpgradeable, AccessControlUpgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    function _authorizeUpgrade(address) internal override onlyRole(Roles.UPGRADER_ROLE) {}
}
