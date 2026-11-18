// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {DGENFT} from "../src/DGENFT.sol";
import {Roles} from "../src/libraries/Roles.sol";
import {BaseTest} from "./BaseTest.t.sol";

/// @dev Correcting a minted token's metadata (its picture) without touching anything else.
contract TokenMetadataUpdateTest is BaseTest {
    event MetadataUpdate(uint256 _tokenId);
    event TokenURIUpdated(uint256 indexed tokenId, string uri);

    address internal metadataEditor = makeAddr("metadataEditor");

    function setUp() public override {
        super.setUp();
        nft.grantRole(Roles.METADATA_ROLE, metadataEditor);
    }

    function testMetadataRoleReplacesTokenUriAndAnnouncesIt() public {
        (uint256 gemId, uint256 tokenId) = _mintGemTo(buyer, 1_000e18, "ipfs://original");
        assertEq(nft.tokenURI(tokenId), "ipfs://original");

        vm.expectEmit(false, false, false, true, address(nft));
        emit MetadataUpdate(tokenId);
        vm.expectEmit(true, false, false, true, address(nft));
        emit TokenURIUpdated(tokenId, "ipfs://corrected");
        vm.prank(metadataEditor);
        nft.setTokenURI(tokenId, "ipfs://corrected");

        assertEq(nft.tokenURI(tokenId), "ipfs://corrected");
        // Ownership and the gem link are untouched; the registry keeps the original record.
        assertEq(nft.ownerOf(tokenId), buyer);
        assertEq(nft.tokenGem(tokenId), gemId);
        assertEq(registry.getGem(gemId).metadataURI, "ipfs://original");
    }

    function testOnlyMetadataRoleMayReplaceTokenUri() public {
        (, uint256 tokenId) = _mintGemTo(buyer, 1_000e18, "ipfs://original");
        bytes32 role = Roles.METADATA_ROLE;

        // Not the holder, and not the admin either: the role must be granted explicitly.
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, buyer, role));
        nft.setTokenURI(tokenId, "ipfs://hijack");

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), role)
        );
        nft.setTokenURI(tokenId, "ipfs://hijack");

        assertEq(nft.tokenURI(tokenId), "ipfs://original");
    }

    function testRefusesUnknownTokenAndEmptyUri() public {
        (, uint256 tokenId) = _mintGemTo(buyer, 1_000e18, "ipfs://original");

        vm.startPrank(metadataEditor);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, tokenId + 1));
        nft.setTokenURI(tokenId + 1, "ipfs://ghost");

        vm.expectRevert(DGENFT.InvalidTokenURI.selector);
        nft.setTokenURI(tokenId, "");
        vm.stopPrank();
    }

    function testUpgradeKeepsTokenUrisAndAddsTheSetter() public {
        (, uint256 tokenId) = _mintGemTo(buyer, 1_000e18, "ipfs://before-upgrade");

        nft.upgradeToAndCall(address(new DGENFT()), bytes(""));

        assertEq(nft.tokenURI(tokenId), "ipfs://before-upgrade");
        vm.prank(metadataEditor);
        nft.setTokenURI(tokenId, "ipfs://after-upgrade");
        assertEq(nft.tokenURI(tokenId), "ipfs://after-upgrade");
    }
}
