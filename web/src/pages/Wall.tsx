import { useState } from "react";
import { AddressLink, Loading, Notice, Stamp, TxLink } from "../components/ui";
import { LAUNCH_BLOCK } from "../lib/config";
import { fmtAmount, fmtTime } from "../lib/format";
import { loadPleas, stampFor, type PleaRecord } from "../lib/pleas";
import { useNow, usePolling } from "../lib/usePolling";

export function WallPage({ id }: { id?: string }) {
  const now = useNow();
  const [progress, setProgress] = useState<string | null>(null);
  const wall = usePolling(
    () =>
      loadPleas(({ from, to, latest }) => setProgress(`Reading blocks ${from.toString()}–${to.toString()} of ${latest.toString()}`)).finally(() => setProgress(null)),
    [],
    20_000,
  );
  const pleas = wall.data?.pleas;

  if (id !== undefined) {
    const plea = pleas?.find((p) => p.id.toString() === id);
    return (
      <>
        <p>
          <a href="#/wall">← Back to the wall</a>
        </p>
        <h1>Plea #{id}</h1>
        {wall.loading && !pleas && <Loading what="the wall" />}
        {wall.error && <Notice tone="denied">Unable to read the wall: {wall.error}. Reload to try again.</Notice>}
        {pleas && !plea && <p>No plea with this id has been submitted since the launch block.</p>}
        {plea && <PleaEntry plea={plea} now={now} single />}
      </>
    );
  }

  return (
    <>
      <h1>The wall</h1>
      <p className="lede">
        Every plea since launch block {LAUNCH_BLOCK.toString()}, stamped with the Cabal’s verdict. Plea text is shown exactly as it was submitted.
      </p>
      {wall.loading && !pleas && (
        <p className="muted" role="status">
          {progress ?? "Loading the wall…"}
        </p>
      )}
      {wall.error && <Notice tone="denied">Unable to read the wall: {wall.error}. Reload to try again.</Notice>}
      {pleas && pleas.length === 0 && (
        <div className="empty">
          <p>
            <strong>No pleas yet.</strong>
          </p>
          <p className="muted">The wall fills as holders ask the Cabal for permission to sell.</p>
          <p>
            <a className="btn btn-primary" href="#/plead">
              <span>Submit a plea</span>
            </a>
          </p>
        </div>
      )}
      {pleas && pleas.length > 0 && (
        <ol className="wall" aria-label="Pleas, newest first">
          {pleas.map((p) => (
            <li key={p.id.toString()}>
              <PleaEntry plea={p} now={now} />
            </li>
          ))}
        </ol>
      )}
      {wall.updatedAt && (
        <p className="muted small">
          Read up to block {wall.data?.toBlock.toString()} · updated {new Date(wall.updatedAt).toLocaleTimeString()}.
        </p>
      )}
    </>
  );
}

function PleaEntry({ plea, now, single = false }: { plea: PleaRecord; now: number; single?: boolean }) {
  const s = stampFor(plea, now);
  return (
    <article className="plea-card" aria-labelledby={`plea-${plea.id}`}>
      <div className="plea-head">
        <Stamp label={s.label} tone={s.tone} size={single ? "lg" : "md"} />
        <div>
          <p className="plea-title" id={`plea-${plea.id}`}>
            {single ? <>Plea #{plea.id.toString()}</> : <a href={`#/wall/${plea.id}`}>Plea #{plea.id.toString()}</a>}
            {plea.isAppeal && (
              <>
                {" "}
                · appeal of <a href={`#/wall/${plea.originalId}`}>#{plea.originalId.toString()}</a>
              </>
            )}
          </p>
          <p className="muted">
            by <AddressLink address={plea.seller} /> · <span className="num">{fmtAmount(plea.amount)}</span> PLEA · fact score{" "}
            <span className="num">{plea.factScore}</span> / 55 · needs <span className="num">{plea.need}</span> / 45
          </p>
        </div>
      </div>
      <blockquote className="plea-text">{plea.text}</blockquote>
      <p className="muted small">
        Submitted {fmtTime(plea.submittedAt)}
        {plea.submittedTx && (
          <>
            {" "}
            <TxLink hash={plea.submittedTx} />
          </>
        )}
        {plea.verdictAt > 0 && (
          <>
            {" "}
            · verdict {fmtTime(plea.verdictAt)}
            {plea.verdictTx && (
              <>
                {" "}
                <TxLink hash={plea.verdictTx} />
              </>
            )}
          </>
        )}
        {plea.imdOut !== undefined && (
          <>
            {" "}
            · sold for <span className="num">{fmtAmount(plea.imdOut)}</span> tIMD
            {plea.executedTx && (
              <>
                {" "}
                <TxLink hash={plea.executedTx} />
              </>
            )}
          </>
        )}
        {plea.appealId !== undefined && (
          <>
            {" "}
            · appealed as <a href={`#/wall/${plea.appealId}`}>#{plea.appealId.toString()}</a>
          </>
        )}
      </p>
    </article>
  );
}
