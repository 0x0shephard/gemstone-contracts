// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {PaymentTokenRegistry} from "../src/PaymentTokenRegistry.sol";
import {ReserveManager} from "../src/ReserveManager.sol";
import {RedemptionManager} from "../src/RedemptionManager.sol";
import {GemRegistry} from "../src/GemRegistry.sol";
import {BaseTest} from "./BaseTest.t.sol";
import {MockV3Aggregator} from "./mocks/MockV3Aggregator.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract PaymentReserveLogicTest is BaseTest {
    function testRemovedPaymentTokenCannotBeQuotedOrUsed() public {
        payments.removeToken(address(usdc));

        vm.expectRevert(PaymentTokenRegistry.TokenNotEnabled.selector);
        payments.quoteTokenToUsd(address(usdc), 1_000e6);

        uint256 gemId = _listedGem(1_000e18, "ipfs://removed-token");
        vm.startPrank(buyer);
        usdc.approve(address(sale), 1_000e6);
        vm.expectRevert(PaymentTokenRegistry.TokenNotEnabled.selector);
        sale.buyNow(gemId, address(usdc), 1_000e6);
        vm.stopPrank();
    }

    function testStaleOracleRevertsPricing() public {
        vm.warp(10 days);

        vm.expectRevert(PaymentTokenRegistry.StalePrice.selector);
        payments.quoteTokenToUsd(address(0), 1 ether);
    }

    function testNegativeOracleAnswerRevertsPricing() public {
        ethFeed.updateAnswer(-1);

        vm.expectRevert(PaymentTokenRegistry.InvalidPrice.selector);
        payments.quoteTokenToUsd(address(0), 1 ether);
    }

    function testOracleRoundAndBoundsValidation() public {
        ethFeed.setRoundData(2, 2_000e8, block.timestamp, 1);
        assertEq(payments.quoteTokenToUsd(address(0), 1 ether), 2_000e18);

        ethFeed.setRoundData(2, 2_000e8, 0, 2);
        vm.expectRevert(PaymentTokenRegistry.StalePrice.selector);
        payments.quoteTokenToUsd(address(0), 1 ether);

        ethFeed.setRoundData(3, 2_000e8, block.timestamp, 3);
        payments.setTokenBounds(address(0), 1_500e8, 2_500e8);
        assertEq(payments.quoteTokenToUsd(address(0), 1 ether), 2_000e18);

        ethFeed.updateAnswer(3_000e8);
        vm.expectRevert(PaymentTokenRegistry.InvalidPrice.selector);
        payments.quoteTokenToUsd(address(0), 1 ether);
    }

    function testSetTokenPreservesOracleBounds() public {
        payments.setTokenBounds(address(0), 1_500e8, 2_500e8);
        payments.setToken(address(0), address(ethFeed), 2 days, true);

        ethFeed.updateAnswer(3_000e8);
        vm.expectRevert(PaymentTokenRegistry.InvalidPrice.selector);
        payments.quoteTokenToUsd(address(0), 1 ether);
    }

    function testTokenCannotBeEnabledWithoutOracleBounds() public {
        MockV3Aggregator unboundedFeed = new MockV3Aggregator(8, 1e8);
        MockERC20 unboundedToken = new MockERC20("Unbounded", "UNB", 18);

        vm.expectRevert(PaymentTokenRegistry.InvalidBounds.selector);
        payments.setToken(address(unboundedToken), address(unboundedFeed), 1 days, true);

        payments.setToken(address(unboundedToken), address(unboundedFeed), 1 days, false);
        payments.setTokenBounds(address(unboundedToken), 80_000_000, 120_000_000);
        payments.setToken(address(unboundedToken), address(unboundedFeed), 1 days, true);
        assertTrue(payments.isEnabled(address(unboundedToken)));
    }

    function testFeeOnTransferReserveFundingRecordsNetReceived() public {
        uint256 gemId = _listedGem(1_000e18, "ipfs://fee-reserve");
        vm.startPrank(buyer);
        feeToken.approve(address(reserveManager), 100e18);
        reserveManager.fundToken(gemId, address(feeToken), 100e18);
        vm.stopPrank();

        assertEq(reserveManager.reserveAssetBalance(gemId, address(feeToken)), 90e18);
        assertEq(reserveManager.reserveBalanceUsd(gemId), 90e18);
        assertEq(feeToken.balanceOf(feeCollector), 10e18);
    }

    function testReserveFundingRejectsUnknownGemIds() public {
        vm.prank(buyer);
        vm.expectRevert(GemRegistry.InvalidGem.selector);
        reserveManager.fundNative{value: 1 ether}(999);

        vm.expectRevert(GemRegistry.InvalidGem.selector);
        reserveManager.recordModuleFunding{value: 1 ether}(999, address(0), 1 ether, 2_000e18);
    }

    function testReserveConsumptionRequiresAvailableBalance() public {
        uint256 gemId = _listedGem(1_000e18, "ipfs://consume-reserve");
        reserveManager.setMinimumReserveUsd(gemId, 100e18);

        vm.expectRevert(abi.encodeWithSelector(ReserveManager.ReserveShortfall.selector, 100e18, 0));
        reserveManager.requireFunded(gemId, 1e18);

        reserveManager.recordModuleFunding{value: 0.05 ether}(gemId, address(0), 0.05 ether, 100e18);
        reserveManager.setProjectedLiabilityUsd(gemId, 100e18);
        reserveManager.consumeReserveUsd(gemId, 40e18);

        assertEq(reserveManager.reserveBalanceUsd(gemId), 100e18);
        assertEq(reserveManager.projectedLiabilityUsd(gemId), 60e18);

        vm.expectRevert(abi.encodeWithSelector(ReserveManager.LiabilityShortfall.selector, 61e18, 60e18));
        reserveManager.consumeReserveUsd(gemId, 61e18);
    }

    function testReasonedReserveConsumptionUpdatesAggregateBalance() public {
        uint256 gemId = _listedGem(1_000e18, "ipfs://reasoned-consume");
        reserveManager.recordModuleFunding{value: 0.05 ether}(gemId, address(0), 0.05 ether, 100e18);
        reserveManager.setProjectedLiabilityUsd(gemId, 100e18);

        reserveManager.consumeReserveUsdFor(gemId, 25e18, keccak256("vault-fee"));

        assertEq(reserveManager.reserveBalanceUsd(gemId), 100e18);
        assertEq(reserveManager.totalReserveBalanceUsd(), 100e18);
        assertEq(reserveManager.projectedLiabilityUsd(gemId), 75e18);
        assertEq(reserveManager.coverageRatioBps(), 13_333);
    }

    function testReserveValuationTracksCurrentOraclePrice() public {
        uint256 gemId = _listedGem(1_000e18, "ipfs://live-reserve-value");
        reserveManager.setMinimumReserveUsd(gemId, 100e18);
        reserveManager.recordModuleFunding{value: 0.05 ether}(gemId, address(0), 0.05 ether, 100e18);
        reserveManager.setProjectedLiabilityUsd(gemId, 100e18);

        assertEq(reserveManager.reserveBalanceUsd(gemId), 100e18);
        assertEq(reserveManager.recordedReserveBalanceUsd(gemId), 100e18);
        assertEq(reserveManager.coverageRatioBps(), 10_000);

        ethFeed.updateAnswer(1_000e8);

        assertEq(reserveManager.reserveBalanceUsd(gemId), 50e18);
        assertEq(reserveManager.totalReserveBalanceUsd(), 50e18);
        assertEq(reserveManager.recordedReserveBalanceUsd(gemId), 100e18);
        assertEq(reserveManager.shortfallUsd(gemId, 1_000e18), 50e18);
        assertEq(reserveManager.coverageRatioBps(), 5_000);
        vm.expectRevert(abi.encodeWithSelector(ReserveManager.Insolvent.selector, 5_000, 10_000));
        reserveManager.requireSolvent();
    }

    function testCoverageRatioAndSolvencyGuard() public {
        uint256 trackedGemId = _listedGem(1_000e18, "ipfs://tracked-liability");
        reserveManager.recordModuleFunding{value: 0.05 ether}(trackedGemId, address(0), 0.05 ether, 100e18);
        reserveManager.setProjectedLiabilityUsd(trackedGemId, 200e18);

        assertEq(reserveManager.coverageRatioBps(), 5_000);

        reserveManager.setMinimumCoverageBps(6_000);
        reserveManager.setGlobalSolvencyCheckEnabled(true);

        uint256 gemId = _listedGem(1_000e18, "ipfs://insolvent");
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(ReserveManager.Insolvent.selector, 5_000, 6_000));
        sale.buyNow{value: 0.5 ether}(gemId, address(0), 0.5 ether);

        reserveManager.setGlobalSolvencyCheckEnabled(false);
        vm.prank(buyer);
        uint256 tokenId = sale.buyNow{value: 0.5 ether}(gemId, address(0), 0.5 ether);
        assertEq(nft.ownerOf(tokenId), buyer);
    }

    function testSolvencyDoesNotGloballyFreezeForOneUnderfundedGem() public {
        uint256 overfundedGemId = _listedGem(1_000e18, "ipfs://overfunded");
        uint256 underfundedGemId = _listedGem(1_000e18, "ipfs://underfunded");

        reserveManager.recordModuleFunding{value: 0.1 ether}(overfundedGemId, address(0), 0.1 ether, 200e18);
        reserveManager.setProjectedLiabilityUsd(overfundedGemId, 100e18);
        reserveManager.setProjectedLiabilityUsd(underfundedGemId, 100e18);

        assertEq(reserveManager.coverageRatioBps(), 10_000);
        assertTrue(reserveManager.isUnderfunded(underfundedGemId));
        reserveManager.requireSolvent();

        reserveManager.recordModuleFunding{value: 0.05 ether}(underfundedGemId, address(0), 0.05 ether, 100e18);
        reserveManager.requireSolvent();
    }

    function testRedemptionCreditsHolderWhoCanClaimToChosenRecipient() public {
        _setTwoTierReservePolicy();
        uint256 gemId = _listedGem(1_000e18, "ipfs://reserve-release");

        vm.prank(buyer);
        uint256 tokenId = sale.buyNow{value: 0.52 ether}(gemId, address(0), 0.52 ether);
        assertEq(reserveManager.reserveBalanceUsd(gemId), 40e18);
        assertEq(reserveManager.totalReserveBalanceUsd(), 40e18);

        uint256 holderBefore = buyer.balance;
        uint256 custodianBefore = custodian.balance;
        _prepareApprovedRedemption(tokenId, keccak256("release-reserve"));
        _finalizeAsOwner(tokenId, buyer, keccak256("release-reserve-nonce"));

        assertEq(buyer.balance, holderBefore);
        assertEq(custodian.balance, custodianBefore);
        assertEq(reserveManager.pendingReserveClaims(buyer, address(0)), 0.02 ether);
        assertEq(reserveManager.totalPendingReserveClaims(address(0)), 0.02 ether);
        assertEq(reserveManager.reserveBalanceUsd(gemId), 0);
        assertEq(reserveManager.totalReserveBalanceUsd(), 0);
        assertEq(reserveManager.reserveAssetBalance(gemId, address(0)), 0);

        vm.prank(buyer);
        reserveManager.claimReserveCredit(address(0), buyer);
        assertEq(buyer.balance - holderBefore, 0.02 ether);
        assertEq(reserveManager.pendingReserveClaims(buyer, address(0)), 0);
        assertEq(reserveManager.totalPendingReserveClaims(address(0)), 0);
    }

    function testRejectingSmartWalletDoesNotBlockBurnAndCanClaimToEoa() public {
        _setTwoTierReservePolicy();
        RejectingReserveHolder holder = new RejectingReserveHolder();
        address payoutRecipient = address(0xBEEF);
        vm.deal(address(holder), 1 ether);

        uint256 gemId = _listedGem(1_000e18, "ipfs://rejecting-holder");
        vm.prank(address(holder));
        uint256 tokenId = sale.buyNow{value: 0.52 ether}(gemId, address(0), 0.52 ether);

        holder.openRedemption(redemption, tokenId, keccak256("rejecting-holder"));
        vm.prank(custodian);
        redemption.startFulfillment(tokenId);
        vm.prank(custodian);
        redemption.submitFulfillmentProof(tokenId, keccak256("rejecting-holder-proof"));
        redemption.approveFulfillmentProof(tokenId, keccak256("rejecting-holder-approval"), 1);
        uint256 custodianBefore = custodian.balance;
        {
            bytes32 nonce = keccak256("rejecting-holder-nonce");
            uint64 issuedAt = uint64(block.timestamp);
            uint64 deadline = issuedAt + 10 minutes;
            bytes32 digest = redemption.redemptionAuthorizationDigest(tokenId, nonce, issuedAt, deadline);
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(AUTHORIZER_KEY, digest);
            holder.finalize(
                redemption, tokenId, nonce, issuedAt, deadline, authorizationSigner, abi.encodePacked(r, s, v)
            );
        }

        vm.expectRevert();
        nft.ownerOf(tokenId);
        GemRegistry.Gem memory gem = registry.getGem(gemId);
        assertEq(uint256(gem.status), uint256(GemRegistry.GemStatus.Redeemed));
        assertEq(custodian.balance, custodianBefore);
        assertEq(reserveManager.pendingReserveClaims(address(holder), address(0)), 0.02 ether);

        uint256 recipientBefore = payoutRecipient.balance;
        holder.claim(reserveManager, address(0), payoutRecipient);
        assertEq(payoutRecipient.balance - recipientBefore, 0.02 ether);
        assertEq(reserveManager.pendingReserveClaims(address(holder), address(0)), 0);
    }

    function testMintSyncsProjectedLiabilityAndRedemptionClearsIt() public {
        _setTwoTierReservePolicy();
        uint256 gemId = _listedGem(1_000e18, "ipfs://liability-sync");

        vm.prank(buyer);
        uint256 tokenId = sale.buyNow{value: 0.52 ether}(gemId, address(0), 0.52 ether);

        assertEq(reserveManager.projectedLiabilityUsd(gemId), 40e18);
        assertEq(reserveManager.totalProjectedLiabilitiesUsd(), 40e18);

        _prepareApprovedRedemption(tokenId, keccak256("liability-clear"));
        _finalizeAsOwner(tokenId, buyer, keccak256("liability-clear-nonce"));

        assertEq(reserveManager.projectedLiabilityUsd(gemId), 0);
        assertEq(reserveManager.totalProjectedLiabilitiesUsd(), 0);
    }

    function testReserveBracketReadApi() public {
        _setTwoTierReservePolicy();

        assertEq(reserveManager.reserveBracketCount(), 2);
        ReserveManager.ReserveBracket memory first = reserveManager.reserveBracket(0);
        assertEq(first.minPriceUsd, 0);
        assertEq(first.maxPriceUsd, 1_000e18);
        assertEq(first.reserveBps, 1_000);
    }

    function testReserveBracketTableMustCoverTopRange() public {
        ReserveManager.ReserveBracket[] memory brackets = new ReserveManager.ReserveBracket[](1);
        brackets[0] = ReserveManager.ReserveBracket({minPriceUsd: 0, maxPriceUsd: 1_000e18, reserveBps: 1_000});

        vm.expectRevert(ReserveManager.InvalidReserveBracket.selector);
        reserveManager.setReserveBrackets(brackets);
    }

    function testPaymentAssetsAreEnumerableAcrossDisableAndReenable() public {
        assertEq(payments.paymentTokenCount(), 3);
        assertEq(payments.paymentTokenAt(0), address(0));
        assertEq(payments.paymentTokenAt(1), address(usdc));
        assertEq(payments.paymentTokenAt(2), address(feeToken));

        payments.removeToken(address(usdc));
        assertFalse(payments.isEnabled(address(usdc)));
        assertEq(payments.paymentTokenCount(), 3);

        _configurePaymentToken(address(usdc), address(usdFeed), 80_000_000, 120_000_000);
        assertTrue(payments.isEnabled(address(usdc)));
        assertEq(payments.paymentTokenCount(), 3);
    }

    function testV2BackfillIsIdempotentForAlreadyTrackedAssets() public {
        address[] memory existingTokens = new address[](2);
        existingTokens[0] = address(0);
        existingTokens[1] = address(usdc);

        payments.initializeV2(existingTokens);

        assertEq(payments.paymentTokenCount(), 3);
        assertEq(payments.paymentTokenAt(0), address(0));
        assertEq(payments.paymentTokenAt(1), address(usdc));
    }

    function testReserveManagerUpgradePreservesExistingAccountingAndConfiguration() public {
        uint256 gemId = _listedGem(1_000e18, "ipfs://reserve-upgrade-storage");
        reserveManager.setMinimumReserveUsd(gemId, 25e18);
        reserveManager.setProjectedLiabilityUsd(gemId, 40e18);
        reserveManager.recordModuleFunding{value: 0.02 ether}(gemId, address(0), 0.02 ether, 40e18);

        address paymentRegistryBefore = address(reserveManager.paymentRegistry());
        address registryBefore = address(reserveManager.registry());
        uint256 assetBalanceBefore = reserveManager.reserveAssetBalance(gemId, address(0));
        uint256 liabilityBefore = reserveManager.projectedLiabilityUsd(gemId);

        reserveManager.upgradeToAndCall(address(new ReserveManager()), bytes(""));

        assertEq(address(reserveManager.paymentRegistry()), paymentRegistryBefore);
        assertEq(address(reserveManager.registry()), registryBefore);
        assertEq(reserveManager.minimumReserveUsd(gemId), 25e18);
        assertEq(reserveManager.reserveAssetBalance(gemId, address(0)), assetBalanceBefore);
        assertEq(reserveManager.projectedLiabilityUsd(gemId), liabilityBefore);
        assertEq(reserveManager.pendingReserveClaims(buyer, address(0)), 0);
        assertEq(reserveManager.totalPendingReserveClaims(address(0)), 0);
    }
}

contract RejectingReserveHolder is IERC721Receiver {
    error RejectNative();

    receive() external payable {
        revert RejectNative();
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    function openRedemption(RedemptionManager redemption, uint256 tokenId, bytes32 requestHash) external {
        redemption.requestRedemption(tokenId, requestHash, keccak256(abi.encode("holder-workflow", tokenId)));
    }

    function claim(ReserveManager reserveManager, address asset, address recipient) external {
        reserveManager.claimReserveCredit(asset, recipient);
    }

    function finalize(
        RedemptionManager redemption,
        uint256 tokenId,
        bytes32 nonce,
        uint64 issuedAt,
        uint64 deadline,
        address authorizer,
        bytes calldata signature
    ) external {
        redemption.finalizeRedemption(tokenId, nonce, issuedAt, deadline, authorizer, signature);
    }
}
