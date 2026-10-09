import type { Address, Hash } from "viem";
import { cabalGateAbi } from "./abi/generated";
import { publicClient } from "./client";
import { ADDR, EXECUTE_WINDOW_S, LAUNCH_BLOCK, LOG_CHUNK } from "./config";

export const STATUS_NAMES = ["None", "Pending", "Approved", "Denied", "Executed", "Lapsed", "Cancelled"] as const;
export type Tone = "approved" | "denied" | "pending" | "lapsed" | "executed" | "neutral";

export interface PleaRecord {
  id: bigint;
  seller: Address;
  amount: bigint;
  factScore: number;
  need: number;
  status: number;
  appealed: boolean;
  isAppeal: boolean;
  submittedAt: number;
  verdictAt: number;
  originalId: bigint;
  text: string;
  appealId?: bigint;
  appealStatus?: number;
  imdOut?: bigint;
  submittedTx?: Hash;
  verdictTx?: Hash;
  executedTx?: Hash;
  submittedBlock?: bigint;
}

type GateLog = Awaited<ReturnType<typeof fetchChunk>>[number];

async function fetchChunk(fromBlock: bigint, toBlock: bigint) {
  return publicClient.getContractEvents({ address: ADDR.gate, abi: cabalGateAbi, fromBlock, toBlock });
}

let cache: { logs: GateLog[]; toBlock: bigint } | null = null;

export type Progress = (info: { from: bigint; to: bigint; latest: bigint }) => void;

/** Every gate event since the launch block, read in chunks and appended to a module cache. */
export async function fetchGateLogs(onProgress?: Progress): Promise<{ logs: GateLog[]; toBlock: bigint }> {
  const latest = await publicClient.getBlockNumber();
  let from = cache ? cache.toBlock + 1n : LAUNCH_BLOCK;
  const logs = cache ? [...cache.logs] : [];
  while (from <= latest) {
    const to = from + LOG_CHUNK - 1n < latest ? from + LOG_CHUNK - 1n : latest;
    onProgress?.({ from, to, latest });
    const chunk = await fetchChunk(from, to);
    logs.push(...chunk);
    from = to + 1n;
  }
  cache = { logs, toBlock: latest };
  return cache;
}

/** Loads every plea: ids and transactions from the logs, current state from getPlea(id). */
export async function loadPleas(onProgress?: Progress): Promise<{ pleas: PleaRecord[]; toBlock: bigint }> {
  const { logs, toBlock } = await fetchGateLogs(onProgress);
  const meta = new Map<string, Partial<PleaRecord>>();
  const touch = (id: bigint) => {
    const key = id.toString();
    let m = meta.get(key);
    if (!m) {
      m = { id };
      meta.set(key, m);
    }
    return m;
  };
  for (const log of logs) {
    const args = log.args as Record<string, unknown>;
    switch (log.eventName) {
      case "PleaSubmitted": {
        const m = touch(args.id as bigint);
        m.submittedTx = log.transactionHash;
        m.submittedBlock = log.blockNumber;
        break;
      }
      case "Verdict":
        touch(args.id as bigint).verdictTx = log.transactionHash;
        break;
      case "SellExecuted": {
        const m = touch(args.id as bigint);
        m.executedTx = log.transactionHash;
        m.imdOut = args.imdOut as bigint;
        break;
      }
      case "Appealed":
        touch(args.originalId as bigint).appealId = args.appealId as bigint;
        touch(args.appealId as bigint);
        break;
      case "PleaLapsed":
      case "PleaCancelled":
        touch(args.id as bigint);
        break;
      default:
        break;
    }
  }
  const ids = [...meta.values()].map((m) => m.id as bigint).sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));
  if (ids.length === 0) return { pleas: [], toBlock };
  const states = await publicClient.multicall({
    contracts: ids.map((id) => ({ address: ADDR.gate, abi: cabalGateAbi, functionName: "getPlea", args: [id] }) as const),
    allowFailure: false,
  });
  const byId = new Map<string, PleaRecord>();
  ids.forEach((id, i) => {
    const s = states[i];
    const m = meta.get(id.toString()) ?? {};
    byId.set(id.toString(), {
      id,
      seller: s.seller,
      amount: s.amount,
      factScore: Number(s.factScore),
      need: Number(s.need),
      status: Number(s.status),
      appealed: s.appealed,
      isAppeal: s.isAppeal,
      submittedAt: Number(s.submittedAt),
      verdictAt: Number(s.verdictAt),
      originalId: s.originalId,
      text: s.text,
      ...m,
    });
  });
  for (const p of byId.values()) {
    if (p.appealId !== undefined) p.appealStatus = byId.get(p.appealId.toString())?.status;
  }
  const pleas = [...byId.values()].sort((a, b) => (a.id > b.id ? -1 : a.id < b.id ? 1 : 0));
  return { pleas, toBlock };
}

export function stampFor(p: PleaRecord, now: number): { label: string; tone: Tone } {
  switch (p.status) {
    case 1:
      return { label: "Pending", tone: "pending" };
    case 2:
      return now > p.verdictAt + EXECUTE_WINDOW_S ? { label: "Lapsed", tone: "lapsed" } : { label: "Approved", tone: "approved" };
    case 3:
      if (p.appealed && p.appealStatus !== undefined) {
        if (p.appealStatus === 2 || p.appealStatus === 4 || p.appealStatus === 5) return { label: "Appealed → Overturned", tone: "approved" };
        if (p.appealStatus === 3) return { label: "Appealed → Upheld", tone: "denied" };
        if (p.appealStatus === 6) return { label: "Appealed → Cancelled", tone: "lapsed" };
        return { label: "Appealed → Pending", tone: "pending" };
      }
      return { label: "Denied", tone: "denied" };
    case 4:
      return { label: "Executed", tone: "executed" };
    case 5:
      return { label: "Lapsed", tone: "lapsed" };
    case 6:
      return { label: "Cancelled", tone: "lapsed" };
    default:
      return { label: "Unknown", tone: "neutral" };
  }
}
