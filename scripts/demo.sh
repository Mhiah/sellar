#!/usr/bin/env bash
# Sellar live demo on Mezo testnet. Every step is a real transaction.
# Needs: foundry (cast), DEPLOYER_KEY (a testnet-only key holding test BTC), ETH_RPC_URL.
# Writes a markdown evidence table to $EVIDENCE (default: evidence.md).
#
# All other wallets (agent, reporter, reviewer, victim...) are derived from DEPLOYER_KEY, so every
# wallet in this run belongs to the team. Nothing here is outside usage.
set -euo pipefail

: "${DEPLOYER_KEY:?}"
export ETH_RPC_URL="${ETH_RPC_URL:-https://rpc.test.mezo.org}"
EVIDENCE="${EVIDENCE:-evidence.md}"
RUN="${RUN_ID:-$(date +%s)}"

BO=0xCdF7028ceAB81fA0C6971208e83fa7872994beE5
TM=0xE47c80e8c23f6B4A1aE41c34837a0599D5D16bb0
PF=0x86bCF0841622a5dAC14A313a15f96A95421b9366
SP=0x1CCA7E410eE41739792eA0A24e00349Dd247680e
MUSD=0x118917a40FAF1CD7a13dB0Ef56C86De7973Ac503
SAFE="${SAFE:-0x9bf0180a21fFfB35b815Bf0B264706E72e0a26Aa}"
SHIELD="${SHIELD:-0x799d90D2FA41b9827c345E480BEC635B3EF0c444}"
ZERO=0x0000000000000000000000000000000000000000
EXPLORER=https://explorer.test.mezo.org/tx

K_ADA="0x${DEPLOYER_KEY#0x}"
derive() { cast keccak "$(cast concat-hex "$K_ADA" "$(cast from-utf8 "$1")")"; }
K_AGENT=$(derive agent)
K_REVIEWER=$(derive reviewer)
K_BEN=$(derive ben)
K_CHIDI=$(derive "chidi-$RUN")
K_CHIDI_AGENT=$(derive chidi-agent)
addr() { cast wallet address --private-key "$1"; }
ADA=$(addr "$K_ADA"); AGENT=$(addr "$K_AGENT"); REVIEWER=$(addr "$K_REVIEWER")
BEN=$(addr "$K_BEN"); CHIDI=$(addr "$K_CHIDI"); CHIDI_AGENT=$(addr "$K_CHIDI_AGENT")
VENDOR=$(addr "$(derive vendor)")
SCAMMER=$(addr "$(derive "scammer-$RUN")")

e18() { cast to-wei "$1" ether; }
num() { awk '{print $1}'; }
call() { cast call "$@" | num; }

{
  echo "# Live run on Mezo testnet (chain 31611)"
  echo
  echo "Run id \`$RUN\`. SellarSafe \`$SAFE\`, SellarShield \`$SHIELD\`."
  echo
  echo "Every wallet below is a team test wallet. This run shows the mechanics work on Mezo's real"
  echo "contracts. It is not outside usage."
  echo
  echo "| Role | Address |"
  echo "|---|---|"
  echo "| Ada (owner, has a Mezo loan) | \`$ADA\` |"
  echo "| Ada's agent key | \`$AGENT\` |"
  echo "| Vendor (trusted payee) | \`$VENDOR\` |"
  echo "| Scammer | \`$SCAMMER\` |"
  echo "| Ben (reporter) | \`$BEN\` |"
  echo "| Chidi (victim) | \`$CHIDI\` |"
  echo "| Chidi's agent key | \`$CHIDI_AGENT\` |"
  echo "| Reviewer | \`$REVIEWER\` |"
  echo
  echo "| # | Step | Result | Transaction |"
  echo "|---|---|---|---|"
} > "$EVIDENCE"

N=0
# tx <label> <result text> <key> <to> <sig> [args...]   (set VALUE to send BTC)
tx() {
  local label="$1" result="$2" key="$3"; shift 3
  local out hash status
  out=$(cast send --json --private-key "$key" ${VALUE:+--value "$VALUE"} "$@")
  hash=$(echo "$out" | jq -r .transactionHash)
  status=$(echo "$out" | jq -r .status)
  [ "$status" = "0x1" ] || { echo "FAILED: $label ($hash)"; exit 1; }
  N=$((N + 1))
  echo "| $N | $label | $result | [\`${hash:0:10}…\`]($EXPLORER/$hash) |" >> "$EVIDENCE"
  echo "ok  $N  $label  $hash"
}
note() { echo "| | _$1_ | $2 | |" >> "$EVIDENCE"; echo "    $1: $2"; }
gas() { VALUE=$(e18 0.00002) tx "Send test BTC for gas to $1" "0.00002 BTC" "$K_ADA" "$2"; }

echo "== setup"
PRICE=$(call $PF 'fetchPrice()(uint256)')
if [ "$(call $TM 'getTroveStatus(address)(uint8)' "$ADA")" != "1" ]; then
  VALUE=$(e18 0.045) tx "Ada opens a Mezo loan: 0.045 BTC locked, 1,800 MUSD borrowed (BorrowerOperations.openTrove)" \
    "Loan open" "$K_ADA" $BO 'openTrove(uint256,address,address)' "$(e18 1800)" $ZERO $ZERO
fi
ICR=$(call $TM 'getCurrentICR(address,uint256)(uint256)' "$ADA" "$PRICE")
note "Ada's loan collateral ratio read from TroveManager" "$(cast from-wei "$ICR") (1.0 = 100%)"

for pair in "agent:$AGENT" "reviewer:$REVIEWER" "Ben:$BEN" "Chidi:$CHIDI" "Chidi's agent:$CHIDI_AGENT"; do
  who="${pair%%:*}"; a="${pair##*:}"
  [ "$(cast balance "$a")" != "0" ] || gas "$who" "$a"
done

if [ "$(cast call $SHIELD 'reviewer()(address)')" != "$REVIEWER" ]; then
  tx "Deployer hands the reviewer role to a separate wallet (step 1 of 2)" "Proposed" "$K_ADA" $SHIELD 'proposeReviewer(address)' "$REVIEWER"
  tx "New reviewer accepts (step 2 of 2)" "Reviewer changed" "$K_REVIEWER" $SHIELD 'acceptReviewer()'
fi

tx "Ada approves SellarSafe to take MUSD" "Approved" "$K_ADA" $MUSD 'approve(address,uint256)' $SAFE "$(e18 100)"
tx "Ada deposits 100 MUSD into her safe account" "Balance 100 MUSD" "$K_ADA" $SAFE 'deposit(address,uint256)' "$ADA" "$(e18 100)"
tx "Ada sets her rules: agent key, 50 MUSD per payment, 150 per day, loan floor 150%" "Configured" "$K_ADA" \
  $SAFE 'configure(address,uint128,uint128,uint64,uint256)' "$AGENT" "$(e18 50)" "$(e18 150)" 0 "$(e18 1.5)"
tx "Ada trusts her vendor" "Trusted" "$K_ADA" $SAFE 'trust(address)' "$VENDOR"

echo "== 1. a real invoice is paid, a poisoned one is held"
tx "Agent asks to pay the vendor 20 MUSD" "**Paid at once** (trusted, within limits, loan healthy)" "$K_AGENT" \
  $SAFE 'request(address,address,uint128,bytes32,bool)' "$ADA" "$VENDOR" "$(e18 20)" "$(cast keccak invoice-4470)" false
note "Vendor's MUSD balance" "$(cast from-wei "$(call $MUSD 'balanceOf(address)(uint256)' "$VENDOR")") MUSD"

HOLD=$(call $SAFE 'holdCount()(uint256)')
tx "Agent, fooled by a fake invoice email, asks to pay the scammer 20 MUSD" "**Held**. Nothing left the safe" "$K_AGENT" \
  $SAFE 'request(address,address,uint128,bytes32,bool)' "$ADA" "$SCAMMER" "$(e18 20)" "$(cast keccak invoice-4471)" false
REASONS=$(cast call $SAFE 'holds(uint256)(address,address,uint128,uint64,uint32,uint8,bytes32)' "$HOLD" | sed -n 5p | num)
note "Hold $HOLD reasons" "$REASONS (1 = payee is not on Ada's trusted list)"
note "Scammer's MUSD balance" "$(cast from-wei "$(call $MUSD 'balanceOf(address)(uint256)' "$SCAMMER")") MUSD"
tx "Ada rejects hold $HOLD" "Rejected" "$K_ADA" $SAFE 'reject(uint256)' "$HOLD"

echo "== 2. the cover fund goes to work in Mezo's Stability Pool"
tx "Team seeds the cover fund with 250 MUSD (a plain transfer, disclosed)" "Fund seeded" "$K_ADA" $MUSD 'transfer(address,uint256)' $SHIELD "$(e18 250)"
tx "Anyone calls rebalance: 25% stays liquid, the rest goes into Mezo's Stability Pool (provideToSP)" "Deposited" "$K_BEN" $SHIELD 'rebalance()'
note "Cover fund in the Stability Pool (StabilityPool.getCompoundedMUSDDeposit)" "$(cast from-wei "$(call $SP 'getCompoundedMUSDDeposit(address)(uint256)' $SHIELD)") MUSD"
note "Cover fund liquid" "$(cast from-wei "$(call $SHIELD 'fundLiquid()(uint256)')") MUSD"

echo "== 3. a victim pays the scammer before anyone has reported it"
tx "Ada sends Chidi 60 MUSD so he has funds (setup)" "Sent" "$K_ADA" $MUSD 'transfer(address,uint256)' "$CHIDI" "$(e18 60)"
tx "Chidi approves SellarSafe" "Approved" "$K_CHIDI" $MUSD 'approve(address,uint256)' $SAFE "$(e18 60)"
tx "Chidi deposits 60 MUSD" "Balance 60 MUSD" "$K_CHIDI" $SAFE 'deposit(address,uint256)' "$CHIDI" "$(e18 60)"
tx "Chidi sets his rules" "Configured" "$K_CHIDI" $SAFE 'configure(address,uint128,uint128,uint64,uint256)' "$CHIDI_AGENT" "$(e18 50)" "$(e18 150)" 0 0
tx "Chidi believes the fake invoice and trusts the scammer's address" "Trusted" "$K_CHIDI" $SAFE 'trust(address)' "$SCAMMER"
RECEIPT=$(call $SHIELD 'receiptCount()(uint256)')
tx "Chidi's agent pays the scammer 40 MUSD" "Paid. Receipt $RECEIPT recorded in SellarShield" "$K_CHIDI_AGENT" \
  $SAFE 'request(address,address,uint128,bytes32,bool)' "$CHIDI" "$SCAMMER" "$(e18 40)" "$(cast keccak invoice-4471)" false

echo "== 4. one report protects everyone"
tx "Ada sends Ben 10 MUSD for his bond (setup)" "Sent" "$K_ADA" $MUSD 'transfer(address,uint256)' "$BEN" "$(e18 10)"
tx "Ben approves SellarShield" "Approved" "$K_BEN" $MUSD 'approve(address,uint256)' $SHIELD "$(e18 10)"
tx "Ben reports the scammer and locks a 10 MUSD bond" "**Flagged** for every safe" "$K_BEN" $SHIELD 'report(address,bytes32)' "$SCAMMER" "$(cast keccak 'the fake invoice email')"
HOLD=$(call $SAFE 'holdCount()(uint256)')
tx "Chidi's agent tries to pay the scammer again, 10 MUSD" "**Held**, although Chidi trusted the address" "$K_CHIDI_AGENT" \
  $SAFE 'request(address,address,uint128,bytes32,bool)' "$CHIDI" "$SCAMMER" "$(e18 10)" "$(cast keccak invoice-4472)" false
REASONS=$(cast call $SAFE 'holds(uint256)(address,address,uint128,uint64,uint32,uint8,bytes32)' "$HOLD" | sed -n 5p | num)
note "Hold $HOLD reasons" "$REASONS (16 = payee is flagged on the scam list)"
tx "Chidi rejects hold $HOLD" "Rejected" "$K_CHIDI" $SAFE 'reject(uint256)' "$HOLD"

echo "== 5. confirmed scam: the victim is refunded, the reporter gets his bond back"
tx "Reviewer confirms the scam" "Confirmed" "$K_REVIEWER" $SHIELD 'confirm(address)' "$SCAMMER"
BEFORE=$(call $MUSD 'balanceOf(address)(uint256)' "$CHIDI")
tx "Chidi claims on receipt $RECEIPT" "**Refunded** from the cover fund" "$K_CHIDI" $SHIELD 'claim(uint256)' "$RECEIPT"
AFTER=$(call $MUSD 'balanceOf(address)(uint256)' "$CHIDI")
note "Refund received by Chidi" "$(cast from-wei "$(echo "$AFTER - $BEFORE" | bc)") MUSD"
tx "Ben takes his bond back" "10 MUSD returned" "$K_BEN" $SHIELD 'withdrawBond(address)' "$SCAMMER"

echo "== 6. the safe watches Ada's Mezo loan"
tx "Ada raises her loan floor to 300%, above her loan's current ratio" "Configured" "$K_ADA" \
  $SAFE 'configure(address,uint128,uint128,uint64,uint256)' "$AGENT" "$(e18 50)" "$(e18 150)" 0 "$(e18 3)"
HOLD=$(call $SAFE 'holdCount()(uint256)')
tx "Agent asks to pay the trusted vendor 10 MUSD" "**Held**: paying now would be spending while the loan is below Ada's floor" "$K_AGENT" \
  $SAFE 'request(address,address,uint128,bytes32,bool)' "$ADA" "$VENDOR" "$(e18 10)" "$(cast keccak invoice-4473)" false
REASONS=$(cast call $SAFE 'holds(uint256)(address,address,uint128,uint64,uint32,uint8,bytes32)' "$HOLD" | sed -n 5p | num)
note "Hold $HOLD reasons" "$REASONS (64 = Mezo loan below the owner's floor, read live from TroveManager and PriceFeed)"
tx "Ada approves hold $HOLD herself" "Paid on her approval" "$K_ADA" $SAFE 'approve(uint256,bool)' "$HOLD" false
tx "Ada sets the floor back to 150%" "Configured" "$K_ADA" \
  $SAFE 'configure(address,uint128,uint128,uint64,uint256)' "$AGENT" "$(e18 50)" "$(e18 150)" 0 "$(e18 1.5)"

echo "== final state"
note "Cover fund total (fundAssets)" "$(cast from-wei "$(call $SHIELD 'fundAssets()(uint256)')") MUSD"
note "Reporter bonds held" "$(cast from-wei "$(call $SHIELD 'bondsHeld()(uint256)')") MUSD"
note "Scam list status of the scammer" "$(call $SHIELD 'statusOf(address)(uint8)' "$SCAMMER") (2 = confirmed)"

echo
cat "$EVIDENCE"
