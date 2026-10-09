'use client';

import { useAccount, useChainId } from 'wagmi';
import { formatUnits, isAddress, type Address } from 'viem';
import { chains as chainConfigs, type AssetConfig } from '@/config/chains';
import { getDeployment } from '@/config/deployments';

export function useGapguard() {
  const walletChainId = useChainId();
  const { chainId: accountChainId } = useAccount();
  const chainId = accountChainId ?? walletChainId;
  const deployment = getDeployment(chainId);
  const chainConfig = chainConfigs[chainId];
  return { chainId, deployment, chainConfig, assets: chainConfig?.assets ?? [] };
}

export const PROJECT_TOKEN = (process.env.NEXT_PUBLIC_PROJECT_TOKEN || '').trim();
export const tokenFeaturesEnabled = isAddress(PROJECT_TOKEN);

export function fmtUsd(v: bigint | undefined, decimals = 6, digits = 2): string {
  if (v === undefined) return '—';
  const n = Number(formatUnits(v, decimals));
  return n.toLocaleString(undefined, { minimumFractionDigits: digits, maximumFractionDigits: digits });
}

export function fmtDate(ts: bigint | number | undefined): string {
  if (ts === undefined) return '—';
  const n = typeof ts === 'bigint' ? Number(ts) : ts;
  if (!n) return '—';
  return new Date(n * 1000).toLocaleString(undefined, {
    year: 'numeric',
    month: 'short',
    day: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
  });
}

export function shortAddr(a?: string): string {
  return a ? `${a.slice(0, 6)}…${a.slice(-4)}` : '—';
}

export function assetByToken(assets: AssetConfig[], token?: Address): AssetConfig | undefined {
  if (!token) return undefined;
  return assets.find((a) => a.token.toLowerCase() === token.toLowerCase());
}

export function explorerTx(chainId: number, hash: string): string | undefined {
  const url = chainConfigs[chainId]?.explorer.url;
  return url ? `${url}/tx/${hash}` : undefined;
}
