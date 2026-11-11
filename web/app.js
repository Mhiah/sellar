// Sellar dashboard. No dependencies: talks to the wallet (EIP-1193) and Mezo's RPC directly.
"use strict";

const NET = {
  chainId: "0x7b7b", // 31611
  name: "Mezo Testnet",
  rpc: "https://rpc.test.mezo.org",
  explorer: "https://explorer.test.mezo.org",
  musd: "0x118917a40FAF1CD7a13dB0Ef56C86De7973Ac503",
  safe: "0x9bf0180a21fFfB35b815Bf0B264706E72e0a26Aa",
  shield: "0x799d90D2FA41b9827c345E480BEC635B3EF0c444",
};

// Function selectors (first 4 bytes of keccak of the signature).
const SIG = {
  accounts: "0x5e5c06e2", holdCount: "0xe00ea668", holds: "0xb71b0582", approveHold: "0x747442d3",
  reject: "0xb8adaa11", deposit: "0x47e7ef24", withdraw: "0x2e1a7d4d", configure: "0x71667da5",
  trust: "0x4637d827", untrust: "0xeea327e0", freeze: "0x8d1fdf2f", unfreeze: "0x6a28f000",
  loanHealth: "0xb1ba75f6", trustedAt: "0x47b89d04", holdTtl: "0x63b2a777", flagInfo: "0x9b8fa39e",
  report: "0xcaf2cbc5", fundAssets: "0x3c93b9f2", receiptCount: "0x7f038f3c", receipts: "0x0f7ee1ec",
  claim: "0x379607f5", withdrawBond: "0x7529d9df", cases: "0x2dfe4226", hasReported: "0x202e053d",
  balanceOf: "0x70a08231", allowance: "0xdd62ed3e", approve: "0x095ea7b3",
};
const TOPIC_TRUSTED = "0x85825a10f1ed53996ee005fa260432333e88823a0cfed7324f257f7f4d4df244";
const BOND = 10n * 10n ** 18n;
const ZERO32 = "0x" + "0".repeat(64);

// Why SellarSafe held a request (bit flags from the contract).
const REASONS = [
  [1, "This address is not on your trusted list."],
  [2, "You trusted this address too recently."],
  [4, "This is over your limit for one payment."],
  [8, "This is over your limit for today."],
  [16, "This address is flagged on the scam list."],
  [32, "This address is a confirmed scam."],
  [64, "Your Mezo loan is below the ratio you set."],
];
// What the guard saw, carried in the memo: 0x5e11, then one byte of flags.
const GUARD = [
  [1, "This address came from something your agent read, not from you."],
  [2, "This address looks like one you pay, but it is a different address."],
  [4, "You named a saved payee, but the money is going somewhere else."],
  [8, "This is more than you asked for."],
];

const $ = (id) => document.getElementById(id);
let provider = null, me = null, account = null, holdTtl = 86400n;

// ---------------------------------------------------------------- encoding

const pad = (hex) => hex.replace(/^0x/, "").toLowerCase().padStart(64, "0");
const word = (v) => (typeof v === "bigint" ? pad(v.toString(16)) : typeof v === "boolean" ? pad(v ? "1" : "0") : pad(v));
const enc = (sig, ...args) => sig + args.map(word).join("");
const words = (hex) => (hex.slice(2).match(/.{64}/g) || []).map((w) => BigInt("0x" + w));
const addr = (n) => "0x" + n.toString(16).padStart(40, "0");
const isAddr = (s) => /^0x[0-9a-fA-F]{40}$/.test(s || "");
const short = (a) => a.slice(0, 6) + "…" + a.slice(-4);

function toUnits(text) {
  const t = String(text).trim();
  if (!/^\d+(\.\d{1,18})?$/.test(t)) throw new Error("Enter an amount like 25 or 12.5.");
  const [whole, frac = ""] = t.split(".");
  return BigInt(whole) * 10n ** 18n + BigInt(frac.padEnd(18, "0"));
}
function fmt(units, places = 2) {
  const neg = units < 0n, u = neg ? -units : units;
  const scale = 10n ** BigInt(18 - places);
  const r = (u + scale / 2n) / scale;
  const s = r.toString().padStart(places + 1, "0");
  const whole = s.slice(0, -places).replace(/\B(?=(\d{3})+(?!\d))/g, ",");
  const frac = s.slice(-places).replace(/0+$/, "");
  return (neg ? "-" : "") + whole + (frac ? "." + frac : "");
}

// ---------------------------------------------------------------- chain access

async function rpc(method, params) {
  if (provider && me) return provider.request({ method, params });
  const res = await fetch(NET.rpc, {
    method: "POST", headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
  });
  const out = await res.json();
  if (out.error) throw new Error(out.error.message);
  return out.result;
}
const call = async (to, data) => words(await rpc("eth_call", [{ to, data }, "latest"]));

function say(text, link) {
  const el = $("status");
  el.hidden = !text;
  el.textContent = text || "";
  if (link) {
    const a = document.createElement("a");
    a.href = link; a.target = "_blank"; a.rel = "noopener"; a.textContent = " View transaction";
    el.append(a);
  }
}
function explain(e) {
  const m = (e && (e.shortMessage || e.message)) || String(e);
  if (e && e.code === 4001) return "You cancelled it in your wallet.";
  if (/insufficient funds/i.test(m)) return "Your wallet needs a little test BTC for the network fee.";
  return m.length > 180 ? m.slice(0, 180) + "…" : m;
}

async function send(to, data, label) {
  say(label + ": confirm it in your wallet.");
  const hash = await provider.request({ method: "eth_sendTransaction", params: [{ from: me, to, data }] });
  const url = NET.explorer + "/tx/" + hash;
  say(label + ": waiting for the network.", url);
  for (let i = 0; i < 90; i++) {
    const r = await provider.request({ method: "eth_getTransactionReceipt", params: [hash] });
    if (r) {
      if (BigInt(r.status) !== 1n) throw new Error("The network rejected it.");
      say(label + ": done.", url);
      return r;
    }
    await new Promise((ok) => setTimeout(ok, 2000));
  }
  throw new Error("Still waiting after three minutes. Check the transaction link.");
}

async function act(label, fn) {
  try { await fn(); await refresh(); } catch (e) { say(label + " did not go through. " + explain(e)); }
}

async function ensureAllowance(spender, amount) {
  const [have] = await call(NET.musd, enc(SIG.allowance, me, spender));
  if (have < amount) await send(NET.musd, enc(SIG.approve, spender, amount), "Allow Sellar to take the MUSD");
}

// ---------------------------------------------------------------- wallet

async function connect() {
  if (!window.ethereum) {
    say("No wallet found. Open this page in a browser with MetaMask or another Ethereum wallet.");
    return;
  }
  provider = window.ethereum;
  try {
    const accounts = await provider.request({ method: "eth_requestAccounts" });
    try {
      await provider.request({ method: "wallet_switchEthereumChain", params: [{ chainId: NET.chainId }] });
    } catch (e) {
      await provider.request({
        method: "wallet_addEthereumChain",
        params: [{
          chainId: NET.chainId, chainName: NET.name, rpcUrls: [NET.rpc], blockExplorerUrls: [NET.explorer],
          nativeCurrency: { name: "Bitcoin", symbol: "BTC", decimals: 18 },
        }],
      });
    }
    me = accounts[0];
    $("connect").hidden = true;
    $("who").hidden = false;
    $("who").textContent = short(me);
    say("");
    provider.on && provider.on("accountsChanged", () => location.reload());
    provider.on && provider.on("chainChanged", () => location.reload());
    await refresh();
  } catch (e) {
    say("Could not connect. " + explain(e));
  }
}

// ---------------------------------------------------------------- reads

async function loadAccount() {
  const w = await call(NET.safe, enc(SIG.accounts, me));
  return {
    agent: addr(w[0]), frozen: w[1] === 1n, cooldown: w[2], perPayment: w[4], perDay: w[5],
    balance: w[7], minIcr: w[8],
  };
}
async function loadHolds() {
  const [n] = await call(NET.safe, SIG.holdCount);
  const out = [];
  for (let i = n - 1n; i >= 0n && out.length < 60; i--) {
    const w = await call(NET.safe, enc(SIG.holds, i));
    if (addr(w[0]).toLowerCase() !== me.toLowerCase()) continue;
    out.push({ id: i, to: addr(w[1]), amount: w[2], at: w[3], reasons: Number(w[4]), state: Number(w[5]), memo: pad(w[6].toString(16)) });
  }
  return out;
}
async function loadReceipts() {
  const [n] = await call(NET.shield, SIG.receiptCount);
  const out = [];
  for (let i = n - 1n; i >= 0n && out.length < 60; i--) {
    const w = await call(NET.shield, enc(SIG.receipts, i));
    if (addr(w[0]).toLowerCase() !== me.toLowerCase()) continue;
    out.push({ id: i, to: addr(w[1]), amount: w[2], at: w[3], claimed: w[4] === 1n });
  }
  return out;
}
const flagOf = async (a) => { const w = await call(NET.shield, enc(SIG.flagInfo, a)); return { status: Number(w[0]), reporters: Number(w[1]) }; };

function names() { try { return JSON.parse(localStorage.getItem("sellar.names") || "{}"); } catch (e) { return {}; } }
function saveName(a, name) { try { const n = names(); if (name) n[a.toLowerCase()] = name; else delete n[a.toLowerCase()]; localStorage.setItem("sellar.names", JSON.stringify(n)); } catch (e) {} }
const label = (a) => names()[a.toLowerCase()] || short(a);
const when = (ts) => new Date(Number(ts) * 1000).toLocaleString([], { dateStyle: "medium", timeStyle: "short" });

function reasonsFor(h) {
  const out = [];
  if (h.memo.startsWith("5e11")) {
    const flags = parseInt(h.memo.slice(4, 6), 16);
    for (const [bit, text] of GUARD) if (flags & bit) out.push(text);
  } else if (h.reasons & 128) {
    out.push("Your agent's guard asked for you to look at this one.");
  }
  for (const [bit, text] of REASONS) if (h.reasons & bit) out.push(text);
  return out;
}

// ---------------------------------------------------------------- rendering

function el(tag, cls, text) { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; }
function button(text, cls, onClick) { const b = el("button", "btn " + (cls || ""), text); b.type = "button"; b.addEventListener("click", onClick); return b; }
function item(title, sub, lines, buttons) {
  const row = el("div", "item");
  const amt = el("div", "amt", title + " ");
  if (sub) amt.append(el("span", "", sub));
  row.append(amt);
  if (buttons && buttons.length) { const acts = el("div", "acts"); acts.append(...buttons); row.append(acts); }
  for (const [text, warn] of lines || []) row.append(el("p", "why" + (warn ? " warn" : ""), text));
  return row;
}

async function renderFund() {
  try {
    const [assets] = await call(NET.shield, SIG.fundAssets);
    $("f-fund").replaceChildren(fmt(assets) + " ", el("span", "", "MUSD"));
  } catch (e) { $("f-fund").textContent = "–"; }
}

async function renderWaiting(holds) {
  const now = BigInt(Math.floor(Date.now() / 1000));
  const pending = holds.filter((h) => h.state === 1 && now <= h.at + holdTtl);
  const box = $("holds");
  box.replaceChildren();
  box.hidden = pending.length === 0;
  $("headline").replaceChildren(pending.length ? "Your agent asked." : "Nothing is waiting.", el("br"), pending.length ? "You decide." : "Your agent is within your rules.");
  $("lede").textContent = pending.length
    ? (pending.length === 1 ? "One payment is" : pending.length + " payments are") + " waiting. Nothing leaves your safe until you release it."
    : account.agent === addr(0n)
      ? "You have not set up an agent yet. Add MUSD below, then name your agent's key under Rules."
      : "Payments outside your rules will show up here for you to release or reject.";
  for (const h of pending) {
    const flag = await flagOf(h.to);
    const lines = reasonsFor(h).map((t) => [t, false]);
    const acts = [button("Reject", "", () => act("Reject", () => send(NET.safe, enc(SIG.reject, h.id), "Reject")))];
    if (flag.status === 2) {
      lines.unshift(["A reviewer confirmed this address as a scam. It cannot be released.", true]);
    } else {
      if (flag.status === 1 && !(h.reasons & 16)) lines.unshift(["This address was reported as a scam after your agent asked.", true]);
      acts.push(button(flag.status === 1 ? "Release anyway" : "Release", "go", () =>
        act("Release", () => send(NET.safe, enc(SIG.approveHold, h.id, flag.status === 1), "Release payment"))));
    }
    if (account.frozen) lines.unshift(["Your agent is frozen. Unfreeze under Rules to release payments.", true]);
    box.append(item(fmt(h.amount) + " MUSD", "to " + label(h.to), lines, acts));
  }
}

function renderFacts(loan) {
  $("f-safe").replaceChildren(fmt(account.balance) + " ", el("span", "", "MUSD"));
  if (!loan.has) $("f-loan").replaceChildren("None ", el("span", "", "open"));
  else {
    const pct = fmt(loan.icr * 100n, 1) + "%";
    const below = account.minIcr > 0n && loan.icr < account.minIcr;
    $("f-loan").replaceChildren(pct + " ", el("span", "", below ? "below your floor" : "healthy"));
  }
}

async function renderPayees() {
  const found = new Map(Object.keys(names()).map((a) => [a, true]));
  try {
    const logs = await rpc("eth_getLogs", [{ address: NET.safe, fromBlock: "0x0", toBlock: "latest", topics: [TOPIC_TRUSTED, "0x" + pad(me)] }]);
    for (const l of logs) found.set("0x" + l.topics[2].slice(26), true);
  } catch (e) { /* the node may refuse wide log searches; saved names still show */ }
  const box = $("payee-list");
  box.replaceChildren();
  for (const a of found.keys()) {
    if (!isAddr(a)) continue;
    const [since] = await call(NET.safe, enc(SIG.trustedAt, me, a));
    if (since === 0n) continue;
    box.append(item(names()[a] || short(a), names()[a] ? short(a) : "", [["Trusted since " + when(since), false]],
      [button("Remove", "", () => act("Remove", async () => { await send(NET.safe, enc(SIG.untrust, a), "Remove payee"); saveName(a, ""); }))]));
  }
  if (!box.children.length) box.append(item("No one yet", "", [["Add an address below. Until then, every payment waits for you.", false]]));
}

function renderRules() {
  $("r-agent").value = account.agent === addr(0n) ? "" : account.agent;
  $("r-per").value = fmt(account.perPayment, 6).replace(/,/g, "");
  $("r-day").value = fmt(account.perDay, 6).replace(/,/g, "");
  $("r-cool").value = (account.cooldown / 60n).toString();
  $("r-icr").value = fmt(account.minIcr * 100n, 2).replace(/,/g, "");
  $("freeze").textContent = account.frozen ? "Unfreeze agent" : "Freeze agent";
  $("freeze-text").textContent = account.frozen
    ? "Your agent is frozen. It cannot pay, and held payments cannot be released."
    : "Stops every agent payment and release until you unfreeze.";
}

async function renderActivity(holds, receipts) {
  const rows = [];
  const STATE = { 1: "Waiting for you", 2: "Released by you", 3: "Rejected by you" };
  for (const h of holds) rows.push({ at: h.at, node: item(fmt(h.amount) + " MUSD", "to " + label(h.to), [[STATE[h.state] + ", asked " + when(h.at), false]]) });
  for (const r of receipts) {
    const lines = [["Paid " + when(r.at), false]];
    const acts = [];
    if (r.claimed) lines.push(["Refunded from the cover fund.", false]);
    else {
      const c = await call(NET.shield, enc(SIG.cases, r.to));
      if (Number(c[0]) === 2 && r.at < c[3]) {
        lines.push(["This address was later confirmed as a scam. You can claim a refund.", true]);
        acts.push(button("Claim refund", "go", () => act("Claim", () => send(NET.shield, enc(SIG.claim, r.id), "Claim refund"))));
      }
    }
    rows.push({ at: r.at, node: item(fmt(r.amount) + " MUSD", "to " + label(r.to), lines, acts) });
  }
  rows.sort((a, b) => (a.at < b.at ? 1 : -1));
  const box = $("activity-list");
  box.replaceChildren(...rows.map((r) => r.node));
  if (!rows.length) box.append(item("Nothing yet", "", [["Payments your agent asks for will be listed here.", false]]));
}

async function refresh() {
  await renderFund();
  if (!me) return;
  try {
    account = await loadAccount();
    [holdTtl] = await call(NET.safe, SIG.holdTtl);
    const lh = await call(NET.safe, enc(SIG.loanHealth, me)).catch(() => [0n, 0n]);
    const [walletMusd] = await call(NET.musd, enc(SIG.balanceOf, me));
    const holds = await loadHolds();
    const receipts = await loadReceipts();
    renderFacts({ has: lh[0] === 1n, icr: lh[1] });
    $("money").hidden = false;
    $("wallet-musd").textContent = fmt(walletMusd);
    renderRules();
    await renderWaiting(holds);
    await renderPayees();
    await renderActivity(holds.filter((h) => h.state !== 2), receipts);
  } catch (e) {
    say("Could not read your safe from Mezo. " + explain(e));
  }
}

// ---------------------------------------------------------------- actions

const needWallet = () => { if (!me) { say("Connect your wallet first."); return true; } return false; };

$("connect").addEventListener("click", connect);

$("nav").addEventListener("click", (e) => {
  const tab = e.target.dataset && e.target.dataset.tab;
  if (!tab) return;
  for (const b of $("nav").children) b.toggleAttribute("aria-current", false);
  e.target.setAttribute("aria-current", "page");
  for (const s of document.querySelectorAll("main > section")) s.hidden = s.id !== tab;
});

$("money-form").addEventListener("submit", (e) => {
  e.preventDefault();
  if (needWallet()) return;
  const kind = e.submitter && e.submitter.value;
  act(kind === "withdraw" ? "Withdraw" : "Deposit", async () => {
    const amount = toUnits($("money-amt").value);
    if (kind === "withdraw") await send(NET.safe, enc(SIG.withdraw, amount), "Withdraw");
    else { await ensureAllowance(NET.safe, amount); await send(NET.safe, enc(SIG.deposit, me, amount), "Deposit"); }
    $("money-amt").value = "";
  });
});

$("payee-form").addEventListener("submit", (e) => {
  e.preventDefault();
  if (needWallet()) return;
  const a = $("payee-addr").value.trim();
  act("Trust", async () => {
    if (!isAddr(a)) throw new Error("That is not an address. It should start with 0x and have 42 characters.");
    const flag = await flagOf(a);
    if (flag.status === 1 || flag.status === 2) throw new Error("That address is on the scam list, so it cannot be trusted.");
    await send(NET.safe, enc(SIG.trust, a), "Trust payee");
    saveName(a, $("payee-name").value.trim());
    $("payee-addr").value = ""; $("payee-name").value = "";
  });
});

$("rules-form").addEventListener("submit", (e) => {
  e.preventDefault();
  if (needWallet()) return;
  act("Save rules", async () => {
    const agent = $("r-agent").value.trim();
    if (!isAddr(agent)) throw new Error("The agent key should be an address starting with 0x.");
    if (!/^\d+$/.test($("r-cool").value.trim())) throw new Error("Enter the wait in whole minutes.");
    const data = enc(SIG.configure, agent, toUnits($("r-per").value), toUnits($("r-day").value),
      BigInt($("r-cool").value.trim()) * 60n, toUnits($("r-icr").value) / 100n);
    await send(NET.safe, data, "Save rules");
  });
});

$("freeze").addEventListener("click", () => {
  if (needWallet()) return;
  act(account.frozen ? "Unfreeze" : "Freeze", () =>
    send(NET.safe, account.frozen ? SIG.unfreeze : enc(SIG.freeze, me), account.frozen ? "Unfreeze agent" : "Freeze agent"));
});

let checked = null;
$("scam-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  const a = $("scam-addr").value.trim();
  const out = $("scam-result");
  out.hidden = false; $("scam-acts").hidden = true;
  if (!isAddr(a)) { out.className = "note bad"; out.textContent = "That is not an address. It should start with 0x and have 42 characters."; return; }
  try {
    const c = await call(NET.shield, enc(SIG.cases, a));
    const status = Number(c[0]), reporters = Number(c[2]);
    const people = reporters === 1 ? "1 person" : reporters + " people";
    out.className = "note " + (status === 1 || status === 2 ? "bad" : "ok");
    out.textContent = status === 2 ? "Confirmed scam. Every Sellar safe refuses to release payments to this address."
      : status === 1 ? "Flagged. Reported by " + people + ", with " + fmt(BOND * BigInt(reporters)) + " MUSD bonded. Every Sellar safe holds payments to it."
      : status === 3 ? "A report against this address was dismissed as false. Nobody is reporting it now."
      : "Not reported. That does not prove it is safe.";
    checked = a;
    let mine = false;
    if (me) [mine] = (await call(NET.shield, enc(SIG.hasReported, a, c[1], me))).map((x) => x === 1n);
    $("scam-acts").hidden = false;
    $("scam-report").hidden = status === 2 || mine;
    $("scam-bond").hidden = !mine;
  } catch (err) { out.className = "note bad"; out.textContent = "Could not check. " + explain(err); }
});
$("scam-report").addEventListener("click", () => {
  if (needWallet() || !checked) return;
  act("Report", async () => {
    await ensureAllowance(NET.shield, BOND);
    await send(NET.shield, enc(SIG.report, checked, ZERO32), "Report address");
    $("scam-form").requestSubmit();
  });
});
$("scam-bond").addEventListener("click", () => {
  if (needWallet() || !checked) return;
  act("Take bond back", async () => { await send(NET.shield, enc(SIG.withdrawBond, checked), "Take bond back"); $("scam-form").requestSubmit(); });
});

refresh();
