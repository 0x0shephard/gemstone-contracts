// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {Roles} from "./libraries/Roles.sol";

contract GemRegistry is Initializable, AccessControlUpgradeable, UUPSUpgradeable, PausableUpgradeable {
    enum GemStatus {
        None,
        Registered,
        CustodyConfirmed,
        Verified,
        Listed,
        Minted,
        RedemptionRequested,
        Redeemed,
        Withdrawn
    }

    struct Gem {
        address seller;
        address custodian;
        string metadataURI;
        bytes32 certificateHash;
        uint256 priceUsd;
        uint256 tokenId;
        bytes32 redemptionRequestHash;
        GemStatus status;
    }

    uint256 private _nextGemId;
    mapping(uint256 gemId => Gem) private _gems;
    mapping(address seller => bool) public sellerApproved;

    event SellerApprovalUpdated(address indexed seller, bool approved);
    event GemRegistered(uint256 indexed gemId, address indexed seller, address indexed custodian);
    event CustodyConfirmed(uint256 indexed gemId);
    event GemVerified(uint256 indexed gemId);
    event GemListed(uint256 indexed gemId, uint256 priceUsd);
    event GemMinted(uint256 indexed gemId, uint256 indexed tokenId);
    event RedemptionRequested(uint256 indexed gemId, bytes32 requestHash);
    event RedemptionCancelled(uint256 indexed gemId);
    event GemRedeemed(uint256 indexed gemId);
    event GemWithdrawn(uint256 indexed gemId, bytes32 reasonHash);

    error InvalidAddress();
    error InvalidGem();
    error InvalidStatus(GemStatus current);
    error SellerNotApproved();
    error InvalidPrice();
    error NotGemCustodian();

    function initialize(address admin) external initializer {
        if (admin == address(0)) revert InvalidAddress();
        __AccessControl_init();
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(Roles.UPGRADER_ROLE, admin);
        _grantRole(Roles.LISTER_ROLE, admin);
        _grantRole(Roles.CUSTODIAN_ROLE, admin);
        _grantRole(Roles.VERIFIER_ROLE, admin);
        _grantRole(Roles.COMPLIANCE_ROLE, admin);
        _grantRole(Roles.REDEEMER_ROLE, admin);
        _nextGemId = 1;
    }

    function setSellerApproval(address seller, bool approved) external onlyRole(Roles.COMPLIANCE_ROLE) {
        if (seller == address(0)) revert InvalidAddress();
        sellerApproved[seller] = approved;
        emit SellerApprovalUpdated(seller, approved);
    }

    function registerGem(address seller, address custodian, string calldata metadataURI, bytes32 certificateHash)
        external
        whenNotPaused
        onlyRole(Roles.LISTER_ROLE)
        returns (uint256 gemId)
    {
        if (seller == address(0) || custodian == address(0)) revert InvalidAddress();

        gemId = _nextGemId++;
        _gems[gemId] = Gem({
            seller: seller,
            custodian: custodian,
            metadataURI: metadataURI,
            certificateHash: certificateHash,
            priceUsd: 0,
            tokenId: 0,
            redemptionRequestHash: bytes32(0),
            status: GemStatus.Registered
        });

        emit GemRegistered(gemId, seller, custodian);
    }

    function confirmCustody(uint256 gemId) external whenNotPaused onlyRole(Roles.CUSTODIAN_ROLE) {
        Gem storage gem = _existingGem(gemId);
        if (gem.status != GemStatus.Registered) revert InvalidStatus(gem.status);
        if (msg.sender != gem.custodian) revert NotGemCustodian();
        gem.status = GemStatus.CustodyConfirmed;
        emit CustodyConfirmed(gemId);
    }

    function verifyGem(uint256 gemId) external whenNotPaused onlyRole(Roles.VERIFIER_ROLE) {
        Gem storage gem = _existingGem(gemId);
        if (gem.status != GemStatus.CustodyConfirmed) revert InvalidStatus(gem.status);
        gem.status = GemStatus.Verified;
        emit GemVerified(gemId);
    }

    function listGem(uint256 gemId, uint256 priceUsd) external whenNotPaused onlyRole(Roles.LISTER_ROLE) {
        if (priceUsd == 0) revert InvalidPrice();
        Gem storage gem = _existingGem(gemId);
        if (gem.status != GemStatus.Verified) revert InvalidStatus(gem.status);
        if (!sellerApproved[gem.seller]) revert SellerNotApproved();
        gem.priceUsd = priceUsd;
        gem.status = GemStatus.Listed;
        emit GemListed(gemId, priceUsd);
    }

    function markMinted(uint256 gemId, uint256 tokenId) external whenNotPaused onlyRole(Roles.MINTER_ROLE) {
        Gem storage gem = _existingGem(gemId);
        if (gem.status != GemStatus.Listed) revert InvalidStatus(gem.status);
        gem.tokenId = tokenId;
        gem.status = GemStatus.Minted;
        emit GemMinted(gemId, tokenId);
    }

    function withdrawListedGem(uint256 gemId, bytes32 reasonHash) external whenNotPaused onlyRole(Roles.LISTER_ROLE) {
        Gem storage gem = _existingGem(gemId);
        if (gem.status != GemStatus.Listed) revert InvalidStatus(gem.status);
        gem.status = GemStatus.Withdrawn;
        emit GemWithdrawn(gemId, reasonHash);
    }

    function requestRedemption(uint256 gemId, bytes32 requestHash)
        external
        whenNotPaused
        onlyRole(Roles.REDEEMER_ROLE)
    {
        Gem storage gem = _existingGem(gemId);
        if (gem.status != GemStatus.Minted) revert InvalidStatus(gem.status);
        gem.redemptionRequestHash = requestHash;
        gem.status = GemStatus.RedemptionRequested;
        emit RedemptionRequested(gemId, requestHash);
    }

    function cancelRedemption(uint256 gemId) external whenNotPaused onlyRole(Roles.REDEEMER_ROLE) {
        Gem storage gem = _existingGem(gemId);
        if (gem.status != GemStatus.RedemptionRequested) revert InvalidStatus(gem.status);
        gem.redemptionRequestHash = bytes32(0);
        gem.status = GemStatus.Minted;
        emit RedemptionCancelled(gemId);
    }

    function markRedeemed(uint256 gemId) external whenNotPaused onlyRole(Roles.REDEEMER_ROLE) {
        Gem storage gem = _existingGem(gemId);
        if (gem.status != GemStatus.RedemptionRequested) revert InvalidStatus(gem.status);
        gem.status = GemStatus.Redeemed;
        emit GemRedeemed(gemId);
    }

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    function getGem(uint256 gemId) external view returns (Gem memory) {
        return _existingGemView(gemId);
    }

    function canMint(uint256 gemId) external view returns (bool) {
        Gem storage gem = _existingGemView(gemId);
        return gem.status == GemStatus.Listed && sellerApproved[gem.seller] && gem.priceUsd != 0;
    }

    function _existingGem(uint256 gemId) private view returns (Gem storage gem) {
        gem = _gems[gemId];
        if (gem.status == GemStatus.None) revert InvalidGem();
    }

    function _existingGemView(uint256 gemId) private view returns (Gem storage gem) {
        gem = _gems[gemId];
        if (gem.status == GemStatus.None) revert InvalidGem();
    }

    function _authorizeUpgrade(address) internal override onlyRole(Roles.UPGRADER_ROLE) {}
}
