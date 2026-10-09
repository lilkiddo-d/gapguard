import type { NextConfig } from 'next';

const nextConfig: NextConfig = {
  reactStrictMode: true,
  // RainbowKit/WalletConnect optional peer deps that are never used in the browser bundle
  serverExternalPackages: ['pino-pretty', 'lokijs', 'encoding'],
  // The Node build of @base-org/account (pulled in by the Base Account connector) imports @coinbase/cdp-sdk, whose
  // optional x402/Solana deps are not installed. Gapguard never uses it, so it is aliased to a tiny stub.
  turbopack: {
    resolveAlias: {
      '@coinbase/cdp-sdk': './src/lib/cdp-sdk-stub.js',
    },
  },
  async headers() {
    return [
      {
        source: '/(.*)',
        headers: [
          { key: 'X-Frame-Options', value: 'DENY' },
          { key: 'X-Content-Type-Options', value: 'nosniff' },
          { key: 'Referrer-Policy', value: 'strict-origin-when-cross-origin' },
        ],
      },
    ];
  },
};

export default nextConfig;
