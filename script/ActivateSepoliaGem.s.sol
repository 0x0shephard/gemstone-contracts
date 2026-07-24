// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {GemRegistry} from "../src/GemRegistry.sol";
import {PrimarySaleAuction} from "../src/PrimarySaleAuction.sol";

/// @notice Operator-only activation path from approved evidence to a listed primary sale.
contract ActivateSepoliaGem is Script {
    struct ActivationConfig {
        address seller;
        address custodian;
        string metadataUri;
        bytes32 certificateHash;
        bytes32 valuationHash;
        bytes32 valuationMatrixHash;
        uint256 approvedValuationUsd;
        uint256 saleModeValue;
    }

    function run() external returns (uint256 gemId) {
        uint256 operatorKey = vm.envUint("PRIVATE_KEY");
        address operator = vm.addr(operatorKey);
        ActivationConfig memory config = _loadConfig(operator);
        GemRegistry registry = GemRegistry(vm.envAddress("GEM_REGISTRY_ADDRESS"));
        GemRegistry.PrimarySaleMode saleMode = GemRegistry.PrimarySaleMode(config.saleModeValue);

        vm.startBroadcast(operatorKey);
        if (!registry.sellerApproved(config.seller)) registry.setSellerApproval(config.seller, true);
        gemId = registry.registerGem(config.seller, config.custodian, config.metadataUri, config.certificateHash);
        registry.confirmCustody(gemId);
        registry.verifyGem(gemId, config.valuationHash, config.valuationMatrixHash, config.approvedValuationUsd);
        registry.listGem(gemId, config.approvedValuationUsd, saleMode);
        if (saleMode == GemRegistry.PrimarySaleMode.Auction) {
            uint256 floorUsd = vm.envOr("GEM_AUCTION_FLOOR_USD", config.approvedValuationUsd);
            PrimarySaleAuction sale = PrimarySaleAuction(payable(vm.envAddress("PRIMARY_SALE_AUCTION_ADDRESS")));
            sale.createDailyAuction(gemId, floorUsd);
        }
        vm.stopBroadcast();

        console2.log("Digital Carat gem activated");
        console2.log("gemId", gemId);
        console2.log("seller", config.seller);
        console2.log("custodian", config.custodian);
        console2.log("approvedValuationUsd", config.approvedValuationUsd);
        console2.log("saleMode", config.saleModeValue);
    }

    function _loadConfig(address operator) private view returns (ActivationConfig memory config) {
        config = ActivationConfig({
            seller: vm.envAddress("GEM_SELLER"),
            custodian: vm.envOr("GEM_CUSTODIAN", operator),
            metadataUri: vm.envString("GEM_METADATA_URI"),
            certificateHash: vm.envBytes32("GEM_CERTIFICATE_HASH"),
            valuationHash: vm.envBytes32("GEM_VALUATION_HASH"),
            valuationMatrixHash: vm.envBytes32("GEM_VALUATION_MATRIX_HASH"),
            approvedValuationUsd: vm.envUint("GEM_APPROVED_VALUATION_USD"),
            saleModeValue: vm.envUint("GEM_SALE_MODE")
        });
        require(config.seller != address(0), "GEM_SELLER missing");
        require(config.custodian == operator, "Custodian signer must run confirmation");
        require(bytes(config.metadataUri).length != 0, "GEM_METADATA_URI missing");
        require(config.certificateHash != bytes32(0), "GEM_CERTIFICATE_HASH missing");
        require(config.valuationHash != bytes32(0), "GEM_VALUATION_HASH missing");
        require(config.valuationMatrixHash != bytes32(0), "GEM_VALUATION_MATRIX_HASH missing");
        require(config.approvedValuationUsd != 0, "GEM_APPROVED_VALUATION_USD missing");
        require(config.saleModeValue == 1 || config.saleModeValue == 2, "GEM_SALE_MODE must be 1 or 2");
    }
}
