import { Moon, Sun, Wallet } from "lucide-react";
import { useEffect, useState } from "react";
import { Button } from "./components/ui";
import { IPFS_LABEL } from "./lib/config";
import { short } from "./lib/format";
import { useWallet } from "./lib/wallet";
import { BuyPage } from "./pages/Buy";
import { CashbackPage } from "./pages/Cashback";
import { PleadPage } from "./pages/Plead";
import { StatusPage } from "./pages/Status";
import { WallPage } from "./pages/Wall";

const NAV = [
  { path: "buy", label: "Buy" },
  { path: "cashback", label: "Cashback" },
  { path: "plead", label: "Plead" },
  { path: "wall", label: "Wall" },
  { path: "status", label: "Status" },
] as const;

function parseRoute(hash: string): { page: string; param?: string } {
  const parts = hash.replace(/^#\/?/, "").split("/").filter(Boolean);
  const page = parts[0] ?? "buy";
  return { page: NAV.some((n) => n.path === page) ? page : "buy", param: parts[1] };
}

function useRoute() {
  const [route, setRoute] = useState(() => parseRoute(window.location.hash));
  useEffect(() => {
    const onHash = () => {
      setRoute(parseRoute(window.location.hash));
      window.scrollTo({ top: 0 });
      document.getElementById("main")?.focus();
    };
    window.addEventListener("hashchange", onHash);
    return () => window.removeEventListener("hashchange", onHash);
  }, []);
  return route;
}

function useTheme() {
  const [theme, setTheme] = useState<"light" | "dark">(() => (document.documentElement.getAttribute("data-theme") === "dark" ? "dark" : "light"));
  const toggle = () => {
    const next = theme === "dark" ? "light" : "dark";
    // Suppress transitions for the swap so the theme snaps instead of smearing.
    const style = document.createElement("style");
    style.textContent = "*,*::before,*::after{transition:none !important}";
    document.head.appendChild(style);
    document.documentElement.setAttribute("data-theme", next);
    try {
      localStorage.setItem("plea-theme", next);
    } catch {
      /* private mode */
    }
    void document.documentElement.offsetHeight;
    requestAnimationFrame(() => style.remove());
    setTheme(next);
  };
  return { theme, toggle };
}

export function App() {
  const route = useRoute();
  const { theme, toggle } = useTheme();
  const wallet = useWallet();

  return (
    <>
      <a className="skip" href="#main">
        Skip to content
      </a>
      <header className="topbar">
        <div className="topbar-inner">
          <a className="wordmark" href="#/buy" aria-label="PLEA, home">
            PLEA <span className="wordmark-sub">Sepolia test</span>
          </a>
          <nav aria-label="Pages">
            <ul className="tabs">
              {NAV.map((n) => (
                <li key={n.path}>
                  <a href={`#/${n.path}`} aria-current={route.page === n.path ? "page" : undefined}>
                    {n.label}
                  </a>
                </li>
              ))}
            </ul>
          </nav>
          <div className="topbar-tools">
            {wallet.address && !wallet.onSepolia && (
              <Button variant="primary" onClick={() => void wallet.switchToSepolia()}>
                Switch to Sepolia
              </Button>
            )}
            {wallet.address ? (
              <span className="wallet-chip" title={wallet.address}>
                <Wallet className="icon" aria-hidden="true" /> <span className="mono">{short(wallet.address)}</span>
                <span className="sr-only">connected wallet</span>
              </span>
            ) : (
              <Button variant="secondary" onClick={() => void wallet.connect()} busy={wallet.status === "connecting"}>
                <Wallet className="icon" aria-hidden="true" /> Connect wallet
              </Button>
            )}
            <button type="button" className="icon-btn" onClick={toggle} aria-label={theme === "dark" ? "Switch to light theme" : "Switch to dark theme"} aria-pressed={theme === "dark"}>
              {theme === "dark" ? <Sun className="icon" aria-hidden="true" /> : <Moon className="icon" aria-hidden="true" />}
            </button>
          </div>
        </div>
        {wallet.error && (
          <p className="topbar-error" role="alert">
            {wallet.error}
          </p>
        )}
      </header>
      <main id="main" className="page" tabIndex={-1}>
        {route.page === "buy" && <BuyPage />}
        {route.page === "cashback" && <CashbackPage />}
        {route.page === "plead" && <PleadPage />}
        {route.page === "wall" && <WallPage id={route.param} />}
        {route.page === "status" && <StatusPage />}
      </main>
      <footer className="footer">
        <p>
          PLEA test site for launch #1148 on Sepolia · pinned on IPFS under the label <span className="mono">{IPFS_LABEL}</span> · reads public Sepolia RPCs ·{" "}
          <a href="#/status">all contract addresses</a>.
        </p>
      </footer>
    </>
  );
}
