#!/usr/bin/env node
// PLEA Cabal relayer: watches CabalGate on Sepolia for PleaSubmitted, pays the IMD oracle Intake on
// Ethereum mainnet for each body (no callback), polls api.imd.fun for the signed attestation and
// delivers it to CabalGate.deliverVerdict on Sepolia.
//
// Dependency free: JSON-RPC via fetch, transactions through Foundry's `cast` (must be on PATH).
// Keys are never read by this script: `cast send` uses the keystore/account you configure.
//
// Environment (operator supplied):
//   SEPOLIA_RPC        Sepolia JSON-RPC URL
//   MAINNET_RPC        Ethereum JSON-RPC URL
//   GATE               CabalGate address on Sepolia
//   INTAKE             Intake on mainnet (default 0x1397434cd35e8a9c8ac312a61d3a285eb31dea56)
//   IMD                IMD on mainnet (default 0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7)
//   CAST_AUTH          extra `cast send` auth flags, e.g. "--account relayer" or "--ledger"
//   API                oracle API base (default https://api.imd.fun)
//   FROM_BLOCK         first Sepolia block to scan (default: latest - 5000)
//   STATE_FILE         json file for progress (default ./relayer-state.json)
//   POLL_MS            poll interval (default 15000)
//   MAX_PAY_PER_DAY    mainnet Intake payments allowed per rolling 24h (default 20): the hard budget
//   SELLER_INTERVAL_S  minimum seconds between payments for the same seller (default 14400 = 4h)
//
// Before paying and before delivering the relayer reads CabalGate.getPlea(id).status on Sepolia and
// skips anything that is not Pending (cancelled, lapsed, answered by another relayer). Set
// CabalGate.setRelayer to this script's sender so only its deliveries count.

import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync, existsSync } from "node:fs";

const env = (k, d) => process.env[k] ?? d;
const SEPOLIA_RPC = env("SEPOLIA_RPC");
const MAINNET_RPC = env("MAINNET_RPC");
const GATE = env("GATE");
const INTAKE = env("INTAKE", "0x1397434cd35e8a9c8ac312a61d3a285eb31dea56");
const IMD = env("IMD", "0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7");
const CAST_AUTH = env("CAST_AUTH", "").split(" ").filter(Boolean);
const API = env("API", "https://api.imd.fun");
const STATE_FILE = env("STATE_FILE", "./relayer-state.json");
const POLL_MS = Number(env("POLL_MS", "15000"));
const MAX_PAY_PER_DAY = Number(env("MAX_PAY_PER_DAY", "20"));
const SELLER_INTERVAL_S = Number(env("SELLER_INTERVAL_S", "14400"));
const STATUS_PENDING = 1; // CabalGate.Status.Pending
const ACTION = "0x6f7261636c652e72657175657374406f7261636c652d31000000000000000000"; // bytes32("oracle.request@oracle-1")
const PRICE = "500000000000000000"; // 0.5 IMD; re-read with priceOf before paying
const ONCE = process.argv.includes("--once");

if (!process.argv.includes("--decode-test") && (!SEPOLIA_RPC || !MAINNET_RPC || !GATE)) {
  console.error("SEPOLIA_RPC, MAINNET_RPC and GATE are required");
  process.exit(1);
}

const cast = (args) => execFileSync("cast", args, { encoding: "utf8" }).trim();

async function rpc(url, method, params) {
  const r = await fetch(url, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
  });
  const j = await r.json();
  if (j.error) throw new Error(JSON.stringify(j.error));
  return j.result;
}

const state = existsSync(STATE_FILE) ? JSON.parse(readFileSync(STATE_FILE, "utf8")) : { lastBlock: 0, pleas: {}, payments: [] };
state.payments ??= [];
const save = () => writeFileSync(STATE_FILE, JSON.stringify(state, null, 2));

// PleaSubmitted(uint256 indexed id, address indexed seller, uint256 amount, uint8 factScore, uint8 need, string body)
const TOPIC = cast(["keccak", "PleaSubmitted(uint256,address,uint256,uint8,uint8,string)"]);
const GET_PLEA_SELECTOR = cast(["sig", "getPlea(uint256)"]);

// ABI-decodes the non-indexed event data (uint256 amount, uint8 factScore, uint8 need, string body) and
// returns the body byte for byte: no text round trip through cast's escaped printing.
export function decodeBody(data) {
  const hex = data.startsWith("0x") ? data.slice(2) : data;
  const word = (i) => BigInt("0x" + hex.slice(i * 64, i * 64 + 64));
  const offset = Number(word(3)); // byte offset of the string head
  const length = Number(BigInt("0x" + hex.slice(offset * 2, offset * 2 + 64)));
  const start = offset * 2 + 64;
  return Buffer.from(hex.slice(start, start + length * 2), "hex").toString("utf8");
}

// Reads CabalGate.getPlea(id).status (Plea struct: seller, amount, factScore, need, status, ...).
async function pleaStatus(id) {
  const data = GET_PLEA_SELECTOR + BigInt(id).toString(16).padStart(64, "0");
  const res = await rpc(SEPOLIA_RPC, "eth_call", [{ to: GATE, data }, "latest"]);
  const hex = res.slice(2);
  const head = Number(BigInt("0x" + hex.slice(0, 64))); // offset of the struct (it holds a string)
  return Number(BigInt("0x" + hex.slice(head * 2 + 4 * 64, head * 2 + 5 * 64)));
}

function withinBudget(seller) {
  const now = Math.floor(Date.now() / 1000);
  state.payments = state.payments.filter((p) => now - p.at < 86400);
  if (state.payments.length >= MAX_PAY_PER_DAY) return `daily budget of ${MAX_PAY_PER_DAY} payments reached`;
  const last = state.payments.filter((p) => p.seller === seller).sort((a, b) => b.at - a.at)[0];
  if (last && now - last.at < SELLER_INTERVAL_S) return `seller ${seller} paid ${now - last.at}s ago`;
  return null;
}

async function scan() {
  const latest = Number(await rpc(SEPOLIA_RPC, "eth_blockNumber", []));
  const from = state.lastBlock ? state.lastBlock + 1 : Number(env("FROM_BLOCK", String(Math.max(0, latest - 5000))));
  if (from > latest) return;
  const logs = await rpc(SEPOLIA_RPC, "eth_getLogs", [
    { address: GATE, fromBlock: "0x" + from.toString(16), toBlock: "0x" + latest.toString(16), topics: [TOPIC] },
  ]);
  for (const log of logs) {
    const id = BigInt(log.topics[1]).toString();
    if (state.pleas[id]) continue;
    const seller = "0x" + log.topics[2].slice(26);
    const bodyJson = decodeBody(log.data);
    JSON.parse(bodyJson); // the gate emits valid JSON; refuse to pay for anything else
    state.pleas[id] = { body: bodyJson, seller, status: "new" };
    console.log(`plea ${id} seen`);
  }
  state.lastBlock = latest;
  save();
}

async function pay(id) {
  const p = state.pleas[id];
  if ((await pleaStatus(id)) !== STATUS_PENDING) {
    p.status = "skipped";
    save();
    console.log(`plea ${id} is no longer pending: not paid`);
    return;
  }
  const why = withinBudget(p.seller);
  if (why) {
    console.log(`plea ${id} deferred: ${why}`);
    return;
  }
  // The body names its consumer (chainId 11155111, the gate): the attestation is signed for the gate.
  const price = cast(["call", "--rpc-url", MAINNET_RPC, INTAKE, "priceOf(bytes32,address)(uint256)", ACTION, IMD]).split(" ")[0] || PRICE;
  cast(["send", "--rpc-url", MAINNET_RPC, ...CAST_AUTH, IMD, "approve(address,uint256)", INTAKE, price]);
  const bodyHex = "0x" + Buffer.from(p.body, "utf8").toString("hex");
  const receipt = cast([
    "send", "--rpc-url", MAINNET_RPC, ...CAST_AUTH, "--json", INTAKE,
    "request(bytes32,bytes,(address,bytes4),address,uint256)(bytes32)",
    ACTION, bodyHex, "(0x0000000000000000000000000000000000000000,0x00000000)", IMD, price,
  ]);
  const j = JSON.parse(receipt);
  // The intake emits the request id; the oracle request UUID is looked up from the tx hash.
  p.txHash = j.transactionHash;
  p.status = "paid";
  state.payments.push({ seller: p.seller, at: Math.floor(Date.now() / 1000), id });
  save();
  console.log(`plea ${id} paid on mainnet in ${p.txHash}`);
}

async function findRequestId(p) {
  // Resolve the oracle request UUID for the payment transaction.
  const r = await fetch(`${API}/oracle/requests?tx=${p.txHash}`);
  if (!r.ok) return null;
  const j = await r.json();
  const req = Array.isArray(j) ? j[0] : j;
  return req?.requestId ?? req?.id ?? null;
}

async function deliver(id) {
  const p = state.pleas[id];
  if (!p.requestId) {
    p.requestId = await findRequestId(p);
    if (!p.requestId) return;
    save();
  }
  const r = await fetch(`${API}/oracle/requests/${p.requestId}/attestation`);
  if (r.status === 404) return; // not answered yet
  if (!r.ok) throw new Error(`attestation ${r.status}`);
  const att = await r.json();
  if (!att.signature || !att.message) return;
  if ((await pleaStatus(id)) !== STATUS_PENDING) {
    p.status = "skipped";
    save();
    console.log(`plea ${id} is no longer pending: verdict not delivered`);
    return;
  }
  const m = att.message;
  const answerType = { bool: 0, address: 1, bytes32: 2, uint256: 3, "address[]": 4, "bytes32[]": 5 }[m.answerType] ?? m.answerType;
  const tuple = `(${m.requestId},${m.chainId},${m.questionHash},${answerType},${m.answer},${m.figure},${m.fromBlock},${m.toBlock},${m.blockHash},${m.panelJobId},${m.panelSize},${m.quorum},${m.agreed},${m.issuedAt},${m.expiresAt})`;
  cast([
    "send", "--rpc-url", SEPOLIA_RPC, ...CAST_AUTH, GATE,
    "deliverVerdict(uint256,(bytes32,uint256,bytes32,uint8,bytes,uint256,uint64,uint64,bytes32,bytes32,uint16,uint16,uint16,uint64,uint64),bytes)",
    id, tuple, att.signature,
  ]);
  p.status = "delivered";
  save();
  console.log(`plea ${id} verdict delivered`);
}

async function tick() {
  await scan();
  for (const [id, p] of Object.entries(state.pleas)) {
    try {
      if (p.status === "new") await pay(id);
      else if (p.status === "paid") await deliver(id);
    } catch (e) {
      console.error(`plea ${id}: ${e.message}`);
    }
  }
}

if (process.argv.includes("--decode-test")) {
  // self-check of the decoder against cast's encoder (no network, no keys)
  const body = '{"v":1,"question":"plea [PLEA]I said \\"gm\\" and C:\\\\ok[/PLEA]"}';
  const enc = cast(["abi-encode", "f(uint256,uint8,uint8,string)", "1", "2", "3", body]);
  const back = decodeBody(enc);
  if (back !== body) throw new Error(`decode mismatch: ${back}`);
  JSON.parse(back);
  console.log("decode ok");
} else if (ONCE) {
  await tick();
} else {
  for (;;) {
    await tick();
    await new Promise((r) => setTimeout(r, POLL_MS));
  }
}
