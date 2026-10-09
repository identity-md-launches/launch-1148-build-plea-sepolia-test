import { ExternalLink, LoaderCircle, CircleAlert, CircleCheck } from "lucide-react";
import type { ButtonHTMLAttributes, ReactNode } from "react";
import { EXPLORER } from "../lib/config";
import { fmtDuration, short, shortHash } from "../lib/format";
import type { TxState } from "../lib/tx";
import { useNow } from "../lib/usePolling";
import type { Tone } from "../lib/pleas";

type ButtonProps = ButtonHTMLAttributes<HTMLButtonElement> & {
  variant?: "primary" | "secondary" | "quiet";
  busy?: boolean;
};

/** Standard button: hover, focus-visible, disabled and loading states from the stylesheet. */
export function Button({ variant = "secondary", busy = false, children, disabled, className, ...rest }: ButtonProps) {
  return (
    <button
      type="button"
      className={["btn", `btn-${variant}`, className].filter(Boolean).join(" ")}
      disabled={disabled || busy}
      aria-busy={busy || undefined}
      {...rest}
    >
      {busy && <LoaderCircle className="spin icon" aria-hidden="true" />}
      <span>{children}</span>
    </button>
  );
}

export function TxLink({ hash }: { hash: string }) {
  return (
    <a className="mono" href={`${EXPLORER}/tx/${hash}`} target="_blank" rel="noreferrer">
      {shortHash(hash)} <ExternalLink className="icon-inline" aria-hidden="true" />
      <span className="sr-only">(opens Etherscan)</span>
    </a>
  );
}

export function AddressLink({ address, full = false }: { address: string; full?: boolean }) {
  return (
    <a className="mono addr" href={`${EXPLORER}/address/${address}`} target="_blank" rel="noreferrer">
      {full ? address : short(address)} <ExternalLink className="icon-inline" aria-hidden="true" />
      <span className="sr-only">(opens Etherscan)</span>
    </a>
  );
}

/** One live status line per button, announced politely; errors are alerts. */
export function TxLine({ state, success }: { state: TxState; success?: ReactNode }) {
  if (state.status === "idle") return <p className="txline" role="status" aria-live="polite" />;
  if (state.status === "error") {
    return (
      <p className="txline tone-denied" role="alert">
        <CircleAlert className="icon-inline" aria-hidden="true" /> {state.message}
        {state.hash && (
          <>
            {" "}
            <TxLink hash={state.hash} />
          </>
        )}
      </p>
    );
  }
  return (
    <p className="txline" role="status" aria-live="polite">
      {state.status === "wallet" && "Confirm in your wallet…"}
      {state.status === "mining" && (
        <>
          Sent, waiting for confirmation… {state.hash && <TxLink hash={state.hash} />}
        </>
      )}
      {state.status === "success" && (
        <>
          <CircleCheck className="icon-inline tone-approved" aria-hidden="true" /> {success ?? "Done."}{" "}
          {state.hash && <TxLink hash={state.hash} />}
        </>
      )}
    </p>
  );
}

/** The Cabal's verdict stamp: the one signature move, used on the Wall and plea pages. */
export function Stamp({ label, tone, size = "md" }: { label: string; tone: Tone; size?: "md" | "lg" }) {
  return (
    <span className={`stamp stamp-${tone} stamp-${size}`} role="img" aria-label={`Verdict: ${label}`}>
      {label}
    </span>
  );
}

export function Countdown({ to, done, prefix }: { to: number; done: ReactNode; prefix?: string }) {
  const now = useNow();
  const left = to - now;
  if (left <= 0) return <>{done}</>;
  return (
    <>
      {prefix}
      <span className="num">{fmtDuration(left)}</span>
    </>
  );
}

export function Notice({ tone = "neutral", children }: { tone?: "neutral" | "denied" | "approved" | "pending"; children: ReactNode }) {
  return (
    <div className={`notice notice-${tone}`} role={tone === "denied" ? "alert" : undefined}>
      {children}
    </div>
  );
}

export function Field({
  id,
  label,
  hint,
  error,
  children,
  trailing,
}: {
  id: string;
  label: string;
  hint?: ReactNode;
  error?: string;
  children: ReactNode;
  trailing?: ReactNode;
}) {
  return (
    <div className="field">
      <div className="field-head">
        <label htmlFor={id}>{label}</label>
        {trailing}
      </div>
      {children}
      {hint && (
        <p className="hint" id={`${id}-hint`}>
          {hint}
        </p>
      )}
      {error && (
        <p className="error" id={`${id}-error`} role="alert">
          <CircleAlert className="icon-inline" aria-hidden="true" /> {error}
        </p>
      )}
    </div>
  );
}

export function Stats({ items }: { items: { label: string; value: ReactNode; note?: ReactNode }[] }) {
  return (
    <dl className="stats">
      {items.map((it) => (
        <div className="stat" key={it.label}>
          <dt>{it.label}</dt>
          <dd>
            <span className="num">{it.value}</span>
            {it.note && <span className="stat-note">{it.note}</span>}
          </dd>
        </div>
      ))}
    </dl>
  );
}

export function Section({ title, children, id }: { title: string; children: ReactNode; id?: string }) {
  return (
    <section className="section" aria-labelledby={id ? `${id}-h` : undefined} id={id}>
      <h2 id={id ? `${id}-h` : undefined}>{title}</h2>
      {children}
    </section>
  );
}

export function Loading({ what }: { what: string }) {
  return (
    <p className="muted" role="status">
      <LoaderCircle className="spin icon-inline" aria-hidden="true" /> Loading {what}…
    </p>
  );
}
