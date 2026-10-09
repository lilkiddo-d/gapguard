# Gapguard

Parametric cover for tokenized stocks and RWA tokens on Robinhood Chain (chain 4663). Payouts are triggered by
on-chain data only:

| Product | Pays when |
|---------|-----------|
| Weekend Gap | the token reopens ≥ 10% below its Friday close (Chainlink rounds at fixed MarketClock times) |
| Depeg | Uniswap v3 30-min TWAP deviates ≥ 5% from the oracle for ≥ 4h |
| Oracle Outage | a feed is stale for ≥ 30h of open-market time |
| Issuer Halt | the issuer's `paused()` is true for ≥ 24h (keeper attestation + dispute window) |

Covers are transferable ERC-721s, auto-paid by keepers. Underwriters deposit USDG into per-product ERC-4626 pools
with a 14-day exit cooldown, free-capital-only exits and event freezes. All admin power sits behind a 48h Timelock.

## Layout

| Path | Contents |
|------|----------|
| `contracts/` | Foundry project: `src/` (CoverRegistry, CoverNFT, PricingCurve, CapitalPool, resolvers, AttestationModule, MarketClock, ChainlinkOracleAdapter, FeeCollector, ProjectTokenHooks, ComplianceRegistry, GapguardTimelock), `test/` (unit, fuzz, invariant, fork), `script/Deploy.s.sol` |
| `app/` | Next.js 16 + wagmi/viem + RainbowKit frontend (buy, my covers, pools, trigger history, staking, risk disclosure, geoblock) |
| `scripts/` | keeper bot (`pnpm keeper`) and local-fork helpers |
| `config/chains.ts` | every on-chain address with source links (`pnpm config:export` → `chains.json`) |
| `deployments/` | written by the deploy script |

## Quick start

```bash
pnpm install
```

```bash
pnpm contracts:test
```

```bash
pnpm contracts:test:fork
```

```bash
pnpm app:build
```

See [DEPLOY.md](DEPLOY.md), [DECISIONS.md](DECISIONS.md), [THREAT_MODEL.md](THREAT_MODEL.md),
[TOKEN_INTEGRATION.md](TOKEN_INTEGRATION.md). No token is deployed by this repo; it is unaudited software.
