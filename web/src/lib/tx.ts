import { useCallback, useState } from "react";
import {
  BaseError,
  ContractFunctionRevertedError,
  InsufficientFundsError,
  UserRejectedRequestError,
  type Abi,
  type Address,
  type Hash,
  type TransactionReceipt,
} from "viem";
import { publicClient, type WalletClient } from "./client";
import { useWallet } from "./wallet";
import { fmtTime } from "./format";

export type TxStatus = "idle" | "wallet" | "mining" | "success" | "error";
export interface TxState {
  status: TxStatus;
  hash?: Hash;
  message?: string;
  receipt?: TransactionReceipt;
}

export interface TxContext {
  account: Address;
  walletClient: WalletClient;
}

/** Simulates a call so custom errors are decoded with a readable fix, then sends it. */
export async function writeChecked(
  ctx: TxContext,
  params: { address: Address; abi: Abi; functionName: string; args?: readonly unknown[] },
): Promise<Hash> {
  const { request } = await publicClient.simulateContract({
    account: ctx.account,
    address: params.address,
    abi: params.abi,
    functionName: params.functionName,
    args: params.args as never,
  });
  return ctx.walletClient.writeContract(request as never);
}

/** Per-button transaction state: wallet prompt, mining, success or error. */
export function useTx(label?: string) {
  const wallet = useWallet();
  const [state, setState] = useState<TxState>({ status: "idle" });

  const run = useCallback(
    async (build: (ctx: TxContext) => Promise<Hash>, after?: (receipt: TransactionReceipt) => void | Promise<void>) => {
      setState({ status: "wallet" });
      try {
        const ctx = await wallet.require();
        const hash = await build(ctx);
        setState({ status: "mining", hash });
        const receipt = await publicClient.waitForTransactionReceipt({ hash, pollingInterval: 3_000 });
        if (receipt.status !== "success") {
          setState({ status: "error", hash, message: `${label ?? "The transaction"} reverted on chain. Open it on Etherscan for the reason, then try again.` });
          return;
        }
        setState({ status: "success", hash, receipt });
        await after?.(receipt);
      } catch (e) {
        setState({ status: "error", message: describeError(e) });
      }
    },
    [wallet, label],
  );

  const reset = useCallback(() => setState({ status: "idle" }), []);
  return { state, run, reset, busy: state.status === "wallet" || state.status === "mining" };
}

export const REVERTS: Record<string, string> = {
  BuyTooLarge: "This buy would return more than 5,000,000 PLEA, the per-buy cap during the launch window. Lower the tIMD amount.",
  RecipientRequired: "The swap did not carry your address as recipient. Reload the page and try again.",
  ExactOutputBuyRefused: "Only exact-input buys are allowed while the Cabal lives. Enter the tIMD amount to spend.",
  SellsOnlyViaGate: "PLEA can only be sold through the gate while the Cabal lives. Use the Plead page.",
  NotSeeded: "The pool is not seeded yet.",
  RebalanceNotNeeded: "Nothing to rebalance right now: no filled wall to settle and no reserve to deploy.",
  AmountTooLarge: "Amount is above the limit. Plead for at most 2,500,000 PLEA and at most 35% of your balance.",
  PendingExists: "You already have a plea open. Wait for its verdict, or cancel it 3 hours after submission.",
  NotPending: "This plea is no longer pending.",
  NotApproved: "No approved plea to execute. Wait for an APPROVED verdict first.",
  WindowLapsed: "The 7-minute execution window has passed. Submit a new plea.",
  NotSeller: "Only the wallet that submitted this plea can do that.",
  NotDenied: "Only a denied plea can be appealed.",
  AlreadyAppealed: "This plea was already appealed; each plea can be appealed once.",
  NotMatured: "A pending plea can be cancelled 3 hours after it was submitted.",
  BadPleaText: "The plea text was refused: use 1–280 UTF-8 bytes with no control, zero-width or bidi characters and no “[PLEA” marker.",
  CabalIsWatching: "The Cabal blocks this transfer. Sell only through the gate and send PLEA only where the rules allow.",
  CabalAlive: "The Cabal is alive: a verdict arrived within the last 48 hours.",
  ERC20InsufficientBalance: "Not enough tokens for this action. Use the tIMD faucet or lower the amount.",
  ERC20InsufficientAllowance: "Approve the token first, then retry this action.",
  SafeERC20FailedOperation: "The token transfer failed. Check your balance and the approval, then retry.",
  PriceLimitAlreadyExceeded: "The pool price is already past the limit for this swap.",
};

export function describeError(e: unknown): string {
  const raw = e as { code?: number; message?: string; shortMessage?: string };
  if (raw?.code === 4001) return "Rejected in the wallet. Nothing was sent; try again when ready.";
  if (e instanceof BaseError) {
    const reverted = e.walk((err) => err instanceof ContractFunctionRevertedError);
    if (reverted instanceof ContractFunctionRevertedError) {
      const name = reverted.data?.errorName ?? "";
      const args = (reverted.data?.args ?? []) as readonly unknown[];
      if (name === "Cooldown" && typeof args[0] === "bigint") {
        return `Cooldown: you can plead again after ${fmtTime(Number(args[0]))}.`;
      }
      if (name === "SlippageExceeded" && args.length === 2) {
        return "Price moved: the sell would return less than your minimum. Raise the slippage or try again.";
      }
      if (name === "WrappedError" && Array.isArray(args) && typeof args[1] === "string") {
        return "The pool hook refused the swap. Check the amount and the launch cap, then retry.";
      }
      if (name && REVERTS[name]) return REVERTS[name];
      if (reverted.reason) return `Reverted: ${reverted.reason}`;
      if (name) return `Reverted with ${name}. Check the inputs and retry.`;
      return "The call would revert. Check the inputs and retry.";
    }
    if (e.walk((err) => err instanceof UserRejectedRequestError)) {
      return "Rejected in the wallet. Nothing was sent; try again when ready.";
    }
    if (e.walk((err) => err instanceof InsufficientFundsError)) {
      return "Not enough Sepolia ETH for gas. Get some from a Sepolia faucet and retry.";
    }
    if (/insufficient funds/i.test(e.shortMessage)) {
      return "Not enough Sepolia ETH for gas. Get some from a Sepolia faucet and retry.";
    }
    return e.shortMessage;
  }
  if (e instanceof Error) return e.message;
  return "Unknown error. Reload the page and try again.";
}
