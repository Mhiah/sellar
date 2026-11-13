# Security review

An internal review of Sellar's contracts, guard, website and build pipeline, run on 13 November 2026
against the version 2 contracts on Mezo testnet. It is **not an external audit**. It was done by the
team, with tests written to attack the product, and it lists what is still open as plainly as what
passed.

**Result: fit for testnet and for judging. Not ready for mainnet or real money.** No path was found
that lets anyone move an owner's MUSD out of the safe without that owner's rules or signature. One
high-severity weakness is open in the cover fund's refund design (F-01).

## What was checked

| Area | How | Result |
|---|---|---|
| Who can move money out of the safe | Hostile-caller tests against every function | Only the owner (withdraw, release) or the agent inside the owner's rules |
| Accounts mixing | Fuzz test and an invariant: the safe always holds exactly the sum of all balances | Holds |
| Holds | Paid once; never after reject or expiry; never while frozen | Holds |
| Cover fund and scam list permissions | Only the safe records payments; only the reviewer resolves; the safe link is set once | Holds |
| Re-entry while being paid BTC | Attack contracts on the reward and the BTC sale | Refused |
| Bonds | Never deposited in the Stability Pool; cannot be withdrawn twice (invariant and test) | Holds |
| Static analysis | Slither, 76 detectors | 15 results, all reviewed, none exploitable |
| Guard | Hostile inputs: repeats, split or hidden addresses, text pretending to be the user, bad amounts | Two gaps found and fixed (G-01, G-02) |
| Website | No HTML is built from data; no third-party scripts; no secrets in the browser | Clean; security headers added (W-01) |
| Secrets | Full git history scanned for keys, tokens and env files | None found |
| Dependencies | pip-audit on the guard; OpenZeppelin 5.1.0 vendored | No known vulnerabilities |

## Findings

| ID | Severity | Where | What is wrong | Status |
|---|---|---|---|---|
| F-01 | High | `SellarShield.claim` | **Fake victims can drain the cover fund.** Someone pays an address they control from several safes, lets it be reported and correctly confirmed as a scam, then claims refunds as their own victims. In the test, 10 claims took 4,188 of a 5,000 MUSD fund for 12.5 MUSD in fees. Caps are per payment, not per case or per person. | Open. Needs a contract change: review each claim, or cap payouts per case. Reproduced in `test_Finding_F01` |
| F-02 | Medium | `SellarShield.report` / `withdrawBond` | **A flag is free if the reviewer never acts.** The reporter gets the bond back after 30 days, having held up agent payments to that address, and can repeat it. Owners can still release by hand. | Open. Depends on an active reviewer |
| F-03 | Medium | `SellarShield.confirm` | **No appeal.** A confirmed address is blocked in every safe for good, even for an owner's own release. One reviewer key decides. The owner's money is never trapped: withdrawal always works. | Open. Planned: bonded jurors |
| F-04 | Low | `SellarShield.confirm` | The BTC reward is split equally, so late or sock-puppet reporters dilute the first reporter. | Open |
| F-05 | Low | `SellarSafe` daily limit | Resets at midnight UTC, so two days' allowance can be spent seconds apart. | Open. Documented |
| F-06 | Low | `SellarShield.buyBtc` | The sale price comes only from Mezo's price feed, with no second source or bound. | Open. Accepted: trusts Mezo's oracle |
| F-07 | Info | `SellarSafe._pay` | Payments under 400 wei of MUSD pay no fee (rounding). Not economic to abuse. | Accepted |
| F-08 | Info | `SellarFaucet` | One drip per address, so many addresses can empty it. Test MUSD only. | Accepted |
| G-01 | Medium | Guard | **Repeat payments passed.** "Pay Ade 5 MUSD" let an agent pay 5 again and again, up to the on-chain daily limit. | **Fixed.** The guard now counts what has been paid against what was asked, and asks for a human past it |
| G-02 | Low | Hermes adapter | If a hook failed to record what the agent read, the failure was silent and the guard lost track of where addresses came from. | **Fixed.** Every payment in that conversation now goes to the owner |
| G-03 | Low | Guard | If the user names no amount, there is nothing to compare, so only the on-chain limits bound the payment. Two amounts in one message are not tied to their payees. | Open. Documented |
| G-04 | Medium | Agent setup | The guard runs inside the agent. An agent whose machine is taken over can skip it and use the agent key directly. The safe's on-chain rules still apply: trusted payees and limits only. | By design. Keep the agent key away from the agent's other tools |
| W-01 | Low | Website hosting | No Content-Security-Policy or framing protection was set. | **Fixed.** `web/vercel.json` |
| W-02 | Medium | Website trust | The dashboard shows what its host and Mezo's public node tell it. If either were compromised, an owner could be shown one payee and release another. | Open. Standard for web wallets; verify on the explorer before large releases |
| C-01 | Low | GitHub Actions | A workflow input was pasted into a shell script, and workflow tokens had default permissions. | **Fixed.** Inputs go through the environment and are checked; tokens are read-only |
| C-02 | Info | Keys | The reviewer and every test wallet derive from one deploy key held as a GitHub secret. Fine for testnet; must be separate keys before mainnet. | Open for mainnet |

## What was not verified

- The guard inside a live Hermes agent. It is tested against a stand-in for Hermes.
- Mezo's own contracts and price feed. Sellar trusts them.
- Behaviour under real liquidations in the Stability Pool. Tested with a stand-in pool and a fork.
- Wallet-signing flows on the live site by an automated wallet. They were run by hand on two test accounts.

## Before mainnet

1. Fix F-01 and redeploy.
2. Replace the single reviewer (F-02, F-03).
3. Separate keys for deployer, reviewer and operations (C-02).
4. An independent external audit.
5. A cap on what each safe can hold while the product is young.

The tests behind this review are in [`contracts/test/Audit.t.sol`](../contracts/test/Audit.t.sol) and
the last section of [`guard/tests/test_guard.py`](../guard/tests/test_guard.py). They run on every push.
