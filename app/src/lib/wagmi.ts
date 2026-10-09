import { connectorsForWallets, type Wallet } from '@rainbow-me/rainbowkit';
import {
  coinbaseWallet,
  injectedWallet,
  metaMaskWallet,
  rabbyWallet,
  walletConnectWallet,
} from '@rainbow-me/rainbowkit/wallets';
import { createConfig, createConnector, http } from 'wagmi';
import { mock } from 'wagmi/connectors';
import { defineChain, type Address } from 'viem';
import { robinhoodMainnet } from '@/config/chains';

const rpcUrl = process.env.NEXT_PUBLIC_RPC_URL || robinhoodMainnet.rpcUrls[0];
const forkRpcUrl = process.env.NEXT_PUBLIC_FORK_RPC_URL || 'http://127.0.0.1:8545';

export const robinhood = defineChain({
  id: robinhoodMainnet.chainId,
  name: robinhoodMainnet.name,
  nativeCurrency: robinhoodMainnet.nativeCurrency,
  rpcUrls: { default: { http: [rpcUrl] } },
  blockExplorers: { default: { name: 'Blockscout', url: robinhoodMainnet.explorer.url } },
  contracts: robinhoodMainnet.multicall3 ? { multicall3: { address: robinhoodMainnet.multicall3 } } : undefined,
});

export const robinhoodFork = defineChain({
  id: 31337,
  name: 'Robinhood Chain fork (local)',
  nativeCurrency: robinhoodMainnet.nativeCurrency,
  rpcUrls: { default: { http: [forkRpcUrl] } },
  contracts: robinhoodMainnet.multicall3 ? { multicall3: { address: robinhoodMainnet.multicall3 } } : undefined,
  testnet: true,
});

export const enableFork = process.env.NEXT_PUBLIC_ENABLE_FORK === 'true';
const devWalletAddress = process.env.NEXT_PUBLIC_FORK_DEV_WALLET as Address | undefined;
const projectId = process.env.NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID || '';

export const chains = enableFork ? ([robinhoodFork, robinhood] as const) : ([robinhood] as const);

/**
 * Local-fork-only dev wallet: an unsigned "mock" connector for an address that anvil auto-impersonates
 * (anvil --auto-impersonate). It never holds or uses a private key and is only compiled in when
 * NEXT_PUBLIC_ENABLE_FORK=true and NEXT_PUBLIC_FORK_DEV_WALLET is set.
 */
const forkDevWallet = (address: Address): Wallet => ({
  id: 'fork-dev',
  name: 'Fork dev wallet (impersonated)',
  iconUrl:
    'data:image/svg+xml;utf8,<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><rect width="32" height="32" rx="8" fill="%23111"/><text x="16" y="21" font-size="14" text-anchor="middle" fill="%2300d084" font-family="monospace">fk</text></svg>',
  iconBackground: '#111',
  installed: true,
  createConnector: (details) =>
    createConnector((config) => ({
      ...mock({ accounts: [address], features: { reconnect: true } })(config),
      ...details,
    })),
});

const groups = [
  {
    groupName: 'Wallets',
    wallets: projectId
      ? [injectedWallet, metaMaskWallet, rabbyWallet, coinbaseWallet, walletConnectWallet]
      : [injectedWallet, rabbyWallet, coinbaseWallet],
  },
];
if (enableFork && devWalletAddress) {
  groups.unshift({ groupName: 'Local fork', wallets: [() => forkDevWallet(devWalletAddress)] as never });
}

const connectors = connectorsForWallets(groups, {
  appName: 'Gapguard',
  projectId: projectId || 'gapguard-no-walletconnect',
});

export const wagmiConfig = createConfig({
  chains,
  connectors,
  ssr: true,
  transports: {
    [robinhood.id]: http(rpcUrl),
    [robinhoodFork.id]: http(forkRpcUrl),
  } as never,
});
