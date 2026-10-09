/**
 * Gapguard chain configuration — single source of truth for on-chain addresses.
 *
 * Every address below was taken from an official source (links inline) and cross-checked on-chain
 * (symbol()/decimals()/description()) against https://rpc.mainnet.chain.robinhood.com on 2026-10-08.
 * Never add an address here without a source link. `pnpm config:export` writes chains.json for Foundry.
 *
 * Sources
 *  - Network params:         https://docs.robinhood.com/chain/connecting  and  /chain/deploy-smart-contracts
 *  - WETH / USDG:            https://docs.robinhood.com/chain/contracts
 *  - Stock token registry:   https://api.robinhood.com/rhj/assets  (documented at https://docs.robinhood.com/chain/stock-token-apis/)
 *  - Chainlink feeds:        https://docs.chain.link/data-feeds/price-feeds/addresses?network=robinhood
 *                            (machine-readable: https://reference-data-directory.vercel.app/feeds-robinhood-mainnet.json)
 *  - Uniswap v3:             https://developers.uniswap.org/docs/protocols/v3/deployments/v3-robinhood-chain-deployments
 *  - Uniswap v3 pools:       UniswapV3Factory.PoolCreated logs (factory 0x1f7d…2efa), liquidity checked on-chain
 *  - Protocol contracts:     https://docs.robinhood.com/chain/protocol-contracts
 *
 * Known gaps (documented in DECISIONS.md / THREAT_MODEL.md):
 *  - No Chainlink L2 sequencer-uptime feed is published for Robinhood Chain → `sequencerUptimeFeed` is null and the
 *    OracleAdapter check is disabled until one exists (settable via Timelock).
 *  - DEX liquidity for most stock tokens is thin; Depeg Cover is enabled only for assets with a USDG pool that has
 *    real depth and observation cardinality (QQQ, META, SGOV at launch).
 *  - No native USDC on Robinhood Chain at time of writing; the protocol stablecoin is USDG (6 decimals).
 */

export type Address = `0x${string}`;

export interface AssetConfig {
  symbol: string;
  name: string;
  kind: 'stock' | 'etf' | 'rwa';
  token: Address;
  /** Chainlink AggregatorV3 proxy (8 decimals, 24/5 market hours, heartbeat 86400s, deviation 0.5%). */
  feed: Address;
  /** Uniswap v3 pool used for Depeg TWAP, or null when no pool with adequate depth exists. */
  dexPool: Address | null;
  dexQuote: 'USDG' | 'WETH' | null;
  products: { gap: boolean; depeg: boolean; outage: boolean; halt: boolean };
}

export interface ChainConfig {
  chainId: number;
  name: string;
  nativeCurrency: { name: string; symbol: string; decimals: number };
  rpcUrls: string[];
  explorer: { name: string; url: string; apiUrl: string };
  verification: { verifier: 'blockscout'; verifierUrl: string };
  stablecoin: { symbol: string; address: Address; decimals: number; feed: Address };
  weth: { address: Address; feed: Address };
  sequencerUptimeFeed: Address | null;
  uniswapV3Factory: Address;
  multicall3: Address | null;
  l2Multicall: Address;
  assets: AssetConfig[];
}

const ROBINHOOD_ASSETS: AssetConfig[] = [
  { symbol: 'AAPL', name: 'Apple', kind: 'stock', token: '0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9', feed: '0x6B22A786bAa607d76728168703a39Ea9C99f2cD0', dexPool: null, dexQuote: null, products: { gap: true, depeg: false, outage: true, halt: true } },
  { symbol: 'NVDA', name: 'NVIDIA', kind: 'stock', token: '0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC', feed: '0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15', dexPool: null, dexQuote: null, products: { gap: true, depeg: false, outage: true, halt: true } },
  { symbol: 'TSLA', name: 'Tesla', kind: 'stock', token: '0x322F0929c4625eD5bAd873c95208D54E1c003b2d', feed: '0x4A1166a659A55625345e9515b32adECea5547C38', dexPool: null, dexQuote: null, products: { gap: true, depeg: false, outage: true, halt: true } },
  { symbol: 'MSFT', name: 'Microsoft', kind: 'stock', token: '0xe93237C50D904957Cf27E7B1133b510C669c2e74', feed: '0x45C3C877C15E6BA2EBB19eA114Ea508d14C1Af2E', dexPool: null, dexQuote: null, products: { gap: true, depeg: false, outage: true, halt: true } },
  { symbol: 'GOOGL', name: 'Alphabet', kind: 'stock', token: '0x2e0847E8910a9732eB3fb1bb4b70a580ADAD4FE3', feed: '0xF6f373a037c30F0e5010d854385cA89185AE638b', dexPool: null, dexQuote: null, products: { gap: true, depeg: false, outage: true, halt: true } },
  { symbol: 'AMZN', name: 'Amazon', kind: 'stock', token: '0x12f190a9F9d7D37a250758b26824B97CE941bF54', feed: '0xD5a1508ceD74c084eBf3cBe853e2C968fB2a651C', dexPool: null, dexQuote: null, products: { gap: true, depeg: false, outage: true, halt: true } },
  // META/USDG 0.30% pool: ~105k USDG depth, observation cardinality 1801 (checked 2026-10-08)
  { symbol: 'META', name: 'Meta Platforms', kind: 'stock', token: '0xc0D6457C16Cc70d6790Dd43521C899C87ce02f35', feed: '0x7C38C00C30BEe9378381E7B6135d7283356D71b1', dexPool: '0x107a7Cb40d8665360ba10E59471Af06150A50922', dexQuote: 'USDG', products: { gap: true, depeg: true, outage: true, halt: true } },
  { symbol: 'COIN', name: 'Coinbase', kind: 'stock', token: '0x6330D8C3178a418788dF01a47479c0ce7CCF450b', feed: '0xA3a468A452940B7D6b69991207B508c609a98Ef2', dexPool: null, dexQuote: null, products: { gap: true, depeg: false, outage: true, halt: true } },
  { symbol: 'SPY', name: 'SPDR S&P 500 ETF', kind: 'etf', token: '0x117cc2133c37B721F49dE2A7a74833232B3B4C0C', feed: '0x319724394D3A0e3669269846abE664Cd621f9f6A', dexPool: null, dexQuote: null, products: { gap: true, depeg: false, outage: true, halt: true } },
  // QQQ/USDG 0.05% pool: ~629k USDG depth, observation cardinality 7200 (checked 2026-10-08)
  { symbol: 'QQQ', name: 'Invesco QQQ ETF', kind: 'etf', token: '0xD5f3879160bc7c32ebb4dC785F8a4F505888de68', feed: '0x80901d846d5D7B030F26B480776EE3b29374C2ae', dexPool: '0xD60A5d14dB690B7Afad71F76B108071D7175597d', dexQuote: 'USDG', products: { gap: true, depeg: true, outage: true, halt: true } },
  // SGOV/USDG 0.05% pool: ~121k USDG depth, observation cardinality 100 (checked 2026-10-08)
  { symbol: 'SGOV', name: 'iShares 0-3M Treasury Bond ETF', kind: 'rwa', token: '0x92FD66527192E3e61d4DDd13322Aa222DE86F9B5', feed: '0xa0DF4ee0fFf975306345875E3548Fcc519577A11', dexPool: '0x6Ba50150B17Ffd0972915Aaf04fFd5E8f4Fa49b4', dexQuote: 'USDG', products: { gap: true, depeg: true, outage: true, halt: true } },
  { symbol: 'SLV', name: 'iShares Silver Trust', kind: 'rwa', token: '0x411eFb0E7f985935DAec3D4C3ebaEa0d0AD7D89f', feed: '0x209b73908e92Ae021826eD79609845451Ecba2ce', dexPool: null, dexQuote: null, products: { gap: true, depeg: false, outage: true, halt: true } },
  { symbol: 'USO', name: 'United States Oil Fund', kind: 'rwa', token: '0xa30FA36Db767ad9eD3f7a60fC79526fB4d56D344', feed: '0x75a9c76Ef439e2C7c2E5a34Ab105EcFe3766431c', dexPool: null, dexQuote: null, products: { gap: true, depeg: false, outage: true, halt: true } },
];

export const robinhoodMainnet: ChainConfig = {
  chainId: 4663,
  name: 'Robinhood Chain',
  nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
  rpcUrls: ['https://rpc.mainnet.chain.robinhood.com'],
  explorer: {
    name: 'Blockscout',
    url: 'https://robinhoodchain.blockscout.com',
    apiUrl: 'https://robinhoodchain.blockscout.com/api/',
  },
  verification: { verifier: 'blockscout', verifierUrl: 'https://robinhoodchain.blockscout.com/api/' },
  stablecoin: {
    symbol: 'USDG',
    address: '0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168',
    decimals: 6,
    feed: '0x61B7e5650328764B076A108EFF5fa7282a1B9aD2', // Chainlink USDG / USD
  },
  weth: {
    address: '0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73',
    feed: '0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9', // Chainlink ETH / USD
  },
  sequencerUptimeFeed: null,
  uniswapV3Factory: '0x1f7d7550B1b028f7571E69A784071F0205FD2EfA',
  multicall3: '0xcA11bde05977b3631167028862bE2a173976CA11', // Multicall3 canonical address, bytecode verified on-chain
  l2Multicall: '0x2cAC2D899eCC914d704FeaAE33ac1bF36277DaD1',
  assets: ROBINHOOD_ASSETS,
};

/** Local anvil fork of mainnet (anvil --fork-url ... --chain-id 31337). Same contracts as mainnet. */
export const robinhoodFork: ChainConfig = {
  ...robinhoodMainnet,
  chainId: 31337,
  name: 'Robinhood Chain (local fork)',
  rpcUrls: ['http://127.0.0.1:8545'],
  explorer: { name: 'none', url: '', apiUrl: '' },
};

export const chains: Record<number, ChainConfig> = {
  [robinhoodMainnet.chainId]: robinhoodMainnet,
  [robinhoodFork.chainId]: robinhoodFork,
};

export default chains;
