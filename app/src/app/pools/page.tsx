'use client';

import { useState } from 'react';
import { useAccount, useReadContracts } from 'wagmi';
import { erc20Abi, parseUnits, type Address } from 'viem';
import { capitalPoolAbi, coverRegistryAbi, weekendGapResolverAbi } from '@/abi';
import { PRODUCTS, type ProductMeta } from '@/lib/products';
import { fmtDate, fmtUsd, useGapguard } from '@/lib/hooks';
import { TxButton } from '@/components/TxButton';

const YEAR = 365 * 86_400;

export default function PoolsPage() {
  return (
    <>
      <h1>Underwrite cover</h1>
      <p className="lead">
        Deposit USDG into a product pool to earn its premiums. Your capital pays claims when that product triggers.
        Exits take a 14-day cooldown (your shares stay exposed meanwhile), can only use unlocked capital, and are frozen
        while an event is pending.
      </p>
      <div className="grid cols-2">
        {PRODUCTS.map((p) => (
          <PoolCard key={p.id} product={p} />
        ))}
      </div>
    </>
  );
}

function PoolCard({ product }: { product: ProductMeta }) {
  const { address } = useAccount();
  const { deployment, assets, chainConfig } = useGapguard();
  const [amount, setAmount] = useState('1000');
  const pool = deployment?.contracts[product.poolKey] as Address | undefined;
  const registry = deployment?.contracts.coverRegistry;
  const resolver = deployment?.contracts[product.resolverKey] as Address | undefined;
  const usdg = chainConfig?.stablecoin.address;
  const eligible = assets.filter((a) => a.products[product.key]);

  const base = pool && registry && resolver;
  const r = useReadContracts({
    allowFailure: true,
    contracts: base
      ? [
          { address: pool, abi: capitalPoolAbi, functionName: 'totalAssets' },
          { address: pool, abi: capitalPoolAbi, functionName: 'lockedCapital' },
          { address: pool, abi: capitalPoolAbi, functionName: 'unvestedPremium' },
          { address: pool, abi: capitalPoolAbi, functionName: 'vestEnd' },
          { address: pool, abi: capitalPoolAbi, functionName: 'vestStart' },
          { address: pool, abi: capitalPoolAbi, functionName: 'cooldown' },
          { address: resolver, abi: weekendGapResolverAbi, functionName: 'withdrawalsBlocked' },
          { address: pool, abi: capitalPoolAbi, functionName: 'balanceOf', args: [address ?? '0x0000000000000000000000000000000000000000'] },
          { address: pool, abi: capitalPoolAbi, functionName: 'withdrawRequests', args: [address ?? '0x0000000000000000000000000000000000000000'] },
          { address: pool, abi: capitalPoolAbi, functionName: 'maxRedeem', args: [address ?? '0x0000000000000000000000000000000000000000'] },
          { address: usdg!, abi: erc20Abi, functionName: 'allowance', args: [address ?? '0x0000000000000000000000000000000000000000', pool] },
        ]
      : [],
    query: { enabled: Boolean(base) },
  });
  const exp = useReadContracts({
    contracts: eligible.map((a) => ({
      address: registry!,
      abi: coverRegistryAbi,
      functionName: 'assetExposure' as const,
      args: [product.id, a.token] as const,
    })),
    query: { enabled: Boolean(registry) },
  });
  const v = (i: number) => (r.data?.[i]?.status === 'success' ? r.data[i].result : undefined);
  const total = v(0) as bigint | undefined;
  const locked = v(1) as bigint | undefined;
  const unvested = v(2) as bigint | undefined;
  const vestEnd = v(3) as bigint | undefined;
  const vestStart = v(4) as bigint | undefined;
  const cooldown = v(5) as bigint | undefined;
  const blocked = v(6) as boolean | undefined;
  const shares = v(7) as bigint | undefined;
  const req = v(8) as readonly [bigint, bigint] | undefined;
  const maxRedeem = v(9) as bigint | undefined;
  const allowance = v(10) as bigint | undefined;
  const exposures = eligible.map((a, i) => ({ asset: a, exposure: (exp.data?.[i]?.result as bigint | undefined) ?? 0n }));

  const util = total && total > 0n && locked !== undefined ? Number((locked * 10_000n) / total) / 100 : 0;
  // Trailing premium APY: premiums currently vesting, annualised over their vesting window.
  let apy: number | undefined;
  if (total && total > 0n && unvested !== undefined && vestEnd && vestStart && vestEnd > vestStart) {
    const now = BigInt(Math.floor(Date.now() / 1000));
    const remaining = vestEnd > now ? vestEnd - now : 0n;
    const rate = remaining > 0n ? Number(unvested) / Number(remaining) : 0; // USDG units per second
    apy = (rate * YEAR * 100) / Number(total);
  }
  let amountWei = 0n;
  try {
    amountWei = parseUnits(amount || '0', 6);
  } catch {}

  return (
    <div className="card">
      <h2>{product.name} pool</h2>
      <div className="grid cols-4" style={{ gridTemplateColumns: 'repeat(3, 1fr)' }}>
        <div>
          <div className="small muted">TVL</div>
          <div className="stat">{fmtUsd(total, 6, 0)}</div>
        </div>
        <div>
          <div className="small muted">Utilisation</div>
          <div className="stat">{util.toFixed(1)}%</div>
        </div>
        <div>
          <div className="small muted">Premium APY</div>
          <div className="stat">{apy !== undefined ? `${apy.toFixed(2)}%` : '—'}</div>
        </div>
      </div>
      <div className="bar" style={{ margin: '12px 0' }}>
        <span style={{ width: `${Math.min(util, 100)}%` }} />
      </div>
      {blocked && <p className="small warn">Withdrawals frozen: an event is pending or settling for this product.</p>}

      <h3 style={{ marginTop: 12 }}>Exposure by asset</h3>
      <table>
        <tbody>
          {exposures
            .filter((e) => e.exposure > 0n)
            .map((e) => (
              <tr key={e.asset.token}>
                <td>{e.asset.symbol}</td>
                <td className="num">{fmtUsd(e.exposure, 6, 0)} USDG</td>
                <td className="num muted small">
                  {total && total > 0n ? `${(Number((e.exposure * 10_000n) / total) / 100).toFixed(1)}% of pool` : ''}
                </td>
              </tr>
            ))}
          {exposures.every((e) => e.exposure === 0n) && (
            <tr>
              <td className="muted small">No active cover.</td>
            </tr>
          )}
        </tbody>
      </table>

      <h3 style={{ marginTop: 16 }}>Your position</h3>
      <dl className="kv">
        <dt>Shares</dt>
        <dd>{shares !== undefined ? fmtUsd(shares, 12) : '—'}</dd>
        <dt>Requested for withdrawal</dt>
        <dd>{req ? fmtUsd(req[0], 12) : '—'}</dd>
        <dt>Unlocks</dt>
        <dd>{req && req[1] > 0n ? fmtDate(req[1]) : '—'}</dd>
        <dt>Cooldown</dt>
        <dd>{cooldown ? `${Number(cooldown) / 86_400} days` : '—'}</dd>
      </dl>

      <label htmlFor={`amt-${product.id}`}>Deposit amount (USDG)</label>
      <input id={`amt-${product.id}`} value={amount} onChange={(e) => setAmount(e.target.value)} inputMode="decimal" />
      <div className="row" style={{ marginTop: 12 }}>
        {(allowance ?? 0n) < amountWei ? (
          <TxButton
            label="Approve USDG"
            disabled={!address || amountWei === 0n}
            request={pool && usdg ? { address: usdg, abi: erc20Abi, functionName: 'approve', args: [pool, amountWei] } : undefined}
          />
        ) : (
          <TxButton
            label="Deposit"
            disabled={!address || amountWei === 0n}
            request={pool && address ? { address: pool, abi: capitalPoolAbi, functionName: 'deposit', args: [amountWei, address] } : undefined}
          />
        )}
        <TxButton
          label="Request withdrawal (all)"
          variant="ghost"
          disabled={!address || !shares}
          request={pool && shares ? { address: pool, abi: capitalPoolAbi, functionName: 'requestWithdraw', args: [shares] } : undefined}
        />
        <TxButton
          label="Redeem matured"
          variant="ghost"
          disabled={!address || !maxRedeem}
          request={
            pool && address && maxRedeem
              ? { address: pool, abi: capitalPoolAbi, functionName: 'redeem', args: [maxRedeem, address, address] }
              : undefined
          }
        />
      </div>
    </div>
  );
}
