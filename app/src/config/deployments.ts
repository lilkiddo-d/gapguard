import mainnet from './deployments/4663.json';
import fork from './deployments/31337.json';
import type { Address } from 'viem';

export interface Deployment {
  chainId: number;
  configChainId: number;
  startBlock: number;
  deployedAt: number;
  stablecoin: Address;
  roles: { admin: Address; guardian: Address; keeper: Address; committee: Address };
  contracts: {
    timelock: Address;
    oracleAdapter: Address;
    marketClock: Address;
    pricingCurve: Address;
    feeCollector: Address;
    complianceRegistry: Address;
    projectTokenHooks: Address;
    attestationModule: Address;
    coverNFT: Address;
    coverRegistry: Address;
    poolWeekendGap: Address;
    poolDepeg: Address;
    poolOracleOutage: Address;
    poolIssuerHalt: Address;
    resolverWeekendGap: Address;
    resolverDepeg: Address;
    resolverOracleOutage: Address;
    resolverIssuerHalt: Address;
  };
}

const all: Record<number, Partial<Deployment>> = { 4663: mainnet, 31337: fork };

export function getDeployment(chainId: number | undefined): Deployment | undefined {
  if (!chainId) return undefined;
  const d = all[chainId];
  return d && d.contracts ? (d as Deployment) : undefined;
}
