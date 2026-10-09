'use client';

import { useReadContract, useReadContracts } from 'wagmi';
import type { Address, Hex } from 'viem';
import { weekendGapResolverAbi } from '@/abi';
import { PRODUCTS, type ProductMeta } from '@/lib/products';
import { assetByToken, fmtDate, useGapguard } from '@/lib/hooks';

const PAGE = 50n;

type TriggerEvent = { asset: Address; eventTime: bigint; resolvedAt: bigint; triggered: boolean; metric: bigint };

export default function TriggersPage() {
  return (
    <>
      <h1>Trigger history</h1>
      <p className="lead">
        Every measurement the resolvers have recorded on-chain, including checks that did not trigger. Each event id
        can be recorded only once, and a triggered event pays every eligible cover exactly once.
      </p>
      <div className="grid">
        {PRODUCTS.map((p) => (
          <ResolverHistory key={p.id} product={p} />
        ))}
      </div>
    </>
  );
}

function ResolverHistory({ product }: { product: ProductMeta }) {
  const { deployment, assets } = useGapguard();
  const resolver = deployment?.contracts[product.resolverKey] as Address | undefined;
  const { data: count } = useReadContract({
    address: resolver,
    abi: weekendGapResolverAbi,
    functionName: 'eventCount',
    query: { enabled: Boolean(resolver) },
  });
  const n = count ?? 0n;
  const offset = n > PAGE ? n - PAGE : 0n;
  const { data: ids } = useReadContract({
    address: resolver,
    abi: weekendGapResolverAbi,
    functionName: 'eventIdsPage',
    args: [offset, PAGE],
    query: { enabled: Boolean(resolver && n > 0n) },
  });
  const details = useReadContracts({
    contracts: (ids ?? []).map((id) => ({
      address: resolver!,
      abi: weekendGapResolverAbi,
      functionName: 'eventDetails' as const,
      args: [id as Hex] as const,
    })),
    query: { enabled: Boolean(resolver && ids?.length) },
  });
  const status = useReadContracts({
    contracts: resolver
      ? [
          { address: resolver, abi: weekendGapResolverAbi, functionName: 'withdrawalsBlocked' },
          { address: resolver, abi: weekendGapResolverAbi, functionName: 'lastTriggerAt' },
        ]
      : [],
    query: { enabled: Boolean(resolver) },
  });
  const blocked = status.data?.[0]?.result as boolean | undefined;
  const lastTrigger = status.data?.[1]?.result as bigint | undefined;

  const rows = (ids ?? [])
    .map((id, i) => ({ id, e: details.data?.[i]?.result as TriggerEvent | undefined }))
    .reverse();

  return (
    <div className="card" style={{ overflowX: 'auto' }}>
      <div className="row" style={{ justifyContent: 'space-between' }}>
        <h2 style={{ margin: 0 }}>{product.name}</h2>
        <div className="row small">
          <span className="muted">{n.toString()} records</span>
          {blocked ? <span className="pill amber">event pending / settling</span> : <span className="pill green">normal</span>}
          {lastTrigger ? <span className="muted">last trigger {fmtDate(lastTrigger)}</span> : null}
        </div>
      </div>
      <p className="small muted">{product.trigger}</p>
      {rows.length === 0 ? (
        <p className="muted small">No records yet.</p>
      ) : (
        <table>
          <thead>
            <tr>
              <th>Asset</th>
              <th>Event time</th>
              <th>Recorded</th>
              <th className="num">{product.metricLabel}</th>
              <th>Result</th>
            </tr>
          </thead>
          <tbody>
            {rows.map(({ id, e }) => (
              <tr key={id}>
                <td>{e ? (assetByToken(assets, e.asset)?.symbol ?? e.asset) : '…'}</td>
                <td>{e ? fmtDate(e.eventTime) : '…'}</td>
                <td>{e ? fmtDate(e.resolvedAt) : '…'}</td>
                <td className="num">{e ? product.metricFormat(e.metric) : '…'}</td>
                <td>{e ? e.triggered ? <span className="pill red">Triggered</span> : <span className="pill">No trigger</span> : '…'}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </div>
  );
}
