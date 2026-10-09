import { AddressLink, Button, Countdown, Loading, Notice, Section, Stats, TxLine } from "../components/ui";
import { pleaHookAbi } from "../lib/abi/generated";
import { ADDR, ADDRESS_LABELS, DEADMAN_S, EXPLORER, LAUNCH_BLOCK } from "../lib/config";
import { checksum, fmtAmount, fmtPercent, fmtPrice, fmtTime, priceFromX96 } from "../lib/format";
import { readMarket } from "../lib/reads";
import { useTx, writeChecked } from "../lib/tx";
import { useNow, usePolling } from "../lib/usePolling";
import { useWallet } from "../lib/wallet";

export function StatusPage() {
  const market = usePolling(readMarket, [], 15_000);
  const now = useNow();
  const rebalance = useTx("The rebalance");
  const { address, connect } = useWallet();
  const m = market.data;
  const deadAt = m ? m.lastVerdictAt + DEADMAN_S : 0;
  const marketCap = m ? priceFromX96(m.priceX96) * 1e9 : 0;
  const wired = m && m.hookFromPlea.toLowerCase() === ADDR.hook && m.gateFromPlea.toLowerCase() === ADDR.gate;

  return (
    <>
      <h1>Status</h1>
      <p className="lede">The Cabal, the market and the buy wall, read live from Sepolia every 15 seconds.</p>
      {market.loading && !m && <Loading what="the contracts" />}
      {market.error && <Notice tone="denied">Unable to read the contracts: {market.error}. Reload to try again.</Notice>}
      {m && wired === false && (
        <Notice tone="denied">The PLEA token points at a different hook or gate than this site. Do not transact until the addresses are checked.</Notice>
      )}

      {m && (
        <>
          <Section title="The Cabal" id="cabal">
            <Stats
              items={[
                { label: "Cabal", value: m.cabalDead ? "Dead" : "Alive", note: m.cabalDead ? `retired ${fmtTime(m.cabalKilledAt)}` : "sells need a verdict" },
                { label: "Last verdict", value: fmtTime(m.lastVerdictAt), note: "lastVerdictAt (launch counts as the first)" },
                {
                  label: "Dead-man switch",
                  value: m.cabalDead ? "fired" : <Countdown to={deadAt} done="can be pulled now" />,
                  note: "48 hours without a verdict lets anyone retire the Cabal",
                },
              ]}
            />
          </Section>

          <Section title="Market" id="market">
            <Stats
              items={[
                { label: "Price", value: `${fmtPrice(m.priceX96)} tIMD`, note: "per PLEA" },
                { label: "Market cap", value: `${fmtAmount(BigInt(Math.round(marketCap)) * 10n ** 18n)} tIMD`, note: "1,000,000,000 PLEA supply at price" },
                { label: "PLEA in market", value: fmtAmount(m.pleaInMarket), note: `cap ${fmtAmount(m.inventoryCap)} PLEA` },
                { label: "PLEA burned", value: fmtAmount(m.totalBurned), note: `supply now ${fmtAmount(m.totalSupply)}` },
                { label: "Launch fee", value: fmtPercent(m.launchExtraBps), note: `launched ${fmtTime(m.launchedAt)}` },
              ]}
            />
          </Section>

          <Section title="Buy wall" id="wall-status">
            <Stats
              items={[
                { label: "Wall reserve", value: `${fmtAmount(m.retainedImd)} tIMD`, note: "retained IMD waiting to be deployed" },
                { label: "Deployed in the wall", value: `${fmtAmount(m.wallImd)} tIMD`, note: m.wall.liquidity > 0n ? `ticks ${m.wall.tickLower} to ${m.wall.tickUpper}` : "no wall band placed" },
                { label: "PLEA bought by the wall", value: `${fmtAmount(m.pleaInWall)} PLEA`, note: "burned at the next rebalance" },
                { label: "Rebalance", value: m.pendingRebalance ? "Pending" : "Not needed", note: "anyone may call it; useful work earns 0.01 tIMD" },
              ]}
            />
            <div className="actions">
              <Button
                variant={m.pendingRebalance ? "primary" : "secondary"}
                busy={rebalance.busy}
                disabled={!m.pendingRebalance}
                onClick={() =>
                  address
                    ? rebalance.run((ctx) => writeChecked(ctx, { address: ADDR.hook, abi: pleaHookAbi, functionName: "rebalance" }), () => market.refresh())
                    : connect()
                }
              >
                {address ? "Rebalance" : "Connect wallet to rebalance"}
              </Button>
              {!m.pendingRebalance && <span className="muted">Nothing to settle or deploy right now.</span>}
            </div>
            <TxLine state={rebalance.state} success="Rebalanced." />
          </Section>
        </>
      )}

      <Section title="Addresses" id="addresses">
        <p>
          Sepolia, chain id 11155111. Launch block{" "}
          <a href={`${EXPLORER}/block/${LAUNCH_BLOCK}`} target="_blank" rel="noreferrer">
            {LAUNCH_BLOCK.toString()}
          </a>
          .
        </p>
        <table className="table">
          <thead>
            <tr>
              <th scope="col">Contract</th>
              <th scope="col">Address</th>
              <th scope="col">Role</th>
            </tr>
          </thead>
          <tbody>
            {ADDRESS_LABELS.map((row) => (
              <tr key={row.key}>
                <th scope="row">{row.label}</th>
                <td>
                  <AddressLink address={checksum(ADDR[row.key])} full />
                </td>
                <td className="muted">{row.note}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </Section>
      <p className="muted small">Clock: {fmtTime(now)} local.</p>
    </>
  );
}
