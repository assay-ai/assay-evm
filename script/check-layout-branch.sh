#!/usr/bin/env bash
# The upgrade-safety gate, asked at BRANCH level instead of commit level.
#
# `check-layout.sh` compares the working tree's snapshot with the working tree's source, so one
# commit can move both together and a branch can append twice — each append legal against the
# snapshot as it stood — and land a net layout that no single comparison ever refused. That is
# the exact shape of the failure that left 41 SlashRecord accounts unreadable on the Solana
# devnet after an unchecked layout change, and here the money is INSIDE the contract.
#
# `check-layout.py` exits 0 for identical, 2 for a legal append and 1 for a refusal, and ONLY the
# refusal is the branch-level question. The per-commit script stays exactly as it is; the two
# answer different questions and both are wanted.
#
# **The exit code is read, not tested for truthiness.** The design this was written from spelled
# the check `python3 script/check-layout.py … || { echo "not an append"; }` and claimed the `||`
# "catches only the refusal". It does not: shell `||` and `if !` fire on ANY non-zero status, so
# exit 2 — a LEGAL APPEND, the ordinary case on any upgrade branch — was refused too. Measured
# 2026-09-10 on a probe branch carrying one appended `uint256` on X402Stake: the classifier
# returned 2 and this gate printed "the BRANCH is not an append against the merge base". A gate
# that refuses the change it exists to permit is a gate somebody switches off, and it is a gate
# answering a different question from the one its name asks. An unrecognised exit
# code fails CLOSED, because a classifier that has started answering a fourth thing is not a
# classifier this gate may pass over.
#
# usage: check-layout-branch.sh [base-ref]      default base: origin/main
set -euo pipefail
export PATH="${FOUNDRY_BIN:-$HOME/.foundry/bin}:$PATH"
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE"
FORGE="${FORGE:-forge}"
BASE_REF="${1:-origin/main}"

BASE=$(git merge-base "$BASE_REF" HEAD) || {
  echo "REFUSED: no merge base with $BASE_REF. Fetch it — a stale local ref becomes a COMMITTED"
  echo "         claim about which commit this branch is measured against."
  exit 1
}
echo "classifying against merge base $BASE ($BASE_REF)"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
rm -rf out cache && "$FORGE" build >/dev/null
rc=0
for c in X402Config X402Escrow X402Stake; do
  # Paths are relative to THIS repository's root. Older history of these contracts kept
  # them under an `evm/` subdirectory, where a snapshot path carried an `evm/` prefix; it does
  # not now. Re-adding it makes every lookup miss silently — the loop below
  # reports "NEW on this branch, nothing to compare" for all three contracts and exits 0,
  # so the gate passes having checked nothing.
  if ! git show "$BASE:snapshots/$c.storage.json" > "$TMP/$c.base.json" 2>/dev/null; then
    echo "$c: no snapshot at the merge base — this contract is NEW on this branch, nothing to compare"
    continue
  fi
  "$FORGE" inspect "$c" storageLayout --json > "$TMP/$c.head.json"
  set +e
  out=$(python3 script/check-layout.py "$TMP/$c.base.json" "$TMP/$c.head.json")
  verdict=$?
  set -e
  [ -n "$out" ] && echo "$out"
  case $verdict in
    0) echo "$c: identical to the merge base" ;;
    2) echo "$c: APPEND-ONLY against the merge base — an upgrade, allowed" ;;
    1) echo "$c: the BRANCH is not an append against the merge base."
       echo "     A redeploy, not an upgrade (docs/deploy-runbook.md §7, last paragraph)."
       rc=1 ;;
    *) echo "$c: check-layout.py exited $verdict, which is none of 0/1/2. Failing CLOSED."
       rc=1 ;;
  esac
done
[ $rc -eq 0 ] && echo "branch layout OK (append-only against $BASE)"
exit $rc
