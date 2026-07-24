// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PaymentTokenRegistry} from "../src/PaymentTokenRegistry.sol";
import {ReserveManager} from "../src/ReserveManager.sol";
import {BaseTest} from "./BaseTest.t.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV3Aggregator} from "./mocks/MockV3Aggregator.sol";

contract PaymentArithmeticFuzzTest is BaseTest {
    function testFuzz_quoteTokenToUsdMatchesDecimals(
        uint8 tokenDecimalsSeed,
        uint8 feedDecimalsSeed,
        uint256 amountSeed,
        uint256 answerSeed
    ) public {
        uint8 tokenDecimals = uint8(bound(tokenDecimalsSeed, 0, 18));
        uint8 feedDecimals = uint8(bound(feedDecimalsSeed, 0, 18));
        uint256 amount = bound(amountSeed, 1, 1e30);
        int256 answer = int256(bound(answerSeed, 1, 1e20));

        MockERC20 token = new MockERC20("Fuzz Token", "FZZ", tokenDecimals);
        MockV3Aggregator feed = new MockV3Aggregator(feedDecimals, answer);
        payments.setToken(address(token), address(feed), 1 days, false);
        payments.setTokenBounds(address(token), 1, type(int192).max);
        payments.setToken(address(token), address(feed), 1 days, true);

        // casting is safe because `answer` is bounded to a positive value above.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 unsignedAnswer = uint256(answer);
        uint256 expected =
            (amount * unsignedAnswer * payments.USD_DECIMALS()) / (10 ** tokenDecimals) / (10 ** feedDecimals);
        if (expected == 0) {
            vm.expectRevert(PaymentTokenRegistry.InvalidPrice.selector);
            payments.quoteTokenToUsd(address(token), amount);
        } else {
            assertEq(payments.quoteTokenToUsd(address(token), amount), expected);
        }
    }

    function testFuzz_quoteUsdToTokenRoundsUpAndCoversQuote(
        uint8 tokenDecimalsSeed,
        uint8 feedDecimalsSeed,
        uint256 usdValueSeed,
        uint256 answerSeed
    ) public {
        uint8 tokenDecimals = uint8(bound(tokenDecimalsSeed, 0, 18));
        uint8 feedDecimals = uint8(bound(feedDecimalsSeed, 0, 18));
        uint256 usdValue = bound(usdValueSeed, 1, 1e30);
        int256 answer = int256(bound(answerSeed, 1, 1e20));

        MockERC20 token = new MockERC20("Inverse Quote Token", "IQT", tokenDecimals);
        MockV3Aggregator feed = new MockV3Aggregator(feedDecimals, answer);
        payments.setToken(address(token), address(feed), 1 days, false);
        payments.setTokenBounds(address(token), 1, type(int192).max);
        payments.setToken(address(token), address(feed), 1 days, true);

        uint256 tokenAmount = payments.quoteUsdToToken(address(token), usdValue);
        assertGe(payments.quoteTokenToUsd(address(token), tokenAmount), usdValue);
        if (tokenAmount > 1) {
            try payments.quoteTokenToUsd(address(token), tokenAmount - 1) returns (uint256 previousQuote) {
                assertLt(previousQuote, usdValue);
            } catch (bytes memory reason) {
                // the revert payload is known to contain at least the four-byte custom-error selector.
                // forge-lint: disable-next-line(unsafe-typecast)
                bytes4 reasonSelector = bytes4(reason);
                assertEq(reasonSelector, PaymentTokenRegistry.InvalidPrice.selector);
            }
        }
    }

    function testFuzz_buyNowReserveFundingCoversRequiredReserve(uint256 priceSeed, uint16 reserveBpsSeed) public {
        uint256 priceUsd = bound(priceSeed, 100, 1_000_000) * 1e18;
        uint16 reserveBps = uint16(bound(reserveBpsSeed, 1, 5_000));

        ReserveManager.ReserveBracket[] memory brackets = new ReserveManager.ReserveBracket[](1);
        brackets[0] =
            ReserveManager.ReserveBracket({minPriceUsd: 0, maxPriceUsd: type(uint256).max, reserveBps: reserveBps});
        reserveManager.setReserveBrackets(brackets);

        uint256 gemId = _listedGem(priceUsd, "ipfs://fuzz-reserve");
        uint256 requiredReserveUsd = reserveManager.requiredReserveUsd(gemId, priceUsd);
        uint256 totalUsd = priceUsd + requiredReserveUsd;
        uint256 amount = (totalUsd + 1_999) / 2_000;
        vm.deal(buyer, amount);

        vm.prank(buyer);
        uint256 tokenId = sale.buyNow{value: amount}(gemId, address(0), amount);

        assertEq(nft.ownerOf(tokenId), buyer);
        assertGe(reserveManager.reserveBalanceUsd(gemId), requiredReserveUsd);
        assertGe(reserveManager.reserveAssetBalance(gemId, address(0)), requiredReserveUsd / 2_000);
    }
}
