import {
  createPublicClient,
  createWalletClient,
  custom,
  defineChain,
  fallback,
  http,
  type Address,
  type EIP1193Provider,
} from "viem";
import { sepolia } from "viem/chains";
import { RPC_URLS } from "./config";

export const chain = defineChain({
  ...sepolia,
  rpcUrls: { default: { http: [...RPC_URLS] } },
});

export const publicClient = createPublicClient({
  chain,
  transport: fallback(
    RPC_URLS.map((url) => http(url, { batch: true, timeout: 20_000, retryCount: 1 })),
    { rank: false },
  ),
  batch: { multicall: true },
});

export type PublicClient = typeof publicClient;

export function injected(): EIP1193Provider | undefined {
  return (window as unknown as { ethereum?: EIP1193Provider }).ethereum;
}

export function walletClientFor(provider: EIP1193Provider, account: Address) {
  return createWalletClient({ chain, account, transport: custom(provider) });
}

export type WalletClient = ReturnType<typeof walletClientFor>;
