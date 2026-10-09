// Exports config/chains.ts into config/chains.json in a Foundry-friendly shape (parallel arrays per chain).
// Run with: node config/export.ts   (Node >= 22.6 strips TypeScript types natively)
import { writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { chains } from './chains.ts';

const ZERO = '0x0000000000000000000000000000000000000000';
const out: Record<string, unknown> = {};
for (const c of Object.values(chains)) {
  out[`chain_${c.chainId}`] = {
    chainId: c.chainId,
    stablecoin: c.stablecoin.address,
    stablecoinFeed: c.stablecoin.feed,
    weth: c.weth.address,
    wethFeed: c.weth.feed,
    sequencerUptimeFeed: c.sequencerUptimeFeed ?? ZERO,
    symbols: c.assets.map((a) => a.symbol),
    tokens: c.assets.map((a) => a.token),
    feeds: c.assets.map((a) => a.feed),
    dexPools: c.assets.map((a) => a.dexPool ?? ZERO),
    gap: c.assets.map((a) => a.products.gap),
    depeg: c.assets.map((a) => a.products.depeg),
    outage: c.assets.map((a) => a.products.outage),
    halt: c.assets.map((a) => a.products.halt),
  };
}
const here = dirname(fileURLToPath(import.meta.url));
writeFileSync(join(here, 'chains.json'), JSON.stringify(out, null, 2) + '\n');
console.log('wrote config/chains.json for chains', Object.keys(out).join(', '));
