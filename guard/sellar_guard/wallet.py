"""The agent's only way to pay: 4eyes screening first, then SellarSafe.

4eyes sees what the chain cannot: where an address came from (typed by the user, or only read in an
email, page or file), whether it is a lookalike of a trusted payee, and whether the amount is more
than the user asked for. If any of that looks wrong, the guard asks SellarSafe for a human
(`escalate`), so the payment waits on-chain as a hold that only the owner can release.

SellarSafe sees what the guard cannot be trusted with: the trusted list, limits, the shared scam
list and the owner's Mezo loan. If the guard were bypassed or fooled, those still hold the payment.
"""
from __future__ import annotations

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


class GuardedWallet:
    def __init__(self, client: SellarClient, payees: Optional[dict[str, str]] = None, session: str = "default"):
        self.client = client
        self.session = session
        self.prov = Provenance()
        # The guard's own copy of the owner's payee names, used to spot "you said Ade, this is not Ade".
        self.store = Store(memory=True)
        self.store.set_setting("hold_new_payees", False)   # new payees are SellarSafe's call, on-chain
        for name, address in (payees or {}).items():
            self.store.trust(name, address)

    # --- what the agent's harness feeds in -------------------------------------------------------
    def note_user(self, text: str) -> None:
        """Something the human typed."""
        self.prov.note_user(self.session, text or "", list(self.store.payees()))

    def note_content(self, text: str) -> None:
        """Something the agent only read: an email, a web page, a file, a tool result."""
        self.prov.note_content(self.session, text or "")

    # --- screening ---------------------------------------------------------------------------------
    def screen(self, to: str, amount: float) -> list[Reason]:
        act = MoneyAction(tool="sellar_pay", kind="transfer", recipients=[chain.norm(to)], amount=float(amount),
                          token="MUSD")
        reasons = assess(act, self.store, self.prov.view(self.session))
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

        out = self.client.request(to, to_units(amount), keccak(text=memo) if memo else b"\0" * 32, escalate)
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
