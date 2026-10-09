import type { Address } from "viem";
import { stackerAbi, testImdAbi } from "./abi/extra";
import { cabalGateAbi, pleaAbi, pleaHookAbi } from "./abi/generated";
import { publicClient } from "./client";
import { ADDR } from "./config";
import type { Band } from "./math";
import type { PoolKey } from "./preview";

const hook = { address: ADDR.hook, abi: pleaHookAbi } as const;
const gate = { address: ADDR.gate, abi: cabalGateAbi } as const;
const plea = { address: ADDR.plea, abi: pleaAbi } as const;
const imd = { address: ADDR.imd, abi: testImdAbi } as const;

export interface MarketState {
  poolKey: PoolKey;
  priceX96: bigint;
  sqrtPriceX96: bigint;
  launchExtraBps: bigint;
  launchedAt: number;
  market: Band;
  wall: Band;
  pleaInMarket: bigint;
  pleaInWall: bigint;
  retainedImd: bigint;
  wallImd: bigint;
  cashbackFloat: bigint;
  pendingRebalance: boolean;
  inventoryCap: bigint;
  totalBurned: bigint;
  cabalDead: boolean;
  cabalKilledAt: number;
  lastVerdictAt: number;
  totalSupply: bigint;
  pleaBurnClaims: bigint;
  imdCashbackClaims: bigint;
  imdRetainClaims: bigint;
  imdOwnerClaims: bigint;
  hookFromPlea: Address;
  gateFromPlea: Address;
}

export async function readMarket(): Promise<MarketState> {
  const r = await publicClient.multicall({
    allowFailure: false,
    contracts: [
      { ...hook, functionName: "poolKey" },
      { ...hook, functionName: "priceX96" },
      { ...hook, functionName: "currentSqrtPriceX96" },
      { ...hook, functionName: "launchExtraBps" },
      { ...hook, functionName: "launchedAt" },
      { ...hook, functionName: "market" },
      { ...hook, functionName: "wall" },
      { ...hook, functionName: "pleaInMarket" },
      { ...hook, functionName: "pleaInWall" },
      { ...hook, functionName: "retainedImd" },
      { ...hook, functionName: "wallImd" },
      { ...hook, functionName: "cashbackFloat" },
      { ...hook, functionName: "pendingRebalance" },
      { ...hook, functionName: "inventoryCap" },
      { ...hook, functionName: "totalBurned" },
      { ...plea, functionName: "cabalDead" },
      { ...plea, functionName: "cabalKilledAt" },
      { ...gate, functionName: "lastVerdictAt" },
      { ...plea, functionName: "totalSupply" },
      { ...hook, functionName: "pleaBurnClaims" },
      { ...hook, functionName: "imdCashbackClaims" },
      { ...hook, functionName: "imdRetainClaims" },
      { ...hook, functionName: "imdOwnerClaims" },
      { ...plea, functionName: "hook" },
      { ...plea, functionName: "gate" },
    ],
  });
  const key = r[0];
  const band = (b: readonly [number, number, bigint]): Band => ({ tickLower: b[0], tickUpper: b[1], liquidity: b[2] });
  return {
    poolKey: { currency0: key.currency0, currency1: key.currency1, fee: key.fee, tickSpacing: key.tickSpacing, hooks: key.hooks },
    priceX96: r[1],
    sqrtPriceX96: r[2],
    launchExtraBps: r[3],
    launchedAt: Number(r[4]),
    market: band(r[5]),
    wall: band(r[6]),
    pleaInMarket: r[7],
    pleaInWall: r[8],
    retainedImd: r[9],
    wallImd: r[10],
    cashbackFloat: r[11],
    pendingRebalance: r[12],
    inventoryCap: r[13],
    totalBurned: r[14],
    cabalDead: r[15],
    cabalKilledAt: Number(r[16]),
    lastVerdictAt: Number(r[17]),
    totalSupply: r[18],
    pleaBurnClaims: r[19],
    imdCashbackClaims: r[20],
    imdRetainClaims: r[21],
    imdOwnerClaims: r[22],
    hookFromPlea: r[23],
    gateFromPlea: r[24],
  };
}

export interface AccountState {
  imdBalance: bigint;
  pleaBalance: bigint;
  ethBalance: bigint;
  imdAllowanceRouter: bigint;
  imdAllowanceGate: bigint;
  pleaAllowanceGate: bigint;
  costBasis: { imdSpent: bigint; pleaHeld: bigint };
  cashbackOwed: bigint;
  stacked: bigint;
  pendingId: bigint;
  lastExecutedAt: number;
  lastDeniedAt: number;
}

export async function readAccount(me: Address): Promise<AccountState> {
  const [r, ethBalance] = await Promise.all([
    publicClient.multicall({
      allowFailure: false,
      contracts: [
        { ...imd, functionName: "balanceOf", args: [me] },
        { ...plea, functionName: "balanceOf", args: [me] },
        { ...imd, functionName: "allowance", args: [me, ADDR.poolSwapTest] },
        { ...imd, functionName: "allowance", args: [me, ADDR.gate] },
        { ...plea, functionName: "allowance", args: [me, ADDR.gate] },
        { ...hook, functionName: "costBasis", args: [me] },
        { ...hook, functionName: "cashbackOwed", args: [me] },
        { address: ADDR.stacker, abi: stackerAbi, functionName: "stackedBy", args: [ADDR.hook, me] },
        { ...gate, functionName: "pendingOf", args: [me] },
        { ...gate, functionName: "lastExecutedAt", args: [me] },
        { ...gate, functionName: "lastDeniedAt", args: [me] },
      ],
    }),
    publicClient.getBalance({ address: me }),
  ]);
  return {
    imdBalance: r[0],
    pleaBalance: r[1],
    imdAllowanceRouter: r[2],
    imdAllowanceGate: r[3],
    pleaAllowanceGate: r[4],
    costBasis: { imdSpent: r[5][0], pleaHeld: r[5][1] },
    cashbackOwed: r[6],
    stacked: r[7],
    pendingId: r[8],
    lastExecutedAt: Number(r[9]),
    lastDeniedAt: Number(r[10]),
    ethBalance,
  };
}

export async function readFactScore(me: Address, amount: bigint): Promise<number> {
  const score = await publicClient.readContract({ ...gate, functionName: "factScore", args: [me, amount] });
  return Number(score);
}

export async function readPlea(id: bigint) {
  return publicClient.readContract({ ...gate, functionName: "getPlea", args: [id] });
}
