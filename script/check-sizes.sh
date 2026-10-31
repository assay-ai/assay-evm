#!/usr/bin/env bash
# EIP-170 caps DEPLOYED (runtime) code at 24,576 bytes, per IMPLEMENTATION — the ERC1967Proxy in
# front of it is ~50 bytes of runtime and irrelevant to the limit. The gate fires at 23,000 so it
# goes off before a deploy — or an UPGRADE — does, leaving room for the auditor's remediation
# round. It must be green before every upgrade, not only before the first deploy: an upgrade that
# pushes an implementation over the hard limit fails at deploy time, which is a good place to fail,
# and this is what makes it fail in CI instead.
#
# **It measures `deployedBytecode`, not `bytecode`.** An earlier version measured
# `forge inspect <c> bytecode`, which is the CREATION bytecode — constructor plus the runtime it
# returns. That is the wrong number twice over: EIP-170 bounds the runtime half only, and the two
# differ by 1,433 bytes on AssayEscrow and AssayStake here (constructor code plus the EIP-712
# ShortString immutables). Gating on the larger figure would fire early and, worse, would teach a
# reader that the limit applies to creation code. Creation size is printed beside it as
# information — EIP-3860's initcode limit is 49,152 and nothing here is near it.
set -euo pipefail
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE"
FORGE="${FORGE:-forge}"
CEILING=23000
HARD=24576
rc=0
$FORGE build >/dev/null
# ChannelDoor is the escrow's external library: deployed on its own, so bounded on its own.
# AssayEscrowExtension is reached by the escrow's fallback (D-29): deployed on its own, bounded on
# its own. The escrow's CREATION code carries the extension's (its constructor creates it), so
# that one is held under EIP-3860's 49,152-byte initcode limit below.
for c in AssayConfig AssayEscrow AssayEscrowExtension AssayStake ChannelDoor; do
  runtime=$($FORGE inspect "$c" deployedBytecode | tr -d '\n' | sed 's/^0x//' | wc -c | awk '{print int($1/2)}')
  creation=$($FORGE inspect "$c" bytecode        | tr -d '\n' | sed 's/^0x//' | wc -c | awk '{print int($1/2)}')
  printf '%-20s runtime %6d bytes  (%5.1f%% of the %d hard limit)   creation %6d\n' \
    "$c" "$runtime" "$(echo "$runtime $HARD" | awk '{print $1*100/$2}')" "$HARD" "$creation"
  if [ "$runtime" -gt "$CEILING" ]; then
    echo "  OVER the $CEILING-byte gate (EIP-170 hard limit is $HARD)"
    echo "  -> do NOT raise the gate. Split the contract, and say so in the PR description."
    rc=1
  fi
done
INITCODE=49152
# The escrow's creation code is core + extension, so it grows with both halves. The gate fires at
# 45,000 for the same reason the runtime gate fires at 23,000: before the hard limit does.
INIT_CEILING=45000
escrowInit=$($FORGE inspect AssayEscrow bytecode | tr -d '\n' | sed 's/^0x//' | wc -c | awk '{print int($1/2)}')
printf '%-20s creation %6d bytes (gate %d, EIP-3860 limit %d)\n' AssayEscrow "$escrowInit" "$INIT_CEILING" "$INITCODE"
if [ "$escrowInit" -gt "$INIT_CEILING" ]; then
  echo "AssayEscrow creation code is $escrowInit bytes, over the $INIT_CEILING-byte gate (EIP-3860 limit $INITCODE; it carries the extension's)"
  rc=1
fi
[ $rc -eq 0 ] && echo "sizes OK"
exit $rc
