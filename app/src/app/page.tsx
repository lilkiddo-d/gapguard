'use client';

import { useMemo, useState } from 'react';
import { useAccount, useReadContract, useReadContracts } from 'wagmi';
import { erc20Abi, parseUnits, type Address } from 'viem';
import Link from 'next/link';
import { coverRegistryAbi, chainlinkOracleAdapterAbi, weekendGapResolverAbi } from '@/abi';
import { PRODUCTS } from '@/lib/products';
import { fmtUsd, useGapguard } from '@/lib/hooks';
import { TxButton } from '@/components/TxButton';

const DAY = 86_400;

export default function BuyPage() {
  const { address } = useAccount();
  const { deployment, assets, chainConfig } = useGapguard();
  const [productId, setProductId] = useState(0);
  const [asset, setAsset] = useState<Address | undefined>(assets[0]?.token);
  const [amount, setAmount] = useState('1000');
  const [days, setDays] = useState(28);
  const [ack, setAck] = useState(false);

  const product = PRODUCTS[productId];
  const registry = deployment?.contracts.coverRegistry;
  const resolver = deployment?.contracts[product.resolverKey];
  const usdg = chainConfig?.stablecoin.address;

  const eligible = useMemo(
    () => assets.filter((a) => a.products[product.key]),
    [assets, product.key],
  );
  const selected = eligible.find((a) => a.token === asset) ?? eligible[0];
  const token = selected?.token;

  let amountWei = 0n;
  try {
    amountWei = parseUnits(amount || '0', 6);
  } catch {
    amountWei = 0n;
  }
  const duration = BigInt(days * DAY);

  const reads = useReadContracts({
    allowFailure: true,
    contracts:
      registry && token && resolver
        ? [
            { address: registry, abi: coverRegistryAbi, functionName: 'quote', args: [productId, token, amountWei, duration] },
            { address: registry, abi: coverRegistryAbi, functionName: 'availableCapacity', args: [productId, token] },
            { address: registry, abi: coverRegistryAbi, functionName: 'assetAllowed', args: [productId, token] },
            {
              address: resolver,
              abi: weekendGapResolverAbi,
              functionName: 'canPurchase',
              args: [token, BigInt(Math.floor(Date.now() / 1000) + 3600), BigInt(Math.floor(Date.now() / 1000) + 3600) + duration],
            },
            { address: deployment.contracts.oracleAdapter, abi: chainlinkOracleAdapterAbi, functionName: 'getPrice', args: [token] },
            { address: registry, abi: coverRegistryAbi, functionName: 'paused' },
          ]
        : [],
    query: { enabled: Boolean(registry && token && resolver) },
  });
  const [quoteR, capR, allowedR, canBuyR, priceR, pausedR] = reads.data ?? [];
  const quote = quoteR?.status === 'success' ? (quoteR.result as readonly [bigint, bigint]) : undefined;
  const premium = quote?.[0];
  const rateBps = quote?.[1];
  const capacity = capR?.status === 'success' ? (capR.result as bigint) : undefined;
  const allowed = allowedR?.status === 'success' ? (allowedR.result as boolean) : undefined;
  const canBuy = canBuyR?.status === 'success' ? (canBuyR.result as boolean) : undefined;
  const price = priceR?.status === 'success' ? (priceR.result as readonly [bigint, bigint])[0] : undefined;
  const paused = pausedR?.status === 'success' ? (pausedR.result as boolean) : undefined;

  const { data: allowance } = useReadContract({
    address: usdg,
    abi: erc20Abi,
    functionName: 'allowance',
    args: address && registry ? [address, registry] : undefined,
    query: { enabled: Boolean(address && registry && usdg) },
  });
  const { data: balance } = useReadContract({
    address: usdg,
    abi: erc20Abi,
    functionName: 'balanceOf',
    args: address ? [address] : undefined,
    query: { enabled: Boolean(address && usdg) },
  });

  const maxPremium = premium !== undefined ? (premium * 101n) / 100n + 1n : undefined;
  const needsApproval = maxPremium !== undefined && (allowance ?? 0n) < maxPremium;
  const overCapacity = capacity !== undefined && amountWei > capacity;
  const insufficient = balance !== undefined && maxPremium !== undefined && balance < maxPremium;
  const problems: string[] = [];
  if (!deployment) problems.push('Contracts are not deployed on this network.');
  if (amountWei < 10_000_000n) problems.push('Minimum cover is 10 USDG.');
  if (overCapacity) problems.push('Amount exceeds available capacity for this asset.');
  if (canBuy === false) problems.push('Sales are paused for this asset: an event is pending or the feed/token is in an abnormal state.');
  if (allowed === false) problems.push('This asset is not enabled for this product.');
  if (paused) problems.push('The protocol is paused by the guardian.');
  if (insufficient) problems.push('Insufficient USDG balance for the premium.');

  const disabled = !address || !ack || problems.length > 0 || premium === undefined;

  return (
    <>
      <h1>Buy parametric cover</h1>
      <p className="lead">
        Pick what you want protection against. If the trigger fires on-chain while your cover is active, the cover
        NFT’s holder is paid the full cover amount automatically — no claim forms, no adjusters.
      </p>

      <div className="grid cols-4">
        {PRODUCTS.map((p) => (
          <div
            key={p.id}
            className={`card selectable ${p.id === productId ? 'selected' : ''}`}
            onClick={() => setProductId(p.id)}
            role="button"
            aria-pressed={p.id === productId}
          >
            <h3>{p.name}</h3>
            <p className="small muted" style={{ margin: 0 }}>
              {p.trigger}
            </p>
          </div>
        ))}
      </div>

      <div className="grid cols-2" style={{ marginTop: 20 }}>
        <div className="card">
          <h2>{product.name}</h2>
          <p className="small muted">{product.how}</p>

          <label htmlFor="asset">Asset</label>
          <select id="asset" value={token} onChange={(e) => setAsset(e.target.value as Address)}>
            {eligible.map((a) => (
              <option key={a.token} value={a.token}>
                {a.symbol} — {a.name}
              </option>
            ))}
          </select>

          <label htmlFor="amount">Cover amount (USDG paid out if triggered)</label>
          <input id="amount" inputMode="decimal" value={amount} onChange={(e) => setAmount(e.target.value)} />

          <label htmlFor="days">
            Cover period: <strong>{days} days</strong> (starts ~1 hour after purchase)
          </label>
          <input id="days" type="range" min={7} max={90} value={days} onChange={(e) => setDays(Number(e.target.value))} />

          <label style={{ display: 'flex', alignItems: 'flex-start', marginTop: 16 }}>
            <input type="checkbox" checked={ack} onChange={(e) => setAck(e.target.checked)} />
            <span>
              I understand this is parametric cover that pays only if the on-chain trigger fires, that premiums are
              not refundable, and I have read the <Link href="/risk">risk disclosure</Link>.
            </span>
          </label>
        </div>

        <div className="card">
          <h2>Quote</h2>
          <dl className="kv">
            <dt>Asset oracle price</dt>
            <dd>{price !== undefined ? `$${fmtUsd(price, 18)}` : 'unavailable (market closed?)'}</dd>
            <dt>Annualised rate</dt>
            <dd>{rateBps !== undefined ? `${(Number(rateBps) / 100).toFixed(2)}%` : '—'}</dd>
            <dt>Premium</dt>
            <dd className="stat">{premium !== undefined ? `${fmtUsd(premium)} USDG` : '—'}</dd>
            <dt>Max premium (1% slippage)</dt>
            <dd>{maxPremium !== undefined ? fmtUsd(maxPremium) : '—'}</dd>
            <dt>Available capacity</dt>
            <dd>{capacity !== undefined ? `${fmtUsd(capacity, 6, 0)} USDG` : '—'}</dd>
            <dt>Your USDG</dt>
            <dd>{balance !== undefined ? fmtUsd(balance) : '—'}</dd>
          </dl>
          {problems.length > 0 && (
            <ul className="small warn" style={{ paddingLeft: 18 }}>
              {problems.map((p) => (
                <li key={p}>{p}</li>
              ))}
            </ul>
          )}
          <div className="row" style={{ marginTop: 16 }}>
            {needsApproval ? (
              <TxButton
                label="Approve USDG"
                disabled={disabled}
                request={
                  usdg && registry && maxPremium !== undefined
                    ? { address: usdg, abi: erc20Abi, functionName: 'approve', args: [registry, maxPremium] }
                    : undefined
                }
              />
            ) : (
              <TxButton
                label="Buy cover"
                disabled={disabled}
                request={
                  registry && token && maxPremium !== undefined
                    ? {
                        address: registry,
                        abi: coverRegistryAbi,
                        functionName: 'buyCover',
                        args: [productId, token, amountWei, duration, 0n, maxPremium],
                      }
                    : undefined
                }
              />
            )}
            {!address && <span className="muted small">Connect a wallet to buy.</span>}
          </div>
        </div>
      </div>
    </>
  );
}
