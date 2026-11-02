#!/usr/bin/env bash
# The EVENT SURFACE of each deployed contract, compared with a committed snapshot.
#
# `abi-surface.sh` gates the functions an implementation exports; nothing gated the events it emits.
# Indexers, the backend's reconciler and every receipt reader decode logs by topic hash, so a
# changed event signature is an interface change exactly as a changed function is: an old reader
# silently stops seeing the event. The standing rule is that event changes ship backend-first; this
# gate makes the change visible in review instead of relying on someone noticing.
#
# Each event appears twice: its topic hash, and its indexed flags per input.
#
# The escrow's logs come from three artifacts: the core, the extension (reached by its fallback,
# D-29) and the linked `ChannelDoor` library (D-28; a library's events are not in the escrow's own
# ABI). Their union is the escrow's event surface.
#
#   ./script/check-events.sh            check
#   ./script/check-events.sh --update   rewrite the snapshots — only for an intended event change,
#                                       committed together with the change and its backend note
set -euo pipefail
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE"
FORGE="${FORGE:-forge}"
DIR=snapshots/events
mkdir -p "$DIR"
$FORGE build >/dev/null

events_of() {
  # "<topic> <signature> <indexed flags>" per line, sorted by signature. The flags (one 0/1 per
  # input) matter as much as the signature: moving a field between topics and data keeps the
  # topic hash and breaks every decoder.
  local out=""
  for a in "$@"; do
    out+=$($FORGE inspect "$a" events --json | jq -r 'to_entries[] | "\(.value) \(.key)"' | sort -k2)
    out+=$'\n'
    out+=$($FORGE inspect "$a" abi --json | jq -r '.[] | select(.type=="event")
      | "\(.name)(\([.inputs[].type] | join(","))) indexed=\([.inputs[] | if .indexed then 1 else 0 end] | map(tostring) | join(""))"')
    out+=$'\n'
  done
  printf '%s' "$out" | sed '/^$/d' | sort -u
}

rc=0
for target in AssayEscrow AssayConfig AssayStake; do
  case "$target" in
    AssayEscrow) got=$(events_of AssayEscrow AssayEscrowExtension ChannelDoor) ;;
    *) got=$(events_of "$target") ;;
  esac
  [ -n "$got" ] || { echo "$target: no events read (forge inspect failed?)"; exit 1; }
  file="$DIR/$target.events.txt"
  if [ "${1:-}" = "--update" ]; then
    printf '%s\n' "$got" > "$file"
    echo "$target: snapshot written"
    continue
  fi
  if [ ! -f "$file" ]; then
    echo "$target: no snapshot at $file"
    rc=1
    continue
  fi
  if ! diff -u "$file" <(printf '%s\n' "$got") >/dev/null; then
    echo "$target: event surface changed (an interface change; ship the backend first):"
    diff -u "$file" <(printf '%s\n' "$got") | sed -n '3,$p' | grep '^[-+]' || true
    rc=1
  fi
done
[ $rc -eq 0 ] && [ "${1:-}" != "--update" ] && echo "events OK"
exit $rc
