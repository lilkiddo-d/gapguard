// Keeps the app in sync with the monorepo:
//  1. copies ../config/chains.ts -> src/config/chains.ts (single source of truth for addresses)
//  2. regenerates src/abi/*.ts from ../contracts/out when Foundry artifacts exist
//  3. ensures src/config/deployments/{4663,31337}.json exist (written by script/Deploy.s.sol)
// Every step is skipped gracefully when the source is missing (e.g. Vercel building only /app).
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const app = join(dirname(fileURLToPath(import.meta.url)), '..');
const repo = join(app, '..');

const cfgSrc = join(repo, 'config', 'chains.ts');
if (existsSync(cfgSrc)) {
  const banner = '// AUTO-COPIED from /config/chains.ts by app/scripts/sync.mjs - edit the original.\n';
  writeFileSync(join(app, 'src', 'config', 'chains.ts'), banner + readFileSync(cfgSrc, 'utf8'));
  console.log('[sync] config/chains.ts copied');
}

const contracts = [
  'CoverRegistry',
  'CoverNFT',
  'CapitalPool',
  'WeekendGapResolver',
  'DepegResolver',
  'OracleOutageResolver',
  'IssuerHaltResolver',
  'ProjectTokenHooks',
  'AttestationModule',
  'ChainlinkOracleAdapter',
  'MarketClock',
];
const out = join(repo, 'contracts', 'out');
if (existsSync(out)) {
  mkdirSync(join(app, 'src', 'abi'), { recursive: true });
  const index = [];
  for (const name of contracts) {
    const f = join(out, `${name}.sol`, `${name}.json`);
    if (!existsSync(f)) continue;
    const abi = JSON.parse(readFileSync(f, 'utf8')).abi;
    const varName = name.charAt(0).toLowerCase() + name.slice(1) + 'Abi';
    writeFileSync(
      join(app, 'src', 'abi', `${name}.ts`),
      `// Generated from contracts/out by app/scripts/sync.mjs. Do not edit.\nexport const ${varName} = ${JSON.stringify(abi, null, 2)} as const;\n`,
    );
    index.push(`export { ${varName} } from './${name}';`);
  }
  writeFileSync(join(app, 'src', 'abi', 'index.ts'), index.join('\n') + '\n');
  console.log(`[sync] ${index.length} ABIs generated`);
}

const depDir = join(app, 'src', 'config', 'deployments');
mkdirSync(depDir, { recursive: true });
for (const id of ['4663', '31337']) {
  const f = join(depDir, `${id}.json`);
  if (!existsSync(f)) writeFileSync(f, '{}\n');
}
