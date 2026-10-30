// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {DGENFT} from "../../src/DGENFT.sol";
import {GemRegistry} from "../../src/GemRegistry.sol";
import {PrimarySaleAuction} from "../../src/PrimarySaleAuction.sol";
import {Treasury} from "../../src/Treasury.sol";

/// @notice Rehearses the seller-mint upgrade against live Arbitrum One state.
/// @dev Skipped unless `ARBITRUM_FORK_URL` is set, so CI never depends on a public RPC:
///      ARBITRUM_FORK_URL=<rpc> forge test --match-contract SellerMintArbitrumForkTest -vv
///      The Safe is impersonated for the upgrade and the operator for the gem lifecycle; nothing is
///      broadcast.
contract SellerMintArbitrumForkTest is Test {
    address internal constant SAFE = 0xD420d1bdCFd89eC47437E6Ca97Bf32373a5C94A9;
    address internal constant OPERATOR = 0x89c2c9fA2711Fef55C55a07fd2A7A3bb81505D53;
    DGENFT internal constant NFT = DGENFT(0x603687aBbc6504Bc6EA8836fA44cFBaE92b42D4E);
    GemRegistry internal constant REGISTRY = GemRegistry(0x195f80cB544Ab5FDEE5F92C318F92F004C0aF08c);
    PrimarySaleAuction internal constant SALE = PrimarySaleAuction(payable(0xdC7440e02e1dD5bD64FcBe36eA2f4f67A6d56cA3));
    Treasury internal constant TREASURY = Treasury(payable(0x4F5113644d5A0314D52Db5E4a2EBC247B661b417));

    struct GemSnapshot {
        GemRegistry.Gem gem;
        GemRegistry.PrimarySaleMode mode;
        bool auctionActive;
        bytes auction;
    }

    function setUp() public {
        string memory url = vm.envOr("ARBITRUM_FORK_URL", string(""));
        if (bytes(url).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(url);
        assertEq(block.chainid, 42161);
    }

    function _implementation(address proxy) private view returns (address) {
        return address(uint160(uint256(vm.load(proxy, ERC1967Utils.IMPLEMENTATION_SLOT))));
    }

    function _snapshot() private view returns (GemSnapshot[] memory snaps, uint256 count) {
        snaps = new GemSnapshot[](200);
        for (uint256 gemId = 1; gemId <= 200; gemId++) {
            try REGISTRY.getGem(gemId) returns (GemRegistry.Gem memory gem) {
                (bool ok, bytes memory auction) =
                    address(SALE).staticcall(abi.encodeWithSignature("auctions(uint256)", gemId));
                require(ok, "auctions() read failed");
                snaps[count++] = GemSnapshot({
                    gem: gem,
                    mode: REGISTRY.primarySaleMode(gemId),
                    auctionActive: REGISTRY.primaryAuctionActive(gemId),
                    auction: auction
                });
            } catch {
                break;
            }
        }
    }

    function _upgrade() private {
        address registryImpl = address(new GemRegistry());
        address saleImpl = address(new PrimarySaleAuction());
        // GemRegistry first, so PSA never reads a mode the registry cannot encode.
        vm.startPrank(SAFE);
        REGISTRY.upgradeToAndCall(registryImpl, bytes(""));
        SALE.upgradeToAndCall(saleImpl, bytes(""));
        vm.stopPrank();
        assertEq(_implementation(address(REGISTRY)), registryImpl);
        assertEq(_implementation(address(SALE)), saleImpl);
    }

    function testUpgradePreservesStateAndSellerMintWorksOnLiveConfig() public {
        (GemSnapshot[] memory before, uint256 count) = _snapshot();
        address platformRecipient = TREASURY.platformRecipient();
        emit log_named_uint("gems on chain", count);

        _upgrade();

        // Every existing gem, sale mode and auction record reads back unchanged.
        (GemSnapshot[] memory afterUpgrade, uint256 countAfter) = _snapshot();
        assertEq(countAfter, count);
        for (uint256 i = 0; i < count; i++) {
            assertEq(abi.encode(afterUpgrade[i].gem), abi.encode(before[i].gem), "gem changed");
            assertEq(uint256(afterUpgrade[i].mode), uint256(before[i].mode), "mode changed");
            assertEq(afterUpgrade[i].auctionActive, before[i].auctionActive, "auction flag changed");
            assertEq(afterUpgrade[i].auction, before[i].auction, "auction record changed");
        }
        assertEq(SALE.sellerMintFeeUsd(), 0);

        // Full seller-mint lifecycle with the live operator roles and live reserve policy.
        address seller = makeAddr("fork-seller");
        vm.startPrank(OPERATOR);
        REGISTRY.setSellerApproval(seller, true);
        uint256 gemId = REGISTRY.registerGem(seller, OPERATOR, "ipfs://fork-seller-mint", keccak256("fork-cert"));
        REGISTRY.confirmCustody(gemId);
        REGISTRY.verifyGem(gemId, keccak256("fork-valuation"), keccak256("fork-matrix"), 500e18);
        REGISTRY.listGem(gemId, 500e18, GemRegistry.PrimarySaleMode.SellerMint);
        uint256 tokenId = SALE.mintToSeller(gemId, address(0), 0);
        vm.stopPrank();

        assertEq(NFT.ownerOf(tokenId), seller);
        assertEq(uint256(REGISTRY.getGem(gemId).status), uint256(GemRegistry.GemStatus.Minted));

        // The Safe can introduce a fee; the seller then pays it to the platform recipient in ETH.
        vm.prank(SAFE);
        SALE.setSellerMintFeeUsd(1e18);
        address seller2 = makeAddr("fork-seller-2");
        vm.deal(seller2, 1 ether);
        vm.startPrank(OPERATOR);
        REGISTRY.setSellerApproval(seller2, true);
        uint256 gemId2 = REGISTRY.registerGem(seller2, OPERATOR, "ipfs://fork-seller-mint-2", keccak256("fork-cert-2"));
        REGISTRY.confirmCustody(gemId2);
        REGISTRY.verifyGem(gemId2, keccak256("fork-valuation-2"), keccak256("fork-matrix"), 500e18);
        REGISTRY.listGem(gemId2, 500e18, GemRegistry.PrimarySaleMode.SellerMint);
        vm.expectRevert(PrimarySaleAuction.NotSeller.selector);
        SALE.mintToSeller(gemId2, address(0), 0);
        vm.stopPrank();

        uint256 platformBefore = platformRecipient.balance;
        uint256 pendingBefore = SALE.pendingRefunds(platformRecipient, address(0));
        vm.prank(seller2);
        uint256 tokenId2 = SALE.mintToSeller{value: 0.01 ether}(gemId2, address(0), 0.01 ether);
        assertEq(NFT.ownerOf(tokenId2), seller2);
        assertEq(tokenId2, tokenId + 1);
        uint256 feeReceived = platformRecipient.balance - platformBefore
            + SALE.pendingRefunds(platformRecipient, address(0)) - pendingBefore;
        assertGt(feeReceived, 0);
        emit log_named_uint("fee received by platform (wei) for $1", feeReceived);
    }
}
