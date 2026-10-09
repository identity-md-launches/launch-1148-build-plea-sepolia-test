import type { Address } from "viem";

// Chain facts from .imd/reads/network.json and verified addresses from
// .imd/reads/deployment.json plus the live launch handoff (#1148).
export const CHAIN_ID = 11155111;
export const CHAIN_ID_HEX = "0xaa36a7";
export const RPC_URLS = [
  "https://ethereum-sepolia-rpc.publicnode.com",
  "https://rpc.sepolia.ethpandaops.io",
  "https://sepolia.rpc.sentio.xyz",
] as const;
export const EXPLORER = "https://sepolia.etherscan.io";
export const ACC_URL = "https://imd.fun/acc";
export const IPFS_LABEL = "plea-test";

export const ADDR = {
  plea: "0x76b4e4ead394a71668e3e97f30f9072bbaa8a861",
  hook: "0x37337cd25f09a1cb77bba55d12358c9d00e2e8cc",
  gate: "0x29bfb82df72d839bed5e4f79b3528af85f1a2e2e",
  distributor: "0x514bf74301de943d0db83e6f5bdc0aa0d0ad435e",
  launch: "0xc43405eb24a776669e4a78d22164d55593cd61bf",
  imd: "0x2b69099e59b05901faa1dd164fabf098bf831e82",
  simd: "0xf9e2eec3b610ec6781f7438ac5fb4bc049d81cc1",
  stacker: "0x293c7134ab8f6bf1d8ff44ed806575f8f1baf477",
  poolManager: "0xe03a1074c86cfedd5c142c4f04f1a1536e203543",
  poolSwapTest: "0x9b6b46e2c869aa39918db7f52f5557fe577b6eee",
} as const satisfies Record<string, Address>;

export const ADDRESS_LABELS: { key: keyof typeof ADDR; label: string; note: string }[] = [
  { key: "plea", label: "PLEA", note: "the token" },
  { key: "hook", label: "PleaHook", note: "pool hook, fees, wall, cashback" },
  { key: "gate", label: "CabalGate", note: "pleas, verdicts, sells" },
  { key: "distributor", label: "PleaDistributor", note: "10% Merkle claim" },
  { key: "launch", label: "PleaLaunch", note: "deployed the hook" },
  { key: "imd", label: "TestIMD (tIMD)", note: "quote asset with faucet()" },
  { key: "simd", label: "TestSIMD (tsIMD)", note: "stacked IMD" },
  { key: "stacker", label: "Stacker", note: "credits cashback as tsIMD" },
  { key: "poolManager", label: "Uniswap v4 PoolManager", note: "holds the pool" },
  { key: "poolSwapTest", label: "Uniswap PoolSwapTest", note: "swap router used to buy" },
];

export const LAUNCH_BLOCK = 11877100n;
export const LOG_CHUNK = 5000n;

// Uniswap v4 TickMath bounds.
export const MIN_SQRT_PRICE_PLUS_ONE = 4295128740n;
export const Q96 = 2n ** 96n;

// Contract constants (CabalGate / PleaHook).
export const ORACLE_FEE = 500000000000000000n; // 0.5 tIMD
export const APPEAL_FEE = 850000000000000000n; // 0.85 tIMD
export const MAX_SELL = 2_500_000n * 10n ** 18n;
export const MAX_SHARE_BPS = 3500n;
export const LAUNCH_MAX_BUY = 5_000_000n * 10n ** 18n;
export const LAUNCH_WINDOW_S = 90 * 60;
export const EXECUTE_WINDOW_S = 7 * 60;
export const COOLDOWN_S = 4 * 3600;
export const PENDING_TIMEOUT_S = 3 * 3600;
export const PENDING_EXPIRY_S = 2 * 3600;
export const DEADMAN_S = 48 * 3600;
export const MAX_PLEA_BYTES = 280;
export const IMD_FEE_BPS = 125n;
export const PLEA_BURN_BPS = 25n;
export const BPS = 10_000n;

export const WALLET_ADD_CHAIN = {
  chainId: CHAIN_ID_HEX,
  chainName: "Sepolia",
  rpcUrls: [...RPC_URLS],
  nativeCurrency: { name: "Sepolia Ether", symbol: "ETH", decimals: 18 },
  blockExplorerUrls: [EXPLORER],
};
