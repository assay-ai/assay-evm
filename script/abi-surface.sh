#!/usr/bin/env bash
# The FUNCTION SURFACE of a contract, canonicalised so it can be hashed and compared.
#
# Three variables decide whether an upgrade is safe: the storage layout, the EIP-712 domain, and
# the set of functions the new implementation exports. The first two have mechanical gates
# (`check-layout.sh`, and the runbook's `DOMAIN_SEPARATOR()` comparison plus its redeem-a-real-
# voucher check). **The third had none.** A new implementation could add a `sweep(address)`, a
# second redeem door or a `setBalance` and every gate stayed green: the layout is unchanged, the
# domain is unchanged, and `implementationRuntimeKeccak` is REWRITTEN BY THE OPERATOR as part of
# the upgrade — so `check-bytecode.sh` confirms the deployed code matches the new source, never
# that the new source's surface matches the old one.
#
# This file is that gate's shared half. `new-deployment-record.sh` writes `abiKeccak` and the
# named `abiFunctions` list into the record; `check-bytecode.sh` and `verify-deployment.sh`
# recompute both and refuse a silent change. Adding a function is then exactly as deliberate an
# act as changing the storage layout: the record has to be rewritten, and the rewrite shows the
# added signature by name in the diff a reviewer reads.
#
# `forge inspect <C> methodIdentifiers` is the whole external surface as solc computed it —
# `public` state variables and inherited functions included, which is the point, since
# `upgradeToAndCall` and `proxiableUUID` arrive that way.
#
# **What it cannot see.** It is a comparison between the RECORD and the LOCAL BUILD, not between
# the record and the chain: an EVM account exposes bytecode, not an ABI, and recovering a selector
# set from `via_ir` output is not something to trust a deployment to. The record-to-chain link is
# `check-bytecode.sh` / `verify-deployment.sh` check 2, which compares the deployed runtime
# bytecode against the hash in the record. The two together say: the chain runs the code this
# build produced, and this build exports the functions the record names.
#
# Sourced, not executed.

# "<selector> <signature>" per line, sorted by signature. jq's sort is byte-wise on the key, so
# the order is a property of the surface and not of the order solc happened to emit it in.
#
# `AssayEscrow` answers through its `fallback` with `AssayEscrowExtension` as well (D-29), so its
# surface is the UNION of the two: a function added to the extension is a new door on the proxy
# exactly as one added to the core is. The getters both inherit from the storage base appear
# once.
# The core and the extension may share only the storage base's five public getters (the core
# answers them); any other shared selector would leave an extension door unreachable, so the
# union is refused (review L-3).
ESCROW_SHARED_GETTERS='["ASSET()","CONFIG()","STAKE()","totalEscrowed()","totalHeld()"]'

methods_json() {
  if [ "$1" = "AssayEscrow" ]; then
    local overlap
    overlap=$(jq -rs --argjson ok "$ESCROW_SHARED_GETTERS" \
      '[(.[0] | to_entries[]) as $e | (.[1] | to_entries[]) | select(.value == $e.value) | .key]
        | unique - $ok | .[]' \
      <("${FORGE:-forge}" inspect AssayEscrowExtension methodIdentifiers --json) \
      <("${FORGE:-forge}" inspect AssayEscrow methodIdentifiers --json))
    if [ -n "$overlap" ]; then
      echo "AssayEscrow core and extension share a selector: $overlap" >&2
      return 1
    fi
    jq -s '.[0] + .[1]' \
      <("${FORGE:-forge}" inspect AssayEscrowExtension methodIdentifiers --json) \
      <("${FORGE:-forge}" inspect AssayEscrow methodIdentifiers --json)
  else
    "${FORGE:-forge}" inspect "$1" methodIdentifiers --json
  fi
}

abi_lines() {
  methods_json "$1" | jq -r 'to_entries|sort_by(.key)|.[]|"\(.value) \(.key)"'
}

abi_hash() {
  cast keccak "$(cast from-utf8 "$(abi_lines "$1")")"
}

# The same list, indented as JSON array entries for the deployment record.
abi_json_entries() {
  methods_json "$1" \
    | jq -r 'to_entries|sort_by(.key)|map("        \"\(.value) \(.key)\"")|join(",\n")'
}
