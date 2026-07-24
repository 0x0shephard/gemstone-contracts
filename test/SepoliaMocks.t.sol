// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SepoliaMockUSDC} from "../src/mocks/SepoliaMockUSDC.sol";
import {SepoliaMockUsdFeed} from "../src/mocks/SepoliaMockUsdFeed.sol";

contract SepoliaMocksTest is Test {
    address private owner = makeAddr("owner");
    address private holder = makeAddr("holder");
    address private user = makeAddr("user");

    SepoliaMockUSDC private token;
    SepoliaMockUsdFeed private feed;

    function setUp() public {
        token = new SepoliaMockUSDC(owner, holder, 1_000_000e6);
        feed = new SepoliaMockUsdFeed(owner, 1e8);
    }

    function testMockUsdcUsesSixDecimalsAndOwnerMinting() public {
        assertEq(token.name(), "Digital Carat Mock USDC");
        assertEq(token.symbol(), "mUSDC");
        assertEq(token.decimals(), 6);
        assertEq(token.balanceOf(holder), 1_000_000e6);

        vm.prank(owner);
        token.mint(user, 250e6);
        assertEq(token.balanceOf(user), 250e6);
    }

    function testNonOwnerCannotMintOrUpdateFeed() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        vm.prank(user);
        token.mint(user, 1e6);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        vm.prank(user);
        feed.setAnswer(99_000_000);
    }

    function testFeedIsChainlinkCompatibleAndRefreshable() public {
        assertEq(feed.decimals(), 8);
        assertEq(feed.description(), "Digital Carat Mock USDC / USD");

        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = feed.latestRoundData();
        assertEq(roundId, 1);
        assertEq(answer, 1e8);
        assertEq(updatedAt, block.timestamp);
        assertEq(answeredInRound, roundId);

        vm.warp(block.timestamp + 1 days);
        vm.prank(owner);
        feed.refresh();

        (roundId, answer,, updatedAt, answeredInRound) = feed.latestRoundData();
        assertEq(roundId, 2);
        assertEq(answer, 1e8);
        assertEq(updatedAt, block.timestamp);
        assertEq(answeredInRound, roundId);
    }

    function testFeedRejectsInvalidAnswer() public {
        vm.expectRevert(SepoliaMockUsdFeed.InvalidAnswer.selector);
        vm.prank(owner);
        feed.setAnswer(0);
    }
}
