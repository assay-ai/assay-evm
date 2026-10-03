#!/usr/bin/env bash
# The UPGRADE-SAFETY gate (D-7). These contracts sit behind UUPS proxies (D-1), so
# an upgrade reuses the live storage: a layout change is allowed ONLY if it is append-only,
# and check-layout.py is what decides that. A refusal means the change is a REDEPLOY, not an
# upgrade. (On the Solana side an unchecked layout change left 41 devnet accounts unreadable;
# that is what happens when nothing checks.)
#
# ALL THREE contracts are gated, not only X402Escrow. X402Config is upgradeable too, it holds
# `admin`, and `admin` is the upgrade authority of the other two — leaving the one contract that
# holds the upgrade key outside the gate would be the worst of the three to leave out.
#
#   ./script/check-layout.sh                          check
#   ./script/check-layout.sh --update                 regenerate snapshots — ONLY for a change
#                                                     check-layout.py classifies as identical or
#                                                     append. It refuses anything else.
#   ./script/check-layout.sh --redeploy-not-an-upgrade "<reason>"
#                                                     the loud override: writes a snapshot for a
#                                                     REFUSED layout and records the reason and
#                                                     the refusal text inside it.
#
# **Why `--update` classifies.** The first version of this script copied whatever `forge inspect`
# emitted straight into the snapshot. An illegal reorder plus `--update` in the same commit was
# therefore a green gate, and in the diff it looked exactly like routine snapshot maintenance. A
# flag whose name says "update" must not be able to launder a redeploy; a deliberate redeploy has
# to be spelled out, in a flag nobody types by accident, and leave its reason in the file.
#
# **What this does not cover.** This compares the WORKING TREE's snapshot with
# the working tree's source, so a single commit can move both together. CI must compare the new
# layout against the snapshot at the MERGE BASE, not at HEAD, or `--update` and the source edit
# still travel as one reviewed-looking change. `script/check-layout-branch.sh` is that check.
#
# **Build from a CLEAN `out/`.** The byte comparison below is sensitive to
# build *incrementality*, not only to source changes. `forge inspect` stamps astIds, and a
# partially rebuilt `out/` can renumber them with no source edit at all — so an UNCHANGED tree can
# be told `snapshot is byte-stale — refresh with --update`. Measured in a
# scratch copy whose `out/` had been through a partial recompile of identical source. Nothing is
# laundered when that happens (classify-before-update still refuses a real reorder), but a gate that cries stale on unchanged source is what teaches
# people to type `--update` without reading the classification — which is exactly the habit
# this gate must not teach. CI must `rm -rf out cache` before running this, and a human seeing "byte-stale" on a tree
# they did not edit should rebuild cleanly rather than reach for the flag.
set -euo pipefail
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE"
FORGE="${FORGE:-forge}"
MODE="${1:-}"
REASON="${2:-}"
if [ "$MODE" = "--redeploy-not-an-upgrade" ] && [ -z "$REASON" ]; then
  echo "--redeploy-not-an-upgrade requires a reason: it is written into the snapshot"; exit 2
fi
TMPD=$(mktemp -d); trap 'rm -rf "$TMPD"' EXIT
rc=0

# `extra_output = ["storageLayout"]` in foundry.toml makes `forge build` emit the layout, so this
# build and the `forge inspect` calls below compile the SAME source set and therefore produce the
# same astIds. Without it `forge inspect` compiles a smaller unit on its own and the snapshots
# read as byte-stale on every run. See foundry.toml for the measurement.
$FORGE build >/dev/null

# Classify $1 (snapshot) against $2 (fresh layout). Echoes the classifier's output; returns its
# verdict: 0 identical, 2 legal append, 1 refused.
classify() {
  set +e
  CLASSIFY_OUT=$(python3 script/check-layout.py "$1" "$2")
  local v=$?
  set -e
  return $v
}

for c in X402Config X402Escrow X402Stake; do
  cur="$TMPD/$c.json"
  snap="snapshots/$c.storage.json"
  if ! $FORGE inspect "$c" storageLayout --json > "$cur" 2>"$TMPD/$c.err"; then
    if [ -f "$snap" ]; then
      echo "$c: NO LAYOUT, but snapshots/$c.storage.json exists — a contract was REMOVED"
    else
      echo "$c: does not exist and has no snapshot"
    fi
    rc=1; continue
  fi

  if [ "$MODE" = "--redeploy-not-an-upgrade" ]; then
    if [ ! -f "$snap" ]; then echo "$c: no snapshot to override"; continue; fi
    classify "$snap" "$cur" && verdict=$? || verdict=$?
    if [ "$verdict" -ne 1 ]; then
      echo "$c: not refused — use --update, the override is for a REFUSED layout only"; continue
    fi
    python3 - "$snap" "$cur" "$REASON" <<'PY'
import json, subprocess, sys, datetime
snap, cur, reason = sys.argv[1], sys.argv[2], sys.argv[3]
refusal = subprocess.run(["python3", "script/check-layout.py", snap, cur],
                         capture_output=True, text=True).stdout.strip().splitlines()
doc = json.load(open(cur))
doc["_redeploy"] = {
    "reason": reason,
    "at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "refusedBecause": refusal,
    "note": "This layout was NOT an append. Every proxy already deployed against the previous "
            "snapshot must be REDEPLOYED; upgrading one to this layout corrupts its storage.",
}
json.dump(doc, open(snap, "w"), indent=2)
PY
    echo "$c: REDEPLOY snapshot written, with the reason and the refusal inside it"
    echo "     reason: $REASON"
    rc=1   # a redeploy is never a green build; it needs a human on the other side of the review
    continue
  fi

  if [ "$MODE" = "--update" ]; then
    if [ ! -f "$snap" ]; then
      cp "$cur" "$snap"; echo "$c: snapshot CREATED (there was none to classify against)"; continue
    fi
    classify "$snap" "$cur" && verdict=$? || verdict=$?
    case $verdict in
      0) cp "$cur" "$snap"; echo "$c: snapshot refreshed (layout unchanged)" ;;
      2) cp "$cur" "$snap"; echo "$c: snapshot updated (append-only change)" ;;
      *) [ -n "$CLASSIFY_OUT" ] && echo "$CLASSIFY_OUT"
         echo "$c: --update REFUSED — this is not an append, and --update will not launder one."
         echo "     If the redeploy is deliberate: ./script/check-layout.sh --redeploy-not-an-upgrade \"<reason>\""
         rc=1 ;;
    esac
    continue
  fi

  [ -f "$snap" ] || { echo "$c: missing snapshot $snap"; rc=1; continue; }

  if diff -q "$snap" "$cur" >/dev/null; then
    echo "$c: layout unchanged"
    continue
  fi

  # The files differ. That is not yet a layout change: `forge inspect` stamps astIds into every
  # entry and into every struct type key, and those move when an unrelated comment moves. Only
  # check-layout.py can tell the three cases apart.
  classify "$snap" "$cur" && verdict=$? || verdict=$?
  [ -n "$CLASSIFY_OUT" ] && echo "$CLASSIFY_OUT"
  case $verdict in
    0) if python3 -c "import json,sys; sys.exit(0 if '_redeploy' in json.load(open(sys.argv[1])) else 1)" "$snap"; then
         reason=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['_redeploy']['reason'])" "$snap")
         echo "$c: layout unchanged — snapshot carries a REDEPLOY note: $reason"
       else
         echo "$c: layout unchanged (snapshot is byte-stale — astIds moved; refresh with --update)"
       fi ;;
    2) echo "$c: APPEND-ONLY change, allowed. Regenerate the snapshot with --update IN THIS COMMIT."
       rc=1 ;;  # still fails CI until the snapshot is regenerated and reviewed
    *) echo "$c: REFUSED — this is a redeploy, not an upgrade"; rc=1 ;;
  esac
done

# D-4: the Escrow struct is four slots, and the ProviderStake struct is four slots. If a field is
# ever APPENDED to either, the number changes in the same reviewed commit as the append — these
# are assertions about the shipped layout, not claims that the structs may never grow.
#
# They are separate from the append-only classifier above and catch a different mistake: the
# classifier compares against a SNAPSHOT, so a struct that gained a member and had its snapshot
# refreshed with --update in the same commit passes it legitimately. These two lines are where a
# packing that quietly became five slots has to be argued for out loud.
check_struct_size() {  # <contract> <struct label> <expected bytes> <why>
  local size
  if size=$($FORGE inspect "$1" storageLayout --json 2>/dev/null \
    | jq -er --arg l "$2" '.types | to_entries[] | select(.value.label == $l) | .value.numberOfBytes'); then
    if [ "$size" != "$3" ]; then
      echo "$2 is $size bytes, expected $3 ($4)"; rc=1
    fi
  else
    echo "could not read the size of $2"; rc=1
  fi
}
check_struct_size X402Escrow "struct X402Escrow.Escrow" 128 "four slots — D-4"
check_struct_size X402Stake "struct X402Stake.ProviderStake" 128 "four slots — the designed packing"

[ $rc -eq 0 ] && echo "layout OK"
exit $rc
