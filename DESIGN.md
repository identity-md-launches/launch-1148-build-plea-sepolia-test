# DESIGN.md — PLEA test site

Documents the design implemented in `web/src` (export in `dist/`). Mode "Operate": a working trading and plea tool with standard web controls; the world lends type, palette, density and one signature move, the Cabal's verdict stamp.

## Overview

Audience: holders testing PLEA on Sepolia. Pages are hash routes (`#/buy`, `#/cashback`, `#/plead`, `#/wall`, `#/wall/:id`, `#/status`) rendered by `web/src/App.tsx`. Each page is one column, max 64rem wide, with sections separated by space and a single 1px rule; headings carry more space above than below. Status is always carried by a stamp label plus colour, never colour alone. Plea text is rendered as React text inside `blockquote.plea-text` with `white-space: pre-wrap; overflow-wrap: anywhere` (no HTML injection path).

## Colors

Tokens live in `web/src/styles.css`. Primitives (`--vellum-*`, `--ink-*`, `--indigo-*`, `--ember-*`, `--verdict-*`, `--slate-*`, `--night-*`, `--paper-*`) are never used in components; components use the semantic tokens, switched by `html[data-theme="light"|"dark"]` (one mechanism; the inline script in `web/index.html` reads `localStorage.plea-theme` or `prefers-color-scheme`, the header button toggles and suppresses transitions during the swap).

| Role | Token | Light | Dark |
| --- | --- | --- | --- |
| Page background | `--color-bg` | `#f4efe4` | `#15131c` |
| Surface (header, cards, inputs) | `--color-surface` | `#fcf9f2` | `#1e1b27` |
| Hover surface | `--color-surface-hover` | `#ebe4d3` | `#27232f` |
| Border / strong border | `--color-border` / `--color-border-strong` | `#d9d0bb` / `#b8ad93` | `#363142` / `#4d475c` |
| Body text | `--color-text` | `#1f1b2d` | `#ede7da` |
| Secondary text | `--color-text-secondary` | `#5a5470` | `#aaa3ba` |
| Accent (one filled action per view) | `--color-accent` (`-hover`, `--color-on-accent`) | `#4a3fb5` / white | `#8f86ff` / `#15131c` |
| Links | `--color-link` | `#3d3399` | `#a79fff` |
| Focus ring, caret accent | `--color-focus` | `#c2410c` | `#ffb067` |
| Approved | `--color-approved` | `#1c7a4a` | `#5fd39a` |
| Denied | `--color-denied` | `#b02a22` | `#ff7b70` |
| Pending | `--color-pending` | `#8a5a00` | `#f0c15a` |
| Lapsed / cancelled | `--color-lapsed` | `#6b6880` | `#9d98ad` |
| Selection | `--color-selection-bg` / `-text` | accent / white | accent / `#15131c` |

Rendered pairs read in the browser (computed styles, 1280px): light body `#1f1b2d` on `#f4efe4`, secondary `#5a5470` on `#f4efe4`, link `#3d3399`, primary button white on `#4a3fb5`; dark body `#ede7da` on `#15131c`, secondary `#aaa3ba` on `#15131c`. Contrast ratios were not measured with a tool in this run; see `artifacts/validation.md`.

Scrollbars (`scrollbar-color`, `::-webkit-scrollbar-*`), `::selection`, `caret-color` and `accent-color` all take their colours from these tokens.

## Typography

- Display: "Fraunces Variable" (`web/src/fonts/fraunces-latin-wght-normal.woff2`, OFL, weight axis 100–900, `font-optical-sizing: auto`) for `h1`, `h2`, the wordmark, plea text and the stamp.
- Body/UI: "Inter Variable" (`web/src/fonts/inter-latin-wght-normal.woff2`, OFL) for everything else; `h3` uses Inter 600.
- Mono: system `ui-monospace` stack, only for addresses and hashes (`.mono`).
- Scale (`--text-*`): xs 0.8125rem (stat notes), sm 0.875rem (hints, errors, tx lines, stamps), base 1rem (body, inputs), md 1.0625rem (lede, stat values, plea text, large stamp), lg 1.5rem (h2), xl 2rem (h1), 2xl 2.5rem (h1 from 48rem).
- Line-height 1.1 for display headings, 1.3 for h3, 1.5–1.55 for body. Headings use `text-wrap: balance`, paragraphs `text-wrap: pretty` and `max-width: 70ch`.
- `.num` applies `font-variant-numeric: tabular-nums` to amounts, prices, scores and countdowns. Small uppercase labels (wordmark sub, stamp) get +0.04–0.12em letter-spacing; h1 gets −0.01em.

## Layout

Spacing steps `--space-1…12` (0.25–3rem). Content column `.page` max 64rem with 1rem inline padding. Forms cap fields at 32rem. `.stats` is a `repeat(auto-fit, minmax(11rem, 1fr))` definition-list grid (2 columns under 40rem, 1 under 24rem). The header is sticky; under 40rem the tab list drops to its own row and scrolls horizontally with trailing padding so the next tab peeks. The address table collapses to stacked rows under 40rem. No horizontal overflow was observed at 360 and 1280px.

## Elevation & depth

Flat by default. Surfaces are distinguished by background tokens and 1px borders; only `.plea-card` carries `--shadow-raised` (two layered transparent shadows). Nothing is blurred or glassy; no gradients.

## Shapes

Radii: `--radius-sm` 0.375rem (tabs, chips, stamps, skip link), `--radius-md` 0.625rem (buttons, inputs, notices), `--radius-lg` 0.875rem (plea cards, concentric with the md inner elements). Borders are 1px; the stamp uses a 2px border with an inset double ring.

## Components (`web/src/components/ui.tsx`)

- `Button` — `variant` primary (filled accent, one per view) / secondary / quiet; `busy` shows a spinner and keeps the label, sets `aria-busy`; hover (`@media (hover: hover)`), `:active` scale 0.96, disabled opacity 0.55, `:focus-visible` 2px ember ring.
- `TxLine` — per-button live status (`role="status"`, errors as `role="alert"`) with Etherscan links; states wallet → mining → success/error, driven by `useTx` in `web/src/lib/tx.ts`.
- `Stamp` — the verdict stamp: Fraunces 700 uppercase, letter-spaced, rotated −4°, double ring, coloured by tone (approved, denied, pending, lapsed, executed). The one authored motion: `stamp-in` 480ms scale 1.5→1 with `cubic-bezier(0.16, 1, 0.3, 1)`, only under `prefers-reduced-motion: no-preference`.
- `Field` — label bound with `htmlFor`, hint and error ids wired through `aria-describedby`, `aria-invalid` on failing inputs, optional trailing "Use max" link button.
- `Stats` — `dl.stats` label/value/note triplets for live numbers.
- `Section`, `Notice` (1px border, tone colour, `role="alert"` when denied), `AddressLink`/`TxLink` (mono, external icon, screen-reader suffix), `Countdown` (ticking, tabular), `Loading`.
- Icons: lucide-react only (`Wallet`, `Sun`, `Moon`, `ExternalLink`, `LoaderCircle`, `CircleAlert`, `CircleCheck`), stroke 1.75, `currentColor`.

## Do's and don'ts

- Start a new page as a `.page` child: `h1`, `.lede`, then `Section`s; put numbers in `Stats` and actions in `.actions` with one `btn-primary`.
- Add state colour only through the `--color-approved/denied/pending/lapsed` tokens and always pair it with a label.
- Keep monospace for addresses and hashes; amounts use Inter with `.num`.
- Don't add cards inside cards, hero metrics, eyebrow labels, gradients, blur, emoji icons or modals; use an inline step or a page.
- To add a page: register it in `NAV` in `App.tsx`, create `pages/Name.tsx`, read chain state with `usePolling` + `lib/reads.ts`, send transactions with `useTx` + `writeChecked`.
