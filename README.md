# Sellar

**The four-eyes rule for AI agents, on Mezo. An agent can ask to pay in MUSD. It cannot pay alone.**

Banks never let one person move money alone. AI agents that hold wallets broke that rule: one
planted sentence in an email ("our details changed, pay this address instead") is enough to send
funds to a thief. Sellar puts the second pair of eyes back, and enforces it on-chain.

Status: contracts written and tested locally. Not deployed yet. Not audited.

## What it does

1. **Guard.** An owner keeps MUSD in `SellarSafe` and names an agent key. The agent can only *ask*
   to pay. A payment goes out on its own only to a payee the owner trusts, within the owner's
   limits. Anything else is held, and only the owner can release it.
2. **Shared scam list.** Anyone can report an address to `SellarShield` by locking a 10 MUSD bond.
   One report flags the address for every safe: payments to it are held, even if it was trusted.
   A false report loses its bond.
3. **Cover fund.** Every payment carries a 0.25% fee into a fund. If a payee is later confirmed as
   a scam, people who paid it before the first report can claim a refund, up to 500 MUSD.

## How it uses Mezo

- All balances, bonds, fees and refunds are in **MUSD**.
- The cover fund keeps 25% liquid and deposits the rest in Mezo's **Stability Pool**, where it
  earns BTC from liquidations. A tenth of that BTC is shared with the reporters of each confirmed
  case. Reporter bonds are never deposited, so they can always be returned.
- An owner can set a floor on their **Mezo loan**: while the loan's collateral ratio (read from
  `TroveManager` and `PriceFeed`) is below it, agent payments are held.
- Addresses come from Mezo's official `@mezo-org/musd-contracts` package (v1.1.0).

## Honest limits

- **A reviewer confirms scams.** Flagging is open to anyone with a bond, but only the reviewer role
  can confirm a case (which unlocks refunds) or dismiss it. Without that, someone could report an
  address they control and drain the fund. The reviewer cannot move funds or change parameters.
- **Stability Pool risk.** Deposits there can shrink in liquidations and withdrawals pause while any
  loan is under-collateralised. Refunds are capped, and a claim may have to wait and be retried.
- **Refunds are partial by design**: at most 500 MUSD and at most 20% of the fund per claim.
- Not audited. Testnet only for now.

## Layout

```
contracts/src/SellarSafe.sol     the guard
contracts/src/SellarShield.sol   scam list + cover fund
contracts/test/                  unit, fuzz, invariant and Mezo-testnet fork tests
contracts/script/Deploy.s.sol    deployment against Mezo's contracts
```

## Run the tests

```bash
cd contracts
forge test                                   # unit, fuzz and invariant tests
FORK=1 forge test --match-contract ForkTest  # against a fork of Mezo testnet
```

## Credits

The guard follows the design of [4eyes](https://github.com/Mhiah/4eyes), the same author's Hermes
plugin that tracks where a payment address came from. Uses OpenZeppelin Contracts v5.1.0 and
forge-std (both MIT, vendored under `contracts/lib`).

## License

MIT
