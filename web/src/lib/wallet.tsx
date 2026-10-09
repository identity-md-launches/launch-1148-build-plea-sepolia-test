import { createContext, useCallback, useContext, useEffect, useMemo, useState, type ReactNode } from "react";
import type { Address, EIP1193Provider } from "viem";
import { CHAIN_ID, CHAIN_ID_HEX, WALLET_ADD_CHAIN } from "./config";
import { injected, walletClientFor, type WalletClient } from "./client";

export type WalletStatus = "none" | "idle" | "connecting" | "ready";

export interface WalletState {
  status: WalletStatus;
  address?: Address;
  chainId?: number;
  error?: string;
}

export interface WalletContext extends WalletState {
  onSepolia: boolean;
  connect: () => Promise<void>;
  switchToSepolia: () => Promise<void>;
  /** Connects (and switches chain) if needed, then returns a wallet client for the account. */
  require: () => Promise<{ account: Address; walletClient: WalletClient }>;
}

const Ctx = createContext<WalletContext | null>(null);

function errorMessage(e: unknown): string {
  const err = e as { code?: number; message?: string; shortMessage?: string };
  if (err?.code === 4001) return "Request rejected in the wallet. Try again when ready.";
  if (err?.code === -32002) return "The wallet already has a pending request. Open the wallet and finish it.";
  return err?.shortMessage ?? err?.message ?? "The wallet returned an unknown error.";
}

export function WalletProvider({ children }: { children: ReactNode }) {
  const [state, setState] = useState<WalletState>({ status: "idle" });
  const [provider, setProvider] = useState<EIP1193Provider | undefined>(() => injected());

  // Silent read of the current account and chain, plus live updates.
  useEffect(() => {
    const p = provider ?? injected();
    if (!p) {
      setState({ status: "none" });
      return;
    }
    if (!provider) setProvider(p);
    let alive = true;
    (async () => {
      try {
        const [accounts, chainIdHex] = await Promise.all([
          p.request({ method: "eth_accounts" }) as Promise<Address[]>,
          p.request({ method: "eth_chainId" }) as Promise<string>,
        ]);
        if (!alive) return;
        setState({ status: accounts[0] ? "ready" : "idle", address: accounts[0], chainId: parseInt(chainIdHex, 16) });
      } catch {
        if (alive) setState({ status: "idle" });
      }
    })();
    const onAccounts = (accounts: readonly string[]) =>
      setState((s) => ({ ...s, address: accounts[0] as Address | undefined, status: accounts[0] ? "ready" : "idle" }));
    const onChain = (hex: string) => setState((s) => ({ ...s, chainId: parseInt(hex, 16) }));
    p.on("accountsChanged", onAccounts);
    p.on("chainChanged", onChain);
    return () => {
      alive = false;
      p.removeListener("accountsChanged", onAccounts);
      p.removeListener("chainChanged", onChain);
    };
  }, [provider]);

  const switchToSepolia = useCallback(async () => {
    const p = provider ?? injected();
    if (!p) throw new Error("No wallet found. Install a browser wallet such as MetaMask and reload the page.");
    try {
      await p.request({ method: "wallet_switchEthereumChain", params: [{ chainId: CHAIN_ID_HEX }] });
    } catch (e) {
      const err = e as { code?: number; message?: string };
      const unknownChain = err?.code === 4902 || /unrecognized|not added|4902/i.test(err?.message ?? "");
      if (!unknownChain) throw new Error(errorMessage(e));
      await p.request({ method: "wallet_addEthereumChain", params: [WALLET_ADD_CHAIN] });
    }
    const hex = (await p.request({ method: "eth_chainId" })) as string;
    setState((s) => ({ ...s, chainId: parseInt(hex, 16) }));
  }, [provider]);

  const connect = useCallback(async () => {
    const p = provider ?? injected();
    if (!p) {
      setState({ status: "none", error: "No wallet found. Install a browser wallet such as MetaMask and reload the page." });
      return;
    }
    if (!provider) setProvider(p);
    setState((s) => ({ ...s, status: "connecting", error: undefined }));
    try {
      const accounts = (await p.request({ method: "eth_requestAccounts" })) as Address[];
      const hex = (await p.request({ method: "eth_chainId" })) as string;
      setState({ status: accounts[0] ? "ready" : "idle", address: accounts[0], chainId: parseInt(hex, 16) });
      if (parseInt(hex, 16) !== CHAIN_ID) await switchToSepolia();
    } catch (e) {
      setState((s) => ({ ...s, status: s.address ? "ready" : "idle", error: errorMessage(e) }));
    }
  }, [provider, switchToSepolia]);

  const require = useCallback(async () => {
    const p = provider ?? injected();
    if (!p) throw new Error("No wallet found. Install a browser wallet such as MetaMask and reload the page.");
    let account = state.address;
    if (!account) {
      const accounts = (await p.request({ method: "eth_requestAccounts" })) as Address[];
      account = accounts[0];
      setState((s) => ({ ...s, status: account ? "ready" : "idle", address: account }));
      if (!account) throw new Error("No account was shared by the wallet. Connect an account and try again.");
    }
    const hex = (await p.request({ method: "eth_chainId" })) as string;
    if (parseInt(hex, 16) !== CHAIN_ID) await switchToSepolia();
    return { account, walletClient: walletClientFor(p, account) };
  }, [provider, state.address, switchToSepolia]);

  const value = useMemo<WalletContext>(
    () => ({ ...state, onSepolia: state.chainId === CHAIN_ID, connect, switchToSepolia, require }),
    [state, connect, switchToSepolia, require],
  );
  return <Ctx.Provider value={value}>{children}</Ctx.Provider>;
}

export function useWallet(): WalletContext {
  const ctx = useContext(Ctx);
  if (!ctx) throw new Error("useWallet outside WalletProvider");
  return ctx;
}
