/**
 * Read-only sanity check of the keeper's round-hint search against a live RPC (no transactions).
 * Usage: tsx src/check-hints.ts [feed] [closeTs] [openTs]
 * Defaults: AAPL/USD feed on Robinhood Chain, week 2961 (close Sat 2026-10-03 00:00 UTC, reopen Mon 2026-10-05 00:00 UTC).
 */
import { BaseError, ContractFunctionRevertedError, createPublicClient, http, parseAbi, type Address } from 'viem';

const RPC = process.env.KEEPER_RPC_URL || 'https://rpc.mainnet.chain.robinhood.com';
const feed = (process.argv[2] || '0x6B22A786bAa607d76728168703a39Ea9C99f2cD0') as Address;
const close = BigInt(process.argv[3] || 1790985600);
const open = BigInt(process.argv[4] || 1791158400);
const abi = parseAbi([
  'function latestRoundData() view returns (uint80,int256,uint256,uint256,uint80)',
  'function getRoundData(uint80) view returns (uint80,int256,uint256,uint256,uint80)',
]);
const pub = createPublicClient({ transport: http(RPC) });

async function round(id: bigint): Promise<[bigint, bigint]> {
  for (let attempt = 0; ; attempt++) {
    try {
      const r = await pub.readContract({ address: feed, abi, functionName: 'getRoundData', args: [id] });
      return [r[1], r[3]];
    } catch (e) {
      if (e instanceof BaseError && e.walk((x) => x instanceof ContractFunctionRevertedError)) return [0n, 0n];
      if (attempt >= 4) throw e;
      await new Promise((r) => setTimeout(r, 1000 * (attempt + 1)));
    }
  }
}

const [latest] = await pub.readContract({ address: feed, abi, functionName: 'latestRoundData' });
const phase = (latest >> 64n) << 64n;
const top = latest & ((1n << 64n) - 1n);
let lo = 1n;
let hi = top;
while (lo < hi) {
  const mid = lo + (hi - lo + 1n) / 2n;
  if ((await round(phase | mid))[1] <= close) lo = mid;
  else hi = mid - 1n;
}
const closeRound = phase | lo;
lo = 1n;
hi = top;
while (lo < hi) {
  const mid = lo + (hi - lo) / 2n;
  if ((await round(phase | mid))[1] >= open) hi = mid;
  else lo = mid + 1n;
}
const openRound = phase | lo;
const [cp, cu] = await round(closeRound);
const [op, ou] = await round(openRound);
const gapBps = op < cp ? ((cp - op) * 10_000n) / cp : 0n;
console.log({ closeRound, cu, cp, openRound, ou, op, openDelaySec: ou - open, gapBps, withinMaxDelay: ou - open <= 21600n });
