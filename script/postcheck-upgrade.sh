#!/usr/bin/env bash
# ON-CHAIN post-check of an upgrade (runbook §7 post-checks). Read-only: `cast call`
# and `cast storage` only, nothing is signed or sent.
#
# Why it exists: `forge script` runs a script's own post-checks in its local SIMULATION before it
# broadcasts, so the asserts in UpgradeByOwner.s.sol prove the
# simulation, not the chain. Each upgrade is its own transaction, so a broadcast can land partly.
# This reads what actually landed.
#
# Env (all addresses; case does not matter):
#   RPC                              the chain to read
#   PROXY_CONFIG PROXY_STAKE PROXY_ESCROW
#   IMPL_CONFIG IMPL_STAKE IMPL_ESCROW   (each optional) the implementation each slot must hold
#   EXPECTED_OWNER                    (optional) config.owner()
#   EXPECTED_PENDING_OWNER            (optional) config.pendingOwner(); 0x0…0 for "none"
#   EXPECTED_SLASH_DELAY              (optional) config.slashDelaySeconds(); 259200 until the
#                                     admin sets one
#   EXPECTED_ARBITER                  (optional) config.arbiter(); 0x0…0 for "none"
#   EXPECTED_COLLECT_HOLD             (optional) config.collectHoldSeconds(); 3600 until the
#                                     admin sets one
#   EXPECTED_TOTAL_HELD               (optional) escrow.totalHeld(); 0 right after that upgrade
#
# Exit 0 when every check given holds; non-zero naming the first that does not.
set -euo pipefail
export PATH="${FOUNDRY_BIN:-$HOME/.foundry/bin}:$PATH"
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1

SLOT=0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc
lc() { echo "$1" | tr 'A-Z' 'a-z'; }
fail() { echo "  FAIL  $*"; exit 1; }
pass() { echo "  PASS  $*"; }
: "${RPC:?RPC is required}"

for name in CONFIG STAKE ESCROW; do
  proxy_var="PROXY_$name"; impl_var="IMPL_$name"
  proxy="${!proxy_var:?$proxy_var is required}"
  want="${!impl_var:-}"
  live="0x$(cast storage --rpc-url "$RPC" "$proxy" "$SLOT" | tail -c 41)"
  if [ -n "$want" ]; then
    [ "$(lc "$live")" = "$(lc "$want")" ] || fail "$name implementation slot is $live, want $want"
    pass "$name implementation slot = $want"
  else
    echo "  ----  $name implementation slot = $live (not checked)"
  fi
done

if [ -n "${EXPECTED_OWNER:-}" ]; then
  got=$(cast call --rpc-url "$RPC" "$PROXY_CONFIG" 'owner()(address)') || fail "config has no owner() — the Config upgrade did not land"
  [ "$(lc "$got")" = "$(lc "$EXPECTED_OWNER")" ] || fail "config.owner() is $got, want $EXPECTED_OWNER"
  pass "config.owner() = $got"
fi
if [ -n "${EXPECTED_PENDING_OWNER:-}" ]; then
  got=$(cast call --rpc-url "$RPC" "$PROXY_CONFIG" 'pendingOwner()(address)')
  [ "$(lc "$got")" = "$(lc "$EXPECTED_PENDING_OWNER")" ] || fail "config.pendingOwner() is $got, want $EXPECTED_PENDING_OWNER"
  pass "config.pendingOwner() = $got"
fi
if [ -n "${EXPECTED_SLASH_DELAY:-}" ]; then
  got=$(cast call --rpc-url "$RPC" "$PROXY_CONFIG" 'slashDelaySeconds()(uint64)') || fail "config has no slashDelaySeconds() — the dispute upgrade of Config did not land"
  [ "${got%% *}" = "$EXPECTED_SLASH_DELAY" ] || fail "config.slashDelaySeconds() is $got, want $EXPECTED_SLASH_DELAY"
  pass "config.slashDelaySeconds() = $got"
fi
if [ -n "${EXPECTED_ARBITER:-}" ]; then
  got=$(cast call --rpc-url "$RPC" "$PROXY_CONFIG" 'arbiter()(address)') || fail "config has no arbiter()"
  [ "$(lc "$got")" = "$(lc "$EXPECTED_ARBITER")" ] || fail "config.arbiter() is $got, want $EXPECTED_ARBITER"
  pass "config.arbiter() = $got"
fi
if [ -n "${EXPECTED_COLLECT_HOLD:-}" ]; then
  got=$(cast call --rpc-url "$RPC" "$PROXY_CONFIG" 'collectHoldSeconds()(uint64)') || fail "config has no collectHoldSeconds() — the hold upgrade of Config did not land"
  [ "${got%% *}" = "$EXPECTED_COLLECT_HOLD" ] || fail "config.collectHoldSeconds() is $got, want $EXPECTED_COLLECT_HOLD"
  pass "config.collectHoldSeconds() = $got"
fi
if [ -n "${EXPECTED_TOTAL_HELD:-}" ]; then
  got=$(cast call --rpc-url "$RPC" "$PROXY_ESCROW" 'totalHeld()(uint128)') || fail "escrow has no totalHeld() — the hold upgrade of Escrow did not land"
  [ "${got%% *}" = "$EXPECTED_TOTAL_HELD" ] || fail "escrow.totalHeld() is $got, want $EXPECTED_TOTAL_HELD"
  pass "escrow.totalHeld() = $got"
fi
echo "  on-chain post-check passed"
