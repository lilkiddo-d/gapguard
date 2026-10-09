'use client';

import Link from 'next/link';
import { usePathname } from 'next/navigation';
import { ConnectButton } from '@rainbow-me/rainbowkit';
import { tokenFeaturesEnabled, useGapguard } from '@/lib/hooks';

const NAV = [
  { href: '/', label: 'Buy cover' },
  { href: '/covers', label: 'My covers' },
  { href: '/pools', label: 'Underwrite' },
  { href: '/triggers', label: 'Trigger history' },
  ...(tokenFeaturesEnabled ? [{ href: '/stake', label: 'Stake & disputes' }] : []),
  { href: '/risk', label: 'Risk disclosure' },
];

export function Header() {
  const path = usePathname();
  const { deployment, chainId } = useGapguard();
  return (
    <>
      <header className="header">
        <Link href="/" className="brand" aria-label="Gapguard home">
          <svg width="26" height="26" viewBox="0 0 32 32" aria-hidden>
            <path d="M16 2 4 7v8c0 7.5 5.1 13.6 12 15 6.9-1.4 12-7.5 12-15V7L16 2z" fill="#3ddc97" />
            <path d="M10 17h5v-6h2v6h5l-6 6z" fill="#06120c" />
          </svg>
          <span>Gapguard</span>
        </Link>
        <nav>
          {NAV.map((n) => (
            <Link key={n.href} href={n.href} className={path === n.href ? 'active' : ''}>
              {n.label}
            </Link>
          ))}
        </nav>
        <ConnectButton chainStatus="icon" showBalance={false} />
      </header>
      {!deployment && (
        <div className="banner">
          Gapguard contracts are not deployed on chain {chainId} yet. Pages show configuration only.
        </div>
      )}
    </>
  );
}
