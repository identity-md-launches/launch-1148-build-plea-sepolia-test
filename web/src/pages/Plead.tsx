import { useEffect, useState } from "react";
import { Button, Countdown, Field, Loading, Notice, Section, Stamp, Stats, TxLine } from "../components/ui";
import { testImdAbi } from "../lib/abi/extra";
import { cabalGateAbi, pleaAbi } from "../lib/abi/generated";
import {
  ADDR,
  APPEAL_FEE,
  COOLDOWN_S,
  EXECUTE_WINDOW_S,
  MAX_SELL,
  MAX_SHARE_BPS,
  ORACLE_FEE,
  PENDING_EXPIRY_S,
  PENDING_TIMEOUT_S,
} from "../lib/config";
import { fmtAmount, fmtTime, parseAmount } from "../lib/format";
import { estimateSell } from "../lib/math";
import { loadPleas, stampFor, type PleaRecord } from "../lib/pleas";
import { readAccount, readFactScore, readMarket } from "../lib/reads";
import { validatePlea } from "../lib/text";
import { useTx, writeChecked } from "../lib/tx";
import { useNow, usePolling } from "../lib/usePolling";
import { useWallet } from "../lib/wallet";

const SLIPPAGE = [
  { label: "0.5%", bps: 50n },
  { label: "1%", bps: 100n },
  { label: "2%", bps: 200n },
  { label: "5%", bps: 500n },
];

export function PleadPage() {
  const { address, status, connect } = useWallet();
  const now = useNow();
  const acct = usePolling(() => (address ? readAccount(address) : Promise.resolve(undefined)), [address], 12_000);
  const market = usePolling(readMarket, [], 15_000);
  const mine = usePolling(async () => {
    if (!address) return undefined;
    const { pleas } = await loadPleas();
    return pleas.filter((p) => p.seller.toLowerCase() === address.toLowerCase());
  }, [address], 12_000);

  const a = acct.data;
  const pendingId = a?.pendingId ?? 0n;
  const current: PleaRecord | undefined = pendingId !== 0n ? mine.data?.find((p) => p.id === pendingId) : mine.data?.[0];
  const refreshAll = () => Promise.all([acct.refresh(), mine.refresh(), market.refresh()]).then(() => undefined);

  const cooldownUntil = a ? Math.max(a.lastExecutedAt ? a.lastExecutedAt + COOLDOWN_S : 0, a.lastDeniedAt ? a.lastDeniedAt + COOLDOWN_S : 0) : 0;
  const showForm = !!address && pendingId === 0n && (!current || current.status !== 1);

  return (
    <>
      <h1>Plead to sell</h1>
      <p className="lede">
        Selling PLEA needs the Cabal’s approval. Say how much you want to sell and why, in up to 280 bytes. The on-chain fact score counts toward the
        70 points you need; the Cabal scores the plea itself out of 45.
      </p>
      {status === "none" && <Notice tone="pending">No wallet found. Install a browser wallet such as MetaMask, then reload this page.</Notice>}
      {!address && status !== "none" && (
        <div className="actions">
          <Button variant="primary" onClick={connect} busy={status === "connecting"}>
            Connect wallet
          </Button>
          <span className="muted">Connect to plead and to follow your plea.</span>
        </div>
      )}
      {address && (acct.loading && !a ? <Loading what="your account" /> : null)}
      {address && mine.error && <Notice tone="denied">Unable to read your pleas: {mine.error}. Reload to try again.</Notice>}

      {current && (pendingId !== 0n || current.status !== 1) && (
        <CurrentPlea plea={current} now={now} onChange={refreshAll} pendingId={pendingId} />
      )}

      {showForm && a && (
        <PleaForm
          balance={a.pleaBalance}
          allowance={a.imdAllowanceGate}
          imdBalance={a.imdBalance}
          cooldownUntil={cooldownUntil}
          now={now}
          onChange={refreshAll}
        />
      )}

      {mine.data && mine.data.length > 1 && (
        <Section title="Your earlier pleas" id="history">
          <ul className="plea-list">
            {mine.data
              .filter((p) => p.id !== current?.id)
              .map((p) => {
                const s = stampFor(p, now);
                return (
                  <li key={p.id.toString()} className="plea-row">
                    <Stamp label={s.label} tone={s.tone} />
                    <a href={`#/wall/${p.id}`}>Plea #{p.id.toString()}</a>
                    <span className="num">{fmtAmount(p.amount)} PLEA</span>
                    <span className="muted">{fmtTime(p.submittedAt)}</span>
                  </li>
                );
              })}
          </ul>
        </Section>
      )}
    </>
  );
}

function PleaForm({
  balance,
  allowance,
  imdBalance,
  cooldownUntil,
  now,
  onChange,
}: {
  balance: bigint;
  allowance: bigint;
  imdBalance: bigint;
  cooldownUntil: number;
  now: number;
  onChange: () => Promise<void>;
}) {
  const [amountText, setAmountText] = useState("");
  const [text, setText] = useState("");
  const [score, setScore] = useState<number | null>(null);
  const [submitted, setSubmitted] = useState(false);
  const approve = useTx("The approval");
  const submit = useTx("The plea");
  const amount = parseAmount(amountText);
  const maxByShare = (balance * MAX_SHARE_BPS) / 10_000n;
  const max = maxByShare < MAX_SELL ? maxByShare : MAX_SELL;
  const amountError =
    amountText.trim() !== "" && amount === null
      ? "Enter the PLEA amount as a number."
      : amount !== null && amount > max
        ? `Plead for at most ${fmtAmount(max)} PLEA: the lower of 2,500,000 and 35% of your balance.`
        : amount !== null && amount === 0n
          ? "Enter an amount above zero."
          : undefined;
  const textCheck = validatePlea(text);
  const textError = submitted || text.length > 0 ? textCheck.error : undefined;
  const { address } = useWallet();

  useEffect(() => {
    if (!address || !amount || amount <= 0n || amountError) {
      setScore(null);
      return;
    }
    let cancelled = false;
    const t = window.setTimeout(async () => {
      try {
        const s = await readFactScore(address, amount);
        if (!cancelled) setScore(s);
      } catch {
        if (!cancelled) setScore(null);
      }
    }, 300);
    return () => {
      cancelled = true;
      window.clearTimeout(t);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [address, amount?.toString(), amountError]);

  const need = score === null ? null : 70 - score;
  const onCooldown = cooldownUntil > now;
  const needsApproval = allowance < ORACLE_FEE;
  const lowImd = imdBalance < ORACLE_FEE;

  return (
    <Section title="New plea" id="plead-form">
      {onCooldown && (
        <Notice tone="pending">
          Cooldown after your last executed sell or denial. You can plead again in <Countdown to={cooldownUntil} done="a moment" />.
        </Notice>
      )}
      {balance === 0n && <Notice tone="pending">This wallet holds no PLEA. Buy some first, then plead.</Notice>}
      <form
        className="form"
        onSubmit={(e) => {
          e.preventDefault();
          setSubmitted(true);
        }}
      >
        <Field
          id="plea-amount"
          label="PLEA to sell"
          error={amountError}
          hint={
            <>
              At most <span className="num">{fmtAmount(max)}</span> PLEA (you hold <span className="num">{fmtAmount(balance)}</span>).
            </>
          }
          trailing={
            <button type="button" className="link-btn" onClick={() => setAmountText(fmtAmount(max, 18, { max: 6 }).replace(/,/g, ""))}>
              Use max
            </button>
          }
        >
          <div className="input-row">
            <input
              id="plea-amount"
              className="input num"
              inputMode="decimal"
              autoComplete="off"
              placeholder="1000"
              value={amountText}
              aria-invalid={amountError ? true : undefined}
              aria-describedby={amountError ? "plea-amount-error" : "plea-amount-hint"}
              onChange={(e) => setAmountText(e.target.value)}
            />
            <span className="unit">PLEA</span>
          </div>
        </Field>

        <Field
          id="plea-text"
          label="Your plea"
          error={textError}
          hint={
            <>
              <span className="num">{textCheck.bytes}</span> / 280 bytes. One line, no hidden characters. The Cabal scores sincerity, craft, respect and loyalty.
            </>
          }
        >
          <textarea
            id="plea-text"
            className="input"
            rows={4}
            value={text}
            aria-invalid={textError ? true : undefined}
            aria-describedby={textError ? "plea-text-error" : "plea-text-hint"}
            onChange={(e) => setText(e.target.value)}
          />
        </Field>

        <Stats
          items={[
            { label: "Fact score", value: score === null ? "—" : `${score} / 55`, note: "computed on chain for this amount, now" },
            {
              label: "Plea score needed",
              value: need === null ? "—" : `${need} / 45`,
              note: need !== null && need > 45 ? "more than the Cabal can give: lower the share or wait" : "from the Cabal’s judges",
            },
            { label: "Fee", value: "0.5 tIMD", note: lowImd ? "you hold less than 0.5 tIMD; use the faucet" : "paid to the gate at submission" },
          ]}
        />

        <div className="actions">
          {needsApproval && (
            <Button
              variant="primary"
              busy={approve.busy}
              disabled={lowImd}
              onClick={() => approve.run((ctx) => writeChecked(ctx, { address: ADDR.imd, abi: testImdAbi, functionName: "approve", args: [ADDR.gate, ORACLE_FEE] }), onChange)}
            >
              Approve 0.5 tIMD
            </Button>
          )}
          <Button
            variant={needsApproval ? "secondary" : "primary"}
            busy={submit.busy}
            disabled={needsApproval || onCooldown || !amount || !!amountError || !!textCheck.error || lowImd}
            onClick={() => {
              setSubmitted(true);
              if (!amount || amountError || textCheck.error) return;
              void submit.run((ctx) => writeChecked(ctx, { address: ADDR.gate, abi: cabalGateAbi, functionName: "submitSell", args: [amount, text] }), onChange);
            }}
          >
            Submit plea
          </Button>
          {needsApproval && <span className="muted">Approve the 0.5 tIMD fee first, then submit.</span>}
        </div>
        <TxLine state={approve.state} success="0.5 tIMD approved for the gate." />
        <TxLine state={submit.state} success="Plea submitted. Waiting for the Cabal." />
      </form>
    </Section>
  );
}

function CurrentPlea({ plea, now, onChange, pendingId }: { plea: PleaRecord; now: number; onChange: () => Promise<void>; pendingId: bigint }) {
  const stamp = stampFor(plea, now);
  const execute = useTx("The sell");
  const approvePlea = useTx("The approval");
  const cancel = useTx("The cancel");
  const appeal = useTx("The appeal");
  const approveAppeal = useTx("The approval");
  const { address } = useWallet();
  const acct = usePolling(() => (address ? readAccount(address) : Promise.resolve(undefined)), [address, plea.status], 10_000);
  const market = usePolling(readMarket, [plea.status], 15_000);
  const [slip, setSlip] = useState(100n);
  const [appealText, setAppealText] = useState("");
  const a = acct.data;
  const m = market.data;

  const quote = m ? estimateSell(plea.amount, m.sqrtPriceX96, m.market, m.wall) : null;
  const minOut = quote ? (quote.imdOut * (10_000n - slip)) / 10_000n : 0n;
  const execDeadline = plea.verdictAt + EXECUTE_WINDOW_S;
  const expiry = plea.submittedAt + PENDING_EXPIRY_S;
  const cancelAt = plea.submittedAt + PENDING_TIMEOUT_S;
  const appealOpensAt = plea.verdictAt + COOLDOWN_S;
  const appealCheck = validatePlea(appealText);
  const needsPleaApproval = !!a && a.pleaAllowanceGate < plea.amount;
  const needsAppealApproval = !!a && a.imdAllowanceGate < APPEAL_FEE;
  const canAppeal = plea.status === 3 && !plea.appealed && !plea.isAppeal && now >= appealOpensAt;

  return (
    <Section title={pendingId !== 0n ? "Your open plea" : "Your latest plea"} id="current">
      <div className="plea-card">
        <div className="plea-head">
          <Stamp label={stamp.label} tone={stamp.tone} size="lg" />
          <div>
            <p className="plea-title">
              <a href={`#/wall/${plea.id}`}>Plea #{plea.id.toString()}</a>
              {plea.isAppeal && <span className="muted"> · appeal of #{plea.originalId.toString()}</span>}
            </p>
            <p className="muted">
              <span className="num">{fmtAmount(plea.amount)}</span> PLEA · fact score <span className="num">{plea.factScore}</span> / 55 · needs{" "}
              <span className="num">{plea.need}</span> / 45 · submitted {fmtTime(plea.submittedAt)}
            </p>
          </div>
        </div>
        <blockquote className="plea-text">{plea.text}</blockquote>

        {plea.status === 1 && (
          <>
            <p>
              <strong>Waiting for the Cabal.</strong>{" "}
              <Countdown to={expiry} prefix="The oracle request expires in " done="The oracle request has expired without a verdict." />
            </p>
            <div className="actions">
              <Button
                busy={cancel.busy}
                disabled={now < cancelAt}
                onClick={() => cancel.run((ctx) => writeChecked(ctx, { address: ADDR.gate, abi: cabalGateAbi, functionName: "cancel", args: [plea.id] }), onChange)}
              >
                Cancel plea
              </Button>
              <span className="muted">
                <Countdown to={cancelAt} prefix="Cancel opens in " done="Cancel is open: the 0.5 tIMD fee stays spent." />
              </span>
            </div>
            <TxLine state={cancel.state} success="Plea cancelled." />
          </>
        )}

        {plea.status === 2 && now <= execDeadline && (
          <>
            <p>
              <strong>Approved.</strong> Execute within <Countdown to={execDeadline} done="the window has closed" />.
            </p>
            {quote && (
              <Stats
                items={[
                  { label: "Expected", value: `${fmtAmount(quote.imdOut)} tIMD`, note: "pool maths, after the 1.25% fee" },
                  { label: "Minimum", value: `${fmtAmount(minOut)} tIMD`, note: "sent as minOut" },
                ]}
              />
            )}
            <div className="form">
              <Field id="slippage" label="Slippage">
                <select id="slippage" className="input" value={slip.toString()} onChange={(e) => setSlip(BigInt(e.target.value))}>
                  {SLIPPAGE.map((s) => (
                    <option key={s.label} value={s.bps.toString()}>
                      {s.label}
                    </option>
                  ))}
                </select>
              </Field>
              <div className="actions">
                {needsPleaApproval && (
                  <Button
                    variant="primary"
                    busy={approvePlea.busy}
                    onClick={() => approvePlea.run((ctx) => writeChecked(ctx, { address: ADDR.plea, abi: pleaAbi, functionName: "approve", args: [ADDR.gate, plea.amount] }), onChange)}
                  >
                    Approve {fmtAmount(plea.amount)} PLEA
                  </Button>
                )}
                <Button
                  variant={needsPleaApproval ? "secondary" : "primary"}
                  busy={execute.busy}
                  disabled={needsPleaApproval || !quote}
                  onClick={() => execute.run((ctx) => writeChecked(ctx, { address: ADDR.gate, abi: cabalGateAbi, functionName: "executeSell", args: [minOut] }), onChange)}
                >
                  Execute sell
                </Button>
                {needsPleaApproval && <span className="muted">Approve the PLEA for the gate first, then execute.</span>}
              </div>
              <TxLine state={approvePlea.state} success="PLEA approved for the gate." />
              <TxLine state={execute.state} success="Sell executed." />
            </div>
          </>
        )}

        {plea.status === 2 && now > execDeadline && <p>The 7-minute window closed before the sell was executed. Submit a new plea.</p>}

        {plea.status === 3 && (
          <>
            <p>
              <strong>Denied.</strong>{" "}
              <Countdown to={appealOpensAt} prefix="You can plead or appeal again in " done="The 4-hour wait is over." />
            </p>
            {!plea.appealed && !plea.isAppeal && (
              <div className="form">
                <Field
                  id="appeal-text"
                  label="Appeal text"
                  error={appealText.length > 0 ? appealCheck.error : undefined}
                  hint={
                    <>
                      <span className="num">{appealCheck.bytes}</span> / 280 bytes. The judges see the original plea and the denied verdict. Costs 0.85 tIMD, once per plea.
                    </>
                  }
                >
                  <textarea id="appeal-text" className="input" rows={3} value={appealText} onChange={(e) => setAppealText(e.target.value)} />
                </Field>
                <div className="actions">
                  {needsAppealApproval && (
                    <Button
                      variant="primary"
                      busy={approveAppeal.busy}
                      onClick={() => approveAppeal.run((ctx) => writeChecked(ctx, { address: ADDR.imd, abi: testImdAbi, functionName: "approve", args: [ADDR.gate, APPEAL_FEE] }), onChange)}
                    >
                      Approve 0.85 tIMD
                    </Button>
                  )}
                  <Button
                    variant={needsAppealApproval ? "secondary" : "primary"}
                    busy={appeal.busy}
                    disabled={!canAppeal || needsAppealApproval || !!appealCheck.error}
                    onClick={() =>
                      appeal.run((ctx) => writeChecked(ctx, { address: ADDR.gate, abi: cabalGateAbi, functionName: "appeal", args: [plea.id, appealText] }), onChange)
                    }
                  >
                    Appeal for 0.85 tIMD
                  </Button>
                </div>
                <TxLine state={approveAppeal.state} success="0.85 tIMD approved for the gate." />
                <TxLine state={appeal.state} success="Appeal submitted. Waiting for the Cabal." />
              </div>
            )}
            {plea.appealed && <p className="muted">This plea was appealed as #{plea.appealId?.toString()}.</p>}
          </>
        )}

        {plea.status === 4 && (
          <p>
            <strong>Executed.</strong> {plea.imdOut !== undefined && <>You received <span className="num">{fmtAmount(plea.imdOut)}</span> tIMD.</>} You can plead again 4 hours
            after the sell.
          </p>
        )}
        {plea.status === 5 && <p>This approval lapsed unused. Submit a new plea when you are ready.</p>}
        {plea.status === 6 && <p>This plea was cancelled. Submit a new plea when you are ready.</p>}
      </div>
    </Section>
  );
}
