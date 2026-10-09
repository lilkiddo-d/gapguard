'use client';

import { useAccount, useReadContract, useReadContracts } from 'wagmi';
import type { Address } from 'viem';
import { coverNFTAbi, coverRegistryAbi } from '@/abi';
import { PRODUCTS, STATUS } from '@/lib/products';
import { assetByToken, fmtDate, fmtUsd, useGapguard } from '@/lib/hooks';

type Cover = {
  productId: number;
  status: number;
  asset: Address;
  start: bigint;
  end: bigint;
  amount: bigint;
  premium: bigint;
};

export default function CoversPage() {
  const { address } = useAccount();
  const { deployment, assets } = useGapguard();
  const nft = deployment?.contracts.coverNFT;
  const registry = deployment?.contracts.coverRegistry;

  const { data: count } = useReadContract({
    address: nft,
    abi: coverNFTAbi,
    functionName: 'balanceOf',
    args: address ? [address] : undefined,
    query: { enabled: Boolean(nft && address) },
  });
  const n = Number(count ?? 0n);
  const ids = useReadContracts({
    contracts: Array.from({ length: Math.min(n, 100) }, (_, i) => ({
      address: nft!,
      abi: coverNFTAbi,
      functionName: 'tokenOfOwnerByIndex' as const,
      args: [address!, BigInt(i)] as const,
    })),
    query: { enabled: Boolean(nft && address && n > 0) },
  });
  const coverIds = (ids.data ?? []).map((r) => r.result as bigint | undefined).filter((x): x is bigint => x !== undefined);
  const covers = useReadContracts({
    contracts: coverIds.map((id) => ({
      address: registry!,
      abi: coverRegistryAbi,
      functionName: 'getCover' as const,
      args: [id] as const,
    })),
    query: { enabled: Boolean(registry && coverIds.length) },
  });

  const now = Math.floor(Date.now() / 1000);

  return (
    <>
      <h1>My covers</h1>
      <p className="lead">
        Each cover is an ERC-721 NFT. Whoever holds it when a trigger resolves receives the payout — keepers pay
        claimable covers automatically, so you do not need to do anything.
      </p>
      {!address && <div className="card muted">Connect a wallet to see your covers.</div>}
      {address && n === 0 && <div className="card muted">No covers yet.</div>}
      {coverIds.length > 0 && (
        <div className="card" style={{ overflowX: 'auto' }}>
          <table>
            <thead>
              <tr>
                <th>#</th>
                <th>Product</th>
                <th>Asset</th>
                <th className="num">Amount</th>
                <th className="num">Premium</th>
                <th>Period</th>
                <th>Status</th>
              </tr>
            </thead>
            <tbody>
              {coverIds.map((id, i) => {
                const c = covers.data?.[i]?.result as Cover | undefined;
                if (!c) {
                  return (
                    <tr key={id.toString()}>
                      <td>{id.toString()}</td>
                      <td colSpan={6} className="muted">
                        loading…
                      </td>
                    </tr>
                  );
                }
                const a = assetByToken(assets, c.asset);
                const status = STATUS[c.status];
                const live = status === 'Active' && now >= Number(c.start) && now <= Number(c.end);
                const pending = status === 'Active' && now < Number(c.start);
                const ended = status === 'Active' && now > Number(c.end);
                return (
                  <tr key={id.toString()}>
                    <td>{id.toString()}</td>
                    <td>{PRODUCTS[c.productId]?.name}</td>
                    <td>{a?.symbol ?? c.asset}</td>
                    <td className="num">{fmtUsd(c.amount)}</td>
                    <td className="num">{fmtUsd(c.premium)}</td>
                    <td className="small">
                      {fmtDate(c.start)} → {fmtDate(c.end)}
                    </td>
                    <td>
                      {status === 'Claimed' && <span className="pill green">Paid out</span>}
                      {status === 'Expired' && <span className="pill">Expired</span>}
                      {live && <span className="pill green">Active</span>}
                      {pending && <span className="pill amber">Starts soon</span>}
                      {ended && <span className="pill">Ended · grace period</span>}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
          {n > 100 && <p className="small muted">Showing the first 100 covers.</p>}
        </div>
      )}
    </>
  );
}
