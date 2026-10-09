import { useCallback, useEffect, useRef, useState, type DependencyList } from "react";

export interface Polled<T> {
  data: T | undefined;
  error?: string;
  loading: boolean;
  refresh: () => Promise<void>;
  updatedAt?: number;
}

/** Runs `load` now, on every dependency change and every `intervalMs` while the tab is visible. */
export function usePolling<T>(load: () => Promise<T>, deps: DependencyList, intervalMs = 15_000): Polled<T> {
  const [data, setData] = useState<T | undefined>(undefined);
  const [error, setError] = useState<string | undefined>(undefined);
  const [loading, setLoading] = useState(true);
  const [updatedAt, setUpdatedAt] = useState<number | undefined>(undefined);
  const loadRef = useRef(load);
  loadRef.current = load;
  const seq = useRef(0);

  const refresh = useCallback(async () => {
    const id = ++seq.current;
    try {
      const next = await loadRef.current();
      if (id !== seq.current) return;
      setData(next);
      setError(undefined);
      setUpdatedAt(Date.now());
    } catch (e) {
      if (id !== seq.current) return;
      setError(e instanceof Error ? (("shortMessage" in e && typeof e.shortMessage === "string") ? e.shortMessage : e.message) : String(e));
    } finally {
      if (id === seq.current) setLoading(false);
    }
  }, []);

  useEffect(() => {
    setLoading(true);
    void refresh();
    const timer = window.setInterval(() => {
      if (document.visibilityState === "visible") void refresh();
    }, intervalMs);
    return () => window.clearInterval(timer);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [...deps, intervalMs, refresh]);

  return { data, error, loading, refresh, updatedAt };
}

/** A ticking clock in unix seconds for countdowns. */
export function useNow(stepMs = 1000): number {
  const [now, setNow] = useState(() => Math.floor(Date.now() / 1000));
  useEffect(() => {
    const t = window.setInterval(() => setNow(Math.floor(Date.now() / 1000)), stepMs);
    return () => window.clearInterval(t);
  }, [stepMs]);
  return now;
}
