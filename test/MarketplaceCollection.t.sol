// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import {DGENFT} from "../src/DGENFT.sol";
import {Roles} from "../src/libraries/Roles.sol";
import {BaseTest} from "./BaseTest.t.sol";

/// @dev The collection-level surface outside marketplaces (OpenSea and others) read.
contract MarketplaceCollectionTest is BaseTest {
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event ContractURIUpdated();

    function testCollectionOwnerIsDisplayOnlyAndAdminSet() public {
        assertEq(nft.owner(), address(0));

        vm.expectEmit(true, true, false, false, address(nft));
        emit OwnershipTransferred(address(0), seller);
        nft.setCollectionOwner(seller);
        assertEq(nft.owner(), seller);

        // Being the collection owner grants nothing in the contract itself.
        assertFalse(nft.hasRole(nft.DEFAULT_ADMIN_ROLE(), seller));
        assertFalse(nft.hasRole(Roles.MINTER_ROLE, seller));
        bytes32 adminRole = nft.DEFAULT_ADMIN_ROLE();
        vm.prank(seller);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, seller, adminRole)
        );
        nft.setCollectionOwner(stranger);

        nft.setCollectionOwner(address(0));
        assertEq(nft.owner(), address(0));
    }

    function testContractUriIsAdminSetAndAnnounced() public {
        assertEq(nft.contractURI(), "");

        vm.expectEmit(false, false, false, false, address(nft));
        emit ContractURIUpdated();
        nft.setContractURI("https://digitalcarat.io/collection.json");
        assertEq(nft.contractURI(), "https://digitalcarat.io/collection.json");

        bytes32 adminRole = nft.DEFAULT_ADMIN_ROLE();
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, adminRole)
        );
        nft.setContractURI("https://evil.example/collection.json");
    }

    function testRoyaltyIsAdvertisedThroughErc2981() public {
        assertTrue(nft.supportsInterface(type(IERC2981).interfaceId));
        nft.setDefaultRoyalty(platform, 250);
        (address receiver, uint256 amount) = nft.royaltyInfo(1, 1 ether);
        assertEq(receiver, platform);
        assertEq(amount, 0.025 ether);
    }

    function testUpgradeKeepsTokensAndStartsWithNoCollectionSettings() public {
        (uint256 gemId, uint256 tokenId) = _mintGemTo(buyer, 1_000e18, "ipfs://collection-upgrade");
        address reserveManagerBefore = address(nft.reserveManager());

        nft.upgradeToAndCall(address(new DGENFT()), bytes(""));

        assertEq(nft.ownerOf(tokenId), buyer);
        assertEq(nft.tokenGem(tokenId), gemId);
        assertEq(address(nft.reserveManager()), reserveManagerBefore);
        assertTrue(nft.trustedEscrow(address(marketplace)));
        assertEq(nft.owner(), address(0));
        assertEq(nft.contractURI(), "");
    }
}
