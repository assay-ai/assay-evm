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
