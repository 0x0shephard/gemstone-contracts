# Digital Carat Smart Contracts

Foundry implementation of the Digital Carat gemstone-backed NFT protocol.

## Overview

The protocol mints DGE NFTs, ERC-721 tokens representing claims over specific verified gemstones. Minting is gated by seller approval, recorded custodian confirmation, verifier approval, listing approval, payment, and reserve funding.

Core modules:

- `DGENFT`
- `GemRegistry`
- `PaymentTokenRegistry`
- `ReserveManager`
- `Treasury`
- `PrimarySaleAuction`
- `Marketplace`
- `SwapEscrow`
- `RedemptionManager`

See [docs/current-smart-contract-architecture.md](docs/current-smart-contract-architecture.md) for the current smart contract architecture.

See [docs/off-chain-data-architecture.md](docs/off-chain-data-architecture.md) for the recommended backend, metadata, and private data storage model.

## Build And Test

```sh
forge fmt --check
forge build --sizes
forge test --offline -vvv
```

`forge test --offline` is used in this local macOS sandbox because non-offline Forge can crash while initializing online signature lookup.

## Deployment

Deploy ERC1967 proxies and configure initial payment/reserve policy:

```sh
forge script script/DeployDigitalCarat.s.sol:DeployDigitalCarat \
  --rpc-url "$RPC_URL" \
  --broadcast
```

Required env vars:

```sh
PRIVATE_KEY=
RPC_URL=
EXPECTED_CHAIN_ID=
PRODUCTION_DEPLOYMENT=false
ETH_USD_FEED=
ETH_USD_MIN_ANSWER=
ETH_USD_MAX_ANSWER=
PRICE_STALE_AFTER=86400
DEFAULT_RESERVE_BPS=1000
RESERVE_BRACKET_MAX_USD=1000000000000000000000,115792089237316195423570985008687907853269984665640564039457584007913129639935
RESERVE_BRACKET_BPS=1500,1000
```

For Ethereum Sepolia, copy `.env.sepolia.example` to `.env`, add a dedicated
testnet deployer key and RPC URL locally, and confirm the proposed fee, reserve,
recipient, oracle-bound, and staleness settings before broadcasting. Never
commit `.env`.

Optional env vars:

```sh
PLATFORM_RECIPIENT=
VAULT_RESERVE_RECIPIENT=
INSURANCE_RESERVE_RECIPIENT=
TREASURY_RESERVE_RECIPIENT=
SECONDARY_FEE_BPS=200
PAYMENT_TOKENS=0xToken1,0xToken2
PAYMENT_TOKEN_USD_FEEDS=0xFeed1,0xFeed2
PAYMENT_TOKEN_MIN_ANSWERS=80000000,80000000
PAYMENT_TOKEN_MAX_ANSWERS=120000000,120000000
```

Notes:

- Native ETH is configured from `ETH_USD_FEED` and its mandatory minimum/maximum answer bounds.
- ERC-20 payment tokens are configured from optional comma-separated token/feed/minimum/maximum lists. All four lists must have equal length. Token symbols and decimal counts are discovered at runtime, so the same contracts support production USDC, USDT, or another approved asset on any EVM L2.
- Reserve bracket values are 18-decimal USD values.
- Bracket minimums are inferred from zero and the previous bracket max.
- Recipient env vars default to the deployer if omitted.
- `EXPECTED_CHAIN_ID` prevents a deployment through the wrong RPC. Set
  `PRODUCTION_DEPLOYMENT=true` for a live-value L2; the script then rejects
  Sepolia, deployer-default treasury recipients, and a missing production
  stablecoin.
- `SECONDARY_FEE_BPS` defaults to `200` when omitted.

### Optional Sepolia payment mocks

For isolated testnet testing, deploy the owner-mintable six-decimal `mUSDC`
token and owner-operated eight-decimal USD feed:

```sh
forge script script/DeploySepoliaMocks.s.sol:DeploySepoliaMocks \
  --rpc-url "$SEPOLIA_RPC_URL" \
  --broadcast \
  --slow
```

The script prints the resulting `PAYMENT_TOKENS`,
`PAYMENT_TOKEN_USD_FEEDS`, `PAYMENT_TOKEN_MIN_ANSWERS`, and
`PAYMENT_TOKEN_MAX_ANSWERS` values. The mock token and oracle are for Sepolia
testing only. The checked-in Sepolia example references the current Digital
Carat mUSDC and its test-only feed; never copy those addresses to production.

### In-place payment registry upgrade

The V2 payment registry keeps the existing proxy address and storage while
adding enumeration for deployment-specific payment assets. Backfill the assets
already configured on the proxy during the upgrade:

```sh
PAYMENT_TOKEN_REGISTRY_ADDRESS=0x... \
PAYMENT_TOKEN_BACKFILL=0x0000000000000000000000000000000000000000,0xStablecoin \
forge script script/UpgradePaymentTokenRegistry.s.sol:UpgradePaymentTokenRegistry \
  --rpc-url "$RPC_URL" --broadcast --slow
```

Apply the updated 15%/10% reserve schedule without replacing the existing
ReserveManager proxy:

```sh
RESERVE_MANAGER_ADDRESS=0x... \
DEFAULT_RESERVE_BPS=1000 \
RESERVE_BRACKET_MAX_USD=1000000000000000000000,115792089237316195423570985008687907853269984665640564039457584007913129639935 \
RESERVE_BRACKET_BPS=1500,1000 \
forge script script/ConfigureReservePolicy.s.sol:ConfigureReservePolicy \
  --rpc-url "$RPC_URL" --broadcast --slow
```

For Arbitrum or another EVM L2, start from `.env.l2.example`, use that chain's
canonical token and oracle addresses, and deploy the same proxy suite. Sepolia
continues to use mUSDC; payment assets are configuration, not hard-coded protocol state.

Mint test mUSDC from its owner account:

```sh
MOCK_USDC_ADDRESS=0x... \
MOCK_USDC_RECIPIENT=0x... \
MOCK_USDC_AMOUNT=10000000000 \
forge script script/MintSepoliaMockUSDC.s.sol:MintSepoliaMockUSDC \
  --rpc-url "$SEPOLIA_RPC_URL" --broadcast
```

`MOCK_USDC_AMOUNT` is in six-decimal base units; the example mints 10,000 mUSDC.

Deploy a permissionless testnet faucet while preserving the same mUSDC address:

```sh
MOCK_USDC_ADDRESS=0x... \
forge script script/DeploySepoliaMockUSDCFaucet.s.sol:DeploySepoliaMockUSDCFaucet \
  --rpc-url "$SEPOLIA_RPC_URL" --broadcast --slow
```

The deployment transfers mUSDC ownership to the faucet. Each public `claim()`
mints exactly 10,000 mUSDC to its caller. The faucet admin can pause claims or
recover token ownership if the faucet needs to be retired.

### Approved gemstone activation

`ActivateSepoliaGem.s.sol` executes the privileged activation sequence:
seller approval, registration, custody confirmation, valuation commitment,
primary listing, and optional 24-hour auction creation. The operator must be
the recorded custodian for the one-signer MVP flow.

Set `GEM_REGISTRY_ADDRESS`, `PRIMARY_SALE_AUCTION_ADDRESS`, `GEM_SELLER`,
`GEM_CUSTODIAN`, `GEM_METADATA_URI`, `GEM_CERTIFICATE_HASH`,
`GEM_VALUATION_HASH`, `GEM_VALUATION_MATRIX_HASH`,
`GEM_APPROVED_VALUATION_USD`, and `GEM_SALE_MODE` (`1` for buy now, `2` for
auction). `GEM_AUCTION_FLOOR_USD` is optional and defaults to the approved
valuation.

## Dependency Policy

Compiler and optimizer settings are pinned in `foundry.toml`.

Dependencies are vendored under `lib/`:

- `forge-std`
- `openzeppelin-contracts`
- `openzeppelin-contracts-upgradeable`
- `chainlink-brownie-contracts`

When updating dependencies, update the vendored library directories and rerun the full check suite.
