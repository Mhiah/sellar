"""The agent's only way to pay: 4eyes screening first, then SellarSafe.

4eyes sees what the chain cannot: where an address came from (typed by the user, or only read in an
email, page or file), whether it is a lookalike of a trusted payee, and whether the amount is more
than the user asked for. If any of that looks wrong, the guard asks SellarSafe for a human
(`escalate`), so the payment waits on-chain as a hold that only the owner can release.

SellarSafe sees what the guard cannot be trusted with: the trusted list, limits, the shared scam
list and the owner's Mezo loan. If the guard were bypassed or fooled, those still hold the payment.
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Optional

from eth_utils import keccak

from ..foureyes import chain
from ..foureyes.detect import MoneyAction
from ..foureyes.guard import CRITICAL, Provenance, Reason, assess
from ..foureyes.store import Store
from .mezo import SellarClient, describe, to_units

# 4eyes findings the chain has no way to see. Any of these makes the guard ask for a human.
ESCALATE_CODES = {"injected", "lookalike", "changed", "intent"}

# The hold's memo carries what the guard saw, so the owner's dashboard can say why in plain words:
# two marker bytes (0x5e11), one byte of these flags, then the rest of the reference's hash.
MEMO_MARKER = b"\x5e\x11"
MEMO_FLAGS = {"injected": 1, "lookalike": 2, "changed": 4, "intent": 8}


def build_memo(reference: str, found: list[Reason]) -> bytes:
    digest = keccak(text=reference or "")
    flags = 0
    for r in found:
        flags |= MEMO_FLAGS.get(r.code, 0)
    if not flags:
        if not reference:
            return b"\0" * 32
        # A plain reference hash must never look like a guard memo.
        return (bytes([digest[0] ^ 0xFF]) + digest[1:]) if digest[:2] == MEMO_MARKER else digest
    return MEMO_MARKER + bytes([flags]) + digest[3:]


@dataclass
class PayResult:
    status: str                              # paid | held | refused
    message: str
    guard_reasons: list[str] = field(default_factory=list)
    chain_reasons: list[str] = field(default_factory=list)
    hold_id: Optional[int] = None
    tx: Optional[str] = None
    url: Optional[str] = None
    escalated: bool = False


# This wallet only pays MUSD, so an amount the user gives without a token name still means MUSD.
_TOKEN_AMOUNT = re.compile(r"(\d[\d,]*(?:\.\d+)?)\s*MUSD\b", re.I)
_DOLLAR_AMOUNT = re.compile(r"\$\s?(\d[\d,]*(?:\.\d+)?)|(\d[\d,]*(?:\.\d+)?)\s*(?:dollars?|bucks|usd)\b", re.I)
_VERB = re.compile(r"\b(?:pay|send|transfer|give|tip)\b", re.I)
_NUMBER = re.compile(r"(?<![#\w.])(\d[\d,]*(?:\.\d+)?)(?![\w.])")
_REFERENCE = re.compile(r"(?:invoice|order|ref(?:erence)?|no\.?|number|#)\s*#?\s*$", re.I)
# A number followed by one of these is a count or a different token, not an amount of MUSD.
_NOT_MONEY = re.compile(r"\s*(?:%|days?|hours?|hrs?|minutes?|mins?|weeks?|months?|years?|times|people|items?|[A-Z]{2,6}\b)")


def amounts_in(text: str) -> list[float]:
    """MUSD amounts a user message asks for: '5 MUSD', '$5', '5 dollars', or a bare number after pay/send."""
    text = text or ""
    found: list[float] = []

    def add(raw: str) -> None:
        try:
            found.append(float(raw.replace(",", "")))
        except ValueError:
            pass

    for m in _TOKEN_AMOUNT.finditer(text):
        add(m.group(1))
    for m in _DOLLAR_AMOUNT.finditer(text):
        add(m.group(1) or m.group(2))
    if not found:
        for verb in _VERB.finditer(text):
            sentence = re.split(r"\.(?!\d)|\n", text[verb.end():verb.end() + 80])[0]
            for m in _NUMBER.finditer(sentence):
                if _REFERENCE.search(sentence[:m.start()]) or _NOT_MONEY.match(sentence[m.end():]):
                    continue      # "invoice 4471", "in 3 days", "10 USDC"
                add(m.group(1))
                break
    return found


class GuardedWallet:
    def __init__(self, client: SellarClient, payees: Optional[dict[str, str]] = None, session: str = "default"):
        self.client = client
        self.session = session
        self.prov = Provenance()
        self._asked: list[float] = []      # amounts in the most recent user message that named any
        self._used = 0.0                    # MUSD already paid against those amounts
        # Set when the harness could not record something the agent read. From then on the guard
        # cannot tell where an address came from, so every payment goes to the owner.
        self.blind: Optional[str] = None
        # The guard's own copy of the owner's payee names, used to spot "you said Ade, this is not Ade".
        self.store = Store(memory=True)
        self.store.set_setting("hold_new_payees", False)   # new payees are SellarSafe's call, on-chain
        for name, address in (payees or {}).items():
            self.store.trust(name, address)

    # --- what the agent's harness feeds in -------------------------------------------------------
    def note_user(self, text: str) -> None:
        """Something the human typed."""
        self.prov.note_user(self.session, text or "", list(self.store.payees()))
        latest = amounts_in(text or "")
        if latest:
            self._asked = latest
            self._used = 0.0

    def note_content(self, text: str) -> None:
        """Something the agent only read: an email, a web page, a file, a tool result."""
        self.prov.note_content(self.session, text or "")

    # --- screening ---------------------------------------------------------------------------------
    def screen(self, to: str, amount: float) -> list[Reason]:
        act = MoneyAction(tool="sellar_pay", kind="transfer", recipients=[chain.norm(to)], amount=float(amount),
                          token="MUSD")
        # "More than you asked" is judged against the latest message that named an amount, not against
        # every amount ever mentioned in the conversation.
        view = dict(self.prov.view(self.session))
        view["amounts"] = [(a, "MUSD") for a in self._asked]
        reasons = assess(act, self.store, view)
        # One request is one payment. Paying the asked amount again, or in pieces that add up to
        # more, is also "more than you asked".
        total = sum(self._asked)
        if self._asked and not any(r.code == "intent" for r in reasons) and self._used + amount > total * (1 + 1e-6):
            reasons.append(Reason("intent", f"You asked for {total:g} MUSD in total. {self._used:g} MUSD has already "
                                            f"been paid, and this would bring it to {self._used + amount:g}."))
        # "unknown" (never mentioned anywhere) is also something only the guard can know.
        return [r for r in reasons if r.code in ESCALATE_CODES or r.code == "unknown"]

    # --- the payment -------------------------------------------------------------------------------
    def pay(self, to: str, amount: float, memo: str = "") -> PayResult:
        if not chain.is_evm(to or ""):
            return PayResult("refused", f"{to!r} is not a Mezo address.")
        if amount is None or amount <= 0:
            return PayResult("refused", "The amount must be more than zero.")
        found = self.screen(to, amount)
        escalate = any(r.code in ESCALATE_CODES or r.severity == CRITICAL for r in found)
        guard_reasons = [r.text for r in found]
        if self.blind:
            escalate = True
            guard_reasons.append(self.blind)

        try:
            out = self.client.request(to, to_units(amount), build_memo(memo, found), escalate)
        except Exception as exc:   # the safe refused the request outright, or the node could not be reached
            text = str(exc)
            why = ("the owner has frozen the agent" if "AccountFrozen" in text or "0x552afea0" in text
                   else "this key is not the agent for that safe" if "NotAgent" in text or "0x0d9ab13f" in text
                   else text[:200])
            return PayResult("refused", f"SellarSafe did not accept the request: {why}. Nothing was paid. Tell the user.",
                             guard_reasons=guard_reasons, escalated=escalate)
        if out["paid"]:
            self._used += float(amount)     # a hold is the owner's decision, so only what went out counts
        chain_reasons = describe(out["reasons"])
        common = dict(guard_reasons=guard_reasons, chain_reasons=chain_reasons, tx=out["tx"], url=out["url"],
                      escalated=escalate)
        if out["paid"]:
            return PayResult("paid", f"Paid {amount:g} MUSD to {chain.short(to)}.", **common)
        if out["hold_id"] is not None:
            lines = [f"Sellar HELD this payment (hold {out['hold_id']}): {amount:g} MUSD to {chain.short(to)}."]
            lines += [f"- {t}" for t in guard_reasons]
            lines += [f"- On-chain: {t}." for t in chain_reasons]
            lines.append("Do not retry, split or re-route it. Tell the user exactly what is above. Only the "
                         "account owner can release it, from their own wallet.")
            return PayResult("held", "\n".join(lines), hold_id=out["hold_id"], **common)
        return PayResult("refused", "SellarSafe did not accept the request.", **common)
