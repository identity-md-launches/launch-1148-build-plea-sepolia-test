import { formatUnits, getAddress, parseUnits, type Address } from "viem";
import { Q96 } from "./config";

const nf = (max: number, min = 0) => new Intl.NumberFormat("en-US", { maximumFractionDigits: max, minimumFractionDigits: min });

/** Token amount from wei: thousands separators, fewer decimals for larger values. */
export function fmtAmount(wei: bigint | undefined | null, decimals = 18, opts?: { max?: number }): string {
  if (wei === undefined || wei === null) return "—";
  const value = Number(formatUnits(wei, decimals));
  const abs = Math.abs(value);
  let max = opts?.max;
  if (max === undefined) max = abs >= 10_000 ? 0 : abs >= 100 ? 2 : abs >= 1 ? 4 : abs === 0 ? 0 : 6;
  return nf(max).format(value);
}

export function fmtNumber(value: number, max = 2): string {
  return nf(max).format(value);
}

export function fmtPercent(bps: bigint | number): string {
  return `${nf(2).format(Number(bps) / 100)}%`;
}

/** IMD per PLEA from a 2^96-scaled price. */
export function priceFromX96(priceX96: bigint): number {
  return Number(priceX96) / Number(Q96);
}

export function fmtPrice(priceX96: bigint | undefined): string {
  if (priceX96 === undefined) return "—";
  const p = priceFromX96(priceX96);
  if (p === 0) return "0";
  return p.toPrecision(4).replace(/\.?0+$/, "");
}

export function parseAmount(text: string, decimals = 18): bigint | null {
  const cleaned = text.replace(/,/g, "").trim();
  if (!cleaned || !/^\d*\.?\d*$/.test(cleaned) || cleaned === ".") return null;
  try {
    return parseUnits(cleaned, decimals);
  } catch {
    return null;
  }
}

export function checksum(address: string): Address {
  return getAddress(address);
}

export function short(address: string): string {
  const a = getAddress(address);
  return `${a.slice(0, 6)}…${a.slice(-4)}`;
}

export function shortHash(hash: string): string {
  return `${hash.slice(0, 10)}…${hash.slice(-6)}`;
}

export function fmtDuration(seconds: number): string {
  const s = Math.max(0, Math.floor(seconds));
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const sec = s % 60;
  const two = (n: number) => n.toString().padStart(2, "0");
  if (h > 0) return `${h}h ${two(m)}m ${two(sec)}s`;
  if (m > 0) return `${m}m ${two(sec)}s`;
  return `${sec}s`;
}

export function fmtTime(unixSeconds: number): string {
  if (!unixSeconds) return "—";
  return new Date(unixSeconds * 1000).toLocaleString(undefined, {
    year: "numeric",
    month: "short",
    day: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  });
}

export function nowSeconds(): number {
  return Math.floor(Date.now() / 1000);
}
