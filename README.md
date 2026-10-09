# PLEA — sell-gated meme token on Sepolia (test run, contracts only)

Selling PLEA needs a plea approved by the IMD oracle panel ("the Cabal"). Buys go through an
ordinary Uniswap v4 pool whose hook enforces fees, a burn cap and a buy wall; sells go only
through `CabalGate`, which asks the oracle, verifies the signed verdict and executes the swap.

## Contracts (`src/`)

| Contract | Role |
| --- | --- |
| `PLEA` | ERC-20, 1e9 supply, 18 decimals, minted once in `init` (90% hook, 10% distributor). Cabal transfer rule, add-only allowlist, `firstReceivedAt`, `killCabal` (gate only), `burn`. |
| `CabalGate` | `submitSell`, `appeal`, `deliverVerdict` (EIP-712 oracle attestation, domain "IdentityMD Oracle" v2, this chain, this contract), `executeSell`, `cancel`, `killCabal` dead-man switch, question/body/canonical builders. Inherits the protocol's `OracleAttestationConsumer`. |
| `PleaDistributor` | Merkle claim for the 10% share; the owner sets the root once. |
| `PleaLaunch` | Last in the launch: mines a CREATE2 salt on chain (assembly, fixed memory, salts 0,1,2…, `SaltNotFound` after 100,000 tries) so `PleaHook`'s address carries exactly its flag bits (`0x28CC`), deploys the hook, calls `PLEA.init(hook, gate, distributor)`. |
| `PleaHook` | Fork of POOL4 CappedBurnHook (Ethereum `0xc6c965bd…`) on the IMD side. Not in the launch manifest: `PleaLaunch` creates it. |
| `OracleAttestation` | Copied from the protocol reference (only change: `SignatureChecker.isValidSignatureNow`, the name the vendored OpenZeppelin 5.4 exposes; same semantics). |

### Launch order (one transaction, nothing called after)

1. `PLEA(owner)` — owner `0x4b91078b2374c956A65F7Af0999CaE0a935E6821`.
2. `CabalGate(PLEA, TestIMD, oracleSigner)` — TestIMD `0x2b69099e59b05901faa1dd164fabf098bf831e82`, signer `0x5598aa9146215bc13eb26f2c692ad1461fd32982` (owner-settable afterwards).
3. `PleaDistributor(PLEA, owner)`.
4. `PleaLaunch(PLEA, CabalGate, PleaDistributor, PoolManager, TestIMD, Stacker)` — Sepolia PoolManager `0xE03A1074c86CFeDd5C142C4F04F1a1536e203543` (verified to have code), Stacker `0x293c7134ab8f6bf1d8ff44ed806575f8f1baf477` (its bytecode contains `credit(address,uint256)`). TestSIMD `0xf9e2eec3b610ec6781f7438ac5fb4bc049d81cc1` is reached through the Stacker and is not a constructor argument.

`PLEA`'s constructor sets a transient-storage flag (EIP-1153); `init` requires it, records hook/gate/distributor, mints, and calls `hook.seed()` which creates the PLEA/IMD pool (LP fee 0, tick spacing 60) at a 5,700 IMD market cap with the hook's whole PLEA balance as the only liquidity (single-sided). Any failure reverts the whole launch. No `launch.json` is written here; the manifest step fills the values above.

**Rehearsal fallback.** Foundry clears transient storage between top-level calls, and the launch rehearsal deploys each contract with a separate call, so `init` also accepts a call in PLEA's deployment block (`deployBlock`). In the real launch everything is one transaction, so the window is the same. If `seed()` finds no code at the PoolManager (empty-chain rehearsal) it defers; the owner can call `seed()` once on a real chain. On Sepolia the PoolManager exists and seeding happens in the launch tx.

## Hook rules

- **Fees on the IMD side, on the actual fill:** 0.5% cashback to the trader, 0.5% to the owner, 0.25% to pool liquidity (the wall reserve), plus 0.25% of the PLEA leg burned on every trade. The fee on the specified currency is taken in `beforeSwap` as a share of the fill (`amount * r / (10000 + r)` for exact input) and settled against the realised fill in `afterSwap`: whatever the pool did not consume is refunded to the trader, so a partial or zero fill pays a fee only on what was filled. The fee on the unspecified currency is taken in `afterSwap`. Fees are held as ERC-6909 claims; the first trade of a later block redeems matured claims inside the swap (PLEA burned, owner paid, wall reserve and cashback float refilled), and `settleClaims()` does the same for keepers.
- **No PLEA ever leaves the pool as a delta while the Cabal lives.** On an exact-input buy the hook takes the whole PLEA output as its `afterSwap` return delta and transfers the trader's share (output minus the 0.25% burn) as ERC-20 PLEA from the PoolManager to the recipient. The swapper's own PLEA delta is zero, so it can never be minted as ERC-6909 claims and sold in a hookless pool. An exact-output buy fixes the swapper's PLEA delta at the requested amount by v4's accounting (`swapperDelta = swapDelta - hookDelta` on the specified side always equals `amountSpecified`), so it is refused with `ExactOutputBuyRefused` until `killCabal`; routers must quote exact-input buys.
- **Routers must pass the recipient.** `hookData` must be `abi.encode(recipient)` (32 bytes, a non-zero address). While the Cabal lives a buy without it reverts `RecipientRequired`: the PLEA would otherwise be delivered to the swap sender, i.e. the router, where the Cabal's transfer rule strands it. A refused buy costs the buyer nothing. Sells (always through the Gate, which passes the seller) and every trade after `killCabal` fall back to the swap sender when no recipient is given; after `killCabal` buys use plain v4 accounting (the swapper gets the PLEA delta, the hook keeps only the 0.25% burn), so any router works then. Cost basis and cashback are booked to the same address.
- **Partial-fill refunds.** When a swap stops at the swapper's price limit, the part of the specified-side fee the fill did not earn is refunded in `afterSwap`. A PLEA refund (gate sell) is always ERC-20 from the PoolManager. An IMD refund is ERC-20 when the PoolManager already holds that much IMD; otherwise (the swapper settles its input only after the hooks run, and the PoolManager holds no IMD right after launch) it is minted to the trader as an ERC-6909 IMD claim in the PoolManager (`FeeRefunded(..., asClaims = true)`), which any unlock-capable contract can burn and take. The trade never reverts for lack of refund balance.
- **Cashback** is the hook's last step: if `gasleft() > RESERVE` (250,000) it tries `stacker.credit{gas: gasleft() - RESERVE}(trader, amount)` (Stacker approved once at seed; trader from 32-byte `hookData`, else the swap sender, never `tx.origin`); on revert or low gas it sends plain TestIMD; if that fails too the amount is owed and claimable with `claimCashback()`. It never reverts a trade. The float comes from settled claims, so the very first trades are paid on claim.
- **First 90 minutes:** extra buy fee 70%→0% linear (to pool liquidity), max 5,000,000 PLEA per buy.
- **Sells only via the Gate** while the Cabal lives (hook checks the swap sender); PLEA transfers to the PoolManager only from Gate or Hook.
- **Cap / trim / ratchet:** inventory cap starts at the seeded PLEA; buys ratchet it down (full ratchet, rate-limited to 300,000 PLEA/day with carried remainder, floor 900,000 PLEA); PLEA above the cap after a sell is removed proportionally and burned 100%; the IMD recovered goes to the wall reserve.
- **Buy wall:** `rebalance()` (anyone) settles a filled wall (PLEA it bought is burned) and redeploys all retained IMD as one IMD-only band directly below the price, placed off the safer of spot and a block-lagged reference tick (max 200 ticks per block). Simplification vs POOL4: no deployment-floor decay.
- **Keeper tip:** `settleClaims()` and `rebalance()` pay the caller 0.01 IMD from the reserve only when the call handled at least 0.1 IMD of value (claims settled, IMD the wall spent buying PLEA, or a fresh reserve of at least 1 IMD that was actually deployed in that call), and at most once per block. Dust trades and 1,000-PLEA wall fills earn nothing. Reserve that could not be deployed counts for nothing, and wall IMD recycled into a new band is not "fresh". `rebalance()` reverts `RebalanceNotNeeded` when it settled nothing, closed no wall and deployed none. That is the state after a sell exhausts every IMD position: the price sits at the tick extreme, the band cannot be placed (`pendingRebalance()` stays true, `priceX96()` reads 0 so the fact score's P/L and 24h buckets read as a loss/drop), and the next buy brings the price back, after which `rebalance()` deploys the wall.
- **Locked forever:** no `closeMarket`, no withdraw, no owner liquidity power.
- **Per-trader cost basis** (`costBasis`), hourly price checkpoints in a 25-slot ring, `price24hAgo()`.

## Gate rules

- `submitSell(amount, plea)`: 1–280 UTF-8 bytes, well formed, no control / zero-width / bidi characters, no `[PLEA` / `[/PLEA` (case-insensitive); amount ≤ min(2,500,000 PLEA, 35% of balance); one pending per wallet; 4 h after the last executed sell or denial. Takes 0.5 TestIMD and emits `PleaSubmitted(id, seller, amount, factScore, need, body)`.
- Fact score 0–55 (share sold ≤15/25/35% → 18/11/5; held ≥7/3/1 days → 14/9/5; P/L loss 14, ≤+50% 9, ≤+200% 5; 24h price up >2% 9, ±2% 5, down 0; unknown 24h price counts as flat). `need = 70 − factScore`.
- Body: `{v:1, question, chainId:1, window:{hours:1}, answerType:"bool", evidence:"panel", panelSize:30, quorum:20, validForSeconds:3600, allowAmbiguous:true, definitions:{plea, manipulation, facts}, consumer:{chainId:11155111, address:gate}}`. Only `"` and `\` are escaped (everything else is rejected at submit).
- The question text names the plea id and the seller address, so two pleas never share a `questionHash` and a verdict signed for one cannot be delivered to another.
- `deliverVerdict(id, att, sig)`: callable only by the owner-set `relayer` once one is set (anyone while unset); verifies the EIP-712 signature for this gate, consumes `att.requestId`, requires bool, chainId 1, panel ≥30, quorum ≥20, agreed ≥20, not expired, and `questionHash == keccak256` of the canonical JSON (sorted keys, no spaces) of `{answerType, chainId, definitions, evidence, question, v, window:{fromBlock,toBlock}}` with the attestation's blocks. Every verdict resets `lastVerdictAt`.
- Approved → 7-minute `executeSell(minOut)` window; lapsed → plead again. Denied → 4 h wait; one `appeal(id, plea)` for 0.85 TestIMD (0.5 kept as oracle fee, 0.35 to the hook's wall reserve); the appeal question shows the original plea and the DENIED verdict. An appeal is subject to exactly the cooldowns of a new plea (one pending, 4 h after the last executed sell, 4 h after the denial).
- Plea text must be well-formed UTF-8 including the restricted second-byte ranges (no overlongs, surrogates or code points above U+10FFFF).
- `cancel(id)` after 3 h clears a plea the oracle never answered (fee spent). `killCabal()` after 48 h without a verdict lifts all restrictions.

## Oracle relay (Sepolia has no Intake)

`script/relayer.mjs` (no npm dependencies; uses `fetch` and Foundry's `cast`) watches `PleaSubmitted`, decodes the body from the event's ABI data byte for byte (`node script/relayer.mjs --decode-test` checks the decoder against `cast abi-encode` with quotes and backslashes), pays the mainnet Intake `0x1397434cd35e8a9c8ac312a61d3a285eb31dea56` with the body and no callback, polls `api.imd.fun/oracle/requests/:id/attestation`, and calls `deliverVerdict`. Before paying and before delivering it reads `getPlea(id).status` and skips anything not Pending. Mainnet spend is bounded by `MAX_PAY_PER_DAY` (default 20 payments per rolling 24 h) and `SELLER_INTERVAL_S` (default 4 h per seller). Configure `SEPOLIA_RPC`, `MAINNET_RPC`, `GATE`, `CAST_AUTH` (keystore/ledger flags for `cast send`). Keys are never read by the script.

## After launch (owner / operator)

- Fund the relayer with mainnet IMD (0.5 per plea) and ETH; withdraw collected Sepolia TestIMD fees with `CabalGate.withdrawImd`.
- `PleaDistributor.setMerkleRoot(root)` once (leaf `keccak256(abi.encodePacked(index, account, amount))`).
- `CabalGate.setRelayer(relayer)` with the address the relayer script sends from, before the first plea: until it is set anyone may deliver a validly signed verdict, and a seller could pay the public Intake for extra draws on the same body and deliver the first "true". Set it to zero to reopen delivery.
- `CabalGate.setSigner` if the oracle rotates its key. `PLEA.allow(addr)` for exempt senders (add-only).
- Run `rebalance()` / `settleClaims()` keepers (anyone may; tipped).
- Verify the relayer's `consumer` key format against the oracle HTTP door before the first real plea: the body's `consumer:{chainId,address}` shape follows the brief; the API schema was not reachable to confirm the key name.

## Assumptions and open points

- The Stacker's `credit(address,uint256)` pulls IMD from the caller and credits sIMD under project = caller (the hook). Confirmed by selector only.
- Oracle question/definition wording is ours; the `questionHash` canonical form follows the brief.
- Keeper tip 0.01 IMD (minimum 0.1 IMD of work, once per block), wall threshold 1 IMD, minimum trim 1 PLEA, tick spacing 60 are fixed constants.
- `PLEA.init` also accepts a call in PLEA's deployment block without the transient flag (rehearsal fallback, see above). In the factory's one-transaction launch `PleaLaunch` consumes it before the block ends. If PLEA were ever deployed alone, any account could call `init` in that block; do not deploy PLEA outside the launch transaction.
- Ownership is OpenZeppelin single-step `Ownable` on PLEA; `CabalGate` reads `plea.owner()` live. A mistaken `transferOwnership` or `renounceOwnership` permanently disables `setSigner`, `setRelayer`, `withdrawImd` and `allow`. Transfer ownership only to a verified address.
- Salt mining is bounded at 100,000 tries as the brief requires; about 1 in 450 (PleaLaunch address, initcode hash) pairs has no flagged salt, in which case the launch transaction reverts `SaltNotFound` in simulation and must be retried at a new launch address.
- Tests pass with a local v4 `PoolManager` and mocks; no security audit is implied. Owner powers: PLEA allowlist, distributor root, gate signer and fee withdrawal. The owner cannot touch liquidity.

## Build and test

```
forge build
forge test
forge fmt --check
```

`forge test -vv --match-test test_reportLaunchAndMiningGas` prints the PleaLaunch constructor gas and the salt-mining gas. `test/Hook.t.sol` sizes `RESERVE` against a credit that swallows all gas. Site: `site/index.html` (Buy, Plead, Wall), to be pinned under the IPFS label `plea-test` with the handoff addresses.
