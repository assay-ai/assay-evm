#!/usr/bin/env bash
# usage: verify-deployment.sh <chainId> <rpc-url>
#
# Read-only. Asserts the live chain matches deployments/<chainId>.json in every field the backend
# is configured from. Run it before pointing anything at a deployment, again after any redeploy,
# and **AGAIN AFTER EVERY UPGRADE** — the ERC-1967 implementation slot is the field an upgrade
# changes, and this is what proves it changed to what the record says.
#
# **It reads the implementation slot.** A version of this script that only checked the proxy has
# code would pass against a proxy pointing at an implementation nobody recorded, which is the one
# thing an upgrade can get wrong silently. Check 2 below is the whole point of the file.
#
# **Check 0 is the function surface**, added after a review observed that storage
# layout and the EIP-712 domain both have mechanical gates across an upgrade and the set of
# exported functions has none — so a new implementation could add a `sweep(address)` and every
# gate would stay green. It compares the record's `abiKeccak` against the current build and, on a
# mismatch, prints the signatures added and removed BY NAME. See `script/abi-surface.sh` for what
# that comparison can and cannot see; it needs a build, which is the one thing in this script that
# is not a `cast` call, and it is still read-only with respect to the chain.
#
# **Check 1 is the CREATE2 reproduction**, added 2026-09-10. It runs before every network read,
# beside check 0, because both are questions about the RECORD rather than about the chain. It
# recomputes each proxy address from the record's own `implementation`, `initializerArgs` and `salt` and refuses a record whose
# addresses do not reproduce. It is arithmetic, not a network read, and it ties three recorded
# fields to a fourth — which is the one relationship in this file that no `cast call` can check.
set -euo pipefail
export PATH="${FOUNDRY_BIN:-$HOME/.foundry/bin}:$PATH"
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHAIN_ID="${1:?usage: verify-deployment.sh <chainId> <rpc-url>}"
RPC="${2:?usage: verify-deployment.sh <chainId> <rpc-url>}"
REC="$HERE/deployments/$CHAIN_ID.json"
FORGE="${FORGE:-forge}"
# shellcheck source=script/abi-surface.sh
. "$HERE/script/abi-surface.sh"
[ -f "$REC" ] || { echo "no deployment record at $REC"; exit 2; }
fail() { echo "MISMATCH: $*"; exit 1; }
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
lc() { echo "$1" | tr 'A-Z' 'a-z'; }

# Runtime code as CI built it: the deployed bytes with every IMMUTABLE span zeroed.
#
# A deployed implementation is never byte-equal to `forge inspect … deployedBytecode`: the
# constructor writes its immutables into the runtime code, and the compiler's output leaves those
# spans as zeros. For these three contracts that is UUPS's `__self` (the implementation's own
# address, two spans each) and, on Stake and Escrow, EIP712's ShortString name/version and cached
# domain values. Comparing raw keccaks therefore failed on every real deploy — first run against
# 46630 on 2026-09-22 — while passing nothing on a fork either, because it had never been run
# against a broadcast. The spans come from the compiler's own `immutableReferences`, so this masks
# exactly what the constructor writes and nothing an upgrade could hide in.
masked_code() { # <contract> <address>
  local code art starts
  code=$(cast code "$2" --rpc-url "$RPC"); code=${code#0x}
  art="out/$1.sol/$1.json"
  [ -f "$art" ] || "$FORGE" build --quiet >/dev/null
  starts=$(jq -r '.deployedBytecode.immutableReferences // {} | [.[][]] | .[] | "\(.start) \(.length)"' "$art")
  while read -r start len; do
    [ -n "$start" ] || continue
    local zeros; zeros=$(printf '%0*d' $((len * 2)) 0)
    code="${code:0:$((start * 2))}${zeros}${code:$(((start + len) * 2))}"
  done <<< "$starts"
  echo "0x$code"
}

# keccak256("eip1967.proxy.implementation") - 1
SLOT=0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc

[ "$(cast chain-id --rpc-url "$RPC")" = "$CHAIN_ID" ] || fail "chain id"

# 0. The FUNCTION SURFACE the record commits to is the one this build exports. It runs FIRST and
#    it is the only check here that touches no network: an upgrade that adds a door has to rewrite
#    `abiFunctions`, and the added signature is then named — here, and in the record diff a
#    reviewer reads. That is the same deliberate act the storage-layout snapshot demands, and it
#    is what the other three checks cannot supply: `implementationRuntimeKeccak` is rewritten by
#    the operator as part of every upgrade, so it says the deployed code matches the NEW source,
#    never that the new source's shape matches the old.
for c in X402Config X402Stake X402Escrow; do
  wantAbi=$(jq -r ".contracts.\"$c\".abiKeccak // empty" "$REC")
  [ -n "$wantAbi" ] || fail "$c has no abiKeccak in $REC — the record predates the surface gate"
  gotAbi=$(abi_hash "$c")
  [ "$(lc "$gotAbi")" = "$(lc "$wantAbi")" ] && continue
  echo "$c function surface differs from $REC ($gotAbi != $wantAbi)"
  jq -r ".contracts.\"$c\".abiFunctions[]" "$REC" | sort > "$TMP/rec.$c"
  abi_lines "$c" | sort > "$TMP/built.$c"
  echo "  ADDED by this build, not in the record:"
  comm -13 "$TMP/rec.$c" "$TMP/built.$c" | sed 's/^/    + /'
  echo "  REMOVED by this build, present in the record:"
  comm -23 "$TMP/rec.$c" "$TMP/built.$c" | sed 's/^/    - /'
  fail "$c function surface"
done

# 1. Each recorded proxy is the CREATE2 address of its recorded implementation, initializerArgs
#    and salt. CREATE2 is deterministic given (deployer, salt, initcode-hash), so this is
#    ARITHMETIC over the record — no network read at all — which is why it can be run against a
#    record for a chain this machine cannot reach, and why it catches a proxy/implementation pair
#    that was pasted from two different terminals.
#
#    **The CREATE2 deployer is the constant `0x4e59b448…`, not the signing key.** `Deploy.s.sol`
#    creates each proxy with `new ERC1967Proxy{salt: ...}(...)` inside `vm.startBroadcast()`, and
#    forge routes a salted creation through the deterministic deployer: transactionType CREATE2,
#    `to` = 0x4e59b44847b379578588920ca78fbf26c0b4956c, calldata = salt ++ initcode. Measured
#    2026-09-10 from the dry run's own broadcast file; that address has 69 bytes of code on BOTH
#    4663 and 46630, and a deploy to a chain where it does not would fail outright.
#
#    The signing key still moves the address, one level down: the IMPLEMENTATION is a plain
#    CREATE(from, nonce) and sits in the proxy's constructor args, hence in the initcode hash.
#    Measured with the same salt and no broadcast — sender 0x1804c8AB… nonce 0 gave impl
#    0x5b73C549… and proxy 0x8c8A794e…; sender 0x1111…1111 nonce 0 gave impl 0x8F7a45eB… and
#    proxy 0x45a60b9e…. Both reproduce exactly through the line below. So the record's `deployer`
#    is an audit-trail field, not an input here — and because the NONCE is in it too, a dry run's
#    addresses do not predict a broadcast's even from the same key.
#
#    `cast create2 --deployer --salt --init-code-hash` exists on the pinned build
#    (forge/cast 1.2.1-nightly 7e68208e) and is checked against EIP-1014 vector 0
#    (CREATE2(0x0, 0x0, keccak(0x)) = 0xE33C0C7F7df4809055C3ebA6c09CFe4BaF1BD9e0), so the shell
#    fallback keccak256(0xff ++ deployer ++ salt ++ initCodeHash)[12:] is not needed.
CREATE2_DEPLOYER=$(jq -r '.create2Deployer // "0x4e59b44847b379578588920ca78fbf26c0b4956c"' "$REC")
dep=$(jq -r '.deployer // empty' "$REC")
[ -n "$dep" ] || fail "the record has no \`deployer\` field — it predates the CREATE2 check. Regenerate it."
if [ "$(lc "$dep")" = "0x0000000000000000000000000000000000000000" ]; then
  fail "the record has no deployer. Fill it from the deploy transaction's \`from\`, then re-run."
fi
[ "$(cast code "$CREATE2_DEPLOYER" --rpc-url "$RPC")" != "0x" ] \
  || fail "no code at the CREATE2 deployer $CREATE2_DEPLOYER on chain $CHAIN_ID — every salted proxy in this record was created by it, so the record cannot be right"
for c in X402Config X402Stake X402Escrow; do
  proxy=$(jq -er ".contracts.\"$c\".proxy" "$REC")
  salt=$(jq -er ".contracts.\"$c\".salt" "$REC")
  args=$(jq -er ".contracts.\"$c\".initializerArgs" "$REC")
  [ "$args" != "0x" ] || fail "$c has no initializerArgs in the record, so its proxy address cannot be reproduced. Fill it from the deploy (it is abi.encodeCall(initialize, ...)), then re-run."
  init=$(cast keccak "$(cast concat-hex \
      "$($FORGE inspect ERC1967Proxy bytecode | tr -d '\n')" \
      "$(cast abi-encode 'constructor(address,bytes)' \
          "$(jq -er ".contracts.\"$c\".implementation" "$REC")" "$args")")")
  want=$(cast create2 --deployer "$CREATE2_DEPLOYER" --salt "$salt" --init-code-hash "$init")
  [ "$(lc "$want")" = "$(lc "$proxy")" ] || fail \
    "$c proxy is not CREATE2(deployer=$CREATE2_DEPLOYER, salt=$salt, initcode over implementation+initializerArgs) — computed $want, record says $proxy"
done
echo "CREATE2 reproduction OK for all three proxies (arithmetic, no chain read)"

for c in X402Config X402Stake X402Escrow; do
  proxy=$(jq -er ".contracts.\"$c\".proxy" "$REC")
  impl=$(jq -er ".contracts.\"$c\".implementation" "$REC")
  want=$(jq -er ".contracts.\"$c\".implementationRuntimeKeccak" "$REC")

  # 2. The proxy points at the implementation the record names. THE upgrade check: an upgrade
  #    nobody recorded shows up here and nowhere else.
  live=$(cast parse-bytes32-address "$(cast storage "$proxy" "$SLOT" --rpc-url "$RPC")")
  [ "$(lc "$live")" = "$(lc "$impl")" ] || fail "$c implementation slot ($live != $impl)"

  # 3. That implementation's runtime bytecode is the one CI built, immutables masked (above).
  got=$(cast keccak "$(masked_code "$c" "$impl")")
  [ "$(lc "$got")" = "$(lc "$want")" ] || fail "$c implementation bytecode ($got != $want)"

  # 4. The proxy has code at all.
  [ "$(cast code "$proxy" --rpc-url "$RPC")" != "0x" ] || fail "$c proxy has no code"

done

cfg=$(jq -er '.contracts.X402Config.proxy' "$REC")
stk=$(jq -er '.contracts.X402Stake.proxy'  "$REC")
esc=$(jq -er '.contracts.X402Escrow.proxy' "$REC")
ast=$(jq -er '.asset.address' "$REC")

[ "$(lc "$(cast call "$esc" 'CONFIG()(address)' --rpc-url "$RPC")")" = "$(lc "$cfg")" ] || fail "escrow.CONFIG"
[ "$(lc "$(cast call "$stk" 'CONFIG()(address)' --rpc-url "$RPC")")" = "$(lc "$cfg")" ] || fail "stake.CONFIG"
[ "$(lc "$(cast call "$esc" 'STAKE()(address)'  --rpc-url "$RPC")")" = "$(lc "$stk")" ] || fail "escrow.STAKE"
[ "$(lc "$(cast call "$esc" 'ASSET()(address)'  --rpc-url "$RPC")")" = "$(lc "$ast")" ] || fail "escrow.ASSET"
[ "$(lc "$(cast call "$stk" 'ASSET()(address)'  --rpc-url "$RPC")")" = "$(lc "$ast")" ] || fail "stake.ASSET"
[ "$(cast call "$ast" 'decimals()(uint8)' --rpc-url "$RPC")" = "6" ] || fail "asset decimals"
[ "$(cast code "$ast" --rpc-url "$RPC")" != "0x" ] || fail "the settlement asset has NO CODE"

# The admin the record names still holds the key — which under D-1 is also the upgrade authority
# of all three. A handover nobody recorded shows up here.
adm=$(jq -er '.admin' "$REC")
[ "$(lc "$(cast call "$cfg" 'admin()(address)' --rpc-url "$RPC")")" = "$(lc "$adm")" ] || fail "config.admin"

# Read from the PROXY, which is the `verifyingContract` every voucher names. If an upgrade ever
# moved this, every outstanding voucher is already dead — see Upgrade.t.sol (d).
for c in X402Escrow X402Stake; do
  a=$(jq -er ".contracts.\"$c\".proxy" "$REC")
  w=$(jq -er ".domainSeparators.\"$c\"" "$REC")
  g=$(cast call "$a" 'DOMAIN_SEPARATOR()(bytes32)' --rpc-url "$RPC")
  [ "$(lc "$g")" = "$(lc "$w")" ] || fail "$c DOMAIN_SEPARATOR ($g != $w)"
done

echo "deployment $CHAIN_ID verified against $REC (implementation slot, bytecode, function surface, wiring, admin, domains, CREATE2 reproduction)"
