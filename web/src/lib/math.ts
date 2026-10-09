// Uniswap v4 price math in BigInt, used for off-chain quotes: a buy estimate
// when eth_simulateV1 is unavailable and the sell quote behind minOut.
import { BPS, IMD_FEE_BPS, PLEA_BURN_BPS, Q96 } from "./config";

const MAX_U256 = (1n << 256n) - 1n;
const TICK_FACTORS: [number, bigint][] = [
  [0x2, 0xfff97272373d413259a46990580e213an],
  [0x4, 0xfff2e50f5f656932ef12357cf3c7fdccn],
  [0x8, 0xffe5caca7e10e4e61c3624eaa0941cd0n],
  [0x10, 0xffcb9843d60f6159c9db58835c926644n],
  [0x20, 0xff973b41fa98c081472e6896dfb254c0n],
  [0x40, 0xff2ea16466c96a3843ec78b326b52861n],
  [0x80, 0xfe5dee046a99a2a811c461f1969c3053n],
  [0x100, 0xfcbe86c7900a88aedcffc83b479aa3a4n],
  [0x200, 0xf987a7253ac413176f2b074cf7815e54n],
  [0x400, 0xf3392b0822b70005940c7a398e4b70f3n],
  [0x800, 0xe7159475a2c29b7443b29c7fa6e889d9n],
  [0x1000, 0xd097f3bdfd2022b8845ad8f792aa5825n],
  [0x2000, 0xa9f746462d870fdf8a65dc1f90e061e5n],
  [0x4000, 0x70d869a156d2a1b890bb3df62baf32f7n],
  [0x8000, 0x31be135f97d08fd981231505542fcfa6n],
  [0x10000, 0x9aa508b5b7a84e1c677de54f3e99bc9n],
  [0x20000, 0x5d6af8dedb81196699c329225ee604n],
  [0x40000, 0x2216e584f5fa1ea926041bedfe98n],
  [0x80000, 0x48a170391f7dc42444e8fa2n],
];

/** TickMath.getSqrtPriceAtTick. */
export function sqrtPriceAtTick(tick: number): bigint {
  const absTick = Math.abs(tick);
  let ratio = absTick & 1 ? 0xfffcb933bd6fad37aa2d162d1a594001n : 0x100000000000000000000000000000000n;
  for (const [bit, factor] of TICK_FACTORS) {
    if (absTick & bit) ratio = (ratio * factor) >> 128n;
  }
  if (tick > 0) ratio = MAX_U256 / ratio;
  return (ratio >> 32n) + (ratio % (1n << 32n) === 0n ? 0n : 1n);
}

const divUp = (a: bigint, b: bigint) => (a + b - 1n) / b;

export interface Band {
  tickLower: number;
  tickUpper: number;
  liquidity: bigint;
}

/**
 * Exact-input buy (IMD = token0 in, PLEA = token1 out) through the market band.
 * Returns the PLEA delivered to the buyer after the 0.25% burn and the IMD fee.
 */
export function estimateBuy(amountIn: bigint, sqrtP: bigint, market: Band, extraBps: bigint) {
  const rate = IMD_FEE_BPS + extraBps;
  const fee = (amountIn * rate) / (BPS + rate);
  const poolIn = amountIn - fee;
  const L = market.liquidity;
  if (L === 0n || sqrtP === 0n || poolIn === 0n) return { pleaOut: 0n, imdFee: fee, poolIn, exhausted: false };
  const lower = sqrtPriceAtTick(market.tickLower);
  const numerator = L << 96n;
  let next = divUp(numerator * sqrtP, numerator + poolIn * sqrtP);
  let exhausted = false;
  if (next < lower) {
    next = lower;
    exhausted = true;
  }
  const out = (L * (sqrtP - next)) / Q96;
  const burn = (out * PLEA_BURN_BPS) / BPS;
  return { pleaOut: out - burn, imdFee: fee, poolIn, exhausted };
}

/**
 * Exact-input sell (PLEA = token1 in, IMD = token0 out) upward through the
 * market band and then the IMD-only wall band when one sits above the price.
 * Returns the IMD the seller receives after the 1.25% fee on the IMD side.
 */
export function estimateSell(amountIn: bigint, sqrtP: bigint, market: Band, wall: Band) {
  const burn = (amountIn * PLEA_BURN_BPS) / (BPS + PLEA_BURN_BPS);
  let remaining = amountIn - burn;
  let imdOut = 0n;
  let price = sqrtP;
  const bands = [market, wall].filter((b) => b.liquidity > 0n).sort((a, b) => a.tickLower - b.tickLower);
  for (const band of bands) {
    if (remaining === 0n) break;
    const lo = sqrtPriceAtTick(band.tickLower);
    const hi = sqrtPriceAtTick(band.tickUpper);
    if (price >= hi) continue;
    if (price < lo) price = lo;
    const L = band.liquidity;
    // amount1 needed to reach hi: L * (hi - price) / Q96
    const toHi = divUp(L * (hi - price), Q96);
    let next: bigint;
    let used: bigint;
    if (remaining >= toHi) {
      next = hi;
      used = toHi;
    } else {
      next = price + (remaining * Q96) / L;
      used = remaining;
    }
    // amount0 out = L * (next - price) * Q96 / (next * price)
    imdOut += (L * (next - price) * Q96) / (next * price);
    remaining -= used;
    price = next;
  }
  const imdFee = (imdOut * IMD_FEE_BPS) / BPS;
  return { imdOut: imdOut - imdFee, imdFee, unfilled: remaining };
}
