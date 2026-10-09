'use client';

import { useEffect, useState } from 'react';
import { useWaitForTransactionReceipt, useWriteContract } from 'wagmi';
import { useQueryClient } from '@tanstack/react-query';
import { BaseError } from 'viem';
import { explorerTx, useGapguard } from '@/lib/hooks';

type WriteArgs = Parameters<ReturnType<typeof useWriteContract>['writeContract']>[0];

/** Sends one contract write, tracks the receipt, and refreshes all reads once mined. */
export function TxButton({
  label,
  request,
  disabled,
  onDone,
  variant = 'primary',
}: {
  label: string;
  request: WriteArgs | undefined;
  disabled?: boolean;
  onDone?: () => void;
  variant?: 'primary' | 'ghost';
}) {
  const { chainId } = useGapguard();
  const qc = useQueryClient();
  const { writeContract, data: hash, isPending, error, reset } = useWriteContract();
  const receipt = useWaitForTransactionReceipt({ hash });
  const [done, setDone] = useState(false);

  useEffect(() => {
    if (receipt.isSuccess && !done) {
      setDone(true);
      qc.invalidateQueries();
      onDone?.();
    }
  }, [receipt.isSuccess, done, qc, onDone]);

  const busy = isPending || receipt.isLoading;
  const msg = error ? ((error as BaseError).shortMessage ?? error.message) : undefined;
  const link = hash ? explorerTx(chainId, hash) : undefined;

  return (
    <div className="tx">
      <button
        className={variant === 'primary' ? 'btn' : 'btn ghost'}
        disabled={disabled || busy || !request}
        onClick={() => {
          setDone(false);
          reset();
          if (request) writeContract(request);
        }}
      >
        {busy ? 'Confirming…' : label}
      </button>
      {receipt.isSuccess && <span className="ok">Confirmed{link ? <> · <a href={link} target="_blank" rel="noreferrer">view</a></> : null}</span>}
      {receipt.isError && <span className="err">Transaction failed</span>}
      {msg && <span className="err">{msg}</span>}
    </div>
  );
}
