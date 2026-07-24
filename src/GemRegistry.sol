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

    enum PrimarySaleMode {
        None,
        BuyNow,
        Auction
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
    mapping(uint256 gemId => bytes32 hash) public valuationHash;
    mapping(uint256 gemId => bytes32 hash) public valuationMatrixHash;
    mapping(uint256 gemId => uint256 priceUsd) public approvedValuationUsd;
    mapping(uint256 gemId => PrimarySaleMode mode) public primarySaleMode;
    mapping(uint256 gemId => bool active) public primaryAuctionActive;

    event SellerApprovalUpdated(address indexed seller, bool approved);
    event GemRegistered(uint256 indexed gemId, address indexed seller, address indexed custodian);
    event CustodyConfirmed(uint256 indexed gemId);
    event GemVerified(
        uint256 indexed gemId,
        address indexed verifier,
        bytes32 indexed valuationHash,
        bytes32 valuationMatrixHash,
        uint256 approvedValuationUsd
    );
    event GemListed(uint256 indexed gemId, uint256 priceUsd, PrimarySaleMode saleMode);
    event PrimaryAuctionStatusUpdated(uint256 indexed gemId, bool active);
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
    error InvalidValuationCommitment();
    error ValuationPriceMismatch(uint256 approvedPriceUsd, uint256 requestedPriceUsd);
    error InvalidPrimarySaleMode();
    error ActivePrimaryAuction();

    /// @custom:oz-upgrades-unsafe-allow constructor
    /// @dev Locks the implementation contract so only proxy instances can be initialized.
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes registry roles and starts gem ids at 1.
    /// @param admin Account receiving all registry administration roles.
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

    /// @notice Updates whether a seller is approved to list gems.
    /// @dev Callable only by `COMPLIANCE_ROLE`.
    /// @param seller Seller address to update.
    /// @param approved Whether the seller can list verified gems.
    function setSellerApproval(address seller, bool approved) external onlyRole(Roles.COMPLIANCE_ROLE) {
        if (seller == address(0)) revert InvalidAddress();
        sellerApproved[seller] = approved;
        emit SellerApprovalUpdated(seller, approved);
    }

    /// @notice Registers a new gemstone before custody verification.
    /// @dev Callable only by `LISTER_ROLE`.
    /// @param seller Seller that will receive sale proceeds.
    /// @param custodian Recorded custodian responsible for custody and redemption confirmation.
    /// @param metadataURI Off-chain gem metadata URI.
    /// @param certificateHash Hash of the gem certificate or custody record.
    /// @return gemId Newly assigned gem id.
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

    /// @notice Confirms that the recorded custodian has custody of a registered gem.
    /// @dev Caller must have `CUSTODIAN_ROLE` and be the gem's recorded custodian.
    /// @param gemId Gem id to confirm.
    function confirmCustody(uint256 gemId) external whenNotPaused onlyRole(Roles.CUSTODIAN_ROLE) {
        Gem storage gem = _existingGem(gemId);
        if (gem.status != GemStatus.Registered) revert InvalidStatus(gem.status);
        if (msg.sender != gem.custodian) revert NotGemCustodian();
        gem.status = GemStatus.CustodyConfirmed;
        emit CustodyConfirmed(gemId);
    }

    /// @notice Records a versioned valuation commitment and marks a custody-confirmed gem as verified.
    /// @dev Callable only by `VERIFIER_ROLE`; the approved valuation becomes the only valid primary listing price.
    /// @param gemId Gem id to verify.
    /// @param valuationHash_ Commitment to the complete approved valuation decision.
    /// @param valuationMatrixHash_ Commitment to the exact pricing matrix/version used.
    /// @param approvedValuationUsd_ Expert-approved valuation in 18-decimal USD.
    function verifyGem(
        uint256 gemId,
        bytes32 valuationHash_,
        bytes32 valuationMatrixHash_,
        uint256 approvedValuationUsd_
    ) external whenNotPaused onlyRole(Roles.VERIFIER_ROLE) {
        if (valuationHash_ == bytes32(0) || valuationMatrixHash_ == bytes32(0) || approvedValuationUsd_ == 0) {
            revert InvalidValuationCommitment();
        }
        Gem storage gem = _existingGem(gemId);
        if (gem.status != GemStatus.CustodyConfirmed) revert InvalidStatus(gem.status);
        valuationHash[gemId] = valuationHash_;
        valuationMatrixHash[gemId] = valuationMatrixHash_;
        approvedValuationUsd[gemId] = approvedValuationUsd_;
        gem.status = GemStatus.Verified;
        emit GemVerified(gemId, msg.sender, valuationHash_, valuationMatrixHash_, approvedValuationUsd_);
    }

    /// @notice Lists a verified gem for primary sale.
    /// @dev Seller must be approved and `priceUsd` must equal the verifier-approved valuation.
    /// @param gemId Gem id to list.
    /// @param priceUsd Primary sale price in 18-decimal USD.
    /// @param saleMode Exclusive primary sale mode selected during seller intake.
    function listGem(uint256 gemId, uint256 priceUsd, PrimarySaleMode saleMode)
        external
        whenNotPaused
        onlyRole(Roles.LISTER_ROLE)
    {
        if (priceUsd == 0) revert InvalidPrice();
        if (saleMode == PrimarySaleMode.None) revert InvalidPrimarySaleMode();
        Gem storage gem = _existingGem(gemId);
        if (gem.status != GemStatus.Verified) revert InvalidStatus(gem.status);
        if (!sellerApproved[gem.seller]) revert SellerNotApproved();
        uint256 approvedPriceUsd = approvedValuationUsd[gemId];
        if (priceUsd != approvedPriceUsd) revert ValuationPriceMismatch(approvedPriceUsd, priceUsd);
        gem.priceUsd = priceUsd;
        primarySaleMode[gemId] = saleMode;
        gem.status = GemStatus.Listed;
        emit GemListed(gemId, priceUsd, saleMode);
    }

    /// @notice Records that a listed gem has been minted into an NFT.
    /// @dev Callable only by `MINTER_ROLE`, normally PrimarySaleAuction.
    /// @param gemId Gem id that was minted.
    /// @param tokenId NFT id linked to the gem.
    function markMinted(uint256 gemId, uint256 tokenId) external whenNotPaused onlyRole(Roles.MINTER_ROLE) {
        Gem storage gem = _existingGem(gemId);
        if (gem.status != GemStatus.Listed) revert InvalidStatus(gem.status);
        primaryAuctionActive[gemId] = false;
        gem.tokenId = tokenId;
        gem.status = GemStatus.Minted;
        emit GemMinted(gemId, tokenId);
    }

    /// @notice Updates the active primary-auction lock for a listed gem.
    /// @dev Callable by the primary-sale module through `MINTER_ROLE`.
    function setPrimaryAuctionActive(uint256 gemId, bool active) external whenNotPaused onlyRole(Roles.MINTER_ROLE) {
        Gem storage gem = _existingGem(gemId);
        if (gem.status != GemStatus.Listed) revert InvalidStatus(gem.status);
        primaryAuctionActive[gemId] = active;
        emit PrimaryAuctionStatusUpdated(gemId, active);
    }

    /// @notice Withdraws an unsold listed gem from sale.
    /// @dev Callable only by `LISTER_ROLE`; minted gems cannot be withdrawn here.
    /// @param gemId Listed gem id to withdraw.
    /// @param reasonHash Off-chain reason hash for auditability.
    function withdrawListedGem(uint256 gemId, bytes32 reasonHash) external whenNotPaused onlyRole(Roles.LISTER_ROLE) {
        Gem storage gem = _existingGem(gemId);
        if (gem.status != GemStatus.Listed) revert InvalidStatus(gem.status);
        if (primaryAuctionActive[gemId]) revert ActivePrimaryAuction();
        gem.status = GemStatus.Withdrawn;
        emit GemWithdrawn(gemId, reasonHash);
    }

    /// @notice Moves a minted gem into redemption-requested status.
    /// @dev Callable only by `REDEEMER_ROLE`, normally RedemptionManager.
    /// @param gemId Gem id being redeemed.
    /// @param requestHash Off-chain redemption request hash.
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

    /// @notice Cancels an open redemption and restores minted status.
    /// @dev Callable only by `REDEEMER_ROLE`.
    /// @param gemId Gem id whose redemption is cancelled.
    function cancelRedemption(uint256 gemId) external whenNotPaused onlyRole(Roles.REDEEMER_ROLE) {
        Gem storage gem = _existingGem(gemId);
        if (gem.status != GemStatus.RedemptionRequested) revert InvalidStatus(gem.status);
        gem.redemptionRequestHash = bytes32(0);
        gem.status = GemStatus.Minted;
        emit RedemptionCancelled(gemId);
    }

    /// @notice Marks a redemption-requested gem as redeemed.
    /// @dev Callable only by `REDEEMER_ROLE`; clears the stored token id.
    /// @param gemId Gem id to mark redeemed.
    function markRedeemed(uint256 gemId) external whenNotPaused onlyRole(Roles.REDEEMER_ROLE) {
        Gem storage gem = _existingGem(gemId);
        if (gem.status != GemStatus.RedemptionRequested) revert InvalidStatus(gem.status);
        gem.tokenId = 0;
        gem.status = GemStatus.Redeemed;
        emit GemRedeemed(gemId);
    }

    /// @notice Pauses registry state-changing lifecycle operations.
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /// @notice Unpauses registry lifecycle operations.
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /// @notice Returns a registered gem.
    /// @param gemId Gem id to query.
    /// @return Gem record.
    function getGem(uint256 gemId) external view returns (Gem memory) {
        return _existingGemView(gemId);
    }

    /// @notice Returns whether a gem can currently be minted in primary sale.
    /// @param gemId Gem id to check.
    /// @return True when listed, seller-approved, and priced.
    function canMint(uint256 gemId) external view returns (bool) {
        Gem storage gem = _existingGemView(gemId);
        return gem.status == GemStatus.Listed && sellerApproved[gem.seller] && gem.priceUsd != 0;
    }

    /// @dev Returns an existing gem storage pointer or reverts.
    function _existingGem(uint256 gemId) private view returns (Gem storage gem) {
        gem = _gems[gemId];
        if (gem.status == GemStatus.None) revert InvalidGem();
    }

    /// @dev View helper returning an existing gem storage pointer or reverting.
    function _existingGemView(uint256 gemId) private view returns (Gem storage gem) {
        gem = _gems[gemId];
        if (gem.status == GemStatus.None) revert InvalidGem();
    }

    /// @dev Authorizes UUPS upgrades for `UPGRADER_ROLE` holders.
    function _authorizeUpgrade(address) internal override onlyRole(Roles.UPGRADER_ROLE) {}
}
