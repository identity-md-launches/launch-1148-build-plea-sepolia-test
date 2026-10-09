import { ExternalLink } from "lucide-react";
import { Button, Loading, Notice, Section, Stats, TxLine } from "../components/ui";
import { pleaHookAbi } from "../lib/abi/generated";
import { ACC_URL, ADDR } from "../lib/config";
import { fmtAmount } from "../lib/format";
import { readAccount, readMarket } from "../lib/reads";
import { useTx, writeChecked } from "../lib/tx";
import { usePolling } from "../lib/usePolling";
import { useWallet } from "../lib/wallet";

export function CashbackPage() {
  const { address, status, connect } = useWallet();
  const market = usePolling(readMarket, [], 15_000);
  const me = usePolling(() => (address ? readAccount(address) : Promise.resolve(undefined)), [address], 15_000);
  const settle = useTx("Settle claims");
  const claim = useTx("Claim cashback");
  const m = market.data;
  const acct = me.data;
  const pendingClaims = m ? m.imdCashbackClaims + m.imdRetainClaims + m.imdOwnerClaims : 0n;
  const canClaim = !!acct && !!m && acct.cashbackOwed > 0n && m.cashbackFloat >= acct.cashbackOwed;
  const refreshAll = () => Promise.all([market.refresh(), me.refresh()]).then(() => undefined);

  return (
    <>
      <h1>Cashback</h1>
      <p className="lede">
        Every trade pays 0.5% of its tIMD leg back to the trader as stacked IMD (tsIMD). When the float is short at trade time the amount is owed here
        until claims are settled.
      </p>
      {status === "none" && <Notice tone="pending">No wallet found. Install a browser wallet such as MetaMask, then reload this page.</Notice>}

      <Section title="Owed to you" id="owed">
        {!address && (
          <div className="actions">
            <Button variant="primary" onClick={connect} busy={status === "connecting"}>
              Connect wallet
            </Button>
            <span className="muted">Connect to see what the hook owes you.</span>
          </div>
        )}
        {address && me.loading && !acct && <Loading what="your cashback" />}
        {market.error && <Notice tone="denied">Unable to read the hook: {market.error}. Reload to try again.</Notice>}
        {acct && m && (
          <Stats
            items={[
              { label: "Cashback owed", value: `${fmtAmount(acct.cashbackOwed)} tIMD`, note: "cashbackOwed(you)" },
              { label: "Cashback float", value: `${fmtAmount(m.cashbackFloat)} tIMD`, note: "cashbackFloat() available to pay claims" },
              { label: "tsIMD earned from PLEA", value: `${fmtAmount(acct.stacked)} tsIMD`, note: "Stacker.stackedBy(hook, you)" },
            ]}
          />
        )}
        {address && (
          <div className="actions">
            <Button
              variant={canClaim ? "primary" : "secondary"}
              busy={claim.busy}
              disabled={!canClaim}
              onClick={() => claim.run((ctx) => writeChecked(ctx, { address: ADDR.hook, abi: pleaHookAbi, functionName: "claimCashback" }), refreshAll)}
            >
              Claim cashback
            </Button>
            {acct && acct.cashbackOwed === 0n && <span className="muted">Nothing is owed to this wallet right now.</span>}
            {acct && m && acct.cashbackOwed > 0n && m.cashbackFloat < acct.cashbackOwed && (
              <span className="muted">The float is short of what you are owed. Settle claims first to refill it.</span>
            )}
          </div>
        )}
        <TxLine state={claim.state} success="Cashback claimed." />
        <p>
          <a href={ACC_URL} target="_blank" rel="noreferrer">
            Open your stacked IMD on the imd/acc page <ExternalLink className="icon-inline" aria-hidden="true" />
          </a>
        </p>
      </Section>

      <Section title="Settle claims" id="settle">
        <p>
          Fees are held as claims in the PoolManager until someone settles them: PLEA is burned, the owner is paid, the wall reserve and the cashback
          float are refilled. Anyone can call it, and a call that moves at least 0.1 tIMD earns a 0.01 tIMD tip.
        </p>
        {m && (
          <Stats
            items={[
              { label: "tIMD claims waiting", value: `${fmtAmount(pendingClaims)} tIMD`, note: `${fmtAmount(m.imdCashbackClaims)} of it for cashback` },
              { label: "PLEA claims to burn", value: `${fmtAmount(m.pleaBurnClaims)} PLEA` },
            ]}
          />
        )}
        <div className="actions">
          <Button
            variant={!address ? "primary" : "secondary"}
            busy={settle.busy}
            onClick={() => (address ? settle.run((ctx) => writeChecked(ctx, { address: ADDR.hook, abi: pleaHookAbi, functionName: "settleClaims" }), refreshAll) : connect())}
          >
            {address ? "Settle claims" : "Connect wallet"}
          </Button>
          {m && pendingClaims === 0n && m.pleaBurnClaims === 0n && <span className="muted">No claims are waiting; the call would do nothing.</span>}
        </div>
        <TxLine state={settle.state} success="Claims settled." />
      </Section>
    </>
  );
}
