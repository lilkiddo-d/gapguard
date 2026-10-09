import type { Metadata } from 'next';
import Link from 'next/link';
import type { ReactNode } from 'react';
import { Providers } from '@/components/Providers';
import { Header } from '@/components/Header';
import './globals.css';

export const metadata: Metadata = {
  title: 'Gapguard — parametric cover for tokenized stocks',
  description:
    'Parametric cover for tokenized stocks and RWA tokens: weekend gaps, depegs, oracle outages and issuer halts, resolved by on-chain data.',
};

export default function RootLayout({ children }: { children: ReactNode }) {
  return (
    <html lang="en">
      <body>
        <Providers>
          <Header />
          <main className="main">{children}</main>
          <footer className="footer">
            <p>
              Gapguard is experimental software. Cover is parametric: payouts depend only on on-chain data and smart
              contracts, not on your actual loss. It may be a regulated product where you live and it may not be
              available to you. Read the <Link href="/risk">risk disclosure</Link> before using it.
            </p>
            <p className="muted">
              Gapguard is an independent protocol and is not affiliated with, endorsed by, or sponsored by any token
              issuer, broker or chain operator.
            </p>
          </footer>
        </Providers>
      </body>
    </html>
  );
}
