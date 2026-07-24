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
SEPOLIA_RPC_URL=
ETH_USD_FEED=
ETH_USD_MIN_ANSWER=
ETH_USD_MAX_ANSWER=
PRICE_STALE_AFTER=86400
DEFAULT_RESERVE_BPS=500
RESERVE_BRACKET_MAX_USD=1000000000000000000000,115792089237316195423570985008687907853269984665640564039457584007913129639935
RESERVE_BRACKET_BPS=1000,400
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
- ERC-20 payment tokens are configured from optional comma-separated token/feed/minimum/maximum lists. All four lists must have equal length.
- Reserve bracket values are 18-decimal USD values.
- Bracket minimums are inferred from zero and the previous bracket max.
- Recipient env vars default to the deployer if omitted.
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
testing only; the default `.env.sepolia.example` continues to reference Circle
testnet USDC and the existing USDC/USD feed.

Mint test mUSDC from its owner account:

```sh
MOCK_USDC_ADDRESS=0x... \
MOCK_USDC_RECIPIENT=0x... \
MOCK_USDC_AMOUNT=10000000000 \
forge script script/MintSepoliaMockUSDC.s.sol:MintSepoliaMockUSDC \
  --rpc-url "$SEPOLIA_RPC_URL" --broadcast
```

`MOCK_USDC_AMOUNT` is in six-decimal base units; the example mints 10,000 mUSDC.

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
