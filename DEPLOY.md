# Deploying Gapguard

Everything below signs **only** through Foundry keystores. No private key or seed phrase is ever written to a file,
an environment variable or the terminal by these steps. Run commands from the repository root unless noted.

Prerequisites: Foundry (`forge`/`cast`/`anvil` ≥ 1.0), Node ≥ 22.6, pnpm, ~0.05 ETH on Robinhood Chain for the
deployer (≈ 200 transactions) and a little ETH for the keeper.

Recommended before mainnet: create a Safe for governance (Timelock proposer), and decide the guardian and
committee addresses (can be the same Safe or separate signers).

---

## 1. Import the deployer key into an encrypted keystore

```bash
cast wallet import gapguard-deployer --interactive
```

(You paste the key and choose a password in the prompt; it is stored encrypted in `~/.foundry/keystores/`.
The command prints the account address � that is `0xYOUR_DEPLOYER_ADDRESS` below. You can show it again any time with
`cast wallet address --account gapguard-deployer`.)

## 2. Deploy + verify (one command)

```bash
cd contracts && GAPGUARD_ADMIN=0xYOUR_SAFE GAPGUARD_GUARDIAN=0xYOUR_GUARDIAN GAPGUARD_COMMITTEE=0xYOUR_COMMITTEE GAPGUARD_KEEPER=0xYOUR_KEEPER_ADDRESS forge script script/Deploy.s.sol:Deploy --rpc-url https://rpc.mainnet.chain.robinhood.com --account gapguard-deployer --sender 0xYOUR_DEPLOYER_ADDRESS --broadcast --verify --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api/ --slow
```

What it does, in order:

1. deploys the Timelock (48h), OracleAdapter, MarketClock, PricingCurve, FeeCollector, ComplianceRegistry,
   ProjectTokenHooks, AttestationModule, CoverNFT, CoverRegistry, 4 CapitalPools and 4 TriggerResolvers;
2. wires feeds, curves, products, exposure limits, assets (from `config/chains.json`) and roles;
3. grants `DEFAULT_ADMIN_ROLE` on every contract to the Timelock and **renounces** it from the deployer, then asserts
   on-chain that the deployer holds no admin role anywhere and that the token is disabled;
4. verifies every contract on Blockscout;
5. writes `deployments/4663.json` and `app/src/config/deployments/4663.json` (the frontend config).

Environment variables (all optional — if unset they default to the deployer, which the script warns about):

| Var | Meaning |
|-----|---------|
| `GAPGUARD_ADMIN` | Timelock proposer/canceller (use a Safe) |
| `GAPGUARD_GUARDIAN` | can pause (defaults to admin) |
| `GAPGUARD_COMMITTEE` | dispute committee (defaults to admin) |
| `GAPGUARD_KEEPER` | keeper address = `cast wallet address --account gapguard-keeper` |
| `GAPGUARD_TIMELOCK_DELAY` | seconds, ≥ 172800 (default 172800) |

To get the keeper address without exposing anything: `cast wallet address --account gapguard-keeper`.

Want to preview first? The same command **without** `--broadcast --verify …` is a full mainnet simulation (it writes
`deployments/4663.dryrun.json` only):

```bash
cd contracts && forge script script/Deploy.s.sol:Deploy --rpc-url https://rpc.mainnet.chain.robinhood.com --sender 0xYOUR_DEPLOYER_ADDRESS
```

If verification fails transiently (Blockscout rate limits), re-run only verification:

```bash
cd contracts && forge script script/Deploy.s.sol:Deploy --rpc-url https://rpc.mainnet.chain.robinhood.com --account gapguard-deployer --sender 0xYOUR_DEPLOYER_ADDRESS --resume --verify --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api/
```

### Post-deploy (through the Timelock, optional)

* Calibrate Depeg `minLiquidity` per pool: `DepegResolver.setDexConfig(asset, pool, USDG, 1800, <liquidity floor>)`.
* Grow `ObservationCardinality` of a depeg pool if you raise `twapWindow` (`pool.increaseObservationCardinalityNext(n)`,
  callable by anyone).
* Set a sequencer-uptime feed once Chainlink publishes one: `ChainlinkOracleAdapter.setSequencerUptimeFeed(feed, 3600)`.
* Turn on compliance gating: `ComplianceRegistry.setEnabled(true)` and allowlist via `setAllowlisted` (COMPLIANCE_ROLE).

## 3. Wire the project token later

When $GAPG exists (address `GAPG`), schedule the one-shot call from the Timelock proposer. With a Safe, create these
two transactions in the Safe UI (Transaction Builder) using the calldata printed by:

```bash
cast calldata "setProjectToken(address)" 0xGAPG_ADDRESS
```

Exact command if the proposer is a keystore account (`gapguard-admin`):

```bash
cast send $(jq -r .contracts.timelock deployments/4663.json) "schedule(address,uint256,bytes,bytes32,bytes32,uint256)" $(jq -r .contracts.projectTokenHooks deployments/4663.json) 0 $(cast calldata "setProjectToken(address)" 0xGAPG_ADDRESS) 0x0000000000000000000000000000000000000000000000000000000000000000 0x0000000000000000000000000000000000000000000000000000000000000000 172800 --rpc-url https://rpc.mainnet.chain.robinhood.com --account gapguard-admin
```

After 48 hours, anyone can execute:

```bash
cast send $(jq -r .contracts.timelock deployments/4663.json) "execute(address,uint256,bytes,bytes32,bytes32)" $(jq -r .contracts.projectTokenHooks deployments/4663.json) 0 $(cast calldata "setProjectToken(address)" 0xGAPG_ADDRESS) 0x0000000000000000000000000000000000000000000000000000000000000000 0x0000000000000000000000000000000000000000000000000000000000000000 --rpc-url https://rpc.mainnet.chain.robinhood.com --account gapguard-deployer
```

Then set `NEXT_PUBLIC_PROJECT_TOKEN` in Vercel and redeploy the app. See [TOKEN_INTEGRATION.md](TOKEN_INTEGRATION.md).

## 4. Start the keeper

```bash
cast wallet import gapguard-keeper --interactive
```

```bash
pnpm install
```

```bash
pnpm keeper
```

It prompts for the keystore password (hidden input), loads `deployments/<chainId>.json`, and every 5 minutes pokes
depeg/outage/halt resolvers, resolves weekend gaps, auto-pays claimable covers and expires old ones. Options:

* `KEEPER_RPC_URL` — use a dedicated RPC (the public one is rate-limited).
* `POLL_SECONDS` — loop interval (default 300).
* `KEEPER_KEYSTORE_PASSWORD_FILE` — for unattended hosts (a file readable only by the service user).
* `pnpm --filter @gapguard/keeper dry-run` — simulate one loop without sending transactions.

Run it under a process manager (systemd, pm2, Docker restart policy). Keep ≥ 0.01 ETH on the keeper.

## 5. Deploy the frontend to Vercel

1. Import the repo in Vercel → **Root Directory: `app`** (framework auto-detected: Next.js; install command
   `pnpm install`, build command `pnpm build`).
2. Environment variables:
   * `NEXT_PUBLIC_RPC_URL` — your RPC (optional)
   * `NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID` — from WalletConnect Cloud (optional)
   * `NEXT_PUBLIC_PROJECT_TOKEN` — empty until $GAPG is wired
   * `NEXT_PUBLIC_BLOCKED_COUNTRIES` — e.g. `US,CU,IR,KP,SY,RU` (optional geoblock)
3. Commit the generated `app/src/config/deployments/4663.json` (written by the deploy script) and push.

Or from the CLI:

```bash
cd app && npx vercel --prod
```

---

## Local fork rehearsal (what CI/devs run)

```bash
pnpm fork:anvil
```

In a second terminal:

```bash
pnpm fork:deploy
```

```bash
cd app && NEXT_PUBLIC_ENABLE_FORK=true NEXT_PUBLIC_FORK_DEV_WALLET=0x000000000000000000000000000000000000dEaD pnpm dev
```

The fork runs as chain 31337 with `--auto-impersonate`, so the deploy script, keeper
(`KEEPER_UNLOCKED_ADDRESS=0x…dEaD KEEPER_RPC_URL=http://127.0.0.1:8545 pnpm keeper`) and the app's
"Fork dev wallet" send transactions without any private key.
