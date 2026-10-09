/**
 * Gapguard trigger-watcher keeper.
 *
 * Every POLL_SECONDS it:
 *   1. pokes the Depeg resolver for enabled assets (only sends a tx when a deviation/episode exists),
 *   2. reports oracle staleness to the Outage resolver when state changes or an outage crosses its threshold,
 *   3. checkpoints issuer pause flags, proposes halt attestations, finalizes and settles them,
 *   4. resolves the most recent weekend gap for every enabled asset (round hints found by binary search),
 *   5. auto-pays every claimable cover for every triggered event,
 *   6. expires covers past their claim grace period to release underwriter capital.
 *
 * Signing: the Foundry keystore account `gapguard-keeper` (KEEPER_ACCOUNT), decrypted in memory only.
 * On a local anvil fork you can instead set KEEPER_UNLOCKED_ADDRESS (anvil --auto-impersonate), no key at all.
 */
import { readFileSync, existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  BaseError,
  ContractFunctionRevertedError,
  createPublicClient,
  createWalletClient,
  defineChain,
  http,
  parseAbi,
  parseAbiItem,
  type Account,
  type Address,
  type Hex,
  type PublicClient,
  type WalletClient,
} from 'viem';
import {
  coverRegistryAbi,
  depegResolverAbi,
  oracleOutageResolverAbi,
  issuerHaltResolverAbi,
  weekendGapResolverAbi,
  attestationModuleAbi,
  marketClockAbi,
  chainlinkOracleAdapterAbi,
} from '../../app/src/abi/index.ts';
import { loadKeystoreAccount, readPassword } from './keystore.ts';

const here = dirname(fileURLToPath(import.meta.url));
const repo = join(here, '..', '..');

const RPC_URL = process.env.KEEPER_RPC_URL || process.env.ROBINHOOD_RPC_URL || 'https://rpc.mainnet.chain.robinhood.com';
const POLL_SECONDS = Number(process.env.POLL_SECONDS || 300);
const ONCE = process.argv.includes('--once');
const DRY = process.argv.includes('--dry-run');

const feedAbi = parseAbi([
  'function latestRoundData() view returns (uint80,int256,uint256,uint256,uint80)',
  'function getRoundData(uint80) view returns (uint80,int256,uint256,uint256,uint80)',
]);
const tokenAbi = parseAbi(['function paused() view returns (bool)']);
const pausedEvent = parseAbiItem('event Paused(address account)');

type Deployment = { chainId: number; configChainId: number; startBlock: number; contracts: Record<string, Address> };
type Asset = { symbol: string; token: Address; feed: Address };

function log(...a: unknown[]) {
  console.log(new Date().toISOString(), ...a);
}

function loadContext(chainId: number) {
  const depFile = join(repo, 'deployments', `${chainId}.json`);
  if (!existsSync(depFile)) throw new Error(`No deployment for chain ${chainId} at ${depFile}`);
  const dep = JSON.parse(readFileSync(depFile, 'utf8')) as Deployment;
  const cfg = JSON.parse(readFileSync(join(repo, 'config', 'chains.json'), 'utf8'))[`chain_${dep.configChainId}`];
  const assets: Asset[] = cfg.symbols.map((s: string, i: number) => ({ symbol: s, token: cfg.tokens[i], feed: cfg.feeds[i] }));
  return { dep, assets };
}

class Keeper {
  private covers = new Map<bigint, { productId: number; status: number; asset: Address; start: bigint; end: bigint }>();
  private nextCoverToScan = 1n;
  private seenEvents = new Set<string>();
  private lastHaltPoke = new Map<Address, number>();

  constructor(
    private pub: PublicClient,
    private wallet: WalletClient,
    private account: Account | Address,
    private dep: Deployment,
    private assets: Asset[],
  ) {}

  private c(name: string): Address {
    return this.dep.contracts[name];
  }

  private async send(label: string, req: { address: Address; abi: readonly unknown[]; functionName: string; args?: readonly unknown[] }) {
    try {
      const { request } = await this.pub.simulateContract({ ...(req as object), account: this.account } as never);
      if (DRY) {
        log(`[dry-run] would send ${label}`);
        return true;
      }
      const hash = await this.wallet.writeContract(request as never);
      const rcpt = await this.pub.waitForTransactionReceipt({ hash });
      log(`${label}: ${rcpt.status} ${hash}`);
      return rcpt.status === 'success';
    } catch (e) {
      const msg = (e as { shortMessage?: string }).shortMessage ?? String(e);
      log(`${label}: skipped (${msg.split('\n')[0]})`);
      return false;
    }
  }

  private async now(): Promise<bigint> {
    return (await this.pub.getBlock()).timestamp;
  }

  async tick() {
    await this.depeg().catch((e) => log('depeg error', e));
    await this.outage().catch((e) => log('outage error', e));
    await this.halt().catch((e) => log('halt error', e));
    await this.gap().catch((e) => log('gap error', e));
    await this.scanCovers().catch((e) => log('cover scan error', e));
    await this.payClaims().catch((e) => log('claim error', e));
    await this.expire().catch((e) => log('expire error', e));
  }

  // ------------------------------------------------------------------ depeg
  async depeg() {
    const r = this.c('resolverDepeg');
    const threshold = await this.pub.readContract({ address: r, abi: depegResolverAbi, functionName: 'thresholdBps' });
    for (const a of this.assets) {
      const enabled = await this.pub.readContract({ address: r, abi: depegResolverAbi, functionName: 'assetEnabled', args: [a.token] });
      if (!enabled) continue;
      const ep = await this.pub.readContract({ address: r, abi: depegResolverAbi, functionName: 'episodes', args: [a.token] });
      let dev: bigint | undefined;
      try {
        dev = (await this.pub.readContract({ address: r, abi: depegResolverAbi, functionName: 'deviationBps', args: [a.token] }))[2];
      } catch {
        // oracle stale (market closed) - clean up lapsed episodes
        if (ep[0] !== 0n) await this.send(`depeg.expireEpisode(${a.symbol})`, { address: r, abi: depegResolverAbi, functionName: 'expireEpisode', args: [a.token] });
        continue;
      }
      if (dev >= BigInt(threshold) || ep[0] !== 0n) {
        await this.send(`depeg.poke(${a.symbol}) dev=${dev}bps`, { address: r, abi: depegResolverAbi, functionName: 'poke', args: [a.token] });
      }
    }
  }

  // ------------------------------------------------------------------ outage
  async outage() {
    const r = this.c('resolverOracleOutage');
    const oracle = this.c('oracleAdapter');
    const threshold = await this.pub.readContract({ address: r, abi: oracleOutageResolverAbi, functionName: 'outageThreshold' });
    for (const a of this.assets) {
      const enabled = await this.pub.readContract({ address: r, abi: oracleOutageResolverAbi, functionName: 'assetEnabled', args: [a.token] });
      if (!enabled) continue;
      const [lastUpdate, stale] = await this.pub.readContract({ address: r, abi: oracleOutageResolverAbi, functionName: 'staleOpenSeconds', args: [a.token] });
      const maxStale = await this.pub.readContract({ address: oracle, abi: chainlinkOracleAdapterAbi, functionName: 'maxStaleness', args: [a.token] });
      const suspected = await this.pub.readContract({ address: r, abi: oracleOutageResolverAbi, functionName: 'suspected', args: [a.token] });
      const late = stale >= maxStale;
      const eventId = await this.pub.readContract({ address: r, abi: oracleOutageResolverAbi, functionName: 'eventIdFor', args: [a.token, lastUpdate] });
      const recorded = (await this.pub.readContract({ address: r, abi: oracleOutageResolverAbi, functionName: 'eventDetails', args: [eventId] })).resolvedAt !== 0n;
      if (late !== suspected || (stale >= BigInt(threshold) && !recorded)) {
        await this.send(`outage.report(${a.symbol}) stale=${stale}s`, { address: r, abi: oracleOutageResolverAbi, functionName: 'report', args: [a.token] });
      }
    }
  }

  // ------------------------------------------------------------------ issuer halt
  async halt() {
    const r = this.c('resolverIssuerHalt');
    const att = this.c('attestationModule');
    const threshold = BigInt(await this.pub.readContract({ address: r, abi: issuerHaltResolverAbi, functionName: 'haltThreshold' }));
    const now = await this.now();
    for (const a of this.assets) {
      const enabled = await this.pub.readContract({ address: r, abi: issuerHaltResolverAbi, functionName: 'assetEnabled', args: [a.token] });
      if (!enabled) continue;
      const paused = await this.pub.readContract({ address: a.token, abi: tokenAbi, functionName: 'paused' });
      const firstSeen = await this.pub.readContract({ address: r, abi: issuerHaltResolverAbi, functionName: 'firstSeenPaused', args: [a.token] });
      const last = this.lastHaltPoke.get(a.token) ?? 0;
      const stateChanged = (paused && firstSeen === 0n) || (!paused && firstSeen !== 0n);
      if (stateChanged || Date.now() - last > 3_600_000) {
        if (await this.send(`halt.poke(${a.symbol}) paused=${paused}`, { address: r, abi: issuerHaltResolverAbi, functionName: 'poke', args: [a.token] })) {
          this.lastHaltPoke.set(a.token, Date.now());
        }
      }
      const pending = await this.pub.readContract({ address: r, abi: issuerHaltResolverAbi, functionName: 'pendingClaim', args: [a.token] });
      if (paused && firstSeen !== 0n && pending === '0x0000000000000000000000000000000000000000000000000000000000000000') {
        const start = await this.haltStart(a.token, firstSeen, r);
        if (now - start >= threshold) {
          await this.send(`halt.proposeHalt(${a.symbol}, ${start})`, { address: r, abi: issuerHaltResolverAbi, functionName: 'proposeHalt', args: [a.token, start] });
        }
      }
      if (pending !== '0x0000000000000000000000000000000000000000000000000000000000000000') {
        const claim = await this.pub.readContract({ address: r, abi: issuerHaltResolverAbi, functionName: 'claims', args: [pending] });
        const attId = claim[3];
        const status = await this.pub.readContract({ address: att, abi: attestationModuleAbi, functionName: 'statusOf', args: [attId] });
        if (status === 1 || status === 2) {
          await this.send(`attestation.finalize(${attId})`, { address: att, abi: attestationModuleAbi, functionName: 'finalize', args: [attId] });
        }
        await this.send(`halt.settle(${a.symbol})`, { address: r, abi: issuerHaltResolverAbi, functionName: 'settle', args: [pending] });
      }
    }
  }

  /** Halt start = timestamp of the latest Paused event, clamped into the on-chain observation bounds. */
  private async haltStart(token: Address, firstSeen: bigint, resolver: Address): Promise<bigint> {
    const lastUnpaused = await this.pub.readContract({ address: resolver, abi: issuerHaltResolverAbi, functionName: 'lastSeenUnpaused', args: [token] });
    try {
      const latest = await this.pub.getBlockNumber();
      const from = latest > 500_000n ? latest - 500_000n : 0n;
      const logs = await this.pub.getLogs({ address: token, event: pausedEvent, fromBlock: from, toBlock: latest });
      const lastLog = logs.at(-1);
      if (lastLog?.blockNumber) {
        const ts = (await this.pub.getBlock({ blockNumber: lastLog.blockNumber })).timestamp;
        if (ts > lastUnpaused && ts <= firstSeen) return ts;
      }
    } catch {
      /* fall through */
    }
    return firstSeen;
  }

  // ------------------------------------------------------------------ weekend gap
  async gap() {
    const r = this.c('resolverWeekendGap');
    const clock = this.c('marketClock');
    const now = await this.now();
    const delay = BigInt(await this.pub.readContract({ address: r, abi: weekendGapResolverAbi, functionName: 'maxOpenDelay' }));
    let week = await this.pub.readContract({ address: clock, abi: marketClockAbi, functionName: 'weekIdOf', args: [now] });
    for (let k = 0; k < 2; k++, week--) {
      const [close, open] = await this.pub.readContract({ address: clock, abi: marketClockAbi, functionName: 'weeklyWindow', args: [week] });
      if (now < open + 600n) continue; // give the first post-open round time to land
      for (const a of this.assets) {
        const enabled = await this.pub.readContract({ address: r, abi: weekendGapResolverAbi, functionName: 'assetEnabled', args: [a.token] });
        if (!enabled) continue;
        const id = await this.pub.readContract({ address: r, abi: weekendGapResolverAbi, functionName: 'eventIdFor', args: [a.token, week] });
        const ev = await this.pub.readContract({ address: r, abi: weekendGapResolverAbi, functionName: 'eventDetails', args: [id] });
        if (ev.resolvedAt !== 0n) continue;
        let hints: [bigint, bigint] | undefined;
        try {
          hints = await this.findHints(a.feed, close, open, delay);
        } catch (e) {
          log(`gap(${a.symbol}, week ${week}): RPC error while searching rounds, will retry next loop (${String(e).split('\n')[0]})`);
          continue;
        }
        if (!hints) {
          log(`gap(${a.symbol}, week ${week}): no valid rounds yet`);
          continue;
        }
        await this.send(`gap.resolve(${a.symbol}, week ${week})`, {
          address: r,
          abi: weekendGapResolverAbi,
          functionName: 'resolve',
          args: [a.token, week, hints[0], hints[1]],
        });
      }
    }
  }

  /**
   * updatedAt of a round; 0 only if the round genuinely does not exist (the call reverts).
   * Transport errors are retried and finally re-thrown, so a flaky RPC can never corrupt the binary search.
   */
  private async updatedAt(feed: Address, id: bigint): Promise<bigint> {
    for (let attempt = 0; ; attempt++) {
      try {
        return (await this.pub.readContract({ address: feed, abi: feedAbi, functionName: 'getRoundData', args: [id] }))[3];
      } catch (e) {
        const reverted = e instanceof BaseError && e.walk((x) => x instanceof ContractFunctionRevertedError) !== null;
        if (reverted) return 0n;
        if (attempt >= 4) throw e;
        await new Promise((r) => setTimeout(r, 1000 * (attempt + 1)));
      }
    }
  }

  /** Binary search within the latest aggregator phase for [last round <= close, first round >= open]. */
  private async findHints(feed: Address, close: bigint, open: bigint, maxDelay: bigint): Promise<[bigint, bigint] | undefined> {
    const [latest] = await this.pub.readContract({ address: feed, abi: feedAbi, functionName: 'latestRoundData' });
    const phase = (latest >> 64n) << 64n;
    const top = latest & ((1n << 64n) - 1n);
    if ((await this.updatedAt(feed, phase | 1n)) > close) return undefined;
    let lo = 1n;
    let hi = top;
    while (lo < hi) {
      const mid = lo + (hi - lo + 1n) / 2n;
      if ((await this.updatedAt(feed, phase | mid)) <= close) lo = mid;
      else hi = mid - 1n;
    }
    const closeRound = phase | lo;
    lo = 1n;
    hi = top;
    while (lo < hi) {
      const mid = lo + (hi - lo) / 2n;
      if ((await this.updatedAt(feed, phase | mid)) >= open) hi = mid;
      else lo = mid + 1n;
    }
    const openRound = phase | lo;
    const ou = await this.updatedAt(feed, openRound);
    if (ou < open || ou > open + maxDelay) return undefined;
    return [closeRound, openRound];
  }

  // ------------------------------------------------------------------ covers / claims / expiry
  async scanCovers() {
    const reg = this.c('coverRegistry');
    const next = await this.pub.readContract({ address: reg, abi: coverRegistryAbi, functionName: 'nextCoverId' });
    for (let id = 1n; id < next; id++) {
      const known = this.covers.get(id);
      if (known && known.status !== 1) continue; // final
      if (known && id < this.nextCoverToScan && id % 10n !== BigInt(Date.now() % 10)) continue; // refresh lazily
      const c = await this.pub.readContract({ address: reg, abi: coverRegistryAbi, functionName: 'getCover', args: [id] });
      this.covers.set(id, { productId: c.productId, status: c.status, asset: c.asset, start: c.start, end: c.end });
    }
    this.nextCoverToScan = next;
  }

  async payClaims() {
    const reg = this.c('coverRegistry');
    const resolvers = ['resolverWeekendGap', 'resolverDepeg', 'resolverOracleOutage', 'resolverIssuerHalt'];
    for (let p = 0; p < 4; p++) {
      const r = this.c(resolvers[p]);
      const count = await this.pub.readContract({ address: r, abi: weekendGapResolverAbi, functionName: 'eventCount' });
      const from = count > 200n ? count - 200n : 0n;
      const ids = await this.pub.readContract({ address: r, abi: weekendGapResolverAbi, functionName: 'eventIdsPage', args: [from, 200n] });
      for (const eventId of ids as readonly Hex[]) {
        const ev = await this.pub.readContract({ address: r, abi: weekendGapResolverAbi, functionName: 'eventDetails', args: [eventId] });
        if (!ev.triggered) continue;
        for (const [coverId, c] of this.covers) {
          if (c.status !== 1 || c.productId !== p) continue;
          if (c.asset.toLowerCase() !== ev.asset.toLowerCase()) continue;
          if (ev.eventTime < c.start || ev.eventTime > c.end) continue;
          const ok = await this.send(`claim(cover ${coverId}, event ${eventId.slice(0, 10)})`, {
            address: reg,
            abi: coverRegistryAbi,
            functionName: 'claim',
            args: [coverId, eventId],
          });
          if (ok) c.status = 2;
        }
        this.seenEvents.add(eventId);
      }
    }
  }

  async expire() {
    const reg = this.c('coverRegistry');
    const grace = await this.pub.readContract({ address: reg, abi: coverRegistryAbi, functionName: 'claimGracePeriod' });
    const now = await this.now();
    const due = [...this.covers.entries()].filter(([, c]) => c.status === 1 && now > c.end + grace).map(([id]) => id);
    for (let i = 0; i < due.length; i += 100) {
      const batch = due.slice(i, i + 100);
      if (await this.send(`expireCovers(${batch.length})`, { address: reg, abi: coverRegistryAbi, functionName: 'expireCovers', args: [batch] })) {
        for (const id of batch) this.covers.get(id)!.status = 3;
      }
    }
  }
}

async function main() {
  const probe = createPublicClient({ transport: http(RPC_URL) });
  const chainId = await probe.getChainId();
  const { dep, assets } = loadContext(chainId);
  const chain = defineChain({
    id: chainId,
    name: `chain-${chainId}`,
    nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
    rpcUrls: { default: { http: [RPC_URL] } },
  });
  const pub = createPublicClient({ chain, transport: http(RPC_URL) }) as PublicClient;

  let account: Account | Address;
  const unlocked = process.env.KEEPER_UNLOCKED_ADDRESS as Address | undefined;
  if (unlocked) {
    if (chainId !== 31337) throw new Error('KEEPER_UNLOCKED_ADDRESS is only allowed on a local fork (chain 31337)');
    account = unlocked;
  } else {
    const name = process.env.KEEPER_ACCOUNT || 'gapguard-keeper';
    const pw = await readPassword(`Password for keystore "${name}": `);
    account = loadKeystoreAccount(name, pw);
  }
  const wallet = createWalletClient({ chain, transport: http(RPC_URL), account: account as never });
  const addr = typeof account === 'string' ? account : account.address;
  log(`keeper ${addr} on chain ${chainId}; registry ${dep.contracts.coverRegistry}; ${assets.length} assets; poll ${POLL_SECONDS}s${DRY ? ' (dry-run)' : ''}`);

  const keeper = new Keeper(pub, wallet, account, dep, assets);
  for (;;) {
    const t = Date.now();
    await keeper.tick();
    if (ONCE) break;
    const wait = Math.max(5_000, POLL_SECONDS * 1000 - (Date.now() - t));
    await new Promise((r) => setTimeout(r, wait));
  }
}

main().catch((e) => {
  console.error(e instanceof Error ? e.message : e);
  process.exit(1);
});
