#!/usr/bin/env bash
# Anvil-fork REHEARSAL of the D-17 / D-18 upgrade of the live Robinhood-testnet proxies
# (docs/deploy-runbook.md §7.4). Nothing here touches the real chain: every transaction goes to a
# local anvil fork, signed by impersonated accounts.
#
# What it proves, in order, against the live state of chain 46630:
#   1. script/UpgradeOwnerSplit.s.sol runs as the REAL current admin (impersonated) and its own
#      post-checks pass;
#   2. both EIP-712 domain separators, a sample buyer's escrow struct and the provider's stake
#      struct are BYTE-IDENTICAL before and after (raw eth_call return data, diffed here);
#   3. owner == the old admin, then the two-step transfer to the NEW owner key completes;
#   4. the admin can no longer upgrade any of the three proxies, and the owner can
#      (script/UpgradeByOwner.s.sol, deployer deploys, owner upgrades);
#   5. the seq jump cap reverts (VoucherSeqGapTooLarge) for the sample buyer, on both paths;
#   6. a real delegate-signed voucher still redeems after the upgrade (the domain is live);
#   7. the removed doors are gone (Permit2 deposit, recoverVoucherSigner, verifierExpiry), no
#      token-moving owner door exists, and a direct setLimits consumes authNonce.
#
# usage: testnet/rehearse-owner-split.sh            (reads deployments/46630.json; the new owner's
#        ADDRESS — never its key — from ~/.config/goassay-testnet/owner.env)
set -euo pipefail
export PATH="${FOUNDRY_BIN:-$HOME/.foundry/bin}:$PATH"
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE"

UPSTREAM="${RH_TESTNET_RPC:-https://rpc.testnet.chain.robinhood.com}"
PORT="${ANVIL_PORT:-8547}"
RPC="http://127.0.0.1:$PORT"
REC="deployments/46630.json"
SAMPLE_BUYER="${SAMPLE_BUYER:-0x18103e1D79257c695B2FBbd4b346CD2Ba7927296}"
SAMPLE_PROVIDER="${SAMPLE_PROVIDER:-0xA271A3407D3302f4b4Fbe469b9188487cedd7d45}"
NEW_OWNER="${NEW_OWNER:-$(grep '^OWNER_ADDR=' "$HOME/.config/goassay-testnet/owner.env" | cut -d= -f2)}"

C=$(jq -r '.contracts.X402Config.proxy' "$REC")
S=$(jq -r '.contracts.X402Stake.proxy' "$REC")
E=$(jq -r '.contracts.X402Escrow.proxy' "$REC")
DEPLOYER=$(jq -r '.deployer' "$REC")
SLOT=0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc
VOUCHER_T='(address,address,uint64,bytes32,bytes32,uint64,uint64,uint64)'
ESCROW_T='(uint128,uint64,uint64,uint64,uint64,uint64,uint64,uint64,uint64,uint128,uint128,uint128)'
OUT=$(mktemp -d)
ANVIL_PID=""
cleanup() { [ -n "$ANVIL_PID" ] && kill "$ANVIL_PID" 2>/dev/null || true; rm -rf "$OUT"; }
trap cleanup EXIT

pass() { echo "  PASS  $*"; }
fail() { echo "  FAIL  $*"; exit 1; }
sel() { cast sig "$1"; }
# expect_revert <error signature> <cast call args…>: the eth_call must revert with that selector.
expect_revert() {
  local want; want=$(sel "$1"); shift
  local out
  if out=$(cast call --rpc-url "$RPC" "$@" 2>&1); then fail "expected revert $want, call succeeded"; fi
  echo "$out" | grep -qi "$want" || fail "expected $want, got: $(echo "$out" | tail -1)"
}
call() { cast call --rpc-url "$RPC" "$@"; }
# Address equality, case-insensitively: cast prints the checksummed form, and an operator may not.
lc() { echo "$1" | tr 'A-Z' 'a-z'; }
same() { [ "$(lc "$1")" = "$(lc "$2")" ]; }
send_as() { local from="$1"; shift; cast send --rpc-url "$RPC" --unlocked --from "$from" "$@" >/dev/null; }

echo "== starting anvil fork of $UPSTREAM on :$PORT"
anvil --fork-url "$UPSTREAM" --port "$PORT" --auto-impersonate --silent &
ANVIL_PID=$!
for _ in $(seq 1 60); do cast chain-id --rpc-url "$RPC" >/dev/null 2>&1 && break; sleep 1; done
[ "$(cast chain-id --rpc-url "$RPC")" = "46630" ] || fail "fork is not chain 46630"
echo "   fork block $(cast block-number --rpc-url "$RPC")"

ADMIN=$(call "$C" 'admin()(address)')
REDEEMER=$(call "$C" 'params()((address,address,uint64,uint64,uint64,uint64,uint16,uint16,uint16,uint16))' | tr -d '()' | cut -d, -f2 | tr -d ' ')
echo "   config $C  stake $S  escrow $E"
echo "   admin $ADMIN  deployer $DEPLOYER  redeemer $REDEEMER  new owner $NEW_OWNER"
for a in "$ADMIN" "$DEPLOYER" "$NEW_OWNER" "$REDEEMER" "$SAMPLE_BUYER"; do
  cast rpc --rpc-url "$RPC" anvil_setBalance "$a" 0x16345785D8A0000 >/dev/null   # 0.1 ETH, fork only
done

snapshot() { # <file>
  {
    echo "escrow.DOMAIN_SEPARATOR $(cast call --rpc-url "$RPC" "$E" 'DOMAIN_SEPARATOR()')"
    echo "stake.DOMAIN_SEPARATOR  $(cast call --rpc-url "$RPC" "$S" 'DOMAIN_SEPARATOR()')"
    echo "escrow.escrowOf(buyer)  $(cast call --rpc-url "$RPC" "$E" 'escrowOf(address)' "$SAMPLE_BUYER")"
    echo "stake.stakeOf(provider) $(cast call --rpc-url "$RPC" "$S" 'stakeOf(address)' "$SAMPLE_PROVIDER")"
    echo "escrow.totalEscrowed    $(cast call --rpc-url "$RPC" "$E" 'totalEscrowed()')"
    echo "stake.totalStaked       $(cast call --rpc-url "$RPC" "$S" 'totalStaked()')"
    echo "config.params           $(cast call --rpc-url "$RPC" "$C" 'params()')"
    echo "config.admin            $(cast call --rpc-url "$RPC" "$C" 'admin()')"
    echo "config.paused           $(cast call --rpc-url "$RPC" "$C" 'paused()')"
    echo "escrow.delegatesOf(b)   $(cast call --rpc-url "$RPC" "$E" 'delegatesOf(address)' "$SAMPLE_BUYER")"
  } > "$1"
}
impl() { cast storage --rpc-url "$RPC" "$1" "$SLOT"; }

echo "== 0. before"
snapshot "$OUT/before"
for p in "$C" "$S" "$E"; do echo "   impl($p) $(impl "$p")"; done
expect_revert 'NotAdmin()' "$C" 'upgradeToAndCall(address,bytes)' 0x0000000000000000000000000000000000000001 0x --from "$NEW_OWNER"
pass "before: the deployed Config refuses a non-admin upgrade (NotAdmin)"

echo "== 1. UpgradeOwnerSplit.s.sol, broadcast as the impersonated admin"
PROXY_CONFIG=$C PROXY_STAKE=$S PROXY_ESCROW=$E EXPECTED_CHAIN_ID=46630 \
SAMPLE_BUYER=$SAMPLE_BUYER SAMPLE_PROVIDER=$SAMPLE_PROVIDER DEPLOYER_ADDRESS=$DEPLOYER NEW_OWNER=$NEW_OWNER \
  forge script script/UpgradeOwnerSplit.s.sol --rpc-url "$RPC" --broadcast --unlocked --sender "$ADMIN" \
  --slow 2>&1 | grep -E "^\s+(chainId|deployer|admin|pending|X402|escrow|stake|0x)|ONCHAIN EXECUTION COMPLETE|Error|revert" | sed 's/^/   /'
for p in "$C" "$S" "$E"; do echo "   impl($p) $(impl "$p")"; done
RPC=$RPC PROXY_CONFIG=$C PROXY_STAKE=$S PROXY_ESCROW=$E EXPECTED_OWNER=$(lc "$ADMIN") \
EXPECTED_PENDING_OWNER=$(lc "$NEW_OWNER") script/postcheck-upgrade.sh | sed 's/^/   /' \
  || fail "on-chain post-check (script/postcheck-upgrade.sh)"
pass "on-chain post-check: owner == admin and pendingOwner == new owner, read from the fork"

echo "== 2. byte-identical state"
snapshot "$OUT/after"
if diff "$OUT/before" "$OUT/after" >/dev/null; then
  sed 's/^/   /' "$OUT/after" | cut -c1-140
  pass "domain separators, sample escrow, provider stake, totals, params, admin, pause: byte-identical"
else
  diff "$OUT/before" "$OUT/after"; fail "state moved across the upgrade"
fi

echo "== 3. owner = old admin, then the two-step transfer"
same "$(call "$C" 'owner()(address)')" "$ADMIN" && pass "owner() == the old admin ($ADMIN)" || fail "owner is not the admin"
same "$(call "$C" 'pendingOwner()(address)')" "$NEW_OWNER" && pass "pendingOwner() == new owner" || fail "pending owner"
expect_revert 'NotOwner()' "$S" 'upgradeToAndCall(address,bytes)' "$(impl "$S" | sed 's/0x000000000000000000000000/0x/')" 0x --from "$NEW_OWNER"
pass "a PROPOSED owner holds nothing (stake upgrade from it: NotOwner)"
expect_revert 'OwnableUnauthorizedAccount(address)' "$C" 'acceptOwnership()' --from "$ADMIN"
pass "only the proposed key can accept (admin: OwnableUnauthorizedAccount)"
send_as "$NEW_OWNER" "$C" 'acceptOwnership()'
same "$(call "$C" 'owner()(address)')" "$NEW_OWNER" && pass "acceptOwnership(): owner() == $NEW_OWNER" || fail "owner did not move"
same "$(call "$C" 'admin()(address)')" "$ADMIN" && pass "admin() still $ADMIN" || fail "admin moved"
expect_revert 'OwnershipCannotBeRenounced()' "$C" 'renounceOwnership()' --from "$NEW_OWNER"
pass "renounceOwnership() reverts for the owner"

echo "== 4. the admin cannot upgrade; the owner can"
ANY=$(impl "$E" | sed 's/0x000000000000000000000000/0x/')
expect_revert 'OwnableUnauthorizedAccount(address)' "$C" 'upgradeToAndCall(address,bytes)' "$(impl "$C" | sed 's/0x000000000000000000000000/0x/')" 0x --from "$ADMIN"
expect_revert 'NotOwner()' "$S" 'upgradeToAndCall(address,bytes)' "$(impl "$S" | sed 's/0x000000000000000000000000/0x/')" 0x --from "$ADMIN"
expect_revert 'NotOwner()' "$E" 'upgradeToAndCall(address,bytes)' "$ANY" 0x --from "$ADMIN"
expect_revert 'OwnableUnauthorizedAccount(address)' "$C" 'setAdmin(address)' "$ADMIN" --from "$ADMIN"
pass "admin: Config/Stake/Escrow upgrade and setAdmin all refused"
call "$C" 'setPaused(bool)' false --from "$ADMIN" >/dev/null && pass "admin still administers (setPaused eth_call succeeds)"
ESC_NEXT=$(PROXY_CONFIG=$C PROXY_STAKE=$S PROXY_ESCROW=$E EXPECTED_CHAIN_ID=46630 UPGRADE_ESCROW=true \
  forge script script/UpgradeByOwner.s.sol --sig 'deploy()' --rpc-url "$RPC" --broadcast --unlocked \
  --sender "$DEPLOYER" 2>&1 | grep -Eo 'IMPL_ESCROW= *0x[0-9a-fA-F]{40}' | grep -Eo '0x[0-9a-fA-F]{40}')
echo "   deployer deployed a fresh escrow implementation $ESC_NEXT"
# The hash the owner pins: in production it is the one check-bytecode.sh verified against the build.
ESC_HASH=$(cast keccak "$(cast code --rpc-url "$RPC" "$ESC_NEXT" | tr -d '\n')")
PROXY_CONFIG=$C PROXY_STAKE=$S PROXY_ESCROW=$E EXPECTED_CHAIN_ID=46630 UPGRADE_ESCROW=true IMPL_ESCROW=$ESC_NEXT \
SAMPLE_BUYER=$SAMPLE_BUYER SAMPLE_PROVIDER=$SAMPLE_PROVIDER EXPECTED_CODEHASH_ESCROW=0x$(printf '%064x' 1) \
  forge script script/UpgradeByOwner.s.sol --rpc-url "$RPC" --sender "$NEW_OWNER" > "$OUT/hash.log" 2>&1 || true
grep -Eq "ImplementationCodehashMismatch|$(sel 'ImplementationCodehashMismatch(address,bytes32,bytes32)')" "$OUT/hash.log" \
  && pass "UpgradeByOwner.s.sol refuses an IMPL_* whose code hash is not EXPECTED_CODEHASH_*" \
  || { tail -5 "$OUT/hash.log"; fail "script did not refuse a wrong code hash"; }
PROXY_CONFIG=$C PROXY_STAKE=$S PROXY_ESCROW=$E EXPECTED_CHAIN_ID=46630 UPGRADE_ESCROW=true IMPL_ESCROW=$ESC_NEXT \
SAMPLE_BUYER=$SAMPLE_BUYER SAMPLE_PROVIDER=$SAMPLE_PROVIDER EXPECTED_CODEHASH_ESCROW=$ESC_HASH \
  forge script script/UpgradeByOwner.s.sol --rpc-url "$RPC" --broadcast --unlocked --sender "$NEW_OWNER" \
  2>&1 | grep -E "upgraded|Error|revert" | sed 's/^/   /'
same "$(impl "$E" | sed 's/0x000000000000000000000000/0x/')" "$ESC_NEXT" \
  && pass "the owner upgraded the escrow (UpgradeByOwner.s.sol run(), its post-checks green)" || fail "owner upgrade"
PROXY_CONFIG=$C PROXY_STAKE=$S PROXY_ESCROW=$E EXPECTED_CHAIN_ID=46630 UPGRADE_ESCROW=true IMPL_ESCROW=$ESC_NEXT \
SAMPLE_BUYER=$SAMPLE_BUYER SAMPLE_PROVIDER=$SAMPLE_PROVIDER EXPECTED_CODEHASH_ESCROW=$ESC_HASH \
  forge script script/UpgradeByOwner.s.sol --rpc-url "$RPC" --sender "$ADMIN" > "$OUT/refuse.log" 2>&1 || true
grep -Eq "NotTheOwner|$(sel 'NotTheOwner(address,address)')" "$OUT/refuse.log" \
  && pass "UpgradeByOwner.s.sol refuses to run for the admin (NotTheOwner)" || { tail -5 "$OUT/refuse.log"; fail "script did not refuse the admin"; }

echo "== 5. the seq jump cap"
SEQHIGH=$(call "$E" "escrowOf(address)($ESCROW_T)" "$SAMPLE_BUYER" | tr -d '()' | cut -d, -f2 | awk '{print $1}')
NOW=$(cast block --rpc-url "$RPC" latest -f timestamp)
DUMMY=0x$(printf '11%.0s' $(seq 1 64))1b
v() { echo "($SAMPLE_BUYER,$SAMPLE_PROVIDER,1000,0x$(printf '%064x' 1),0x$(printf '%064x' "$2"),$1,$NOW,$((NOW + 60)))"; }
expect_revert 'VoucherSeqGapTooLarge()' "$E" "redeemVoucher($VOUCHER_T,bytes)" "$(v $((SEQHIGH + 1000001)) 1)" "$DUMMY" --from "$REDEEMER"
expect_revert 'VoucherSeqGapTooLarge()' "$E" "redeemVoucher($VOUCHER_T,bytes)" "$(v 18446744073709551615 2)" "$DUMMY" --from "$REDEEMER"
expect_revert 'VoucherSeqGapTooLarge()' "$E" "redeemVoucherBatch($VOUCHER_T[],bytes[])" "[$(v $((SEQHIGH + 1000001)) 3)]" "[$DUMMY]" --from "$REDEEMER"
pass "seqHigh=$SEQHIGH: seq seqHigh+1,000,001 and 2^64-1 refused VoucherSeqGapTooLarge (single and batch)"
expect_revert 'InvalidSignature()' "$E" "redeemVoucher($VOUCHER_T,bytes)" "$(v $((SEQHIGH + 1000000)) 4)" "$DUMMY" --from "$REDEEMER"
pass "seq seqHigh+1,000,000 passes the cap and is refused only by the signature check (InvalidSignature)"

echo "== 6. a real delegate-signed voucher redeems after the upgrade"
DKEY=$(cast wallet new --json | jq -r '.[0].private_key // .private_key')
DADDR=$(cast wallet address --private-key "$DKEY")
send_as "$SAMPLE_BUYER" "$E" 'authorizeDelegate(address,uint64,uint64,uint64)' "$DADDR" 1000 1000 $((NOW + 86400))
SEQ=$((SEQHIGH + 1))
cat > "$OUT/voucher.json" <<JSON
{"types":{"EIP712Domain":[{"name":"name","type":"string"},{"name":"version","type":"string"},{"name":"chainId","type":"uint256"},{"name":"verifyingContract","type":"address"}],
"Voucher":[{"name":"payer","type":"address"},{"name":"provider","type":"address"},{"name":"amount","type":"uint64"},{"name":"resourceHash","type":"bytes32"},{"name":"requestHash","type":"bytes32"},{"name":"seq","type":"uint64"},{"name":"issuedAt","type":"uint64"},{"name":"expiresAt","type":"uint64"}]},
"primaryType":"Voucher","domain":{"name":"x402 Settlement","version":"2","chainId":46630,"verifyingContract":"$E"},
"message":{"payer":"$SAMPLE_BUYER","provider":"$SAMPLE_PROVIDER","amount":1000,"resourceHash":"0x$(printf '%064x' 1)","requestHash":"0x$(printf '%064x' 5)","seq":$SEQ,"issuedAt":$NOW,"expiresAt":$((NOW + 60))}}
JSON
SIG=$(cast wallet sign --private-key "$DKEY" --data --from-file "$OUT/voucher.json")
BAL0=$(call "$E" "escrowOf(address)($ESCROW_T)" "$SAMPLE_BUYER" | tr -d '()' | cut -d, -f1 | awk '{print $1}')
send_as "$REDEEMER" "$E" "redeemVoucher($VOUCHER_T,bytes)" "$(v $SEQ 5)" "$SIG"
BAL1=$(call "$E" "escrowOf(address)($ESCROW_T)" "$SAMPLE_BUYER" | tr -d '()' | cut -d, -f1 | awk '{print $1}')
[ $((BAL0 - BAL1)) -eq 1000 ] && pass "delegate voucher seq $SEQ redeemed: balance $BAL0 -> $BAL1" || fail "redeem"
cat > "$OUT/v2.json" < <(sed "s/\"seq\":$SEQ/\"seq\":$((SEQ + 1000001))/" "$OUT/voucher.json")
SIG2=$(cast wallet sign --private-key "$DKEY" --data --from-file "$OUT/v2.json")
expect_revert 'VoucherSeqGapTooLarge()' "$E" "redeemVoucher($VOUCHER_T,bytes)" "$(v $((SEQ + 1000001)) 5)" "$SIG2" --from "$REDEEMER"
pass "a correctly SIGNED delegate voucher at seqHigh+1,000,001 is still refused VoucherSeqGapTooLarge"
unset DKEY

echo "== 7. removed doors, no owner token door, authNonce on direct decisions"
for f in 'depositWithPermit2(address,uint64,uint256,uint256,bytes)' "recoverVoucherSigner($VOUCHER_T,bytes)"; do
  sig=$(sel "$f"); out=$(cast call --rpc-url "$RPC" "$E" "${sig}$(printf '%0512x' 0)" 2>&1 || true)
  echo "$out" | grep -qi "revert" && pass "escrow no longer answers $f" || fail "$f still answers"
done
out=$(cast call --rpc-url "$RPC" "$C" 'verifierExpiry(address)(uint64)' "$ADMIN" 2>&1 || true)
echo "$out" | grep -qi "revert" && pass "config no longer answers verifierExpiry(address)" || fail "verifierExpiry"
for f in 'sweep(address,address,uint256)' 'rescueToken(address,address,uint256)' 'sweepExcess(address,address,uint256)'; do
  for p in "$E" "$S"; do
    out=$(cast call --rpc-url "$RPC" "$p" "$f" "$(call "$E" 'ASSET()(address)')" "$NEW_OWNER" 1 --from "$NEW_OWNER" 2>&1 || true)
    echo "$out" | grep -qi "revert" || fail "$p answers $f"
  done
done
pass "neither money contract answers sweep / rescueToken / sweepExcess, even for the owner"
N0=$(call "$E" "escrowOf(address)($ESCROW_T)" "$SAMPLE_BUYER" | tr -d '()' | cut -d, -f3 | awk '{print $1}')
send_as "$SAMPLE_BUYER" "$E" 'setLimits(uint64,uint64)' 999999 9999999
N1=$(call "$E" "escrowOf(address)($ESCROW_T)" "$SAMPLE_BUYER" | tr -d '()' | cut -d, -f3 | awk '{print $1}')
[ $((N1 - N0)) -eq 1 ] && pass "a direct setLimits consumed authNonce ($N0 -> $N1)" || fail "authNonce"

echo "== rehearsal complete: every check passed"
