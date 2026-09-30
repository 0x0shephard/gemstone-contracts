// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {DeployDigitalCarat} from "./DeployDigitalCarat.s.sol";
import {GemRegistry} from "../src/GemRegistry.sol";
import {SepoliaMockUSDC} from "../src/mocks/SepoliaMockUSDC.sol";
import {SepoliaMockUsdFeed} from "../src/mocks/SepoliaMockUsdFeed.sol";
import {SepoliaMockUSDCFaucet} from "../src/mocks/SepoliaMockUSDCFaucet.sol";
import {Roles} from "../src/libraries/Roles.sol";

/// @notice Deploys and seeds a complete protocol on a local anvil chain for the
///         frontend end-to-end suite. Never run against a public network.
/// @dev The chain keeps Sepolia's id so the app and edge functions need no test
///      branches; the guard below refuses anything but a local anvil node.
///      Prints one `E2E_DEPLOYMENT {json}` line for the harness to parse.
contract DeployLocalE2E is Script {
    struct Actors {
        uint256 adminKey;
        uint256 custodianKey;
        uint256 aliceKey;
        uint256 bobKey;
        address admin;
        address operator;
        address custodian;
        address seller;
        address alice;
        address bob;
    }

    struct Mocks {
        SepoliaMockUSDC usdc;
        SepoliaMockUsdFeed usdFeed;
        SepoliaMockUsdFeed ethFeed;
        SepoliaMockUSDCFaucet faucet;
    }

    struct Seeded {
        uint256 listedGem;
        uint256 aliceTokenOne;
        uint256 aliceTokenTwo;
        uint256 aliceGiftToken;
        uint256 aliceKeptToken;
        uint256 aliceFaultToken;
        uint256 aliceResumeToken;
        uint256 bobToken;
    }

    function run() external {
        // anvil_nodeInfo only exists on a local anvil node; a public RPC reverts here.
        vm.rpc("anvil_nodeInfo", "[]");
        Actors memory a = _actors();
        Mocks memory m = _deployMocks(a);
        _configureDeploymentEnv(m);
        DeployDigitalCarat.Deployment memory d = new DeployDigitalCarat().run();
        Seeded memory seeded = _seed(d, a, m);
        _print(d, m, seeded);
    }

    function _actors() private view returns (Actors memory a) {
        a.adminKey = vm.envUint("PRIVATE_KEY");
        a.custodianKey = vm.envUint("E2E_CUSTODIAN_KEY");
        a.aliceKey = vm.envUint("E2E_ALICE_KEY");
        a.bobKey = vm.envUint("E2E_BOB_KEY");
        a.admin = vm.addr(a.adminKey);
        a.operator = vm.envAddress("GIFT_OPERATOR_ADDRESS");
        a.custodian = vm.addr(a.custodianKey);
        a.seller = vm.envAddress("E2E_SELLER");
        a.alice = vm.addr(a.aliceKey);
        a.bob = vm.addr(a.bobKey);
    }

    function _deployMocks(Actors memory a) private returns (Mocks memory m) {
        vm.startBroadcast(a.adminKey);
        m.usdc = new SepoliaMockUSDC(a.admin, a.admin, 10_000_000e6);
        m.usdFeed = new SepoliaMockUsdFeed(a.admin, 1e8);
        m.ethFeed = new SepoliaMockUsdFeed(a.admin, 2_000e8);
        m.usdc.transfer(a.alice, 100_000e6);
        m.usdc.transfer(a.bob, 100_000e6);
        m.faucet = new SepoliaMockUSDCFaucet(a.admin, m.usdc);
        m.usdc.transferOwnership(address(m.faucet));
        vm.stopBroadcast();
    }

    function _configureDeploymentEnv(Mocks memory m) private {
        vm.setEnv("ETH_USD_FEED", vm.toString(address(m.ethFeed)));
        vm.setEnv("ETH_USD_MIN_ANSWER", "50000000000");
        vm.setEnv("ETH_USD_MAX_ANSWER", "1000000000000");
        vm.setEnv("PRICE_STALE_AFTER", "86400");
        vm.setEnv("PAYMENT_TOKENS", vm.toString(address(m.usdc)));
        vm.setEnv("PAYMENT_TOKEN_USD_FEEDS", vm.toString(address(m.usdFeed)));
        vm.setEnv("PAYMENT_TOKEN_MIN_ANSWERS", "80000000");
        vm.setEnv("PAYMENT_TOKEN_MAX_ANSWERS", "120000000");
        vm.setEnv("DEFAULT_RESERVE_BPS", "1000");
        vm.setEnv(
            "RESERVE_BRACKET_MAX_USD",
            "1000000000000000000000,115792089237316195423570985008687907853269984665640564039457584007913129639935"
        );
        vm.setEnv("RESERVE_BRACKET_BPS", "1500,1000");
    }

    function _seed(DeployDigitalCarat.Deployment memory d, Actors memory a, Mocks memory)
        private
        returns (Seeded memory seeded)
    {
        vm.startBroadcast(a.adminKey);
        d.registry.grantRole(Roles.CUSTODIAN_ROLE, a.custodian);
        d.registry.setSellerApproval(a.seller, true);
        uint256[8] memory gems = [
            _register(d.registry, a, "Listed Ruby"),
            _register(d.registry, a, "Alice Sapphire"),
            _register(d.registry, a, "Alice Emerald"),
            _register(d.registry, a, "Bob Spinel"),
            _register(d.registry, a, "Alice Opal"),
            _register(d.registry, a, "Alice Topaz"),
            _register(d.registry, a, "Alice Garnet"),
            _register(d.registry, a, "Alice Pearl")
        ];
        vm.stopBroadcast();

        vm.startBroadcast(a.custodianKey);
        for (uint256 i = 0; i < gems.length; i++) {
            d.registry.confirmCustody(gems[i]);
        }
        vm.stopBroadcast();

        vm.startBroadcast(a.adminKey);
        for (uint256 i = 0; i < gems.length; i++) {
            d.registry.verifyGem(gems[i], keccak256(abi.encode("e2e", gems[i])), keccak256("e2e-matrix"), 1_000e18);
            d.registry.listGem(gems[i], 1_000e18, GemRegistry.PrimarySaleMode.BuyNow);
        }
        vm.stopBroadcast();

        // $1,000 at $2,000/ETH plus its 10% reserve.
        seeded.listedGem = gems[0];
        vm.startBroadcast(a.aliceKey);
        seeded.aliceTokenOne = d.sale.buyNow{value: 0.55 ether}(gems[1], address(0), 0.55 ether);
        seeded.aliceTokenTwo = d.sale.buyNow{value: 0.55 ether}(gems[2], address(0), 0.55 ether);
        seeded.aliceGiftToken = d.sale.buyNow{value: 0.55 ether}(gems[4], address(0), 0.55 ether);
        // Never moved by any journey, so "your own tokens are not offered" stays testable.
        seeded.aliceKeptToken = d.sale.buyNow{value: 0.55 ether}(gems[5], address(0), 0.55 ether);
        seeded.aliceFaultToken = d.sale.buyNow{value: 0.55 ether}(gems[6], address(0), 0.55 ether);
        seeded.aliceResumeToken = d.sale.buyNow{value: 0.55 ether}(gems[7], address(0), 0.55 ether);
        vm.stopBroadcast();
        vm.startBroadcast(a.bobKey);
        seeded.bobToken = d.sale.buyNow{value: 0.55 ether}(gems[3], address(0), 0.55 ether);
        vm.stopBroadcast();
    }

    function _print(DeployDigitalCarat.Deployment memory d, Mocks memory m, Seeded memory seeded) private {
        string memory key = "deployment";
        vm.serializeAddress(key, "DGENFT", address(d.nft));
        vm.serializeAddress(key, "GemRegistry", address(d.registry));
        vm.serializeAddress(key, "PaymentTokenRegistry", address(d.payments));
        vm.serializeAddress(key, "ReserveManager", address(d.reserveManager));
        vm.serializeAddress(key, "ComplianceRegistry", address(d.compliance));
        vm.serializeAddress(key, "Treasury", address(d.treasury));
        vm.serializeAddress(key, "PrimarySaleAuction", address(d.sale));
        vm.serializeAddress(key, "RedemptionManager", address(d.redemption));
        vm.serializeAddress(key, "Marketplace", address(d.marketplace));
        vm.serializeAddress(key, "SwapEscrow", address(d.swapEscrow));
        vm.serializeAddress(key, "MockUSDC", address(m.usdc));
        vm.serializeAddress(key, "MusdcFaucet", address(m.faucet));
        vm.serializeAddress(key, "EthUsdFeed", address(m.ethFeed));
        vm.serializeAddress(key, "UsdcUsdFeed", address(m.usdFeed));
        vm.serializeUint(key, "listedGem", seeded.listedGem);
        vm.serializeUint(key, "aliceTokenOne", seeded.aliceTokenOne);
        vm.serializeUint(key, "aliceTokenTwo", seeded.aliceTokenTwo);
        vm.serializeUint(key, "aliceGiftToken", seeded.aliceGiftToken);
        vm.serializeUint(key, "aliceKeptToken", seeded.aliceKeptToken);
        vm.serializeUint(key, "aliceFaultToken", seeded.aliceFaultToken);
        vm.serializeUint(key, "aliceResumeToken", seeded.aliceResumeToken);
        string memory json = vm.serializeUint(key, "bobToken", seeded.bobToken);
        console2.log("E2E_DEPLOYMENT", json);
    }

    function _register(GemRegistry registry, Actors memory a, string memory name) private returns (uint256) {
        string memory uri = _metadata(name);
        return registry.registerGem(a.seller, a.custodian, uri, keccak256(bytes(uri)));
    }

    /// @dev Inline metadata, so the suite needs no IPFS gateway.
    function _metadata(string memory name) private pure returns (string memory) {
        string memory image = string.concat(
            "data:image/svg+xml;base64,",
            Base64.encode(
                bytes(
                    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><circle cx="32" cy="32" r="24" fill="#8a7550"/></svg>'
                )
            )
        );
        return string.concat(
            "data:application/json;base64,",
            Base64.encode(
                bytes(
                    string.concat(
                        '{"name":"',
                        name,
                        '","image":"',
                        image,
                        '","attributes":[{"trait_type":"Gem Type","value":"sapphire"},{"trait_type":"Carat Weight","value":"',
                        Strings.toString(2),
                        '"}]}'
                    )
                )
            )
        );
    }
}
