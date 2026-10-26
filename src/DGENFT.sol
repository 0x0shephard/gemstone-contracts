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
import {ReserveManager} from "./ReserveManager.sol";
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
    // Appended for UUPS storage compatibility. Do not reorder these fields.
    ReserveManager public reserveManager;
    mapping(address escrow => bool trusted) public trustedEscrow;
    mapping(uint256 tokenId => address depositor) public escrowDepositor;
    // Appended for outside marketplaces (OpenSea and others). Do not reorder these fields.
    address private _collectionOwner;
    string private _contractURI;

    uint256 public constant MAX_LEGACY_ESCROW_MIGRATIONS = 100;

    event DgeMinted(uint256 indexed tokenId, uint256 indexed gemId, address indexed to, string uri);
    event TransferLockUpdated(uint256 indexed tokenId, bool locked);
    event ReserveGuardInitialized(address indexed reserveManager);
    event TrustedEscrowAdded(address indexed escrow);
    event EscrowDepositRecorded(uint256 indexed tokenId, address indexed escrow, address indexed depositor);
    event EscrowDepositCleared(uint256 indexed tokenId, address indexed escrow, address indexed recipient);
    event LegacyEscrowDepositBootstrapped(uint256 indexed tokenId, address indexed escrow, address indexed depositor);
    /// @dev Same signature as OpenZeppelin `Ownable`, which marketplaces index to find the collection owner.
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    /// @dev ERC-7572: tells marketplaces to re-read `contractURI`.
    event ContractURIUpdated();

    error InvalidAddress();
    error GemAlreadyMinted();
    error TokenLocked();
    error ReserveGuardNotConfigured();
    error ZeroReserveTransfer();
    error InvalidEscrowConfiguration();
    error LegacyMigrationLimitExceeded();
    error IncompleteLegacyEscrowMigration(address escrow, uint256 currentBalance, uint256 migratedBalance);

    /// @custom:oz-upgrades-unsafe-allow constructor
    /// @dev Locks the implementation contract so only proxy instances can be initialized.
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the DGE NFT collection and grants protocol roles to `admin`.
    /// @param admin Account that receives admin, upgrader, minter, burner, and locker roles.
    /// @param name_ ERC-721 collection name.
    /// @param symbol_ ERC-721 collection symbol.
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

    /// @notice Activates the reserve transfer guard and atomically registers protocol escrows.
    /// @dev Existing escrow balances must be exhaustively bootstrapped in the same call. This
    ///      prevents an upgrade from silently stranding zero-reserve tokens already in custody.
    /// @param reserveManager_ Reserve manager used for the live per-gem balance check.
    /// @param escrows Marketplace, swap escrow, gift custody operator, and any other audited escrows.
    /// @param legacyTokenIds Tokens already owned by one of `escrows` at upgrade time.
    /// @param legacyDepositors Audited original depositors corresponding to `legacyTokenIds`.
    function initializeReserveGuard(
        ReserveManager reserveManager_,
        address[] calldata escrows,
        uint256[] calldata legacyTokenIds,
        address[] calldata legacyDepositors
    ) external reinitializer(2) onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(reserveManager_) == address(0) || escrows.length == 0) {
            revert InvalidEscrowConfiguration();
        }
        if (legacyTokenIds.length != legacyDepositors.length) revert InvalidEscrowConfiguration();
        if (legacyTokenIds.length > MAX_LEGACY_ESCROW_MIGRATIONS) revert LegacyMigrationLimitExceeded();

        reserveManager = reserveManager_;
        for (uint256 i = 0; i < escrows.length; i++) {
            _addTrustedEscrow(escrows[i]);
        }

        for (uint256 i = 0; i < legacyTokenIds.length; i++) {
            uint256 tokenId = legacyTokenIds[i];
            address escrow = ownerOf(tokenId);
            address depositor = legacyDepositors[i];
            if (!trustedEscrow[escrow] || depositor == address(0) || depositor == escrow) {
                revert InvalidEscrowConfiguration();
            }
            if (escrowDepositor[tokenId] != address(0)) revert InvalidEscrowConfiguration();
            escrowDepositor[tokenId] = depositor;
            emit LegacyEscrowDepositBootstrapped(tokenId, escrow, depositor);
        }

        // Each trusted address must have every currently held DGE token represented above.
        // The bounded nested scan is upgrade-only and capped by MAX_LEGACY_ESCROW_MIGRATIONS.
        for (uint256 i = 0; i < escrows.length; i++) {
            uint256 migratedBalance;
            for (uint256 j = 0; j < legacyTokenIds.length; j++) {
                if (ownerOf(legacyTokenIds[j]) == escrows[i]) migratedBalance++;
            }
            uint256 currentBalance = balanceOf(escrows[i]);
            if (currentBalance != migratedBalance) {
                revert IncompleteLegacyEscrowMigration(escrows[i], currentBalance, migratedBalance);
            }
        }

        emit ReserveGuardInitialized(address(reserveManager_));
    }

    /// @notice Appends an empty escrow address after the reserve guard is active.
    /// @dev An address that already owns DGE tokens must be included in the audited initialization
    ///      migration instead; adding it here would leave its existing tokens without depositors.
    function addTrustedEscrow(address escrow) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(reserveManager) == address(0)) revert ReserveGuardNotConfigured();
        if (escrow == address(0) || balanceOf(escrow) != 0) revert InvalidEscrowConfiguration();
        _addTrustedEscrow(escrow);
    }

    /// @notice Mints a DGE NFT for a listed gemstone.
    /// @dev Callable only by accounts with `MINTER_ROLE`; each gem can be minted once.
    /// @param to Recipient of the NFT.
    /// @param gemId Gemstone identifier linked to the token.
    /// @param uri Token metadata URI.
    /// @return tokenId Newly minted NFT id.
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

    /// @notice Locks or unlocks token transfers.
    /// @dev Callable only by `LOCKER_ROLE`; used during redemption.
    /// @param tokenId Token whose transfer lock is updated.
    /// @param locked True to block transfers, false to allow them.
    function setTransferLocked(uint256 tokenId, bool locked) external onlyRole(Roles.LOCKER_ROLE) {
        _requireOwned(tokenId);
        transferLocked[tokenId] = locked;
        emit TransferLockUpdated(tokenId, locked);
    }

    /// @notice Burns a protocol-owned redemption token and clears gem-token mappings.
    /// @dev Callable only by `BURNER_ROLE`; intended for RedemptionManager.
    /// @param tokenId Token to burn.
    function burnFromProtocol(uint256 tokenId) external onlyRole(Roles.BURNER_ROLE) {
        _requireOwned(tokenId);
        uint256 gemId = tokenGem[tokenId];
        delete transferLocked[tokenId];
        delete escrowDepositor[tokenId];
        delete tokenGem[tokenId];
        delete tokenForGem[gemId];
        _burn(tokenId);
    }

    /// @notice Sets the collection-wide ERC-2981 royalty.
    /// @param receiver Royalty receiver.
    /// @param feeNumerator Royalty fee numerator using OpenZeppelin's royalty denominator.
    function setDefaultRoyalty(address receiver, uint96 feeNumerator) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setDefaultRoyalty(receiver, feeNumerator);
    }

    /// @notice Deletes the collection-wide ERC-2981 royalty configuration.
    function deleteDefaultRoyalty() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _deleteDefaultRoyalty();
    }

    /// @dev Enforces redemption locks and the central zero-reserve rule for every transfer path.
    ///      Mint and burn remain exempt. The rule applies only to a token that owes reserve under
    ///      the current policy and holds no reserve asset at all (checked without oracles, so a
    ///      price outage cannot freeze a funded token). Such a token may enter a trusted escrow only when
    ///      the escrow itself pulls it in, and may leave one only back to the recorded depositor
    ///      unless a sale path funds the reserve first.
    function _update(address to, uint256 tokenId, address auth)
        internal
        override(ERC721Upgradeable)
        returns (address previousOwner)
    {
        previousOwner = _ownerOf(tokenId);
        if (previousOwner != address(0) && to != address(0)) {
            if (transferLocked[tokenId]) revert TokenLocked();
            if (address(reserveManager) == address(0)) revert ReserveGuardNotConfigured();

            uint256 gemId = tokenGem[tokenId];
            if (!reserveManager.hasReserveAssets(gemId) && _owesReserve(gemId)) {
                bool escrowReturn = trustedEscrow[previousOwner] && auth == previousOwner
                    && escrowDepositor[tokenId] == to && to != previousOwner;
                // Marketplace listing pulls the token in, and its buy, offer and auction paths fund
                // the shortfall before releasing it. A push (owner sends to an escrow) stays blocked.
                bool escrowPull = trustedEscrow[to] && auth == to && !trustedEscrow[previousOwner];
                if (!escrowReturn && !escrowPull) revert ZeroReserveTransfer();
            }

            if (to != previousOwner) {
                if (trustedEscrow[to] && !trustedEscrow[previousOwner]) {
                    escrowDepositor[tokenId] = previousOwner;
                    emit EscrowDepositRecorded(tokenId, to, previousOwner);
                } else if (trustedEscrow[previousOwner] && !trustedEscrow[to]) {
                    delete escrowDepositor[tokenId];
                    emit EscrowDepositCleared(tokenId, previousOwner, to);
                }
            }
        }
        return super._update(to, tokenId, auth);
    }

    /// @dev True when the reserve policy charges this gem anything: a rate at its registry price,
    ///      or a per-gem minimum. At a 0% rate with no minimum nothing is owed, so the token moves
    ///      freely. The rate is checked rather than the computed amount, so a gem with no registry
    ///      price (never listed) still counts as owing while a rate is in force.
    function _owesReserve(uint256 gemId) private view returns (bool) {
        if (reserveManager.minimumReserveUsd(gemId) != 0) return true;
        uint256 priceUsd = reserveManager.registry().getGem(gemId).priceUsd;
        return reserveManager.reserveBpsFor(priceUsd) != 0;
    }

    /// @notice The collection owner marketplaces show and let edit the collection page (OpenSea
    ///         reads `owner()`). Display only: it grants no permission in this contract, where
    ///         every power stays with AccessControl roles.
    function owner() external view returns (address) {
        return _collectionOwner;
    }

    /// @notice Sets the marketplace-facing collection owner. Use a Safe: marketplaces let this
    ///         account edit the collection page and, off-chain, its payout settings.
    /// @param newOwner New collection owner, or address(0) to leave the collection unclaimed.
    function setCollectionOwner(address newOwner) external onlyRole(DEFAULT_ADMIN_ROLE) {
        emit OwnershipTransferred(_collectionOwner, newOwner);
        _collectionOwner = newOwner;
    }

    /// @notice ERC-7572 collection metadata URI (name, description, image, external link).
    function contractURI() external view returns (string memory) {
        return _contractURI;
    }

    /// @notice Sets the ERC-7572 collection metadata URI.
    /// @param uri JSON metadata URI, or empty to clear it.
    function setContractURI(string calldata uri) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _contractURI = uri;
        emit ContractURIUpdated();
    }

    function _addTrustedEscrow(address escrow) private {
        if (escrow == address(0) || trustedEscrow[escrow]) revert InvalidEscrowConfiguration();
        trustedEscrow[escrow] = true;
        emit TrustedEscrowAdded(escrow);
    }

    /// @notice Returns token metadata URI.
    /// @param tokenId Token id to query.
    function tokenURI(uint256 tokenId)
        public
        view
        override(ERC721Upgradeable, ERC721URIStorageUpgradeable)
        returns (string memory)
    {
        return super.tokenURI(tokenId);
    }

    /// @notice Reports interface support across ERC-721, ERC-721 URI storage, royalty, and access control.
    /// @param interfaceId Interface id to query.
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721URIStorageUpgradeable, ERC721RoyaltyUpgradeable, AccessControlUpgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    /// @dev Authorizes UUPS upgrades for `UPGRADER_ROLE` holders.
    function _authorizeUpgrade(address) internal override onlyRole(Roles.UPGRADER_ROLE) {}
}
