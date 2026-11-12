# Live run on Mezo testnet (chain 31611), version 2 contracts

Run id `43085407924`. SellarSafe `0x9e0Fe4b54f80A62527A7a2A19DEDd3c97e66FD3A`, SellarShield `0x245C2cA317F640b8976e2584d68Eed59Fc698701`.

Every wallet below is a team test wallet. This run shows the mechanics work on Mezo's real
contracts. It is not outside usage.

| Role | Address |
|---|---|
| Ada (owner, has a Mezo loan) | `0xE6d044BEB44390CCe70C436CAe2BD2AEE602077E` |
| Ada's agent key | `0x0e6e511eD72B90E919fd7f3484eBEbA956F80813` |
| Vendor (trusted payee) | `0x7B9f48DcdCCa0872660744348E41FF66ffaa68Bc` |
| Scammer | `0xC61fa4DD134d4C791F8687FB86d3912aFb17A7f9` |
| Ben (reporter) | `0x1Cb68e283690A6aF88A3a97229B1C44900B8998e` |
| Chidi (victim) | `0xb38072B093161594C75e09cd58eC242c1D27ED0c` |
| Chidi's agent key | `0xA925EaeFB670Cb46eC30B4ACE5568D77Be411010` |
| Reviewer | `0xD2aeaD8fd23002167bCe69A1E9ac6A6ca879922D` |

| # | Step | Result | Transaction |
|---|---|---|---|
| | _Ada's loan collateral ratio read from TroveManager_ | 1.667732184673935571 (1.0 = 100%) | |
| 1 | Ada moves her MUSD out of the version 1 safe | 37.845000000000000000 MUSD back in her wallet | [`0x5271dedb…`](https://explorer.test.mezo.org/tx/0x5271dedb8d51f8a0142a9be455ab73f5f2f8d380a06f02f988eeaa48a193382c) |
| 2 | Send test BTC for gas to Chidi | 0.00002 BTC | [`0xb851e465…`](https://explorer.test.mezo.org/tx/0xb851e465771c2a47d776bce967aefc8dab25ed8284f6343c95360508040ed4f6) |
| 3 | Deployer hands the reviewer role to a separate wallet (step 1 of 2) | Proposed | [`0x8a9a4325…`](https://explorer.test.mezo.org/tx/0x8a9a4325d754f82a20a5dc894c845b04731a0b2ff593f3db4563b8d8d974bc15) |
| 4 | New reviewer accepts (step 2 of 2) | Reviewer changed | [`0xab2d7e66…`](https://explorer.test.mezo.org/tx/0xab2d7e661498f3e6ee53dc0f26b03fae91aa20b00b6349f95d81ffb599b45e82) |
| 5 | Ada approves SellarSafe to take MUSD | Approved | [`0x5eb72081…`](https://explorer.test.mezo.org/tx/0x5eb7208191efc47bae1dde640c268ac49a0fb91386453702c73f26d95927028f) |
| 6 | Ada deposits 100 MUSD into her safe account | Balance 100 MUSD | [`0x0b4f794c…`](https://explorer.test.mezo.org/tx/0x0b4f794ce557b96df4f0633ace603cdc39a0a5d3cc03027617145dcb2b1693a9) |
| 7 | Ada sets her rules: agent key, 50 MUSD per payment, 150 per day, loan floor 150% | Configured | [`0x88af2d82…`](https://explorer.test.mezo.org/tx/0x88af2d82fd22d7029f8228ee51004067be367aa18aea6fbdb786f4217cc32d98) |
| 8 | Ada trusts her vendor | Trusted | [`0x58dcd877…`](https://explorer.test.mezo.org/tx/0x58dcd8772d686ea1eff912630ac6fb01aca26ac07fe2371dad177b2725754269) |
| 9 | Agent asks to pay the vendor 20 MUSD | **Paid at once** (trusted, within limits, loan healthy) | [`0x0b936225…`](https://explorer.test.mezo.org/tx/0x0b936225c8b24df72789f65d1dca112f83ef7ed260a715d46536d46225aef3dd) |
| | _Vendor's MUSD balance_ | 82.000000000000000000 MUSD | |
| 10 | Agent, fooled by a fake invoice email, asks to pay the scammer 20 MUSD | **Held**. Nothing left the safe | [`0xc50de4a3…`](https://explorer.test.mezo.org/tx/0xc50de4a37fcb1db3821e0cd6fe8a86514030d030ca7c748b5270c39aecd55028) |
| | _Hold 0 reasons_ | 1 (1 = payee is not on Ada's trusted list) | |
| | _Scammer's MUSD balance_ | 0.000000000000000000 MUSD | |
| 11 | Ada rejects hold 0 | Rejected | [`0x4a1d4b80…`](https://explorer.test.mezo.org/tx/0x4a1d4b80fc2fde3c2d8081a113d92ea17fac2303991c803242ea511b36d99635) |
| 12 | Team seeds the cover fund with 250 MUSD (a plain transfer, disclosed) | Fund seeded | [`0x262104f6…`](https://explorer.test.mezo.org/tx/0x262104f63142475613ff15d60afaebfdc4a1e573cd9e4a2c1759d628cb22b6a1) |
| 13 | Anyone calls rebalance: 25% stays liquid, the rest goes into Mezo's Stability Pool (provideToSP) | Deposited | [`0xe530ed14…`](https://explorer.test.mezo.org/tx/0xe530ed14fdd8f445ca60db2dee1bde3595f7e3c2064d5848416fb60774c61108) |
| | _Cover fund in the Stability Pool (StabilityPool.getCompoundedMUSDDeposit)_ | 187.537500000000000000 MUSD | |
| | _Cover fund liquid_ | 62.512500000000000000 MUSD | |
| 14 | Ada sends Chidi 60 MUSD so he has funds (setup) | Sent | [`0x642ce782…`](https://explorer.test.mezo.org/tx/0x642ce7822a3d7398d29e2d922b118c6b7426a011b8230bd44732677644200f17) |
| 15 | Chidi approves SellarSafe | Approved | [`0x71e55bd2…`](https://explorer.test.mezo.org/tx/0x71e55bd27db588e376291e8d42ceb784b90afe9a9bbbb89f35d09d85c8187d6b) |
| 16 | Chidi deposits 60 MUSD | Balance 60 MUSD | [`0x92af1524…`](https://explorer.test.mezo.org/tx/0x92af152469b026a038c535808c0d2b8013c2d98733211368485947332415cb05) |
| 17 | Chidi sets his rules | Configured | [`0x42465745…`](https://explorer.test.mezo.org/tx/0x42465745cc7ffe3311c80d92a054f4809dd8b14c0c1016a89369155190311542) |
| 18 | Chidi believes the fake invoice and trusts the scammer's address | Trusted | [`0x73226b86…`](https://explorer.test.mezo.org/tx/0x73226b86df140bf028e75e42bb8f906cfaa8465d6a26a5c8aa8b4caca1dc874d) |
| 19 | Chidi's agent pays the scammer 40 MUSD | Paid. Receipt 1 recorded in SellarShield | [`0x36e1827a…`](https://explorer.test.mezo.org/tx/0x36e1827ae17776c71d563a7cc7291a392158ffebe42a6e7a30a910efadf01758) |
| 20 | Ada sends Ben 10 MUSD for his bond (setup) | Sent | [`0x49708a59…`](https://explorer.test.mezo.org/tx/0x49708a59c25d5afedbeaf95248939714caf2434a75f66e9e3a490e1666ce40a6) |
| 21 | Ben approves SellarShield | Approved | [`0xb909726e…`](https://explorer.test.mezo.org/tx/0xb909726ed97fb83b5024f74136ddfdb88188fcff90e9c30a4284dd8553eb08e2) |
| 22 | Ben reports the scammer and locks a 10 MUSD bond | **Flagged** for every safe | [`0x27cf0bc3…`](https://explorer.test.mezo.org/tx/0x27cf0bc37d22bdbffc89090d55fc5126a9fecb44f3c70f8f31d616ce31fdbf70) |
| 23 | Chidi's agent tries to pay the scammer again, 10 MUSD | **Held**, although Chidi trusted the address | [`0xc6724b42…`](https://explorer.test.mezo.org/tx/0xc6724b42f7727fdf2ae35b9830e10f39ca6cee4ca4398d7ca1b9c9b24c515b23) |
| | _Hold 1 reasons_ | 16 (16 = payee is flagged on the scam list) | |
| 24 | Chidi rejects hold 1 | Rejected | [`0x7590ff31…`](https://explorer.test.mezo.org/tx/0x7590ff31abb711221f4af4c96f0cce4cc11d98b113a8f198d789d6aa3745a254) |
| 25 | Reviewer confirms the scam | Confirmed | [`0x197fbec5…`](https://explorer.test.mezo.org/tx/0x197fbec591cb1b4d8612f36c9b66a4252dce80de9851e317c3cd4a9317778c6e) |
| 26 | Chidi claims on receipt 1 | **Refunded** from the cover fund | [`0xbc9b774b…`](https://explorer.test.mezo.org/tx/0xbc9b774b555fe49dde771d0c63e88c848c14c961ff733456ce952828d3520f46) |
| | _Refund received by Chidi_ | 40.000000000000000000 MUSD | |
| 27 | Ben takes his bond back | 10 MUSD returned | [`0xd6c612d7…`](https://explorer.test.mezo.org/tx/0xd6c612d78abd7e7b3738313e10867ba0559c82f7d3fe72adfdee9fda7c3531b7) |
| 28 | Ada raises her loan floor to 300%, above her loan's current ratio | Configured | [`0x243ad47d…`](https://explorer.test.mezo.org/tx/0x243ad47dfe229152ec381634f04b22c4f399806f04dd1fbb01be294b0024c117) |
| 29 | Agent asks to pay the trusted vendor 10 MUSD | **Held**: paying now would be spending while the loan is below Ada's floor | [`0x2b120635…`](https://explorer.test.mezo.org/tx/0x2b12063523c1aebe22da8847a9f748851e5f49a23b62d1e73da68c5a807a04b8) |
| | _Hold 2 reasons_ | 64 (64 = Mezo loan below the owner's floor, read live from TroveManager and PriceFeed) | |
| 30 | Ada approves hold 2 herself | Paid on her approval | [`0x1657b15b…`](https://explorer.test.mezo.org/tx/0x1657b15bd3ffd03fe0119eb7473a456efea4fcd84fc0a7c3d730072a8651f611) |
| 31 | Ada sets the floor back to 150% | Configured | [`0xb02685b8…`](https://explorer.test.mezo.org/tx/0xb02685b865528196998a82adafe839499dcdd797546cdffff92f8dc9d55bc363) |
| 32 | Team sends the fund 0.0005 BTC, standing in for a Stability Pool gain (no liquidation has paid the fund on testnet yet) | Fund holds 0.0005 BTC for sale | [`0x66fdf2d4…`](https://explorer.test.mezo.org/tx/0x66fdf2d4182ca4b3598854f7e9124bb3755853ae8e8b79d1f63876e2376d3dda) |
| | _Price read from Mezo's PriceFeed_ | 74187.181170000000000000 MUSD per BTC. Cost of 0.0005 BTC after the 1% discount: 36.722654679150000000 MUSD | |
| 33 | A buyer approves SellarShield to take the MUSD | Approved | [`0xa51c0132…`](https://explorer.test.mezo.org/tx/0xa51c0132ae448ffc3bff19877516d73f0ef47701d84c84486f664f04e4bd45d3) |
| 34 | The buyer buys the fund's BTC with MUSD (buyBtc) | **BTC sold.** The MUSD went into the cover fund | [`0x75f5fa91…`](https://explorer.test.mezo.org/tx/0x75f5fa91784984980910560339aadeec5c7aed2eb5ba8b485b8f00b443e0a19f) |
| | _Cover fund MUSD ready for refunds_ | from 22.637500000000000000 to 59.346816597250000000 MUSD | |
| | _BTC left for sale_ | 0.000000000000000000 BTC | |
| | _Ada's holds (holdCountOf)_ | 2 | |
| | _Ada's receipts (receiptCountOf)_ | 2 | |
| | _Ada's spending counted toward her agent's daily limit (spentToday)_ | 20.000000000000000000 MUSD. The 10 MUSD she released herself is not counted | |
| | _Cover fund total (fundAssets)_ | 246.884316597250000000 MUSD | |
| | _Reporter bonds held_ | 0.000000000000000000 MUSD | |
| | _Scam list status of the scammer_ | 2 (2 = confirmed) | |

The price moved between the quote and the purchase, so the fund received 36.71 MUSD for the BTC, a little under the 36.72 quoted. The buyer's limit was 1% above the quote.

---

## Guard run: 4eyes screening in front of SellarSafe

Run id `43086361203`, on the version 2 safe. Owner `0xE6d044BEB44390CCe70C436CAe2BD2AEE602077E`, vendor "Ade" `0x7B9f48DcdCCa0872660744348E41FF66ffaa68Bc`, scammer `0x80f3609C9216080337255FF31f453EA96f28C181`. Team test wallets.

Safe balance before: 69.925 MUSD. Owner's Mezo loan ratio: 166.7%.

| Scenario | User typed | Agent tried | Guard | SellarSafe on-chain | Transaction |
|---|---|---|---|---|---|
| The user names a saved payee and an amount | "pay Ade 5 MUSD for the logo" | 5 MUSD to `0x7B9f48…` | No objection | **Paid** | [`0x27b5f042…`](https://explorer.test.mezo.org/tx/0x27b5f042aedb74532aa2cd307834f644ec551b23ff25fd2ec2064d61f92420cc) |
| A poisoned invoice: the address exists only in an email the agent read | "pay the invoice in my latest email" | 5 MUSD to `0x80f360…` | Asked for a human: 0x80f3…c181 came from content Hermes read (an email, web page, file or tool result), not from you. Confirm it with the payee another way. | **Held** (hold 3): the payee is not on the owner's trusted list; the guard asked for a human | [`0xfeab8a51…`](https://explorer.test.mezo.org/tx/0xfeab8a518622c71b20c081424c072579643644eb81f7e4d9325a664ff4cc374c) |
| The agent tries to send more than the user asked, to a payee the safe trusts | "pay Ade 5 MUSD" | 12 MUSD to `0x7B9f48…` | Asked for a human: You asked for 5 MUSD, this sends 12. | **Held** (hold 4): the guard asked for a human | [`0xb47fd325…`](https://explorer.test.mezo.org/tx/0xb47fd3257b2d1a1bfa3fe1032134cda0056d4aaf0cd4a0aa273642cb12c15fe6) |

Safe balance after: 64.9125 MUSD. Holds 3 and 4 were left waiting for the owner to decide on the dashboard.

In the third row the on-chain rules alone would have paid: the vendor is trusted and 12 MUSD is within the limits. The payment was held only because the guard saw that the user had asked for 5.

---

## The owner decides on the dashboard

Sent from the website (now at [sellar.myacxt.site](https://sellar.myacxt.site/), then at mhiah.github.io/sellar), by the owner's own wallet (a team test wallet, `0xE6d044BEB44390CCe70C436CAe2BD2AEE602077E`), on the two holds the guard run left waiting.

| # | Step | Result | Transaction |
|---|---|---|---|
| 1 | Owner clicks **Release** on hold 4 ("This is more than you asked for.") | 12 MUSD paid to Ade. Safe balance 64.91 to 52.88 MUSD (12 plus the 0.03 MUSD cover fee) | [`0x9ed29a9e…`](https://explorer.test.mezo.org/tx/0x9ed29a9ecf56526bf2c73ebc3c4ab607be98f964c96933da4169bac3a27baa29) |
| 2 | Owner clicks **Reject** on hold 3 ("This address came from something your agent read, not from you.") | Rejected. Nothing left the safe | [`0xa20f92be…`](https://explorer.test.mezo.org/tx/0xa20f92be37e75dfd02862ca913d21c4ce997de464454a2d8759dcafb9e452c07) |

---

The first live run, the first guard runs and the first release and reject sent from the dashboard were on the version 1 contracts. They are kept in [EVIDENCE-v1.md](EVIDENCE-v1.md).
