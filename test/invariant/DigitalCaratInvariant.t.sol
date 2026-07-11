// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DigitalCaratHandler} from "./DigitalCaratHandler.t.sol";
import {BaseTest} from "../BaseTest.t.sol";

contract DigitalCaratInvariantTest is StdInvariant, BaseTest {
    DigitalCaratHandler internal handler;

    function setUp() public override {
        super.setUp();
        address[6] memory actors = [admin, seller, buyer, bidder, custodian, stranger];
        handler = new DigitalCaratHandler(
            DigitalCaratHandler.Protocol({
                nft: nft,
                registry: registry,
                reserveManager: reserveManager,
                compliance: compliance,
                sale: sale,
                redemption: redemption,
                marketplace: marketplace,
                swapEscrow: swapEscrow,
                usdc: usdc
            }),
            actors
        );

        bytes4[] memory selectors = new bytes4[](26);
        selectors[0] = DigitalCaratHandler.registerListedGem.selector;
        selectors[1] = DigitalCaratHandler.withdrawListedGem.selector;
        selectors[2] = DigitalCaratHandler.buyNow.selector;
        selectors[3] = DigitalCaratHandler.createDailyAuction.selector;
        selectors[4] = DigitalCaratHandler.bidAuction.selector;
        selectors[5] = DigitalCaratHandler.settleAuction.selector;
        selectors[6] = DigitalCaratHandler.warpForward.selector;
        selectors[7] = DigitalCaratHandler.listToken.selector;
        selectors[8] = DigitalCaratHandler.cancelListing.selector;
        selectors[9] = DigitalCaratHandler.buyListing.selector;
        selectors[10] = DigitalCaratHandler.createMarketplaceOffer.selector;
        selectors[11] = DigitalCaratHandler.createNativeMarketplaceOffer.selector;
        selectors[12] = DigitalCaratHandler.acceptMarketplaceOffer.selector;
        selectors[13] = DigitalCaratHandler.cancelExpiredMarketplaceOffer.selector;
        selectors[14] = DigitalCaratHandler.fundReserve.selector;
        selectors[15] = DigitalCaratHandler.consumeReserve.selector;
        selectors[16] = DigitalCaratHandler.setProjectedLiability.selector;
        selectors[17] = DigitalCaratHandler.configureSolvency.selector;
        selectors[18] = DigitalCaratHandler.createSwap.selector;
        selectors[19] = DigitalCaratHandler.cancelSwap.selector;
        selectors[20] = DigitalCaratHandler.acceptSwap.selector;
        selectors[21] = DigitalCaratHandler.setBlocked.selector;
        selectors[22] = DigitalCaratHandler.requestRedemption.selector;
        selectors[23] = DigitalCaratHandler.cancelRedemption.selector;
        selectors[24] = DigitalCaratHandler.confirmRedemption.selector;
        selectors[25] = DigitalCaratHandler.transferToken.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_registryNftConsistency() public view {
        handler.assertRegistryNftConsistency();
    }

    function invariant_reserveAccounting() public view {
        handler.assertReserveAccounting();
    }

    function invariant_escrowConsistency() public view {
        handler.assertEscrowConsistency();
    }

    function invariant_auctionEscrowConsistency() public view {
        handler.assertAuctionEscrowConsistency();
    }
}
