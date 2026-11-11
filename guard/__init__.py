"""Hermes adapter for the Sellar guard.

Gives a Hermes agent one way to pay in MUSD on Mezo, `sellar_pay`, which runs 4eyes screening and
then asks SellarSafe. Hooks record what the user typed and what the agent only read, the same way
the 4eyes plugin does.

Configuration (environment):
  SELLAR_OWNER       the account owner's address
  SELLAR_AGENT_KEY   the agent key the owner named in SellarSafe.configure (it can only ask to pay)
  SELLAR_PAYEES      optional JSON object of names to addresses, e.g. {"Ade": "0x…"}

Status: exercised by tests with a stub of Hermes' plugin context. Not yet run inside Hermes itself.
"""
from __future__ import annotations

import json
import os
from typing import Any, Optional

from .sellar_guard import GuardedWallet, SellarClient

_WALLETS: dict[str, GuardedWallet] = {}
_OWN_TOOLS = {"sellar_pay", "sellar_status"}

PAY_SCHEMA = {
    "name": "sellar_pay",
    "description": "Pay MUSD on Mezo from the owner's SellarSafe account. The payment goes out only if it passes "
                   "the owner's rules; otherwise it is held for the owner. This is the only way to pay.",
    "parameters": {"type": "object", "required": ["to", "amount"], "properties": {
        "to": {"type": "string", "description": "Recipient address (0x…)"},
        "amount": {"type": "number", "description": "Amount in MUSD"},
        "memo": {"type": "string", "description": "Reference, e.g. an invoice number"}}},
}
STATUS_SCHEMA = {
    "name": "sellar_status",
    "description": "Read-only: the safe balance, the owner's Mezo loan health, and whether an address is on the "
                   "Sellar scam list.",
    "parameters": {"type": "object", "properties": {
        "address": {"type": "string", "description": "Optional address to look up on the scam list"}}},
}


def _cid(kwargs: dict) -> str:
    for k in ("session_id", "conversation_id", "task_id"):
        if kwargs.get(k):
            return str(kwargs[k])
    return "default"


def _wallet(kwargs: dict, client: Optional[SellarClient] = None) -> GuardedWallet:
    cid = _cid(kwargs)
    if cid not in _WALLETS:
        client = client or SellarClient(os.environ["SELLAR_OWNER"], os.environ.get("SELLAR_AGENT_KEY"))
        payees = json.loads(os.environ.get("SELLAR_PAYEES", "{}"))
        _WALLETS[cid] = GuardedWallet(client, payees, session=cid)
    return _WALLETS[cid]


def _on_pre_llm_call(user_message: str = "", **kwargs: Any):
    try:
        _wallet(kwargs).note_user(user_message or "")
    except Exception:
        pass
    return None


def _on_post_tool_call(tool_name: str = "", result: Any = "", **kwargs: Any):
    if tool_name in _OWN_TOOLS:
        return None
    try:
        _wallet(kwargs).note_content(result if isinstance(result, str) else json.dumps(result, default=str))
    except Exception:
        pass
    return None


def tool_pay(args: dict, **kwargs: Any) -> str:
    if "SELLAR_OWNER" not in os.environ and _cid(kwargs) not in _WALLETS:
        return json.dumps({"status": "refused", "message": "Sellar is not set up: SELLAR_OWNER and SELLAR_AGENT_KEY "
                                                           "are missing. Nothing was paid."})
    r = _wallet(kwargs).pay(str(args.get("to", "")), float(args.get("amount") or 0), str(args.get("memo", "")))
    return json.dumps({"status": r.status, "message": r.message, "hold_id": r.hold_id, "transaction": r.url})


def tool_status(args: dict, **kwargs: Any) -> str:
    c = _wallet(kwargs).client
    out = {"balance_musd": c.balance(), "loan": c.loan_health()}
    if args.get("address"):
        out["scam_list"] = c.flag_info(str(args["address"]))
    return json.dumps(out)


def register(ctx) -> None:
    ctx.register_hook("pre_llm_call", _on_pre_llm_call)
    ctx.register_hook("post_tool_call", _on_post_tool_call)
    ctx.register_tool(name="sellar_pay", toolset="sellar", schema=PAY_SCHEMA, handler=tool_pay)
    ctx.register_tool(name="sellar_status", toolset="sellar", schema=STATUS_SCHEMA, handler=tool_status)
