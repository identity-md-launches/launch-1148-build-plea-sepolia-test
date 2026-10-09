import { useEffect, useState } from "react";
import { decodeEventLog, type Address } from "viem";
import { AddressLink, Button, Countdown, Field, Loading, Notice, Section, Stats, TxLine } from "../components/ui";
import { testImdAbi } from "../lib/abi/extra";
import { ADDR, LAUNCH_MAX_BUY, LAUNCH_WINDOW_S } from "../lib/config";
import { fmtAmount, fmtPercent, fmtPrice, parseAmount, priceFromX96 } from "../lib/format";
import { estimateBuy } from "../lib/math";
import { buyArgs, buyErrorsAbi, previewBuy, type BuyPreview } from "../lib/preview";
import { readAccount, readMarket } from "../lib/reads";
import { useTx, writeChecked } from "../lib/tx";
import { useNow, usePolling } from "../lib/usePolling";
import { useWallet } from "../lib/wallet";

export function BuyPage() {
  const { address, status, connect } = useWallet();
  const market = usePolling(readMarket, [], 15_000);
  const me = usePolling(() => (address ? readAccount(address) : Promise.resolve(undefined)), [address], 15_000);
  const now = useNow();
  const [amountText, setAmountText] = useState("");
  const [preview, setPreview] = useState<{ amount: bigint; result: BuyPreview; estimate?: bigint } | null>(null);
  const [previewing, setPreviewing] = useState(false);
  const faucet = useTx("The faucet call");
  const approve = useTx("The approval");
  const buy = useTx("The buy");
  const [bought, setBought] = useState<bigint | null>(null);

  const amountIn = parseAmount(amountText);
  const m = market.data;
  const acct = me.data;
  const windowEnd = m ? m.launchedAt + LAUNCH_WINDOW_S : 0;
  const inWindow = m ? now < windowEnd : false;

  // Preview the same swap with eth_simulateV1; fall back to the pool maths.
  useEffect(() => {
    if (!m || !amountIn || amountIn <= 0n) {
      setPreview(null);
      return;
    }
    let cancelled = false;
    setPreviewing(true);
    const t = window.setTimeout(async () => {
      const est = estimateBuy(amountIn, m.sqrtPriceX96, m.market, m.launchExtraBps);
      // Without a connected wallet there is no buyer to simulate for: show the pool-maths estimate only.
      const result: BuyPreview = address
        ? await previewBuy(m.poolKey, amountIn, address, {
            balance: acct?.imdBalance ?? 0n,
            allowance: acct?.imdAllowanceRouter ?? 0n,
          })
        : { ok: false, error: "Connect a wallet for an exact preview.", unsupported: true };
      if (cancelled) return;
      setPreview({ amount: amountIn, result, estimate: est.pleaOut });
      setPreviewing(false);
    }, 350);
    return () => {
      cancelled = true;
      window.clearTimeout(t);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [amountIn?.toString(), address, m?.sqrtPriceX96?.toString(), acct?.imdBalance?.toString(), acct?.imdAllowanceRouter?.toString()]);

  const amountError =
    amountText.trim() !== "" && amountIn === null
      ? "Enter the tIMD amount as a number, for example 2.5."
      : amountIn !== null && acct && amountIn > acct.imdBalance
        ? `You hold ${fmtAmount(acct.imdBalance)} tIMD. Lower the amount or use the faucet.`
        : undefined;
  const needsApproval = !!amountIn && !!acct && acct.imdAllowanceRouter < amountIn;
  const previewOut = preview?.result.ok ? preview.result.pleaOut : preview?.estimate;
  const overCap = inWindow && previewOut !== undefined && previewOut > LAUNCH_MAX_BUY;

  const refreshAll = async () => {
    await Promise.all([market.refresh(), me.refresh()]);
  };

  const basis = acct?.costBasis;
  const avgCost = basis && basis.pleaHeld > 0n ? Number(basis.imdSpent) / Number(basis.pleaHeld) : null;
  const priceNow = m ? priceFromX96(m.priceX96) : null;

  return (
    <>
      <h1>Buy PLEA</h1>
      <p className="lede">
        Spend test IMD for PLEA through the Uniswap v4 pool. Buys are exact-input, the hook takes a 1.25% fee on the tIMD side, burns 0.25% of the
        PLEA and delivers the rest straight to your wallet.
      </p>

      {status === "none" && (
        <Notice tone="pending">No wallet found. Install a browser wallet such as MetaMask, then reload this page to buy.</Notice>
      )}

      <Section title="Get test IMD" id="faucet">
        <p>
          The faucet on the TestIMD token gives tIMD to any caller on Sepolia. You also need a little Sepolia ETH for gas.
        </p>
        <div className="actions">
          <Button
            variant={!address ? "primary" : "secondary"}
            busy={faucet.busy}
            onClick={() => (address ? faucet.run((ctx) => writeChecked(ctx, { address: ADDR.imd, abi: testImdAbi, functionName: "faucet" }), refreshAll) : connect())}
          >
            {address ? "Get tIMD from the faucet" : "Connect wallet"}
          </Button>
          <span className="muted">
            Balance: <span className="num">{acct ? fmtAmount(acct.imdBalance) : "—"}</span> tIMD · <span className="num">{acct ? fmtAmount(acct.pleaBalance) : "—"}</span> PLEA
          </span>
        </div>
        <TxLine state={faucet.state} success="tIMD received." />
      </Section>

      <Section title="Buy PLEA with tIMD" id="buy">
        {market.error && <Notice tone="denied">Unable to read the pool: {market.error}. Reload to try again.</Notice>}
        {m && (
          <Stats
            items={[
              { label: "Price", value: `${fmtPrice(m.priceX96)} tIMD`, note: "per PLEA" },
              {
                label: "Launch fee",
                value: inWindow ? fmtPercent(m.launchExtraBps) : "0%",
                note: inWindow ? <Countdown to={windowEnd} prefix="falls to 0% in " done="window over" /> : "launch window over",
              },
              {
                label: "Per-buy cap",
                value: inWindow ? `${fmtAmount(LAUNCH_MAX_BUY)} PLEA` : "none",
                note: inWindow ? <Countdown to={windowEnd} prefix="lifts in " done="lifted" /> : "5,000,000 PLEA cap ended with the launch window",
              },
            ]}
          />
        )}
        <form
          className="form"
          onSubmit={(e) => {
            e.preventDefault();
          }}
        >
          <Field
            id="buy-amount"
            label="tIMD to spend"
            error={amountError}
            hint="Exact input: you set the tIMD, the pool decides the PLEA."
            trailing={
              acct && (
                <button type="button" className="link-btn" onClick={() => setAmountText(fmtAmount(acct.imdBalance, 18, { max: 6 }).replace(/,/g, ""))}>
                  Use max
                </button>
              )
            }
          >
            <div className="input-row">
              <input
                id="buy-amount"
                className="input num"
                inputMode="decimal"
                autoComplete="off"
                placeholder="1.0"
                value={amountText}
                aria-invalid={amountError ? true : undefined}
                aria-describedby={amountError ? "buy-amount-error" : "buy-amount-hint"}
                onChange={(e) => {
                  setAmountText(e.target.value);
                  setBought(null);
                }}
              />
              <span className="unit">tIMD</span>
            </div>
          </Field>

          <div className="preview" aria-live="polite">
            {!amountIn && <p className="muted">Enter an amount to preview the PLEA you receive.</p>}
            {amountIn && previewing && !preview && <p className="muted">Previewing…</p>}
            {amountIn && preview && preview.result.ok && (
              <p>
                You receive about <strong className="num">{fmtAmount(preview.result.pleaOut)}</strong> PLEA for{" "}
                <span className="num">{fmtAmount(preview.amount)}</span> tIMD (fee <span className="num">{fmtAmount(preview.result.imdFee)}</span> tIMD, previewed with an
                eth_call of this exact swap).
              </p>
            )}
            {amountIn && preview && !preview.result.ok && preview.result.unsupported && (
              <p>
                You receive an estimated <strong className="num">{fmtAmount(preview.estimate)}</strong> PLEA (pool maths;{" "}
                {address ? "the RPC did not simulate the swap" : "connect a wallet for an exact preview"}).
              </p>
            )}
            {amountIn && preview && !preview.result.ok && !preview.result.unsupported && (
              <p className="tone-denied" role="alert">
                {preview.result.error}
              </p>
            )}
            {overCap && (
              <p className="tone-denied" role="alert">
                That is more than the 5,000,000 PLEA per-buy cap of the launch window. Lower the amount.
              </p>
            )}
          </div>

          <div className="actions">
            {!address ? (
              <Button variant="primary" onClick={connect} busy={status === "connecting"}>
                Connect wallet
              </Button>
            ) : (
              <>
                {needsApproval && (
                  <Button
                    variant="primary"
                    busy={approve.busy}
                    disabled={!amountIn || !!amountError}
                    onClick={() =>
                      amountIn &&
                      approve.run(
                        (ctx) => writeChecked(ctx, { address: ADDR.imd, abi: testImdAbi, functionName: "approve", args: [ADDR.poolSwapTest, amountIn] }),
                        () => me.refresh(),
                      )
                    }
                  >
                    Approve {amountIn ? fmtAmount(amountIn) : ""} tIMD
                  </Button>
                )}
                <Button
                  variant={needsApproval ? "secondary" : "primary"}
                  busy={buy.busy}
                  disabled={!amountIn || !!amountError || needsApproval || overCap || !m}
                  onClick={() =>
                    amountIn &&
                    m &&
                    buy.run(
                      (ctx) =>
                        writeChecked(ctx, {
                          address: ADDR.poolSwapTest,
                          abi: buyErrorsAbi,
                          functionName: "swap",
                          args: buyArgs(m.poolKey, amountIn, ctx.account),
                        }),
                      async (receipt) => {
                        let got = 0n;
                        for (const log of receipt.logs) {
                          if (log.address.toLowerCase() !== ADDR.plea) continue;
                          try {
                            const ev = decodeEventLog({ abi: testImdAbi, data: log.data, topics: log.topics });
                            if (ev.eventName === "Transfer" && (ev.args as { to: Address }).to.toLowerCase() === address.toLowerCase()) got += (ev.args as { value: bigint }).value;
                          } catch {
                            /* other event */
                          }
                        }
                        setBought(got);
                        await refreshAll();
                      },
                    )
                  }
                >
                  Buy PLEA
                </Button>
                {needsApproval && <span className="muted">Approve tIMD first, then buy.</span>}
              </>
            )}
          </div>
          <TxLine state={approve.state} success="tIMD approved for the swap router." />
          <TxLine state={buy.state} success={bought !== null ? <>Bought <span className="num">{fmtAmount(bought)}</span> PLEA.</> : "Buy confirmed."} />
        </form>
        <p className="muted small">
          Router: Uniswap PoolSwapTest <AddressLink address={ADDR.poolSwapTest} /> · exact input, price limit MIN_SQRT_PRICE + 1, hookData = your address.
        </p>
      </Section>

      <Section title="Your cost basis" id="basis">
        {!address && <p className="muted">Connect a wallet to see what you paid for your PLEA.</p>}
        {address && me.loading && !acct && <Loading what="your balances" />}
        {acct && basis && (
          <Stats
            items={[
              { label: "PLEA bought", value: fmtAmount(basis.pleaHeld), note: "net of burn, as booked by the hook" },
              { label: "tIMD spent", value: fmtAmount(basis.imdSpent), note: "including fees" },
              { label: "Average cost", value: avgCost === null ? "—" : `${avgCost.toPrecision(4).replace(/\.?0+$/, "")} tIMD`, note: "per PLEA" },
              {
                label: "Value now",
                value: priceNow !== null ? `${fmtAmount(BigInt(Math.round(Number(basis.pleaHeld) * priceNow)))} tIMD` : "—",
                note: avgCost !== null && priceNow !== null ? `${priceNow >= avgCost ? "+" : ""}${(((priceNow - avgCost) / avgCost) * 100).toFixed(1)}% against cost` : "",
              },
            ]}
          />
        )}
        {acct && basis && basis.pleaHeld === 0n && <p className="muted">No buys booked for this wallet yet.</p>}
      </Section>
    </>
  );
}
