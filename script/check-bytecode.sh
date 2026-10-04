#!/usr/bin/env bash
# Implementation-bytecode AND function-surface drift gate. A source change that alters the deployed bytecode of an
# IMPLEMENTATION must be a deliberate decision — under D-1 that decision is normally an
# UPGRADE (`upgradeToAndCall` from the Ledger, runbook §7) and occasionally a redeploy.
# Set "status": "pending-deploy" in the record to acknowledge an intended change; the record's
# `implementation` + `implementationRuntimeKeccak` are rewritten once it has been applied.
# The ERC1967Proxy is not compared: its bytecode is OpenZeppelin's and check-vendor.sh owns it.
#
# Reports "skipping" while no record has "status": "deployed", and prints nothing to check when
# there is no deployments/ directory at all (none is published in this repository). That is
# correct, not a failure.
#
# The loop below was made to fail on both of its questions against a locally flipped record — a
# mutated runtime hash, and `setAdminUnchecked(address)` appended to X402Config. A record is
# written at "pending-deploy" because a record must not claim a deployment that does not exist;
# docs/ci-gates.md §6 carries both outputs.
set -euo pipefail
export PATH="${FOUNDRY_BIN:-$HOME/.foundry/bin}:$PATH"
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE"
FORGE="${FORGE:-forge}"
# shellcheck source=script/abi-surface.sh
. "$HERE/script/abi-surface.sh"
rc=0
found=0
for rec in deployments/*.json; do
  [ -e "$rec" ] || continue
  found=1
  if [ "$(jq -er '.status' "$rec")" != "deployed" ]; then
    echo "skipping $rec (status: $(jq -er '.status' "$rec"))"
    continue
  fi
  for c in X402Config X402Stake X402Escrow; do
    want=$(jq -er ".contracts.\"$c\".implementationRuntimeKeccak" "$rec")
    # `cast keccak` reading the bytecode from a PIPE fails — the trailing newline makes it
    # "Error: odd number of digits", and under `set -euo pipefail` that aborted the whole gate.
    # It was never noticed because no record had reached `"status": "deployed"`, so the loop this
    # line is in had never run. `tr -d '\n'` and the argument form, as new-deployment-record.sh
    # already spells it.
    got=$(cast keccak "$($FORGE inspect "$c" deployedBytecode | tr -d '\n')")
    if [ "$got" != "$want" ]; then
      echo "implementation bytecode drift in $c vs $rec"
      echo "  built  $got"
      echo "  record $want"
      echo "  -> this is an UPGRADE (runbook §7) or a redeploy. Say which in .status."
      rc=1
    fi
    # The function surface, separately, because it answers a different question. Bytecode drift
    # says "the code changed"; surface drift says "the code changed SHAPE", and only the second
    # can hand a live proxy a door that was never reviewed. A record written before
    # `abiKeccak` existed has no field to compare and is skipped by name rather than silently.
    wantAbi=$(jq -r ".contracts.\"$c\".abiKeccak // empty" "$rec")
    if [ -z "$wantAbi" ]; then
      echo "$rec has no abiKeccak for $c — record predates the surface gate; regenerate it"
      rc=1
    else
      gotAbi=$(abi_hash "$c")
      if [ "$gotAbi" != "$wantAbi" ]; then
        echo "function surface drift in $c vs $rec"
        echo "  built  $gotAbi"
        echo "  record $wantAbi"
        echo "  -> a function was ADDED or REMOVED. ./script/verify-deployment.sh names which."
        rc=1
      fi
    fi
  done
done
[ $found -eq 0 ] && echo "no deployment records yet — nothing to compare (expected before the first deploy)"
[ $rc -eq 0 ] && echo "bytecode OK"
exit $rc
