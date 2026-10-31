#!/usr/bin/env bash
# Portability probe, CI only: the same sources compile for an EVM without PUSH0 (`paris`) and stay
# under the size gates there. It never changes production bytecode — the deployed build is the
# default profile (`shanghai`), and this one writes to its own `out-paris/` and `cache-paris/`.
# Its purpose is to keep a pre-Shanghai chain a build-profile change rather than a code change.
set -euo pipefail
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE"
FORGE="${FORGE:-forge}"
export FOUNDRY_PROFILE=paris
$FORGE build --skip test --skip script >/dev/null
rc=0
for c in AssayConfig AssayEscrow AssayEscrowExtension AssayStake ChannelDoor; do
  runtime=$(jq -r '.deployedBytecode.object' "out-paris/$c.sol/$c.json" 2>/dev/null \
    || jq -r '.deployedBytecode.object' "out-paris/$(basename "$(dirname "$(find out-paris -name "$c.json" | head -1)")")/$c.json")
  n=$(( (${#runtime} - 2) / 2 ))
  printf '%-20s paris runtime %6d bytes\n' "$c" "$n"
  [ "$n" -le 23000 ] || { echo "  OVER the 23000-byte gate on paris"; rc=1; }
done
[ $rc -eq 0 ] && echo "paris OK"
exit $rc
