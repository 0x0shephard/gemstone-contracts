// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {ComplianceRegistry} from "./ComplianceRegistry.sol";
import {DGENFT} from "./DGENFT.sol";
import {GemRegistry} from "./GemRegistry.sol";
import {ReserveManager} from "./ReserveManager.sol";
import {Roles} from "./libraries/Roles.sol";

/// @notice Locks a gemstone NFT while its physical redemption is fulfilled and
///         burns it only after approved evidence and owner-wallet authorization.
contract RedemptionManager is
    Initializable,
    AccessControlUpgradeable,
    UUPSUpgradeable,
    PausableUpgradeable,
    ReentrancyGuard
{
    // V1 storage. Never reorder or change these fields.
    DGENFT public nft;
    GemRegistry public registry;
    ReserveManager public reserveManager;
    ComplianceRegistry public complianceRegistry;

    enum RedemptionPhase {
        None,
        Requested,
        FulfillmentStarted,
        ProofSubmitted,
        ProofApproved,
        Completed
    }

    struct RedemptionRecord {
        address owner;
        bytes32 requestHash;
        bytes32 workflowIdHash;
        bytes32 collectorCommitment;
        bytes32 proofDigest;
        bytes32 approvalId;
        uint64 requestedAt;
        uint64 fulfillmentStartedAt;
        uint64 proofSubmittedAt;
        uint64 proofApprovedAt;
        uint64 approvalVersion;
        uint64 proofVersion;
        RedemptionPhase phase;
    }

    struct RecoveryProposal {
        bytes32 proposalHash;
        bytes32 evidenceDigest;
        uint64 proposedAt;
        uint64 executeAfter;
        uint8 requiredApprovals;
        uint8 approvals;
        bool executed;
    }

    // V2 storage. Append-only for UUPS compatibility.
    mapping(uint256 tokenId => RedemptionRecord record) private _redemptions;
    mapping(bytes32 nonce => bool used) public authorizationNonceUsed;
    mapping(uint256 tokenId => RecoveryProposal proposal) private _recoveryProposals;
    mapping(bytes32 proposalHash => mapping(address approver => bool approved)) public recoveryApprovalBy;
    mapping(uint256 tokenId => uint64 sequence) private _recoverySequence;
    uint64 public recoveryDelay;
    uint8 public recoveryApprovalThreshold;
    bool public redemptionV2Initialized;

    uint256 public constant MIN_REDEMPTION_RESERVE_BPS = 2_000;
    uint64 public constant MIN_RECOVERY_DELAY = 7 days;
    uint64 public constant MAX_AUTHORIZATION_LIFETIME = 15 minutes;

    bytes32 public constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 public constant REDEMPTION_AUTHORIZATION_TYPEHASH = keccak256(
        "RedemptionAuthorization(uint256 tokenId,address owner,bytes32 requestHash,bytes32 workflowIdHash,bytes32 proofDigest,uint64 proofVersion,bytes32 approvalId,uint64 approvalVersion,bytes32 collectorCommitment,bytes32 nonce,uint64 issuedAt,uint64 deadline)"
    );
    bytes32 private constant _NAME_HASH = keccak256("DigitalCaratRedemption");
    bytes32 private constant _VERSION_HASH = keccak256("2");
    bytes32 private constant _REDEMPTION_REASON = keccak256("REDEMPTION_CONFIRMED");

    event RedemptionV2Initialized(
        address indexed proofApprover, address indexed authorizer, uint64 recoveryDelay, uint8 recoveryApprovalThreshold
    );
    event RedemptionOpened(uint256 indexed tokenId, uint256 indexed gemId, address indexed owner, bytes32 requestHash);
    event RedemptionWorkflowBound(uint256 indexed tokenId, bytes32 indexed workflowIdHash);
    event CollectorCommitmentSet(uint256 indexed tokenId, bytes32 indexed collectorCommitment);
    event FulfillmentStarted(uint256 indexed tokenId, uint256 indexed gemId, address indexed custodian);
    event FulfillmentProofSubmitted(uint256 indexed tokenId, bytes32 indexed proofDigest, uint64 indexed proofVersion);
    event FulfillmentProofRejected(
        uint256 indexed tokenId, bytes32 indexed proofDigest, uint64 indexed proofVersion, bytes32 reasonHash
    );
    event FulfillmentProofApproved(
        uint256 indexed tokenId,
        bytes32 indexed proofDigest,
        bytes32 indexed approvalId,
        uint64 approvalVersion,
        address approver
    );
    event RedemptionCancelled(uint256 indexed tokenId, uint256 indexed gemId);
    event RedemptionConfirmed(uint256 indexed tokenId, uint256 indexed gemId);
    event RedemptionFinalized(
        uint256 indexed tokenId,
        uint256 indexed gemId,
        address indexed owner,
        bytes32 proofDigest,
        bytes32 approvalId,
        bytes32 authorizationNonce,
        bool recovered
    );
    event RecoveryPolicyUpdated(uint64 delay, uint8 threshold);
    event RecoveryProposed(
        uint256 indexed tokenId,
        bytes32 indexed proposalHash,
        bytes32 indexed evidenceDigest,
        uint64 executeAfter,
        uint8 requiredApprovals,
        address proposer
    );
    event RecoveryApproved(
        uint256 indexed tokenId, bytes32 indexed proposalHash, address indexed approver, uint8 approvals
    );

    error InvalidAddress();
    error InvalidConfiguration();
    error RedemptionV2NotInitialized();
    error NotGemCustodian();
    error NotTokenOwner();
    error TokenNotMapped();
    error RedemptionNotAllowed();
    error NotRedemptionCanceller();
    error RedemptionReserveTooLow(uint256 requiredUsd, uint256 balanceUsd);
    error InvalidPhase(RedemptionPhase expected, RedemptionPhase actual);
    error InvalidDigest();
    error InvalidAuthorizationWindow();
    error InvalidAuthorization();
    error AuthorizationNonceAlreadyUsed();
    error LegacyConfirmationDisabled();
    error DuplicateApprover();
    error RecoveryNotReady(uint64 executeAfter);
    error RecoveryApprovalInsufficient(uint8 required, uint8 actual);
    error InvalidRecoveryProposal();
    error LegacyRequestNotVerifiable();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address admin,
        DGENFT nft_,
        GemRegistry registry_,
        ReserveManager reserveManager_,
        ComplianceRegistry complianceRegistry_
    ) external initializer {
        if (
            admin == address(0) || address(nft_) == address(0) || address(registry_) == address(0)
                || address(reserveManager_) == address(0) || address(complianceRegistry_) == address(0)
        ) revert InvalidAddress();
        __AccessControl_init();
        __Pausable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(Roles.UPGRADER_ROLE, admin);
        _grantRole(Roles.REDEEMER_ROLE, admin);
        nft = nft_;
        registry = registry_;
        reserveManager = reserveManager_;
        complianceRegistry = complianceRegistry_;
    }

    /// @notice Atomically configures V2 roles and recovery policy during upgrade.
    function initializeV2(
        address proofApprover,
        address authorizer,
        address[] calldata recoveryApprovers,
        uint8 threshold,
        uint64 delay
    ) external reinitializer(2) onlyRole(DEFAULT_ADMIN_ROLE) {
        if (proofApprover == address(0) || authorizer == address(0)) revert InvalidAddress();
        if (proofApprover == authorizer) revert InvalidConfiguration();
        _validateRecoveryPolicy(delay, threshold);
        if (recoveryApprovers.length < threshold) revert InvalidConfiguration();
        for (uint256 i = 0; i < recoveryApprovers.length; ++i) {
            address approver = recoveryApprovers[i];
            if (approver == address(0)) revert InvalidAddress();
            if (approver == authorizer) revert InvalidConfiguration();
            for (uint256 j = 0; j < i; ++j) {
                if (recoveryApprovers[j] == approver) revert DuplicateApprover();
            }
            _grantRole(Roles.RECOVERY_APPROVER_ROLE, approver);
        }
        _grantRole(Roles.PROOF_APPROVER_ROLE, proofApprover);
        _grantRole(Roles.AUTHORIZER_ROLE, authorizer);
        recoveryDelay = delay;
        recoveryApprovalThreshold = threshold;
        redemptionV2Initialized = true;
        emit RedemptionV2Initialized(proofApprover, authorizer, delay, threshold);
    }

    /// @notice Retained only so stale V1 clients fail explicitly without locking a token.
    function requestRedemption(uint256, bytes32) external pure {
        revert LegacyRequestNotVerifiable();
    }

    function requestRedemption(uint256 tokenId, bytes32 requestHash, bytes32 workflowIdHash)
        external
        nonReentrant
        whenNotPaused
    {
        _requestRedemption(tokenId, requestHash, workflowIdHash);
    }

    function _requestRedemption(uint256 tokenId, bytes32 requestHash, bytes32 workflowIdHash) internal {
        _requireV2();
        if (requestHash == bytes32(0) || workflowIdHash == bytes32(0)) revert InvalidDigest();
        if (nft.ownerOf(tokenId) != msg.sender) revert NotTokenOwner();
        if (!complianceRegistry.canRedeem(msg.sender)) revert RedemptionNotAllowed();
        uint256 gemId = nft.tokenGem(tokenId);
        if (gemId == 0) revert TokenNotMapped();
        GemRegistry.Gem memory gem = registry.getGem(gemId);
        reserveManager.requireSolvent();
        uint256 requiredUsd = reserveManager.requiredReserveUsd(gemId, gem.priceUsd);
        uint256 balanceUsd = reserveManager.reserveBalanceUsd(gemId);
        if (balanceUsd * 10_000 < requiredUsd * MIN_REDEMPTION_RESERVE_BPS) {
            revert RedemptionReserveTooLow(requiredUsd, balanceUsd);
        }
        RedemptionRecord storage record = _redemptions[tokenId];
        if (record.phase != RedemptionPhase.None) revert InvalidPhase(RedemptionPhase.None, record.phase);
        record.owner = msg.sender;
        record.requestHash = requestHash;
        record.workflowIdHash = workflowIdHash;
        record.requestedAt = _timestamp();
        record.phase = RedemptionPhase.Requested;
        nft.setTransferLocked(tokenId, true);
        registry.requestRedemption(gemId, requestHash);
        emit RedemptionOpened(tokenId, gemId, msg.sender, requestHash);
        emit RedemptionWorkflowBound(tokenId, workflowIdHash);
    }

    /// @notice Imports a V1 open request after verifying its current on-chain lock and registry state.
    function migrateOpenRedemption(uint256 tokenId, bytes32 workflowIdHash, uint64 requestedAt)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _requireV2();
        if (workflowIdHash == bytes32(0) || requestedAt == 0 || requestedAt > block.timestamp) revert InvalidDigest();
        RedemptionRecord storage record = _redemptions[tokenId];
        if (record.phase != RedemptionPhase.None) revert InvalidPhase(RedemptionPhase.None, record.phase);
        uint256 gemId = nft.tokenGem(tokenId);
        if (gemId == 0 || !nft.transferLocked(tokenId)) revert LegacyRequestNotVerifiable();
        GemRegistry.Gem memory gem = registry.getGem(gemId);
        if (gem.status != GemRegistry.GemStatus.RedemptionRequested || gem.redemptionRequestHash == bytes32(0)) {
            revert LegacyRequestNotVerifiable();
        }
        record.owner = nft.ownerOf(tokenId);
        record.requestHash = gem.redemptionRequestHash;
        record.workflowIdHash = workflowIdHash;
        record.requestedAt = requestedAt;
        record.phase = RedemptionPhase.Requested;
        emit RedemptionWorkflowBound(tokenId, workflowIdHash);
    }

    function setCollectorCommitment(uint256 tokenId, bytes32 collectorCommitment) external whenNotPaused {
        RedemptionRecord storage record = _recordAtPhase(tokenId, RedemptionPhase.Requested);
        _requireCurrentOwner(record, tokenId);
        record.collectorCommitment = collectorCommitment;
        emit CollectorCommitmentSet(tokenId, collectorCommitment);
    }

    function startFulfillment(uint256 tokenId) external whenNotPaused {
        RedemptionRecord storage record = _recordAtPhase(tokenId, RedemptionPhase.Requested);
        uint256 gemId = _gemId(tokenId);
        if (msg.sender != registry.getGem(gemId).custodian) revert NotGemCustodian();
        record.fulfillmentStartedAt = _timestamp();
        record.phase = RedemptionPhase.FulfillmentStarted;
        emit FulfillmentStarted(tokenId, gemId, msg.sender);
    }

    function submitFulfillmentProof(uint256 tokenId, bytes32 proofDigest) external whenNotPaused {
        if (proofDigest == bytes32(0)) revert InvalidDigest();
        RedemptionRecord storage record = _recordAtPhase(tokenId, RedemptionPhase.FulfillmentStarted);
        uint256 gemId = _gemId(tokenId);
        if (msg.sender != registry.getGem(gemId).custodian) revert NotGemCustodian();
        record.proofDigest = proofDigest;
        record.proofSubmittedAt = _timestamp();
        record.proofVersion += 1;
        record.phase = RedemptionPhase.ProofSubmitted;
        emit FulfillmentProofSubmitted(tokenId, proofDigest, record.proofVersion);
    }

    function rejectFulfillmentProof(uint256 tokenId, bytes32 reasonHash)
        external
        whenNotPaused
        onlyRole(Roles.PROOF_APPROVER_ROLE)
    {
        if (reasonHash == bytes32(0)) revert InvalidDigest();
        RedemptionRecord storage record = _recordAtPhase(tokenId, RedemptionPhase.ProofSubmitted);
        bytes32 rejectedDigest = record.proofDigest;
        uint64 rejectedVersion = record.proofVersion;
        record.proofDigest = bytes32(0);
        record.proofSubmittedAt = 0;
        record.phase = RedemptionPhase.FulfillmentStarted;
        emit FulfillmentProofRejected(tokenId, rejectedDigest, rejectedVersion, reasonHash);
    }

    function approveFulfillmentProof(uint256 tokenId, bytes32 approvalId, uint64 approvalVersion)
        external
        whenNotPaused
        onlyRole(Roles.PROOF_APPROVER_ROLE)
    {
        if (approvalId == bytes32(0) || approvalVersion == 0) revert InvalidDigest();
        RedemptionRecord storage record = _recordAtPhase(tokenId, RedemptionPhase.ProofSubmitted);
        record.approvalId = approvalId;
        record.approvalVersion = approvalVersion;
        record.proofApprovedAt = _timestamp();
        record.phase = RedemptionPhase.ProofApproved;
        emit FulfillmentProofApproved(tokenId, record.proofDigest, approvalId, approvalVersion, msg.sender);
    }

    function cancelRedemption(uint256 tokenId) external nonReentrant whenNotPaused {
        uint256 gemId = _gemId(tokenId);
        address owner = nft.ownerOf(tokenId);
        address recordedCustodian = registry.getGem(gemId).custodian;
        if (msg.sender != owner && msg.sender != recordedCustodian && !hasRole(Roles.REDEEMER_ROLE, msg.sender)) {
            revert NotRedemptionCanceller();
        }
        RedemptionRecord storage record = _redemptions[tokenId];
        if (record.phase != RedemptionPhase.None && record.phase != RedemptionPhase.Requested) {
            revert InvalidPhase(RedemptionPhase.Requested, record.phase);
        }
        GemRegistry.Gem memory gem = registry.getGem(gemId);
        if (gem.status != GemRegistry.GemStatus.RedemptionRequested) revert LegacyRequestNotVerifiable();
        delete _redemptions[tokenId];
        registry.cancelRedemption(gemId);
        nft.setTransferLocked(tokenId, false);
        emit RedemptionCancelled(tokenId, gemId);
    }

    /// @notice Disabled permanently because V1 allowed the custodian to burn before owner authorization.
    function confirmRedemption(uint256) external pure {
        revert LegacyConfirmationDisabled();
    }

    function finalizeRedemption(
        uint256 tokenId,
        bytes32 nonce,
        uint64 issuedAt,
        uint64 deadline,
        address authorizer,
        bytes calldata signature
    ) external nonReentrant whenNotPaused {
        RedemptionRecord storage record = _recordAtPhase(tokenId, RedemptionPhase.ProofApproved);
        _requireCurrentOwner(record, tokenId);
        if (nonce == bytes32(0)) revert InvalidDigest();
        if (
            issuedAt > block.timestamp || deadline < block.timestamp || deadline < issuedAt
                || deadline - issuedAt > MAX_AUTHORIZATION_LIFETIME
        ) revert InvalidAuthorizationWindow();
        if (authorizationNonceUsed[nonce]) revert AuthorizationNonceAlreadyUsed();
        if (!hasRole(Roles.AUTHORIZER_ROLE, authorizer)) revert InvalidAuthorization();
        bytes32 digest = redemptionAuthorizationDigest(tokenId, nonce, issuedAt, deadline);
        if (!SignatureChecker.isValidSignatureNowCalldata(authorizer, digest, signature)) {
            revert InvalidAuthorization();
        }
        authorizationNonceUsed[nonce] = true;
        _completeRedemption(tokenId, record, nonce, false);
    }

    function setRecoveryPolicy(uint64 delay, uint8 threshold) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _validateRecoveryPolicy(delay, threshold);
        recoveryDelay = delay;
        recoveryApprovalThreshold = threshold;
        emit RecoveryPolicyUpdated(delay, threshold);
    }

    function proposeRecovery(uint256 tokenId, bytes32 evidenceDigest)
        external
        whenNotPaused
        onlyRole(Roles.RECOVERY_APPROVER_ROLE)
        returns (bytes32 proposalHash)
    {
        if (evidenceDigest == bytes32(0)) revert InvalidDigest();
        RedemptionRecord storage record = _recordAtPhase(tokenId, RedemptionPhase.ProofApproved);
        RecoveryProposal storage existing = _recoveryProposals[tokenId];
        if (existing.proposalHash != bytes32(0) && !existing.executed) revert InvalidRecoveryProposal();
        uint64 sequence = ++_recoverySequence[tokenId];
        uint64 executeAfter = record.proofApprovedAt + recoveryDelay;
        proposalHash = keccak256(
            abi.encode(
                block.chainid,
                address(this),
                tokenId,
                _redemptionBindingHash(record),
                evidenceDigest,
                sequence,
                executeAfter,
                recoveryApprovalThreshold
            )
        );
        _recoveryProposals[tokenId] = RecoveryProposal({
            proposalHash: proposalHash,
            evidenceDigest: evidenceDigest,
            proposedAt: _timestamp(),
            executeAfter: executeAfter,
            requiredApprovals: recoveryApprovalThreshold,
            approvals: 1,
            executed: false
        });
        recoveryApprovalBy[proposalHash][msg.sender] = true;
        emit RecoveryProposed(
            tokenId, proposalHash, evidenceDigest, executeAfter, recoveryApprovalThreshold, msg.sender
        );
        emit RecoveryApproved(tokenId, proposalHash, msg.sender, 1);
    }

    function approveRecovery(uint256 tokenId, bytes32 proposalHash)
        external
        whenNotPaused
        onlyRole(Roles.RECOVERY_APPROVER_ROLE)
    {
        _recordAtPhase(tokenId, RedemptionPhase.ProofApproved);
        RecoveryProposal storage proposal = _recoveryProposals[tokenId];
        if (proposal.proposalHash != proposalHash || proposal.executed) revert InvalidRecoveryProposal();
        if (recoveryApprovalBy[proposalHash][msg.sender]) revert DuplicateApprover();
        recoveryApprovalBy[proposalHash][msg.sender] = true;
        proposal.approvals += 1;
        emit RecoveryApproved(tokenId, proposalHash, msg.sender, proposal.approvals);
    }

    function executeRecovery(uint256 tokenId, bytes32 proposalHash)
        external
        nonReentrant
        whenNotPaused
        onlyRole(Roles.RECOVERY_APPROVER_ROLE)
    {
        RedemptionRecord storage record = _recordAtPhase(tokenId, RedemptionPhase.ProofApproved);
        RecoveryProposal storage proposal = _recoveryProposals[tokenId];
        if (proposal.proposalHash != proposalHash || proposal.executed) revert InvalidRecoveryProposal();
        if (proposal.approvals < proposal.requiredApprovals) {
            revert RecoveryApprovalInsufficient(proposal.requiredApprovals, proposal.approvals);
        }
        if (block.timestamp < proposal.executeAfter) revert RecoveryNotReady(proposal.executeAfter);
        proposal.executed = true;
        _completeRedemption(tokenId, record, bytes32(0), true);
    }

    function redemptionRecord(uint256 tokenId) external view returns (RedemptionRecord memory) {
        return _redemptions[tokenId];
    }

    function recoveryProposal(uint256 tokenId) external view returns (RecoveryProposal memory) {
        return _recoveryProposals[tokenId];
    }

    function domainSeparator() public view returns (bytes32) {
        return keccak256(abi.encode(DOMAIN_TYPEHASH, _NAME_HASH, _VERSION_HASH, block.chainid, address(this)));
    }

    function redemptionAuthorizationDigest(uint256 tokenId, bytes32 nonce, uint64 issuedAt, uint64 deadline)
        public
        view
        returns (bytes32)
    {
        RedemptionRecord storage record = _redemptions[tokenId];
        bytes32 structHash = keccak256(
            abi.encode(
                REDEMPTION_AUTHORIZATION_TYPEHASH,
                tokenId,
                record.owner,
                record.requestHash,
                record.workflowIdHash,
                record.proofDigest,
                record.proofVersion,
                record.approvalId,
                record.approvalVersion,
                record.collectorCommitment,
                nonce,
                issuedAt,
                deadline
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator(), structHash));
    }

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    function _completeRedemption(
        uint256 tokenId,
        RedemptionRecord storage record,
        bytes32 authorizationNonce,
        bool recovered
    ) internal {
        uint256 gemId = _gemId(tokenId);
        address holder = record.owner;
        record.phase = RedemptionPhase.Completed;
        registry.markRedeemed(gemId);
        reserveManager.clearProjectedLiabilityUsd(gemId);
        reserveManager.creditAllReserveAssets(gemId, holder, _REDEMPTION_REASON);
        nft.burnFromProtocol(tokenId);
        emit RedemptionConfirmed(tokenId, gemId);
        emit RedemptionFinalized(
            tokenId, gemId, holder, record.proofDigest, record.approvalId, authorizationNonce, recovered
        );
    }

    function _redemptionBindingHash(RedemptionRecord storage record) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                record.owner,
                record.requestHash,
                record.workflowIdHash,
                record.proofDigest,
                record.proofVersion,
                record.approvalId,
                record.approvalVersion,
                record.collectorCommitment
            )
        );
    }

    function _recordAtPhase(uint256 tokenId, RedemptionPhase expected)
        internal
        view
        returns (RedemptionRecord storage record)
    {
        _requireV2();
        record = _redemptions[tokenId];
        if (record.phase != expected) revert InvalidPhase(expected, record.phase);
    }

    function _requireCurrentOwner(RedemptionRecord storage record, uint256 tokenId) internal view {
        if (msg.sender != record.owner || nft.ownerOf(tokenId) != record.owner) revert NotTokenOwner();
    }

    function _gemId(uint256 tokenId) internal view returns (uint256 gemId) {
        gemId = nft.tokenGem(tokenId);
        if (gemId == 0) revert TokenNotMapped();
    }

    function _requireV2() internal view {
        if (!redemptionV2Initialized) revert RedemptionV2NotInitialized();
    }

    function _validateRecoveryPolicy(uint64 delay, uint8 threshold) internal pure {
        if (delay < MIN_RECOVERY_DELAY || threshold < 2) revert InvalidConfiguration();
    }

    function _timestamp() internal view returns (uint64) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint64(block.timestamp);
    }

    function _authorizeUpgrade(address) internal override onlyRole(Roles.UPGRADER_ROLE) {}
}
