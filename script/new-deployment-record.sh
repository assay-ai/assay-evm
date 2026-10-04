#!/usr/bin/env bash
# usage: new-deployment-record.sh <chainId> <rpc-url>
#
# Emits `deployments/<chainId>.json` with everything this repo can determine on its own —
# the commit, the compiler settings, the asset, the three implementation bytecode hashes, the
# three CREATE2 salts — and leaves the six addresses and two domain separators as `0x…`
# placeholders for the operator to paste from `Deploy.s.sol`'s output (runbook §5).
#
# **It refuses to emit a MAINNET record without an operator-supplied USDG address.**
# `docs/chain-facts.md` §1 measured that mainnet USDG is not at the testnet address —
# `cast code 0x915Ef7…03ec` on 4663 returns `0x` while the same call on 46630 returns code, so
# the probe works and the absence is real. The mainnet address is an input this repo cannot
# derive, and the specific mistake it guards is an operator pasting the testnet address into a
# mainnet deploy. Nothing downstream would notice: `X402Escrow.initialize` calls `decimals()` on
# it, a call to an address with no code returns empty rather than reverting, and the failure
# surfaces as an ABI decode error naming neither the address nor the network.
set -euo pipefail
export PATH="${FOUNDRY_BIN:-$HOME/.foundry/bin}:$PATH"
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE"
FORGE="${FORGE:-forge}"
CHAIN_ID="${1:?usage: new-deployment-record.sh <chainId> <rpc-url>}"
RPC="${2:?usage: new-deployment-record.sh <chainId> <rpc-url>}"

# git cannot track an empty directory, so a fresh
# clone has neither until something makes them. Both carry a `.gitkeep` for that reason and this
# line is the belt.
mkdir -p deployments snapshots

TESTNET_USDG=0x915Ef7c9F9f80a69e3BE47A38EE0Bb47607103ec
ASSET="${USDG_ADDRESS:-}"

if [ "$CHAIN_ID" = "4663" ]; then
  if [ -z "$ASSET" ]; then
    echo "REFUSED: a mainnet record needs USDG_ADDRESS, and this repo cannot derive it."
    echo "  Mainnet USDG is NOT at the testnet address (docs/chain-facts.md §1: cast code on"
    echo "  4663 returns 0x, and the same call on 46630 returns code, so the probe works)."
    echo "  Get it from docs.robinhood.com or from Paxos, verify it on the explorer, and pass it:"
    echo "    USDG_ADDRESS=0x… ./script/new-deployment-record.sh 4663 <rpc>"
    exit 1
  fi
  if [ "$(echo "$ASSET" | tr 'A-Z' 'a-z')" = "$(echo "$TESTNET_USDG" | tr 'A-Z' 'a-z')" ]; then
    echo "REFUSED: that is the TESTNET USDG address. There is no code at it on 4663."
    exit 1
  fi
elif [ -z "$ASSET" ]; then
  ASSET="$TESTNET_USDG"
fi

# The asset is probed over RPC in every case, mainnet or not: a record naming an address with no
# code is a record that verifies against nothing.
CODE=$(cast code "$ASSET" --rpc-url "$RPC")
[ "$CODE" != "0x" ] || { echo "REFUSED: no code at $ASSET on chain $CHAIN_ID"; exit 1; }
DEC=$(cast call "$ASSET" 'decimals()(uint8)' --rpc-url "$RPC")
[ "$DEC" = "6" ] || { echo "REFUSED: $ASSET decimals() is $DEC, not 6"; exit 1; }
SYM=$(cast call "$ASSET" 'symbol()(string)' --rpc-url "$RPC" | tr -d '"')
[ "$(cast chain-id --rpc-url "$RPC")" = "$CHAIN_ID" ] || { echo "REFUSED: the RPC is not chain $CHAIN_ID"; exit 1; }

$FORGE build >/dev/null
kc() { cast keccak "$($FORGE inspect "$1" deployedBytecode | tr -d '\n')"; }

# The function surface, recorded per contract so that an upgrade cannot change it silently.
# `script/abi-surface.sh` carries the argument for why this is here and what it cannot see.
# shellcheck source=script/abi-surface.sh
. "$HERE/script/abi-surface.sh"

# `Deploy._salt` is `keccak256(abi.encodePacked("x402:", name, ":v2:", block.chainid))`, and
# `block.chainid` is a `uint256` — so it contributes THIRTY-TWO BIG-ENDIAN BYTES, not the decimal
# string. Spelling it as `printf 'x402:%s:v2:%s' "$name" "$CHAIN_ID" | cast from-utf8 | cast keccak`
# gives a different hash and would put a salt in the record that the script never used.
# `test_theSaltFormulaMatchesTheOneTheShellScriptComputes` pins both spellings against each other.
salt() {
  cast keccak "$(cast concat-hex "$(cast from-utf8 "x402:$1:v2:")" "$(cast to-uint256 "$CHAIN_ID")")"
}

# HERE is this repository's root. Resolving one directory higher would stamp the record with the
# commit of whatever repository contains this one, which is not the commit that built it.
COMMIT=$(git -C "$HERE" rev-parse HEAD)
OUT="deployments/$CHAIN_ID.json"

# The DEPLOYER is part of the addresses, not just of the history — but NOT the way it looks.
#
# `Deploy.s.sol` creates each proxy with `new ERC1967Proxy{salt: _salt(name)}(...)` inside
# `vm.startBroadcast()`, and forge routes a salted creation through the DETERMINISTIC CREATE2
# DEPLOYER `0x4e59b44847b379578588920ca78fbf26c0b4956c` (transactionType CREATE2, `to` set to it,
# calldata = salt ++ initcode). Measured 2026-09-10 from the dry run's broadcast file; the
# deployer has 69 bytes of code on BOTH 4663 and 46630. So the CREATE2 deployer is a constant and
# the proxy address is **not** keccak(0xff ++ signing-EOA ++ salt ++ ...).
#
# It still depends on the signing key, one level down. The IMPLEMENTATION is a plain `CREATE` from
# the EOA — `CREATE(from, nonce)` — and its address is a constructor argument of the proxy, so it
# is inside the initcode, so it is inside the initcode hash. Measured, same salt, no broadcast:
#
#   sender 0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38 nonce 0
#       X402Config impl 0x5b73C5498c1E3b4dbA84de0F1833c4a029d90519
#       X402Config proxy 0x8c8A794e48B23Cfd23a7eE6365f89E4EE0571e6f
#   sender 0x1111111111111111111111111111111111111111 nonce 0
#       X402Config impl 0x8F7a45eBDe059392E46A46DCc14AB24681A961Ea
#       X402Config proxy 0x45a60b9e5647d2b976a28EEB702563e10e650da7
#
# **So the address depends on the key AND ITS NONCE**, which is strictly more fragile than
# "salt + deployer": the dry run signs from nonce 0 and a real key will not, so a dry run's
# addresses do not predict a broadcast's even from the same key.
#
# This field is the audit trail — who signed, and therefore which nonce sequence produced the
# three implementations. It is NOT an input to the address arithmetic; `verify-deployment.sh`
# check 1 recomputes each proxy from the recorded `implementation`, `initializerArgs` and `salt`
# against the constant deterministic deployer, which is the comparison that can actually fail.
# It is emitted as the zero address, like the six addresses and the two domain separators, and
# that check refuses a record still carrying the placeholder.
[ -e "$OUT" ] && { echo "REFUSED: $OUT already exists. Edit it, or move it aside deliberately."; exit 1; }

cat > "$OUT" <<JSON
{
  "chainId": $CHAIN_ID,
  "commit": "$COMMIT",
  "solc": "0.8.24",
  "settings": { "viaIr": true, "optimizerRuns": 200, "evmVersion": "shanghai", "bytecodeHash": "none" },
  "asset": { "address": "$ASSET", "symbol": "$SYM", "decimals": 6 },
  "permit2": "0x000000000022D473030F116dDEE9F6B43aC78BA3",
  "admin": "0x0000000000000000000000000000000000000000",
  "deployer": "0x0000000000000000000000000000000000000000",
  "create2Deployer": "0x4e59b44847b379578588920ca78fbf26c0b4956c",
  "contracts": {
    "X402Config": {
      "proxy": "0x0000000000000000000000000000000000000000",
      "implementation": "0x0000000000000000000000000000000000000000",
      "implementationRuntimeKeccak": "$(kc X402Config)",
      "abiKeccak": "$(abi_hash X402Config)",
      "abiFunctions": [
$(abi_json_entries X402Config)
      ],
      "salt": "$(salt Config)",
      "initializerArgs": "0x"
    },
    "X402Stake": {
      "proxy": "0x0000000000000000000000000000000000000000",
      "implementation": "0x0000000000000000000000000000000000000000",
      "implementationRuntimeKeccak": "$(kc X402Stake)",
      "abiKeccak": "$(abi_hash X402Stake)",
      "abiFunctions": [
$(abi_json_entries X402Stake)
      ],
      "salt": "$(salt Stake)",
      "initializerArgs": "0x"
    },
    "X402Escrow": {
      "proxy": "0x0000000000000000000000000000000000000000",
      "implementation": "0x0000000000000000000000000000000000000000",
      "implementationRuntimeKeccak": "$(kc X402Escrow)",
      "abiKeccak": "$(abi_hash X402Escrow)",
      "abiFunctions": [
$(abi_json_entries X402Escrow)
      ],
      "salt": "$(salt Escrow)",
      "initializerArgs": "0x"
    }
  },
  "domainSeparators": {
    "X402Escrow": "0x0000000000000000000000000000000000000000000000000000000000000000",
    "X402Stake":  "0x0000000000000000000000000000000000000000000000000000000000000000"
  },
  "status": "pending-deploy"
}
JSON
echo "wrote $OUT (status: pending-deploy)"
echo "Fill the six addresses, the admin, the DEPLOYER (the deploy transaction's \`from\`) and the"
echo "two domain separators from Deploy.s.sol's output,"
echo "flip .status to \"deployed\", then: ./script/verify-deployment.sh $CHAIN_ID $RPC"
