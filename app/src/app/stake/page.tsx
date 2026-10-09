'use client';

import { useState } from 'react';
import { useAccount, useReadContracts } from 'wagmi';
import { erc20Abi, parseUnits, type Address } from 'viem';
import { attestationModuleAbi, projectTokenHooksAbi } from '@/abi';
import { PROJECT_TOKEN, fmtDate, fmtUsd, shortAddr, tokenFeaturesEnabled, useGapguard } from '@/lib/hooks';
import { TxButton } from '@/components/TxButton';

const STATUS = ['None', 'Pending', 'Disputed', 'Accepted', 'Rejected'];
const ZERO = '0x0000000000000000000000000000000000000000' as const;

export default function StakePage() {
  const { address } = useAccount();
  const { deployment } = useGapguard();
  const [amount, setAmount] = useState('1000');
  const hooks = deployment?.contracts.projectTokenHooks;
  const att = deployment?.contracts.attestationModule;
  const token = PROJECT_TOKEN as Address;

  const r = useReadContracts({
    allowFailure: true,
    contracts:
      hooks && att && tokenFeaturesEnabled
        ? [
            { address: hooks, abi: projectTokenHooksAbi, functionName: 'tokenEnabled' },
            { address: hooks, abi: projectTokenHooksAbi, functionName: 'totalStaked' },
            { address: hooks, abi: projectTokenHooksAbi, functionName: 'stakers', args: [address ?? ZERO] },
            { address: hooks, abi: projectTokenHooksAbi, functionName: 'pendingRewards', args: [address ?? ZERO] },
            { address: token, abi: erc20Abi, functionName: 'balanceOf', args: [address ?? ZERO] },
            { address: token, abi: erc20Abi, functionName: 'allowance', args: [address ?? ZERO, hooks] },
            { address: att, abi: attestationModuleAbi, functionName: 'disputeBond' },
            { address: att, abi: attestationModuleAbi, functionName: 'attestationCount' },
          ]
        : [],
    query: { enabled: Boolean(hooks && att && tokenFeaturesEnabled) },
  });
  const v = (i: number) => (r.data?.[i]?.status === 'success' ? r.data[i].result : undefined);
  const onchainEnabled = v(0) as boolean | undefined;
  const totalStaked = v(1) as bigint | undefined;
  const info = v(2) as readonly [bigint, bigint, bigint, bigint, bigint, bigint] | undefined;
  const pending = v(3) as bigint | undefined;
  const balance = v(4) as bigint | undefined;
  const allowance = v(5) as bigint | undefined;
  const bond = v(6) as bigint | undefined;
  const count = (v(7) as bigint | undefined) ?? 0n;

  let amountWei = 0n;
  try {
    amountWei = parseUnits(amount || '0', 18);
  } catch {}

  if (!tokenFeaturesEnabled) {
    return (
      <div className="prose">
        <h1>Staking & disputes</h1>
        <p className="lead">
          Token features are disabled in this deployment. Attestation disputes are handled by the Timelock-controlled
          committee.
        </p>
      </div>
    );
  }

  return (
    <>
      <h1>Stake $GAPG · dispute attestations</h1>
      <p className="lead">
        Stakers earn a share of every premium (paid in USDG) and act as the dispute layer for attestation-based
        triggers. Disputing bonds {bond ? fmtUsd(bond, 18, 0) : '—'} $GAPG of your stake: it is slashed if your dispute
        is wrong and released if it is right.
      </p>
      {onchainEnabled === false && (
        <div className="banner" style={{ borderRadius: 10, marginBottom: 16 }}>
          The token address is configured in the app but has not been wired on-chain yet (setProjectToken via the
          Timelock). Staking opens once it is.
        </div>
      )}
      <div className="grid cols-2">
        <div className="card">
          <h2>Your stake</h2>
          <dl className="kv">
            <dt>Wallet $GAPG</dt>
            <dd>{fmtUsd(balance, 18)}</dd>
            <dt>Staked</dt>
            <dd>{info ? fmtUsd(info[0], 18) : '—'}</dd>
            <dt>Bonded in disputes</dt>
            <dd>{info ? fmtUsd(info[1], 18) : '—'}</dd>
            <dt>Unstaking</dt>
            <dd>{info && info[4] > 0n ? `${fmtUsd(info[4], 18)} · ${fmtDate(info[5])}` : '—'}</dd>
            <dt>Claimable rewards</dt>
            <dd>{fmtUsd(pending)} USDG</dd>
            <dt>Total staked</dt>
            <dd>{fmtUsd(totalStaked, 18, 0)}</dd>
          </dl>
          <label htmlFor="stake-amt">Amount ($GAPG)</label>
          <input id="stake-amt" value={amount} onChange={(e) => setAmount(e.target.value)} />
          <div className="row" style={{ marginTop: 12 }}>
            {(allowance ?? 0n) < amountWei ? (
              <TxButton
                label="Approve $GAPG"
                disabled={!address || !onchainEnabled}
                request={hooks ? { address: token, abi: erc20Abi, functionName: 'approve', args: [hooks, amountWei] } : undefined}
              />
            ) : (
              <TxButton
                label="Stake"
                disabled={!address || !onchainEnabled || amountWei === 0n}
                request={hooks ? { address: hooks, abi: projectTokenHooksAbi, functionName: 'stake', args: [amountWei] } : undefined}
              />
            )}
            <TxButton
              label="Request unstake"
              variant="ghost"
              disabled={!address || amountWei === 0n}
              request={hooks ? { address: hooks, abi: projectTokenHooksAbi, functionName: 'requestUnstake', args: [amountWei] } : undefined}
            />
            <TxButton
              label="Withdraw unstaked"
              variant="ghost"
              disabled={!address || !info || info[4] === 0n}
              request={hooks ? { address: hooks, abi: projectTokenHooksAbi, functionName: 'withdrawUnstaked' } : undefined}
            />
            <TxButton
              label="Claim rewards"
              variant="ghost"
              disabled={!address || !pending}
              request={hooks ? { address: hooks, abi: projectTokenHooksAbi, functionName: 'claimRewards' } : undefined}
            />
          </div>
        </div>
        <Attestations att={att} count={count} />
      </div>
    </>
  );
}

function Attestations({ att, count }: { att?: Address; count: bigint }) {
  const from = count > 20n ? count - 19n : 1n;
  const ids = count > 0n ? Array.from({ length: Number(count - from + 1n) }, (_, i) => from + BigInt(i)).reverse() : [];
  const { data } = useReadContracts({
    contracts: ids.map((id) => ({
      address: att!,
      abi: attestationModuleAbi,
      functionName: 'getAttestation' as const,
      args: [id] as const,
    })),
    query: { enabled: Boolean(att && ids.length) },
  });
  return (
    <div className="card" style={{ overflowX: 'auto' }}>
      <h2>Recent attestations</h2>
      {ids.length === 0 && <p className="muted small">No attestations yet.</p>}
      <table>
        <tbody>
          {ids.map((id, i) => {
            const a = data?.[i]?.result as
              | { proposer: Address; disputeDeadline: bigint; status: number; disputer: Address }
              | undefined;
            const open = a && a.status === 1 && Number(a.disputeDeadline) > Date.now() / 1000;
            return (
              <tr key={id.toString()}>
                <td>#{id.toString()}</td>
                <td>{a ? STATUS[a.status] : '…'}</td>
                <td className="small muted">by {shortAddr(a?.proposer)}</td>
                <td className="small">{a ? `window ends ${fmtDate(a.disputeDeadline)}` : ''}</td>
                <td>
                  {open && att && (
                    <TxButton
                      label="Dispute"
                      variant="ghost"
                      request={{ address: att, abi: attestationModuleAbi, functionName: 'dispute', args: [id] }}
                    />
                  )}
                </td>
              </tr>
            );
          })}
        </tbody>
      </table>
    </div>
  );
}
