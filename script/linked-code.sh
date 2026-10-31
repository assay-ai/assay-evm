#!/usr/bin/env bash
# Runtime code of a contract that LINKS an external library, made comparable across deploys.
#
# `AssayEscrow` DELEGATECALLs its channel doors into the `ChannelDoor` library (D-28), and the
# compiler leaves a `__$<hash>$__` placeholder in the escrow's runtime code at every call site
# until the library's address is known. Two questions follow, and they are checked separately:
#
#   1. Is the escrow's own code the one this tree built? `runtime_keccak` hashes the runtime code
#      with every link span ZEROED, so the record can carry it before the library exists.
#   2. Do those spans name the library the record names, and is THAT code the one this tree
#      built? `verify-deployment.sh` reads each span of the live implementation and compares it
#      with `.contracts.<C>.libraries.<L>.address`, then hashes the library's own code.
#
# Zeroing a span without (2) would accept an escrow linked to any address at all; (2) is the
# link-substitution check, done span by span so a mismatch names its offset.
# Sourced by check-bytecode.sh, new-deployment-record.sh and verify-deployment.sh.

zero_links() { sed -E 's/__\$[0-9a-fA-F]{34}\$__/0000000000000000000000000000000000000000/g'; }

runtime_keccak() { # <contract> -> keccak of this tree's runtime code, link spans zeroed
  cast keccak "$($FORGE inspect "$1" deployedBytecode | tr -d '\n' | zero_links)"
}

link_spans() { # <artifact> [library] -> "start length" for each link span (of that library)
  jq -r --arg n "${2:-}" '.deployedBytecode.linkReferences // {} | [.[] | to_entries[]
    | select($n == "" or .key == $n) | .value[]] | .[] | "\(.start) \(.length)"' "$1"
}

linked_libraries() { # <artifact> -> each library name the contract links, one per line
  jq -r '.deployedBytecode.linkReferences // {} | [.[] | keys[]] | unique | .[]' "$1"
}

masked_code() { # <contract> <address> [artifact]
  # Immutable spans AND link spans zeroed — the same bytes `runtime_keccak` zeroes in the build.
  # The link spans are checked against the record separately (check 3b); zeroed here only.
  local code art starts
  code=$(cast code "$2" --rpc-url "$RPC"); code=${code#0x}
  art=${3:-$(artifact_for "$1")}
  # Every span of one immutable must hold the same value before the spans are masked: the
  # compiler writes one value to all of them. Without this, a deployer could put one value at an
  # immutable's getter and another at its other use (the escrow's `fallback` DELEGATECALL target
  # is the second span of `EXTENSION`) and the masked hash would still match (review H-1).
  local id first span
  for id in $(jq -r '.deployedBytecode.immutableReferences // {} | keys[]' "$art"); do
    first=""
    while read -r start len; do
      [ -n "$start" ] || continue
      span="${code:$((start * 2)):$((len * 2))}"
      if [ -z "$first" ]; then first="$span"; elif [ "$span" != "$first" ]; then
        echo "immutable $id of $1 at $2 holds different values at its spans" >&2
        return 1
      fi
    done <<< "$(jq -r --arg id "$id" '.deployedBytecode.immutableReferences[$id][] | "\(.start) \(.length)"' "$art")"
  done
  starts=$(jq -r '.deployedBytecode.immutableReferences // {} | [.[][]] | .[] | "\(.start) \(.length)"' "$art"
           link_spans "$art")
  while read -r start len; do
    [ -n "$start" ] || continue
    local zeros; zeros=$(printf '%0*d' $((len * 2)) 0)
    code="${code:0:$((start * 2))}${zeros}${code:$(((start + len) * 2))}"
  done <<< "$starts"
  echo "0x$code"
}
