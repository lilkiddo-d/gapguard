# Gapguard threat model

Scope: `contracts/src/**` as deployed by `script/Deploy.s.sol`, the keeper (`scripts/`) and the frontend (`app/`).

## Assets at risk

* Underwriter capital in the four `CapitalPool`s (USDG).
* Buyer premiums and payouts.
* Staked $GAPG (once the token is wired) — slashable dispute bonds.
* Protocol fees in `FeeCollector`.

## Trust assumptions

| Actor | Can | Cannot |
|-------|-----|--------|
| Timelock (48h, proposer = ops Safe) | change parameters, products, assets, oracle adapter, fees, compliance; unpause; set the project token once | act faster than 48h; lower the delay below 48h; move pool funds directly |
| Guardian | pause any contract instantly | unpause, change parameters, move funds |
| Keeper (`KEEPER_ROLE`) | propose issuer-halt attestations | pay itself, change resolution outcomes, bypass the dispute window |
| Committee (`COMMITTEE_ROLE`) | dispute attestations (no bond), adjudicate disputes, propose halts | touch funds or parameters |
| Market-clock operator | override a week window / flag holidays ≥ 2 days ahead | change the schedule for a window that is about to matter |
| Anyone | resolve gap events, poke depeg, report outages, poke halts, finalize attestations, claim (to the NFT holder), expire covers | choose who is paid, record an event twice |
| External: Chainlink, Uniswap v3 pools, token issuer (`paused()`, `oraclePaused()`), USDG | provide the data / settlement asset | — (see risks below) |

## Top risks and mitigations

### 1. Trigger manipulation — pushing the DEX price to fake a depeg

*Attack:* buy Depeg cover, then push the Uniswap pool off-peg to trigger it.

*Mitigations*
* The DEX side is a **30-minute TWAP**, never spot; a single-block push barely moves it.
* The deviation must be ≥ 5% on **every** poke for **≥ 4 hours** with **≥ 4 pokes** spaced ≤ 1h apart; any gap or recovery resets the episode (`test_manipulationSpikeDoesNotTrigger`, `test_observationGapRestartsEpisode`). The attacker must hold the pool off-peg against arbitrage for hours.
* Pools below `minLiquidity` are ignored (episode reset) and Depeg cover is only enabled for assets with deep USDG pools (DECISIONS #8).
* Exposure caps: ≤ 30% of the Depeg pool per asset and ≤ 80% pool utilization bound the attacker's maximum payout, so the cost of sustaining the manipulation can be made to exceed the payout by keeping pool sizes and caps proportional to on-chain liquidity.
* The oracle side must be fresh (no measurement while markets are closed, when arbitrage is thinner).
* Opening an episode freezes the pool's withdrawals and stops new sales of that asset.

*Residual risk:* a well-capitalised attacker with a thin pool. Governance must keep `minLiquidity` and caps calibrated; the keeper can be extended to alert when pool depth drops.

### 2. Buying cover after an event is already known

*Mitigations*
* Cover never starts before `now + minLead` (≥ 1h); a cover only pays for events whose **start** time is within `[start, end]` (`test_revert_cannotBuyForPeriodThatHasStarted`, fuzz `testFuzz_cannotBuyForStartedPeriod`).
* Weekend gap event time = **Friday close**: cover bought after the close cannot claim that weekend (`test_revert_claimEventBeforeCoverStart_buyingAfterCloseIsWorthless`).
* Outage event time = the feed's last update; purchases are refused once a feed is late (`canPurchase`).
* Depeg/halt: purchases are refused while an episode is open, the token is paused, or a halt claim is pending.
* Schedule overrides require 2 days' notice, so the clock cannot be bent around a known event.

### 3. Underwriter bank runs

*Mitigations*
* Two-step exit with a **14-day cooldown**; escrowed shares keep bearing losses during it.
* Redemptions can only use **free capital** (`totalAssets − lockedCapital`); capital backing active covers cannot leave (`test_withdraw_onlyFromFreeCapital`).
* Withdrawals are **frozen** while the product's resolver reports a pending/suspected event, for 3 days after any trigger (settlement), and — for Gap — across every weekend window (`test_withdraw_blockedWhileGuardReportsEvent`, `test_withdrawalsBlockedOverWeekend`).
* Premiums vest over 7 days so depositors cannot enter just before premium income and leave right after.

### 4. Oracle failure or manipulation

* Staleness (26h ≈ heartbeat + 2h), positivity and `answeredInRound` checks; optional secondary-feed deviation bound; optional sequencer-uptime check (no feed published yet).
* Issuer `oraclePaused()` is honoured (corporate actions).
* Historical lookups only accept round hints that are **proven** on-chain to be the last round ≤ t / first round ≥ t (phase boundaries handled), so a resolver caller cannot cherry-pick a round (`test_historicalLookups`, `test_fork_wrongRoundHintsRejected`).
* Prices include the corporate-action multiplier (ERC-8056), so splits do not look like gaps.

### 5. Double payment / replay

* Each event id is recorded once (`EventExists`), each cover moves `Active → Claimed` once; invariant `invariant_eachCoverPaysOnce` and fuzz `testFuzz_claimOnlyOnce`.

### 6. Insolvency

* `lockCapital` reverts if locked > total assets; payouts reduce assets and locked capital equally; withdrawals only touch free capital. Invariants: `invariant_poolCapitalCoversActiveCovers`, `invariant_exposureAccounting`.

### 7. Attestation abuse (Issuer Halt)

* The current `paused()` state is read on-chain at proposal time; the claimed start must lie in `(lastSeenUnpaused, firstSeenPaused]`, both recorded by permissionless pokes.
* 24h dispute window; disputes by bonded stakers or the committee; unresolved disputes **reject** after 7 days (fail-safe for underwriters); wrong disputes are slashed.

### 8. Governance / key compromise

* All admin power is behind a 48h Timelock (floor enforced); the deployer renounces everything (`_assertHandover`). The guardian can only pause.
* Keeper keys are limited to halt proposals; a compromised keeper can at worst propose a false halt, which the dispute layer rejects.

### 9. Re-entrancy & token handling

* `ReentrancyGuard` on all fund-moving entry points; checks-effects-interactions throughout; `SafeERC20`; CoverNFT uses `_mint` (no receiver callback); fee-on-transfer-safe staking.

### 10. Frontend / supply chain

* No private keys in the app; the fork-only dev wallet uses anvil impersonation and is compiled in only with `NEXT_PUBLIC_ENABLE_FORK=true`.
* Strict security headers (`X-Frame-Options: DENY`, `nosniff`).

## Static analysis

`slither . --config-file slither.config.json` — **0 high, 0 medium**. Confirmed false positives (strict equality against zero counters, partial use of tuple return values, intentional integer calendar/tick math, a write of a trusted module's return value under `nonReentrant`) are suppressed inline with a justification. Remaining low findings: `timestamp` (inherent: the product is time-based; miner influence of seconds is irrelevant at hour/day granularity) and `calls-loop` (bounded batch of ≤ 100 calls to trusted protocol contracts). Full output: `docs/slither-report.txt`.

## Known limitations

* No sequencer-uptime feed exists for the chain yet.
* DEX liquidity for most tokens is too thin for a depeg trigger; Depeg Cover is limited accordingly.
* Holiday handling for outage time is operator-flagged (with notice); unflagged holidays make outage detection slightly more lenient for buyers (more open time counted), never retroactive.
* Arbitration is by the committee in v1; stake-weighted voting is future work (see TOKEN_INTEGRATION.md).
* This code has not been audited by a third party.
