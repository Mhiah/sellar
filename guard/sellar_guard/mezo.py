"""A small client for SellarSafe and SellarShield on Mezo. JSON-RPC over urllib; signing with eth-account."""
from __future__ import annotations

import json
import urllib.request
from dataclasses import dataclass
from typing import Any, Optional

from eth_utils import keccak, to_checksum_address


@dataclass(frozen=True)
class Network:
    name: str
    chain_id: int
    rpc: str
    explorer: str
    musd: str
    safe: str
    shield: str


MEZO_TESTNET = Network(
    name="Mezo testnet",
    chain_id=31611,
    rpc="https://rpc.test.mezo.org",
    explorer="https://explorer.test.mezo.org",
    musd="0x118917a40FAF1CD7a13dB0Ef56C86De7973Ac503",
    safe="0x9bf0180a21fFfB35b815Bf0B264706E72e0a26Aa",
    shield="0x799d90D2FA41b9827c345E480BEC635B3EF0c444",
)

# Reasons SellarSafe gives for holding a request (bit flags, same values as the contract).
REASONS = {
    1: "the payee is not on the owner's trusted list",
    2: "the payee was trusted too recently (cooldown)",
    4: "over the per-payment limit",
    8: "over the daily limit",
    16: "the payee is flagged on the Sellar scam list",
    32: "the payee is a confirmed scam",
    64: "the owner's Mezo loan is below their floor",
    128: "the guard asked for a human",
}
STATUS = {0: "none", 1: "flagged", 2: "confirmed", 3: "dismissed"}

TOPIC_HELD = "0x" + keccak(text="Held(uint256,address,address,uint256,uint32,bytes32)").hex()
TOPIC_PAID = "0x" + keccak(text="Paid(address,address,uint256,uint256,uint256)").hex()


def selector(signature: str) -> str:
    return "0x" + keccak(text=signature)[:4].hex()


def _word(v: Any) -> str:
    """ABI-encode one static value (address, uint, bool or bytes32) as a 32-byte word."""
    if isinstance(v, bool):
        return f"{int(v):064x}"
    if isinstance(v, int):
        if v < 0:
            raise ValueError("negative values are not supported")
        return f"{v:064x}"
    if isinstance(v, bytes):
        if len(v) != 32:
            raise ValueError("bytes32 expected")
        return v.hex()
    if isinstance(v, str) and v.startswith("0x"):
        h = v[2:]
        if len(h) == 40:
            return h.lower().rjust(64, "0")
        if len(h) == 64:
            return h.lower()
    raise ValueError(f"cannot encode {v!r}")


def encode(signature: str, *args: Any) -> str:
    return selector(signature) + "".join(_word(a) for a in args)


def to_units(amount: float | str) -> int:
    """MUSD has 18 decimals. Parsed as a decimal string so 0.1 is exact."""
    from decimal import Decimal
    return int(Decimal(str(amount)) * 10 ** 18)


def describe(reasons: int) -> list[str]:
    return [text for bit, text in REASONS.items() if reasons & bit]


class Rpc:
    def __init__(self, url: str, timeout: float = 30):
        self.url, self.timeout, self._id = url, timeout, 0

    def __call__(self, method: str, params: list) -> Any:
        self._id += 1
        body = json.dumps({"jsonrpc": "2.0", "id": self._id, "method": method, "params": params}).encode()
        req = urllib.request.Request(self.url, data=body, headers={"content-type": "application/json"})
        with urllib.request.urlopen(req, timeout=self.timeout) as resp:
            out = json.load(resp)
        if out.get("error"):
            raise RuntimeError(f"{method}: {out['error'].get('message', out['error'])}")
        return out["result"]


class SellarClient:
    """Reads the safe and the scam list, and sends payment requests signed with the agent key.

    The agent key can only *ask*: SellarSafe gives it no way to approve, withdraw or change rules."""

    def __init__(self, owner: str, agent_key: Optional[str] = None, net: Network = MEZO_TESTNET, rpc: Any = None):
        self.net = net
        self.owner = to_checksum_address(owner)
        self.rpc = rpc or Rpc(net.rpc)
        self._key = agent_key

    # --- reads ---------------------------------------------------------------------------------------
    def _call(self, to: str, data: str) -> str:
        return self.rpc("eth_call", [{"to": to, "data": data}, "latest"])

    def check(self, to: str, amount_units: int) -> int:
        """Dry run on-chain: the reasons SellarSafe would hold this payment. 0 = it would pay at once."""
        out = self._call(self.net.safe, encode("check(address,address,uint256)", self.owner, to, amount_units))
        return int(out, 16)

    def flag_info(self, who: str) -> dict:
        out = self._call(self.net.shield, encode("flagInfo(address)", who))[2:]
        status, reporters, bonded = (int(out[i:i + 64], 16) for i in (0, 64, 128))
        return {"status": STATUS.get(status, str(status)), "reporters": reporters, "bonded_musd": bonded / 1e18}

    def loan_health(self) -> dict:
        out = self._call(self.net.safe, encode("loanHealth(address)", self.owner))[2:]
        return {"has_loan": bool(int(out[:64], 16)), "ratio": int(out[64:128], 16) / 1e18}

    def balance(self) -> float:
        # accounts(owner) -> (agent, frozen, cooldown, day, perPayment, perDay, spentToday, balance, minIcr)
        out = self._call(self.net.safe, encode("accounts(address)", self.owner))[2:]
        return int(out[7 * 64:8 * 64], 16) / 1e18

    # --- the one write -------------------------------------------------------------------------------
    def request(self, to: str, amount_units: int, memo: bytes = b"\0" * 32, escalate: bool = False) -> dict:
        """Ask SellarSafe to pay. Returns what happened on-chain: paid, or held with a hold id and reasons."""
        if not self._key:
            raise RuntimeError("no agent key configured")
        from eth_account import Account
        acct = Account.from_key(self._key)
        data = encode("request(address,address,uint128,bytes32,bool)", self.owner, to, amount_units, memo, escalate)
        tx = {"from": acct.address, "to": self.net.safe, "data": data}
        gas = int(self.rpc("eth_estimateGas", [tx]), 16)
        signed = acct.sign_transaction({
            "to": self.net.safe, "data": data, "value": 0, "chainId": self.net.chain_id,
            "nonce": int(self.rpc("eth_getTransactionCount", [acct.address, "pending"]), 16),
            "gas": gas * 13 // 10, "gasPrice": max(int(self.rpc("eth_gasPrice", []), 16) * 2, 1),
        })
        raw = getattr(signed, "raw_transaction", None) or signed.rawTransaction
        tx_hash = self.rpc("eth_sendRawTransaction", ["0x" + bytes(raw).hex()])
        return self._outcome(tx_hash, self._wait(tx_hash))

    def _wait(self, tx_hash: str, tries: int = 60) -> dict:
        import time
        for _ in range(tries):
            receipt = self.rpc("eth_getTransactionReceipt", [tx_hash])
            if receipt:
                return receipt
            time.sleep(2)
        raise TimeoutError(f"no receipt for {tx_hash}")

    def _outcome(self, tx_hash: str, receipt: dict) -> dict:
        out = {"tx": tx_hash, "url": f"{self.net.explorer}/tx/{tx_hash}", "paid": False, "hold_id": None,
               "reasons": 0, "reverted": int(receipt.get("status", "0x1"), 16) != 1}
        for log in receipt.get("logs", []):
            if log["address"].lower() != self.net.safe.lower() or not log["topics"]:
                continue
            data = log["data"][2:]
            if log["topics"][0] == TOPIC_PAID:
                out["paid"] = True
            elif log["topics"][0] == TOPIC_HELD:
                out["hold_id"] = int(log["topics"][1], 16)
                out["reasons"] = int(data[64:128], 16)
        return out
