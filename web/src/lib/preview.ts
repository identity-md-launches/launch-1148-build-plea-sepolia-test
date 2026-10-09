import {
  decodeErrorResult,
  encodeAbiParameters,
  encodeFunctionData,
  keccak256,
  maxUint256,
  numberToHex,
  toHex,
  type Address,
  type Hex,
} from "viem";
import { poolSwapTestAbi, poolManagerErrorsAbi, testImdAbi } from "./abi/extra";
import { pleaHookAbi } from "./abi/generated";
import { publicClient } from "./client";
import { ADDR, MIN_SQRT_PRICE_PLUS_ONE } from "./config";
import { REVERTS } from "./tx";

export interface PoolKey {
  currency0: Address;
  currency1: Address;
  fee: number;
  tickSpacing: number;
  hooks: Address;
}

/** ABI used to decode any revert a buy can raise: router, PoolManager, hook and token. */
export const buyErrorsAbi = [...poolSwapTestAbi, ...poolManagerErrorsAbi, ...pleaHookAbi.filter((e) => e.type === "error"), ...testImdAbi.filter((e) => e.type === "error")];

/** The exact swap the Buy button sends: exact-input tIMD → PLEA with the buyer as hookData recipient. */
export function buyArgs(key: PoolKey, amountIn: bigint, buyer: Address) {
  return [
    key,
    { zeroForOne: true, amountSpecified: -amountIn, sqrtPriceLimitX96: MIN_SQRT_PRICE_PLUS_ONE },
    { takeClaims: false, settleUsingBurn: false },
    encodeAbiParameters([{ type: "address" }], [buyer]),
  ] as const;
}

const TRANSFER_TOPIC = keccak256(toHex("Transfer(address,address,uint256)"));
const FEES_TAKEN_TOPIC = keccak256(toHex("FeesTaken(address,bool,uint256,uint256,uint256)"));

interface SimLog {
  address: Address;
  topics: Hex[];
  data: Hex;
}
interface SimCall {
  status: Hex;
  returnData?: Hex;
  logs?: SimLog[];
  error?: { message?: string; data?: Hex };
}

export type BuyPreview =
  | { ok: true; pleaOut: bigint; imdFee: bigint; imdBasis: bigint }
  | { ok: false; error: string; unsupported?: boolean };

/**
 * Previews the same swap with eth_simulateV1 from the buyer's address and reads the
 * PLEA the PoolManager transfers to the buyer. When the buyer has not approved or
 * funded the amount yet, the simulation overrides the tIMD balance and allowance
 * slots (OpenZeppelin ERC-20 layout, checked against the live token) so the preview
 * still reflects the pool and hook maths.
 */
export async function previewBuy(
  key: PoolKey,
  amountIn: bigint,
  buyer: Address,
  state: { balance: bigint; allowance: bigint },
): Promise<BuyPreview> {
  const data = encodeFunctionData({ abi: poolSwapTestAbi, functionName: "swap", args: buyArgs(key, amountIn, buyer) });
  const stateOverrides: Record<string, { stateDiff: Record<string, Hex> }> = {};
  if (state.balance < amountIn || state.allowance < amountIn) {
    const balanceSlot = keccak256(encodeAbiParameters([{ type: "address" }, { type: "uint256" }], [buyer, 0n]));
    const inner = keccak256(encodeAbiParameters([{ type: "address" }, { type: "uint256" }], [buyer, 1n]));
    const allowanceSlot = keccak256(encodeAbiParameters([{ type: "address" }, { type: "bytes32" }], [ADDR.poolSwapTest, inner]));
    stateOverrides[ADDR.imd] = {
      stateDiff: {
        [balanceSlot]: numberToHex(amountIn > state.balance ? amountIn : state.balance, { size: 32 }),
        [allowanceSlot]: numberToHex(maxUint256, { size: 32 }),
      },
    };
  }
  let blocks: { calls: SimCall[] }[];
  try {
    blocks = (await publicClient.request({
      method: "eth_simulateV1" as never,
      params: [
        {
          blockStateCalls: [{ stateOverrides, calls: [{ from: buyer, to: ADDR.poolSwapTest, data, gas: "0x2dc6c0" }] }],
          validation: false,
          traceTransfers: false,
        },
        "latest",
      ] as never,
    })) as { calls: SimCall[] }[];
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    return { ok: false, error: msg, unsupported: true };
  }
  const call = blocks?.[0]?.calls?.[0];
  if (!call) return { ok: false, error: "The RPC returned no simulation result.", unsupported: true };
  if (call.status !== "0x1") {
    const errData = call.error?.data;
    if (errData && errData.length >= 10) {
      try {
        const decoded = decodeErrorResult({ abi: buyErrorsAbi, data: errData });
        const name = decoded.errorName;
        if (name === "WrappedError") {
          const inner = decoded.args?.[2] as Hex | undefined;
          if (inner && inner.length >= 10) {
            try {
              const innerDecoded = decodeErrorResult({ abi: buyErrorsAbi, data: inner });
              return { ok: false, error: REVERTS[innerDecoded.errorName] ?? `The hook refused the buy (${innerDecoded.errorName}).` };
            } catch {
              /* fall through */
            }
          }
        }
        return { ok: false, error: REVERTS[name] ?? `The buy would revert with ${name}.` };
      } catch {
        /* undecodable */
      }
    }
    return { ok: false, error: call.error?.message ?? "The buy would revert." };
  }
  let pleaOut = 0n;
  let imdFee = 0n;
  let imdBasis = 0n;
  for (const log of call.logs ?? []) {
    if (log.address.toLowerCase() === ADDR.plea && log.topics[0] === TRANSFER_TOPIC && log.topics[2]?.toLowerCase().endsWith(buyer.slice(2).toLowerCase())) {
      pleaOut += BigInt(log.data);
    }
    if (log.address.toLowerCase() === ADDR.hook && log.topics[0] === FEES_TAKEN_TOPIC) {
      const words = log.data.slice(2).match(/.{64}/g) ?? [];
      imdBasis = BigInt(`0x${words[1] ?? "0"}`);
      imdFee = BigInt(`0x${words[2] ?? "0"}`);
    }
  }
  return { ok: true, pleaOut, imdFee, imdBasis };
}
