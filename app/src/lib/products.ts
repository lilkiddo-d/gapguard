import type { Deployment } from '@/config/deployments';

export type ProductKey = 'gap' | 'depeg' | 'outage' | 'halt';

export interface ProductMeta {
  id: number;
  key: ProductKey;
  name: string;
  short: string;
  trigger: string;
  how: string;
  poolKey: keyof Deployment['contracts'];
  resolverKey: keyof Deployment['contracts'];
  resolverAbiName: 'WeekendGapResolver' | 'DepegResolver' | 'OracleOutageResolver' | 'IssuerHaltResolver';
  metricLabel: string;
  metricFormat: (v: bigint) => string;
}

const bps = (v: bigint) => `${(Number(v) / 100).toFixed(2)}%`;
const hours = (v: bigint) => `${(Number(v) / 3600).toFixed(1)}h`;

export const PRODUCTS: ProductMeta[] = [
  {
    id: 0,
    key: 'gap',
    name: 'Weekend Gap Cover',
    short: 'Gap',
    trigger: 'Pays if the token reopens more than 10% below its Friday close.',
    how: 'The last Chainlink round at or before Friday 8pm New York time is compared with the first round after the Sunday 8pm reopen. Round ids are verified on-chain, so anyone can resolve.',
    poolKey: 'poolWeekendGap',
    resolverKey: 'resolverWeekendGap',
    resolverAbiName: 'WeekendGapResolver',
    metricLabel: 'Gap',
    metricFormat: bps,
  },
  {
    id: 1,
    key: 'depeg',
    name: 'Depeg Cover',
    short: 'Depeg',
    trigger: 'Pays if the on-chain DEX price trades more than 5% away from the oracle price for 4+ hours.',
    how: 'A 30-minute Uniswap v3 TWAP is compared with the Chainlink price on frequent permissionless pokes. The deviation must hold continuously, with no gaps in observations, for the whole window.',
    poolKey: 'poolDepeg',
    resolverKey: 'resolverDepeg',
    resolverAbiName: 'DepegResolver',
    metricLabel: 'Deviation',
    metricFormat: bps,
  },
  {
    id: 2,
    key: 'outage',
    name: 'Oracle Outage Cover',
    short: 'Outage',
    trigger: 'Pays if the asset’s price feed stops updating for 30+ hours of open-market time.',
    how: 'Staleness only counts while the 24/5 market is open (weekend closures and flagged holidays are excluded). The outage must begin after your cover starts.',
    poolKey: 'poolOracleOutage',
    resolverKey: 'resolverOracleOutage',
    resolverAbiName: 'OracleOutageResolver',
    metricLabel: 'Stale (open time)',
    metricFormat: hours,
  },
  {
    id: 3,
    key: 'halt',
    name: 'Issuer Halt Cover',
    short: 'Halt',
    trigger: 'Pays if the token issuer pauses transfers for 24+ hours.',
    how: 'The token’s paused() flag is checked on-chain by keepers. The halt start time is attested and goes through a 24h dispute window before it pays.',
    poolKey: 'poolIssuerHalt',
    resolverKey: 'resolverIssuerHalt',
    resolverAbiName: 'IssuerHaltResolver',
    metricLabel: 'Halted for',
    metricFormat: hours,
  },
];

export const STATUS = ['None', 'Active', 'Claimed', 'Expired'] as const;
