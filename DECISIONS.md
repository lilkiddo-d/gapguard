# Decisions log

One line of reasoning per decision. Newest decisions at the bottom of each section.

## Chain & external dependencies

| # | Decision | Why |
|---|----------|-----|
| 1 | Target Robinhood Chain mainnet, chain id **4663**, RPC `https://rpc.mainnet.chain.robinhood.com`, explorer `robinhoodchain.blockscout.com`, gas token ETH | Taken from docs.robinhood.com/chain/connecting and verified with `cast chain-id` against the live RPC. |
| 2 | Contract verification via **Blockscout** (`--verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api/`) | That is the method documented on docs.robinhood.com/chain/deploy-smart-contracts; there is no Etherscan instance. |
| 3 | Protocol stablecoin = **USDG** `0x5fc5…d168` (6 decimals) | Listed on the official contracts page and has a Chainlink USDG/USD feed; no native USDC token is listed for the chain. |
| 4 | Stock/RWA token addresses come from the official registry API `api.robinhood.com/rhj/assets` (linked from the Stock Token APIs docs) and are cross-checked on-chain | The docs' contracts page renders this registry live; nothing is guessed. |
| 5 | Oracle = **Chainlink** (official oracle of the chain) behind a swappable `IOracleAdapter` | Docs name Chainlink as the price source; resolvers can be pointed at a new adapter via the Timelock (`setOracle`). |
| 6 | Launch asset set: AAPL, NVDA, TSLA, MSFT, GOOGL, AMZN, META, COIN, SPY, QQQ, SGOV, SLV, USO | Assets that have both a canonical token and a Chainlink `us_equities_24/5` feed; covers stocks, ETFs and RWA-style ETFs (T-bills, silver, oil). |
| 7 | No L2 sequencer-uptime feed is configured | Chainlink publishes none for Robinhood Chain (checked the feed directory); the adapter supports one and the Timelock can set it later. |
| 8 | Depeg Cover enabled only for META, QQQ, SGOV | Scanned all 25.5k Uniswap v3 `PoolCreated` logs: only these have USDG pools with real depth (≥100k USDG) and observation cardinality ≥100; thin pools would make the trigger manipulable. |
| 9 | Solidity 0.8.28, `evm_version = cancun` | Verified MCOPY/TSTORE execute on the live chain via `eth_call`; OZ v5 benefits from cancun. |
| 10 | Uniswap v3 TickMath ported to 0.8 (GPL-2.0-or-later, attributed); `DepegResolver` is GPL as it links it, everything else MIT | Avoids pulling v3-core (0.7) while respecting its licence; port is validated against a live pool's `slot0` in a fork test. |

## Product parameters

| # | Decision | Why |
|---|----------|-----|
| 11 | Weekly window: close **Fri 20:00 New York**, reopen **Sun 20:00 New York** (= Mon 00:00 UTC in EDT / 01:00 UTC in EST) | Matches the 24/5 session of the Chainlink stock feeds; "opens Monday" is interpreted in UTC. |
| 12 | US DST computed on-chain (2nd Sun Mar → 1st Sun Nov) | Removes a trusted operator from the schedule; tested against 2026 boundaries. |
| 13 | Operator may override a week or flag holidays only ≥ 2 days in advance | Lets ops handle exchange holidays without being able to reshape an event that is already known. |
| 14 | Gap Cover: pays at ≥ **10%** gap down; open price = first round within **6h** after reopen; event time = Friday close | 10% is a meaningful tail event; using the close as event time makes cover bought after the close useless for that weekend. |
| 15 | Depeg Cover: 30-min TWAP deviates ≥ **5%** from oracle for ≥ **4h**, ≥ 4 pokes, pokes ≤ 1h apart | Requires sustained mispricing that an attacker must fund against arbitrage for hours. |
| 16 | Outage Cover: ≥ **30h of open-market time** without a feed update | Feeds have a 24h heartbeat; counting only open-market time means a normal weekend never triggers. |
| 17 | Halt Cover: issuer `paused()` for ≥ **24h**, attested by a keeper, 24h dispute window | Pause state is verifiable on-chain but the start time is not, so it is attested and disputable. |
| 18 | Payout = 100% of the cover amount (binary) | Simplest truly parametric design; no loss assessment. |
| 19 | Cover starts ≥ **1h** after purchase (or a chosen start ≤ 30 days ahead); only events that *start* within [start, end] pay | Directly prevents buying cover for a period/event that has already begun. |
| 20 | Resolvers refuse sales while an event is pending (open depeg episode, late feed, paused token / pending halt claim) | Second layer against buying after an event is known. |
| 21 | Duration 7–90 days; minimum cover 10 USDG | Matches the requested 1 week–3 months; dust protection. |
| 22 | Kinked utilization curve per product, priced at utilization *after* the purchase; 500% APR hard cap | Large buyers pay for the capacity they consume; cap prevents fat-finger curves. |
| 23 | Curves (base/slope1/slope2/kink): Gap 3%/8%/40%/70%, Depeg 2%/6%/40%/70%, Outage 1%/4%/30%/70%, Halt 1.5%/5%/30%/70% | Gap is the most frequent tail risk; outage the least. Tunable by the Timelock. |
| 24 | Premium split: 10% protocol fee, 10% to $GAPG stakers (goes to the pool while staking is not live), rest to the pool | Rewards stakers for running the dispute layer without the protocol depending on the token. |

## Capital & risk controls

| # | Decision | Why |
|---|----------|-----|
| 25 | One ERC-4626 pool per product, asset USDG, `_decimalsOffset = 6` | Isolates product risk; virtual shares defeat first-depositor inflation attacks. |
| 26 | Premiums vest linearly over 7 days (excluded from `totalAssets` until vested) | Stops just-in-time deposits from capturing premiums. |
| 27 | Exits: `requestWithdraw` escrows shares (still exposed to losses) → **14-day cooldown** → 7-day redeem window, only from free (unlocked) capital | Underwriters cannot flee before a known event, and cannot withdraw capital backing active covers. |
| 28 | Withdrawals frozen while the product's resolver reports a pending/suspected event and for a **3-day settlement period** after any trigger; Gap pool also frozen over every weekend window | Prevents exiting at pre-loss share prices while payouts are processed. |
| 29 | Max utilization 80% per product; max 25% of pool capital per asset (30% for Depeg) | One event cannot drain a pool; invariant tests prove capital ≥ locked exposure. |
| 30 | Claims are permissionless (keepers auto-pay) and pay the current NFT holder; one payout per cover | Covers are transferable positions; payout cannot be front-run because the recipient is fixed by ownership. |
| 31 | Covers expire (capital unlocked) 14 days after their end | Leaves time for halt attestations/disputes on events that started inside the period. |
| 32 | Guardian can pause instantly; only the Timelock can unpause; claims are also paused | Emergency brake for exploits; unpausing is a deliberate governance action. |

## Governance, token, compliance

| # | Decision | Why |
|---|----------|-----|
| 33 | `DEFAULT_ADMIN_ROLE` on every contract held by a 48h `TimelockController`; `getMinDelay()` is floored at 48h | The floor survives even a timelocked `updateDelay`. |
| 34 | Timelock executors = anyone (address(0)) after the delay; proposers = `GAPGUARD_ADMIN` (a Safe) | Proposals are the trust point; execution after the delay need not be gated. |
| 35 | Deployer is temporary admin and renounces everything in the same script; `_assertHandover` checks it | No EOA keeps privileges after deployment. |
| 36 | `setProjectToken` lives only in `ProjectTokenHooks`; other contracts read `hooks.tokenEnabled()` | Single, one-shot wiring point; the protocol is fully functional with no token. |
| 37 | Disputes: stakers bond 1,000 $GAPG to dispute; the Timelock-controlled committee adjudicates; unresolved disputes reject after 7 days | Stakers are the watchtower layer with skin in the game; rejecting on timeout protects underwriters. |
| 38 | `ComplianceRegistry` is OFF by default; when on, gates buy, deposit, stake and cover-NFT transfers via allowlist or an external provider | Pluggable regulatory gate without affecting the default permissionless flow. |
| 39 | Frontend geoblock via `NEXT_PUBLIC_BLOCKED_COUNTRIES` and Vercel's `x-vercel-ip-country` header (Next 16 `proxy.ts`) | Optional, zero-cost, keeps `/risk` reachable. |
| 40 | Brand: "Gapguard" shield logo; no third-party names or logos in branding; the chain is named only where technically necessary | Requirement + avoid implied endorsement. |

## Tooling & ops

| # | Decision | Why |
|---|----------|-----|
| 41 | Local fork runs as chain id **31337** (`anvil --fork-url … --chain-id 31337 --auto-impersonate`) | Fork deployments never overwrite `deployments/4663.json`; impersonation means no private key is ever needed for local work. |
| 42 | `Deploy.s.sol` writes `deployments/<id>.json` + app config only when broadcasting; dry runs write `<id>.dryrun.json` | A mainnet simulation can never clobber real addresses. |
| 43 | Keeper decrypts the Foundry keystore `gapguard-keeper` in memory (scrypt + AES-128-CTR, MAC checked) | Satisfies "sign only via the keystore" without shelling out per transaction; the key is never logged or written. |
| 44 | Default `depegMinLiquidity = 1` at deploy | Liquidity units are pool-specific; the Timelock should calibrate per asset (see DEPLOY.md). |
| 45 | Frontend: Next.js 16 + wagmi 2 + viem 2 + RainbowKit 2, TypeScript pinned to 5.x | RainbowKit requires wagmi 2; TS 7 (native) is not yet supported by Next's type-check. |
| 46 | `@coinbase/cdp-sdk` aliased to a stub in the Next build | It is only imported by the server build of the Base Account connector and drags in uninstalled optional deps; Gapguard never uses it. |
| 47 | Repository line endings forced to LF (`.gitattributes`) | CRLF skewed Slither's source mapping on Windows. |
| 48 | Slither: all high/medium fixed or (for confirmed false positives) suppressed inline with a written justification; low `timestamp`/`calls-loop` accepted | Time-based logic is inherent to the product; loops are bounded and only call trusted protocol contracts. |
