// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {BaseTest} from "./BaseTest.t.sol";
import {RedemptionManager} from "../src/RedemptionManager.sol";
import {DGENFT} from "../src/DGENFT.sol";
import {GemRegistry} from "../src/GemRegistry.sol";
import {ReserveManager} from "../src/ReserveManager.sol";
import {ComplianceRegistry} from "../src/ComplianceRegistry.sol";
import {Roles} from "../src/libraries/Roles.sol";

contract RedemptionLifecycleV2Test is BaseTest {
    function testLegacyTwoArgumentRequestAlwaysRevertsWithoutLockOrRegistryMutation() public {
        (uint256 gemId, uint256 tokenId) = _mintGemTo(buyer, 1_000e18, "ipfs://stale-client");
        GemRegistry.Gem memory beforeGem = registry.getGem(gemId);

        vm.prank(buyer);
        vm.expectRevert(RedemptionManager.LegacyRequestNotVerifiable.selector);
        redemption.requestRedemption(tokenId, keccak256("stale-client-request"));

        GemRegistry.Gem memory afterGem = registry.getGem(gemId);
        RedemptionManager.RedemptionRecord memory record = redemption.redemptionRecord(tokenId);
        assertFalse(nft.transferLocked(tokenId));
        assertEq(uint256(afterGem.status), uint256(beforeGem.status));
        assertEq(afterGem.redemptionRequestHash, beforeGem.redemptionRequestHash);
        assertEq(uint256(record.phase), uint256(RedemptionManager.RedemptionPhase.None));
        assertEq(record.owner, address(0));
        assertEq(record.requestHash, bytes32(0));
        assertEq(record.workflowIdHash, bytes32(0));
    }

    function testOwnerAuthorizedLifecycleLocksThenAtomicallyCreditsAndBurns() public {
        (uint256 gemId, uint256 tokenId) = _mintGemTo(buyer, 1_000e18, "ipfs://redemption-v2");
        _prepareApprovedRedemption(tokenId, keccak256("request-v2"));

        assertTrue(nft.transferLocked(tokenId));
        RedemptionManager.RedemptionRecord memory record = redemption.redemptionRecord(tokenId);
        assertEq(uint256(record.phase), uint256(RedemptionManager.RedemptionPhase.ProofApproved));
        assertEq(record.owner, buyer);
        assertEq(record.proofVersion, 1);

        _finalizeAsOwner(tokenId, buyer, keccak256("owner-finalize"));

        vm.expectRevert();
        nft.ownerOf(tokenId);
        assertEq(uint256(registry.getGem(gemId).status), uint256(GemRegistry.GemStatus.Redeemed));
        assertEq(
            uint256(redemption.redemptionRecord(tokenId).phase), uint256(RedemptionManager.RedemptionPhase.Completed)
        );
    }

    function testLegacyCustodianConfirmationCannotBypassOwnerAuthorization() public {
        (, uint256 tokenId) = _mintGemTo(buyer, 1_000e18, "ipfs://no-legacy-bypass");
        vm.prank(buyer);
        redemption.requestRedemption(tokenId, keccak256("legacy-bypass"), keccak256("legacy-bypass-workflow"));

        vm.prank(custodian);
        vm.expectRevert(RedemptionManager.LegacyConfirmationDisabled.selector);
        redemption.confirmRedemption(tokenId);

        assertEq(nft.ownerOf(tokenId), buyer);
        assertTrue(nft.transferLocked(tokenId));
    }

    function testFulfillmentStartPermanentlyClosesCancellation() public {
        (, uint256 tokenId) = _mintGemTo(buyer, 1_000e18, "ipfs://cancel-boundary");
        vm.prank(buyer);
        redemption.requestRedemption(tokenId, keccak256("cancel-boundary"), keccak256("cancel-boundary-workflow"));
        vm.prank(custodian);
        redemption.startFulfillment(tokenId);

        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(
                RedemptionManager.InvalidPhase.selector,
                RedemptionManager.RedemptionPhase.Requested,
                RedemptionManager.RedemptionPhase.FulfillmentStarted
            )
        );
        redemption.cancelRedemption(tokenId);
        assertTrue(nft.transferLocked(tokenId));
    }

    function testProofCorrectionIsVersionedAndOnlyApproverCanApprove() public {
        (, uint256 tokenId) = _mintGemTo(buyer, 1_000e18, "ipfs://proof-correction");
        vm.prank(buyer);
        redemption.requestRedemption(tokenId, keccak256("proof-correction"), keccak256("proof-correction-workflow"));
        vm.prank(custodian);
        redemption.startFulfillment(tokenId);
        vm.prank(custodian);
        redemption.submitFulfillmentProof(tokenId, keccak256("proof-one"));

        vm.prank(stranger);
        vm.expectRevert();
        redemption.approveFulfillmentProof(tokenId, keccak256("approval"), 1);

        redemption.rejectFulfillmentProof(tokenId, keccak256("bad-photo"));
        vm.prank(custodian);
        redemption.submitFulfillmentProof(tokenId, keccak256("proof-two"));
        redemption.approveFulfillmentProof(tokenId, keccak256("approval"), 2);

        RedemptionManager.RedemptionRecord memory record = redemption.redemptionRecord(tokenId);
        assertEq(record.proofDigest, keccak256("proof-two"));
        assertEq(record.proofVersion, 2);
        assertEq(record.approvalVersion, 2);
    }

    function testBackendSignerAndNamedCollectorCanNeverBurn() public {
        (, uint256 tokenId) = _mintGemTo(buyer, 1_000e18, "ipfs://owner-only-burn");
        vm.prank(buyer);
        redemption.requestRedemption(tokenId, keccak256("owner-only-burn"), keccak256("owner-only-burn-workflow"));
        vm.prank(buyer);
        redemption.setCollectorCommitment(tokenId, keccak256("named-proxy-and-id-evidence"));
        vm.prank(custodian);
        redemption.startFulfillment(tokenId);
        vm.prank(custodian);
        redemption.submitFulfillmentProof(tokenId, keccak256("proof"));
        redemption.approveFulfillmentProof(tokenId, keccak256("approval"), 1);

        bytes32 nonce = keccak256("owner-only-nonce");
        uint64 issuedAt = uint64(block.timestamp);
        uint64 deadline = issuedAt + 10 minutes;
        bytes32 digest = redemption.redemptionAuthorizationDigest(tokenId, nonce, issuedAt, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(AUTHORIZER_KEY, digest);

        vm.prank(authorizationSigner);
        vm.expectRevert(RedemptionManager.NotTokenOwner.selector);
        redemption.finalizeRedemption(
            tokenId, nonce, issuedAt, deadline, authorizationSigner, abi.encodePacked(r, s, v)
        );

        assertEq(nft.ownerOf(tokenId), buyer);
        assertTrue(nft.transferLocked(tokenId));
    }

    function testAuthorizationIsShortLivedRequestBoundAndNonceCannotReplay() public {
        (, uint256 tokenId) = _mintGemTo(buyer, 1_000e18, "ipfs://auth-binding");
        _prepareApprovedRedemption(tokenId, keccak256("auth-binding"));
        bytes32 nonce = keccak256("auth-binding-nonce");
        uint64 issuedAt = uint64(block.timestamp);
        uint64 deadline = issuedAt + 10 minutes;
        bytes32 digest = redemption.redemptionAuthorizationDigest(tokenId, nonce, issuedAt, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(AUTHORIZER_KEY, digest);

        vm.warp(deadline + 1);
        vm.prank(buyer);
        vm.expectRevert(RedemptionManager.InvalidAuthorizationWindow.selector);
        redemption.finalizeRedemption(
            tokenId, nonce, issuedAt, deadline, authorizationSigner, abi.encodePacked(r, s, v)
        );

        uint64 freshIssuedAt = uint64(block.timestamp);
        uint64 freshDeadline = freshIssuedAt + 10 minutes;
        bytes32 freshDigest = redemption.redemptionAuthorizationDigest(tokenId, nonce, freshIssuedAt, freshDeadline);
        (v, r, s) = vm.sign(AUTHORIZER_KEY, freshDigest);
        vm.prank(buyer);
        redemption.finalizeRedemption(
            tokenId, nonce, freshIssuedAt, freshDeadline, authorizationSigner, abi.encodePacked(r, s, v)
        );
        assertTrue(redemption.authorizationNonceUsed(nonce));
    }

    function testCorrectedProofVersionInvalidatesStaleAuthorization() public {
        (, uint256 tokenId) = _mintGemTo(buyer, 1_000e18, "ipfs://stale-proof-auth");
        vm.prank(buyer);
        redemption.requestRedemption(tokenId, keccak256("stale-proof-auth"), keccak256("stale-proof-auth-workflow"));
        vm.prank(custodian);
        redemption.startFulfillment(tokenId);
        vm.prank(custodian);
        redemption.submitFulfillmentProof(tokenId, keccak256("stale-proof-one"));

        bytes32 nonce = keccak256("stale-proof-nonce");
        uint64 issuedAt = uint64(block.timestamp);
        uint64 deadline = issuedAt + 10 minutes;
        bytes32 staleDigest = redemption.redemptionAuthorizationDigest(tokenId, nonce, issuedAt, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(AUTHORIZER_KEY, staleDigest);

        redemption.rejectFulfillmentProof(tokenId, keccak256("replace-proof"));
        vm.prank(custodian);
        redemption.submitFulfillmentProof(tokenId, keccak256("stale-proof-two"));
        redemption.approveFulfillmentProof(tokenId, keccak256("new-approval"), 1);

        vm.prank(buyer);
        vm.expectRevert(RedemptionManager.InvalidAuthorization.selector);
        redemption.finalizeRedemption(
            tokenId, nonce, issuedAt, deadline, authorizationSigner, abi.encodePacked(r, s, v)
        );
        assertEq(nft.ownerOf(tokenId), buyer);
        assertTrue(nft.transferLocked(tokenId));
        assertFalse(redemption.authorizationNonceUsed(nonce));
        assertEq(redemption.redemptionRecord(tokenId).proofVersion, 2);
    }

    function testRecoveryRequiresDistinctApproversAndSevenDayEvidenceDelay() public {
        (, uint256 tokenId) = _mintGemTo(buyer, 1_000e18, "ipfs://recovery");
        _prepareApprovedRedemption(tokenId, keccak256("recovery"));

        vm.prank(recoveryApproverOne);
        bytes32 proposalHash = redemption.proposeRecovery(tokenId, keccak256("failed-owner-completion-evidence"));

        vm.prank(recoveryApproverOne);
        vm.expectRevert(RedemptionManager.DuplicateApprover.selector);
        redemption.approveRecovery(tokenId, proposalHash);

        vm.prank(recoveryApproverTwo);
        redemption.approveRecovery(tokenId, proposalHash);
        vm.prank(recoveryApproverTwo);
        vm.expectRevert();
        redemption.executeRecovery(tokenId, proposalHash);

        vm.warp(block.timestamp + 7 days);
        vm.prank(recoveryApproverOne);
        redemption.executeRecovery(tokenId, proposalHash);
        vm.expectRevert();
        nft.ownerOf(tokenId);
    }

    function testFuzzAuthorizationCannotExceedFifteenMinutes(uint64 extraLifetime) public {
        extraLifetime = uint64(bound(extraLifetime, 1, type(uint32).max));
        (, uint256 tokenId) = _mintGemTo(buyer, 1_000e18, "ipfs://auth-window-fuzz");
        _prepareApprovedRedemption(tokenId, keccak256("auth-window-fuzz"));
        uint64 issuedAt = uint64(block.timestamp);
        uint64 deadline = issuedAt + 15 minutes + extraLifetime;

        vm.prank(buyer);
        vm.expectRevert(RedemptionManager.InvalidAuthorizationWindow.selector);
        redemption.finalizeRedemption(tokenId, keccak256("nonce"), issuedAt, deadline, authorizationSigner, hex"");
    }

    function testUpgradeRetainsV1DependenciesAndRolesAndInitializesV2Atomically() public {
        RedemptionManagerV1Fixture oldImplementation = new RedemptionManagerV1Fixture();
        RedemptionManagerV1Fixture proxy = RedemptionManagerV1Fixture(
            address(
                new ERC1967Proxy(
                    address(oldImplementation),
                    abi.encodeCall(
                        RedemptionManagerV1Fixture.initialize, (admin, nft, registry, reserveManager, compliance)
                    )
                )
            )
        );
        address[] memory approvers = new address[](2);
        approvers[0] = recoveryApproverOne;
        approvers[1] = recoveryApproverTwo;
        proxy.upgradeToAndCall(
            address(new RedemptionManager()),
            abi.encodeCall(RedemptionManager.initializeV2, (admin, authorizationSigner, approvers, 2, 7 days))
        );
        RedemptionManager upgraded = RedemptionManager(address(proxy));

        assertEq(address(upgraded.nft()), address(nft));
        assertEq(address(upgraded.registry()), address(registry));
        assertEq(address(upgraded.reserveManager()), address(reserveManager));
        assertEq(address(upgraded.complianceRegistry()), address(compliance));
        assertTrue(upgraded.hasRole(upgraded.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(upgraded.redemptionV2Initialized());
        assertEq(upgraded.recoveryDelay(), 7 days);
        assertEq(upgraded.recoveryApprovalThreshold(), 2);
    }

    function testAuditedLegacyOpenRequestCanBeMigratedAfterUpgrade() public {
        (, uint256 tokenId) = _mintGemTo(buyer, 1_000e18, "ipfs://legacy-open-migration");
        RedemptionManagerV1Fixture proxy = RedemptionManagerV1Fixture(
            address(
                new ERC1967Proxy(
                    address(new RedemptionManagerV1Fixture()),
                    abi.encodeCall(
                        RedemptionManagerV1Fixture.initialize, (admin, nft, registry, reserveManager, compliance)
                    )
                )
            )
        );
        nft.grantRole(Roles.LOCKER_ROLE, address(proxy));
        registry.grantRole(Roles.REDEEMER_ROLE, address(proxy));
        bytes32 originalRequestHash = keccak256("audited-v1-request");
        uint64 originalRequestedAt = uint64(block.timestamp);
        vm.prank(buyer);
        proxy.openLegacyRedemption(tokenId, originalRequestHash);

        address[] memory approvers = new address[](2);
        approvers[0] = recoveryApproverOne;
        approvers[1] = recoveryApproverTwo;
        proxy.upgradeToAndCall(
            address(new RedemptionManager()),
            abi.encodeCall(RedemptionManager.initializeV2, (admin, authorizationSigner, approvers, 2, 7 days))
        );
        RedemptionManager upgraded = RedemptionManager(address(proxy));
        bytes32 auditedWorkflowHash = keccak256("audited-v1-workflow-uuid");
        upgraded.migrateOpenRedemption(tokenId, auditedWorkflowHash, originalRequestedAt);

        RedemptionManager.RedemptionRecord memory record = upgraded.redemptionRecord(tokenId);
        assertEq(record.owner, buyer);
        assertEq(record.requestHash, originalRequestHash);
        assertEq(record.workflowIdHash, auditedWorkflowHash);
        assertEq(record.requestedAt, originalRequestedAt);
        assertEq(uint256(record.phase), uint256(RedemptionManager.RedemptionPhase.Requested));
        assertTrue(nft.transferLocked(tokenId));
    }

    function testV2ConfigurationSeparatesBackendSignerFromAdminRoles() public {
        RedemptionManager target = RedemptionManager(
            address(
                new ERC1967Proxy(
                    address(new RedemptionManager()),
                    abi.encodeCall(RedemptionManager.initialize, (admin, nft, registry, reserveManager, compliance))
                )
            )
        );
        address[] memory approvers = new address[](2);
        approvers[0] = recoveryApproverOne;
        approvers[1] = authorizationSigner;

        vm.expectRevert(RedemptionManager.InvalidConfiguration.selector);
        target.initializeV2(admin, authorizationSigner, approvers, 2, 7 days);

        approvers[1] = recoveryApproverTwo;
        vm.expectRevert(RedemptionManager.InvalidConfiguration.selector);
        target.initializeV2(authorizationSigner, authorizationSigner, approvers, 2, 7 days);
    }
}

/// @dev Exact V1 inheritance and storage prefix used to prove the UUPS append-only migration.
contract RedemptionManagerV1Fixture is
    Initializable,
    AccessControlUpgradeable,
    UUPSUpgradeable,
    PausableUpgradeable,
    ReentrancyGuard
{
    DGENFT public nft;
    GemRegistry public registry;
    ReserveManager public reserveManager;
    ComplianceRegistry public complianceRegistry;

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
        __AccessControl_init();
        __Pausable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(Roles.UPGRADER_ROLE, admin);
        nft = nft_;
        registry = registry_;
        reserveManager = reserveManager_;
        complianceRegistry = complianceRegistry_;
    }

    function openLegacyRedemption(uint256 tokenId, bytes32 requestHash) external {
        if (nft.ownerOf(tokenId) != msg.sender) revert();
        uint256 gemId = nft.tokenGem(tokenId);
        nft.setTransferLocked(tokenId, true);
        registry.requestRedemption(gemId, requestHash);
    }

    function _authorizeUpgrade(address) internal override onlyRole(Roles.UPGRADER_ROLE) {}
}
