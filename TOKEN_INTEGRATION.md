# $GAPG token integration

Gapguard **does not deploy any ERC-20**. The project token ($GAPG) is launched separately on a launchpad. The
protocol is fully functional without it; when it is wired in, it adds a staker layer.

## What changes when the token is live

| Feature | Without $GAPG (default) | With $GAPG |
|---------|-------------------------|------------|
| Premium split | 10% protocol fee, 90% to the product pool | 10% protocol fee, **10% to stakers** (USDG), 80% to the pool — only while at least one staker exists |
| Disputing an Issuer Halt attestation | Only the Timelock-controlled committee (`COMMITTEE_ROLE`) can dispute | Any staker can dispute by **bonding 1,000 $GAPG** of stake (committee can still dispute without a bond) |
| Dispute outcome | Committee decides; undecided disputes reject after 7 days | Same; a staker's bond is **slashed** to the `FeeCollector` if the attestation is upheld and **released** if the staker was right |
| Frontend | Staking page hidden (`NEXT_PUBLIC_PROJECT_TOKEN` empty) | "Stake & disputes" page: stake, unstake (7-day cooldown), claim USDG rewards, dispute open attestations |

## Contracts involved

* `ProjectTokenHooks` — the only contract that stores the token:
  * `setProjectToken(address)` — `DEFAULT_ADMIN_ROLE` (= the 48h Timelock), **callable once**; rejects `address(0)`,
    EOAs (no code) and the stablecoin itself. Emits `ProjectTokenSet`.
  * `tokenEnabled()` — `false` until set; every token feature checks it.
  * Staking: `stake`, `requestUnstake` (7-day cooldown; bonded stake cannot be unstaked), `withdrawUnstaked`,
    `claimRewards`, `pendingRewards`. Fee-on-transfer safe. Rewards use O(1) reward-per-share accounting.
  * Dispute bonds (called only by `AttestationModule`): `lockBond`, `releaseBond`, `slashBond`.
  * `notifyReward` (called only by `CoverRegistry`).
* `AttestationModule` — reads `hooks.tokenEnabled()` / `availableToBond()` to decide whether a non-committee caller
  may dispute; locks/slashes/releases bonds.
* `CoverRegistry` — routes the staker share only if `hooks.canReceiveRewards()` (token set, stakers > 0, not paused).

No other contract needs the token address.

## How to wire the token (after launch)

The token address must go through the Timelock (48h). With the ops Safe as proposer, the transaction batch is:

1. `Timelock.schedule(target = ProjectTokenHooks, value = 0, data = setProjectToken(GAPG), predecessor = 0x0, salt = 0x0, delay = 172800)`
2. after 48 hours, anyone: `Timelock.execute(ProjectTokenHooks, 0, data, 0x0, 0x0)`

Exact `cast` commands are in [DEPLOY.md](DEPLOY.md#3-wire-the-project-token-later).

Then set `NEXT_PUBLIC_PROJECT_TOKEN=<GAPG address>` in the frontend (Vercel env) and redeploy the app.

## Safety properties

* Until `setProjectToken` executes, every token path reverts with `TokenNotSet` or is skipped; the test-suite
  (`TokenGovernanceTest.test_tokenDisabledByDefault`) and the deploy script (`_assertHandover`) check this.
* It is one-shot (`TokenAlreadySet`), so a compromised proposer cannot later swap the token for a malicious one.
* The token contract is never trusted with protocol funds: rewards are paid in USDG from `ProjectTokenHooks`'s own
  balance; only staked $GAPG is held, and only slashes move it (to the `FeeCollector`).
* A misbehaving token (pausing, blacklisting) can at worst block staking/unstaking; it cannot block covers, pools or
  committee disputes, which keep working.
* Tests use a mock ERC-20 (`test/mocks/Mocks.sol`) only.

## Future work

* Stake-weighted arbitration (stakers vote, committee as backstop) instead of committee-only verdicts.
* Extending bonded disputes to further attestation-based triggers.
