# Live run on Mezo testnet (chain 31611)

Run id `42972321804`. SellarSafe `0x9bf0180a21fFfB35b815Bf0B264706E72e0a26Aa`, SellarShield `0x799d90D2FA41b9827c345E480BEC635B3EF0c444`.

Every wallet below is a team test wallet. This run shows the mechanics work on Mezo's real
contracts. It is not outside usage.

| Role | Address |
|---|---|
| Ada (owner, has a Mezo loan) | `0xE6d044BEB44390CCe70C436CAe2BD2AEE602077E` |
| Ada's agent key | `0x0e6e511eD72B90E919fd7f3484eBEbA956F80813` |
| Vendor (trusted payee) | `0x7B9f48DcdCCa0872660744348E41FF66ffaa68Bc` |
| Scammer | `0xF544b7D3158E9ed4Df0aa5eC9a5f7B4cE25E2323` |
| Ben (reporter) | `0x1Cb68e283690A6aF88A3a97229B1C44900B8998e` |
| Chidi (victim) | `0x1C1550F6e3692fa7334De3d6b56e9B236d649A1A` |
| Chidi's agent key | `0xA925EaeFB670Cb46eC30B4ACE5568D77Be411010` |
| Reviewer | `0xD2aeaD8fd23002167bCe69A1E9ac6A6ca879922D` |

| # | Step | Result | Transaction |
|---|---|---|---|
| 1 | Ada opens a Mezo loan: 0.045 BTC locked, 1,800 MUSD borrowed (BorrowerOperations.openTrove) | Loan open | [`0xba48bbd0…`](https://explorer.test.mezo.org/tx/0xba48bbd0fbfbf9050178f6bdfdc7e8ba045000aebef0c7b0323aabdf288eeaf6) |
| | _Ada's loan collateral ratio read from TroveManager_ | 1.657309087945848736 (1.0 = 100%) | |
| 2 | Send test BTC for gas to agent | 0.00002 BTC | [`0x864f2feb…`](https://explorer.test.mezo.org/tx/0x864f2febe67db3c3b31dbd6cbeedbe3c1bad5c73e0e0c898d69f0ba39a49eac6) |
| 3 | Send test BTC for gas to reviewer | 0.00002 BTC | [`0x33d84c05…`](https://explorer.test.mezo.org/tx/0x33d84c05d09213a9c726d9692299ddc8d6683861b9861d0f46f7239b0ea886cf) |
| 4 | Send test BTC for gas to Ben | 0.00002 BTC | [`0xb2ae16be…`](https://explorer.test.mezo.org/tx/0xb2ae16be1a9cbe6f5e9644b024461d2dea40dee3071bc2ae4a7ee79dc17f7883) |
| 5 | Send test BTC for gas to Chidi | 0.00002 BTC | [`0xc0247afd…`](https://explorer.test.mezo.org/tx/0xc0247afd2967c0aa825a5e9c36fd399a375d7ed60d0d5c3eb6d701e12a7f3291) |
| 6 | Send test BTC for gas to Chidi's agent | 0.00002 BTC | [`0x4d685a1f…`](https://explorer.test.mezo.org/tx/0x4d685a1f90f27758e4613df1ec6da5a8cf386608a47ec058b602a343a3659c37) |
| 7 | Deployer hands the reviewer role to a separate wallet (step 1 of 2) | Proposed | [`0xb300ed3b…`](https://explorer.test.mezo.org/tx/0xb300ed3b2a46cf4198d3f9970f914b691b0bfbadf0954080ec70bc2897279dc8) |
| 8 | New reviewer accepts (step 2 of 2) | Reviewer changed | [`0xbe989a34…`](https://explorer.test.mezo.org/tx/0xbe989a34e0b1a468355187414f96c265c088797d5b7ed0d3d73f18b8c990ebf6) |
| 9 | Ada approves SellarSafe to take MUSD | Approved | [`0xee7defb0…`](https://explorer.test.mezo.org/tx/0xee7defb09372ac9f665bc09110392279337907aaa6f6ee37a9eb8ef3dd327b30) |
| 10 | Ada deposits 100 MUSD into her safe account | Balance 100 MUSD | [`0xd7ed9359…`](https://explorer.test.mezo.org/tx/0xd7ed93591a028e15d7a4b07a22f94a3d65cd86685594ebfe448b3afc617ab79a) |
| 11 | Ada sets her rules: agent key, 50 MUSD per payment, 150 per day, loan floor 150% | Configured | [`0xeab4759d…`](https://explorer.test.mezo.org/tx/0xeab4759d81828be872298204ce3935b7abc44d75e2016abc411d7ef7663f5d36) |
| 12 | Ada trusts her vendor | Trusted | [`0x40296fca…`](https://explorer.test.mezo.org/tx/0x40296fca85600bef4d133a97292c101e3cfa96875754a4506099491a70f180e7) |
| 13 | Agent asks to pay the vendor 20 MUSD | **Paid at once** (trusted, within limits, loan healthy) | [`0x641c6eb2…`](https://explorer.test.mezo.org/tx/0x641c6eb2991d73737515be29c5ecf45c8ad278881da2c343cc3f8db9efa76460) |
| | _Vendor's MUSD balance_ | 20.000000000000000000 MUSD | |
| 14 | Agent, fooled by a fake invoice email, asks to pay the scammer 20 MUSD | **Held**. Nothing left the safe | [`0xc5717c8c…`](https://explorer.test.mezo.org/tx/0xc5717c8cf718b315d5968ab5e771f10b575710b713d6e699f5b4ca8890d51590) |
| | _Hold 0 reasons_ | 1 (1 = payee is not on Ada's trusted list) | |
| | _Scammer's MUSD balance_ | 0.000000000000000000 MUSD | |
| 15 | Ada rejects hold 0 | Rejected | [`0x84b3b89d…`](https://explorer.test.mezo.org/tx/0x84b3b89d505cefeb42394ff9b1ca7a79e76abf8bb6c1f175ca1ee2484303d7fa) |
| 16 | Team seeds the cover fund with 250 MUSD (a plain transfer, disclosed) | Fund seeded | [`0x4ac0a655…`](https://explorer.test.mezo.org/tx/0x4ac0a655fc2ee48f6a3d4125b448ef389e960bf89d592e94e4681b99f87346c2) |
| 17 | Anyone calls rebalance: 25% stays liquid, the rest goes into Mezo's Stability Pool (provideToSP) | Deposited | [`0x04e85642…`](https://explorer.test.mezo.org/tx/0x04e8564236521c698da3d96fbc7ccfaa2463b0b0b25dd835ca4d9dc4c8868e4d) |
| | _Cover fund in the Stability Pool (StabilityPool.getCompoundedMUSDDeposit)_ | 187.537500000000000000 MUSD | |
| | _Cover fund liquid_ | 62.512500000000000000 MUSD | |
| 18 | Ada sends Chidi 60 MUSD so he has funds (setup) | Sent | [`0x0ab4ef52…`](https://explorer.test.mezo.org/tx/0x0ab4ef522d357d01cd7dd6677b64de122880fb49ed5281529a8641e9e33ad296) |
| 19 | Chidi approves SellarSafe | Approved | [`0x464956be…`](https://explorer.test.mezo.org/tx/0x464956be1fb443611187e30ee807324090a6d0ed40d2212912cb10f03c2ffa07) |
| 20 | Chidi deposits 60 MUSD | Balance 60 MUSD | [`0xddc04ebd…`](https://explorer.test.mezo.org/tx/0xddc04ebd2df6a9c7803273d741be761721b5a227c0f626b7dbb40971662a9073) |
| 21 | Chidi sets his rules | Configured | [`0x98515109…`](https://explorer.test.mezo.org/tx/0x98515109b2d1bcb56e38bb3e46abf5ec0db35ca64a87ec79d47e6b4905763b61) |
| 22 | Chidi believes the fake invoice and trusts the scammer's address | Trusted | [`0x5a3b1ff8…`](https://explorer.test.mezo.org/tx/0x5a3b1ff8bb29d9517ad550614ae4c5ae5cbe14ea69b873ab58265e6b025d0132) |
| 23 | Chidi's agent pays the scammer 40 MUSD | Paid. Receipt 1 recorded in SellarShield | [`0x9c233196…`](https://explorer.test.mezo.org/tx/0x9c2331961e7836d643aaa2b4990dfe5f571c1081206857a7df004607d054b9e2) |
| 24 | Ada sends Ben 10 MUSD for his bond (setup) | Sent | [`0x12f5eba5…`](https://explorer.test.mezo.org/tx/0x12f5eba508b5dd1ebecf59275a17025828a96168bcf1d3f02bcde128bd717a47) |
| 25 | Ben approves SellarShield | Approved | [`0x40fd8799…`](https://explorer.test.mezo.org/tx/0x40fd87992e3c6759e7238072645dae961f04f7795befd5b15cae437939fec5eb) |
| 26 | Ben reports the scammer and locks a 10 MUSD bond | **Flagged** for every safe | [`0xc75b2102…`](https://explorer.test.mezo.org/tx/0xc75b21022761bdb633c9013d62e885fea6f47e755830404d1c78d783cdd5a5b0) |
| 27 | Chidi's agent tries to pay the scammer again, 10 MUSD | **Held**, although Chidi trusted the address | [`0x6d1d0d00…`](https://explorer.test.mezo.org/tx/0x6d1d0d002a7ee67d82e9d889f8f58f659dc79b770aa5c0d36daeb9364266bcab) |
| | _Hold 1 reasons_ | 16 (16 = payee is flagged on the scam list) | |
| 28 | Chidi rejects hold 1 | Rejected | [`0x04822722…`](https://explorer.test.mezo.org/tx/0x04822722bfe51c2acbd93f5c91c610587cc2725e95d87f2e0a857323c3eac49e) |
| 29 | Reviewer confirms the scam | Confirmed | [`0x0f8d5232…`](https://explorer.test.mezo.org/tx/0x0f8d52326b019e415db17428d308eecedc71cc08ca56295a8b614c8b1ef6c93f) |
| 30 | Chidi claims on receipt 1 | **Refunded** from the cover fund | [`0x03605a42…`](https://explorer.test.mezo.org/tx/0x03605a42630459587f6833497b71ca43d7000e588f6bbfc02bdf39ca7717289e) |
| | _Refund received by Chidi_ | 40.000000000000000000 MUSD | |
| 31 | Ben takes his bond back | 10 MUSD returned | [`0x57839f3b…`](https://explorer.test.mezo.org/tx/0x57839f3bad0e618efeb3817550290bad80f3357da84359003af0a442211882cb) |
| 32 | Ada raises her loan floor to 300%, above her loan's current ratio | Configured | [`0x391a5ec8…`](https://explorer.test.mezo.org/tx/0x391a5ec84ef9f8abf709a668545f6eb0b68189addcef05dae653c06801214f44) |
| 33 | Agent asks to pay the trusted vendor 10 MUSD | **Held**: paying now would be spending while the loan is below Ada's floor | [`0x032698b6…`](https://explorer.test.mezo.org/tx/0x032698b68b968a35f831466bc8403e05c6e3513cf3843950d2bae6c7a54381ce) |
| | _Hold 2 reasons_ | 64 (64 = Mezo loan below the owner's floor, read live from TroveManager and PriceFeed) | |
| 34 | Ada approves hold 2 herself | Paid on her approval | [`0x5181ea0f…`](https://explorer.test.mezo.org/tx/0x5181ea0f4a93018906fa8903c8fb830579c921d1ccaae69024b60bea47a78256) |
| 35 | Ada sets the floor back to 150% | Configured | [`0x5e31b190…`](https://explorer.test.mezo.org/tx/0x5e31b1907e036835746e3eb0144839758bcf43da6634cac829b045a29dd6d87a) |
| | _Cover fund total (fundAssets)_ | 210.175000000000000000 MUSD | |
| | _Reporter bonds held_ | 0.000000000000000000 MUSD | |
| | _Scam list status of the scammer_ | 2 (2 = confirmed) | |
