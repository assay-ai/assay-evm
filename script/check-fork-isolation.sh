#!/usr/bin/env bash
# Gate 9. Two properties, both of which have already been got wrong elsewhere in this repo.
#
# 1. A bare `forge test` is OFFLINE. Every contract under test/fork/ must SKIP when
#    RH_TESTNET_RPC is unset — not pass, not error, skip, and say so.
# 2. `.gas-snapshot` contains NO fork row. A fork run has no pinned block (chain-facts.md §6), so
#    its gas figures move between runs; one row of it in the snapshot makes gate 8 red at random,
#    which is the one thing worse than a gate that is red for a real reason.
#
# ## Two corrections to the design this was written from, both measured
#
# **The fork contract names are ENUMERATED FROM THE SOURCE, not matched by prefix.** The original
# design grepped `^Fork[A-Za-z0-9]*Test:`. That catches `ForkEscrowDepositTest` and misses
# `BlocklistAccountingForkTest` and `Permit2ForkTest` — two of the fork contracts this repo
# actually has. A gate that silently covers a subset of what its name claims is a known
# failure mode: green while answering a narrower question than its name claims. Reading the
# names out of
# `test/fork/*.sol` covers every contract that exists and every one added later, and it cannot
# drift out of step with the directory.
#
# **A skipped test DOES emit a snapshot row.** `forge snapshot` writes
# `ForkFactsTest:setUp() (gas: 0)` for a contract whose `setUp` calls `vm.skip(true)`. So gate 8
# carries `--no-match-path "test/fork/*"` (ci-gates.md §8), and this gate is the assertion that
# the flag did its job — a filter and a check on the filter, not two mechanisms doing one job.
set -euo pipefail
export PATH="${FOUNDRY_BIN:-$HOME/.foundry/bin}:$PATH"
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE"
FORGE="${FORGE:-forge}"

# --- the fork contracts, read from the source -------------------------------------------------
# `abstract contract ForkFixture` is deliberately not matched: an abstract contract is never
# instantiated and never produces a snapshot row.
names=$(grep -hoE '^contract[[:space:]]+[A-Za-z0-9_]+' test/fork/*.sol 2>/dev/null | awk '{print $2}' | sort -u || true)
if [ -z "$names" ]; then
  echo "FAIL: test/fork/ declares no concrete contract. Either the directory is empty — in which"
  echo "      case delete this gate rather than let it pass over nothing — or the enumeration"
  echo "      below stopped matching and this gate has been checking an empty list."
  exit 1
fi
echo "fork contracts under test/fork/: $(echo "$names" | tr '\n' ' ')"

# --- 1. no fork row in .gas-snapshot ----------------------------------------------------------
bad=""
while read -r n; do
  [ -n "$n" ] || continue
  if grep -qE "^${n}:" .gas-snapshot; then
    bad="$bad $n"
  fi
done <<< "$names"
if [ -n "$bad" ]; then
  echo "FAIL: .gas-snapshot carries fork rows for:$bad"
  echo "      A fork run has no pinned block, so those figures move between runs. Regenerate with"
  echo "      the fork suite excluded:  rm -rf out cache && forge build &&"
  echo "                                forge snapshot --no-match-path \"test/fork/*\""
  while read -r n; do
    [ -n "$n" ] || continue
    grep -nE "^${n}:" .gas-snapshot | head -3
  done <<< "$names"
  exit 1
fi

# --- 2. offline, every fork test skips --------------------------------------------------------
# `|| true` is load-bearing. Under `set -e` a non-zero `forge test` would abort the script AT the
# assignment, giving exit 1 with NO message — which is a gate that is right by accident and tells
# nobody why. This gate's job is to CLASSIFY forge's output, so it must survive forge failing.
out=$(env -u RH_TESTNET_RPC "$FORGE" test --match-path "test/fork/*" 2>&1 || true)
if echo "$out" | grep -qE '^\[FAIL'; then
  echo "FAIL: a fork test FAILED with RH_TESTNET_RPC unset. Offline it must SKIP, not run and lose."
  echo "$out" | grep -E '^\[FAIL' | head -5
  exit 1
fi
if echo "$out" | grep -qE '^\[PASS\]'; then
  echo "FAIL: a fork test RAN with RH_TESTNET_RPC unset. It reached the network from a gate that"
  echo "      is supposed to be offline, or it asserts something without the fork and should not."
  echo "$out" | grep -E '^\[PASS\]' | head -5
  exit 1
fi
# `[SKIP: skipped] setUp()` when the skip is in setUp; `[SKIP] test_x()` when it is in a modifier.
# Both spellings start `[SKIP`, and matching on the shorter prefix covers both.
if ! echo "$out" | grep -qE '^\[SKIP'; then
  echo "FAIL: no fork test reported a skip. Either test/fork/ produced no tests — in which case"
  echo "      delete this gate rather than let it pass over nothing — or the skip is not"
  echo "      happening and the offline contract is broken."
  echo "$out" | tail -5
  exit 1
fi

echo "fork isolation OK ($(echo "$out" | grep -cE '^\[SKIP' || true) skipped, 0 passed, no snapshot rows)"
