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
ETH_USD_FEED=
PRICE_STALE_AFTER=86400
DEFAULT_RESERVE_BPS=500
RESERVE_BRACKET_MAX_USD=1000000000000000000000,115792089237316195423570985008687907853269984665640564039457584007913129639935
RESERVE_BRACKET_BPS=1000,400
```

Optional env vars:

```sh
PLATFORM_RECIPIENT=
VAULT_RESERVE_RECIPIENT=
INSURANCE_RESERVE_RECIPIENT=
TREASURY_RESERVE_RECIPIENT=
SECONDARY_FEE_BPS=200
PAYMENT_TOKENS=0xToken1,0xToken2
PAYMENT_TOKEN_USD_FEEDS=0xFeed1,0xFeed2
```

Notes:

- Native ETH is configured from `ETH_USD_FEED`.
- ERC-20 payment tokens are configured from the optional comma-separated token/feed lists.
- Reserve bracket values are 18-decimal USD values.
- Bracket minimums are inferred from zero and the previous bracket max.
- Recipient env vars default to the deployer if omitted.
- `SECONDARY_FEE_BPS` defaults to `200` when omitted.

## Dependency Policy

Compiler and optimizer settings are pinned in `foundry.toml`.

Dependencies are vendored under `lib/`:

- `forge-std`
- `openzeppelin-contracts`
- `openzeppelin-contracts-upgradeable`
- `chainlink-brownie-contracts`

When updating dependencies, update the vendored library directories and rerun the full check suite.
