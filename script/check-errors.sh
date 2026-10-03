#!/usr/bin/env bash
# The error-catalogue gate.
#
# `src/Errors.sol`'s header carries an accounting against the Anchor program's `error.rs` — how
# many variants it declares, how many are ported under the same name, how many are EVM-only, and
# which are deliberately absent. **Nothing imported it and no test counted it**, so those four
# numbers were prose: correct on the day they were written and silently wrong on the next error
# added. This recomputes them from both files and fails when they disagree with what the header
# claims, so the header is an assertion rather than a memory.
#
# It also reports **errors with no producer** — declared in `Errors.sol` but never reverted
# anywhere in `src/`. That list is not automatically a failure: `InvalidAdmin` has exactly one
# producer and the `address(0)` sentinel on the `updateConfig` path is the refusal, so a
# selector-table comparison against the deployed ABI will show an intentional gap there. A NEW
# name on the list is a name that either needs a producer or needs deleting; `docs/divergences.md`
# is where each surviving entry is argued for.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE"
# The Anchor program lives in a separate repository (assay-solana). Point RUST_ERRORS at
# its `programs/x402-payment/src/error.rs` in a local checkout to run this cross-check.
RUST="${RUST_ERRORS:-}"
if [ -z "$RUST" ] || [ ! -f "$RUST" ]; then
  echo "error.rs not found (RUST_ERRORS='$RUST'). Clone assay-solana and set"
  echo "RUST_ERRORS=<path-to-checkout>/programs/x402-payment/src/error.rs."
  exit 2
fi
python3 - "$RUST" <<'PY'
import re, sys, pathlib

rust_path = sys.argv[1]
rust = open(rust_path).read()
sol_src = open("src/Errors.sol").read()
# The header is natspec wrapped at 100 columns, so a claim can straddle a line break. Flatten the
# comment prefixes and the whitespace before matching, or every regex here is a line-width test.
flat = re.sub(r'\s+', ' ', re.sub(r'(?m)^\s*///?', ' ', sol_src))

anchor = set(re.findall(r'^\s+([A-Z][A-Za-z0-9]+),\s*$', rust, re.M))
sol = set(re.findall(r'^error ([A-Za-z0-9]+)\(\);', sol_src, re.M))

shared = anchor & sol
anchor_only = anchor - sol
evm_only = sol - anchor

# The four numbers the header claims, read back OUT of the header.
words = {"five": 5, "four": 4, "three": 3, "two": 2, "one": 1}
def claim(pattern):
    m = re.search(pattern, flat)
    if not m:
        print(f"the header no longer states: {pattern}")
        sys.exit(1)
    v = m.group(1)
    return words.get(v.lower(), None) or int(v)

c_total   = claim(r'declares \*\*(\d+)\*\* `ErrorCode` variants')
c_shared  = claim(r'\*\*(\d+)\*\* of them appear below under the same name')
c_evmonly = claim(r'\*\*(\d+)\*\* errors below have no Anchor counterpart')
c_absent  = claim(r'The remaining \*\*([a-z]+|\d+)\*\* are')

rc = 0
def check(label, got, want):
    global rc
    mark = "ok " if got == want else "DRIFT"
    print(f"  {mark} {label}: measured {got}, header says {want}")
    if got != want:
        rc = 1

print(f"error.rs      {rust_path}")
print(f"Errors.sol    {len(sol)} declarations")
check("ErrorCode variants", len(anchor), c_total)
check("ported under the same name", len(shared), c_shared)
check("EVM-only", len(evm_only), c_evmonly)
check("absent from the port", len(anchor_only), c_absent)

# Every absent Anchor name must be NAMED in the header, not merely counted.
for name in sorted(anchor_only):
    if name not in sol_src:
        print(f"  DRIFT {name} is absent from the port and is not named in the header")
        rc = 1

# Producers: an `Errors.sol` name that nothing in src/ reverts.
producers = {}
for p in pathlib.Path("src").rglob("*.sol"):
    if p.name == "Errors.sol":
        continue
    for line in p.read_text().splitlines():
        stripped = line.lstrip()
        if stripped.startswith("//") or stripped.startswith("*") or stripped.startswith("/*"):
            continue
        for m in re.finditer(r'revert ([A-Za-z0-9]+)\(\)', line):
            producers[m.group(1)] = producers.get(m.group(1), 0) + 1

orphans = sorted(n for n in sol if n not in producers)
print(f"  -- errors with no `revert` producer in src/: {len(orphans)}")
for n in orphans:
    print(f"       {n} ({producers.get(n, 0)} producers)")
print("     ^ not automatically a failure; each must be argued for in docs/divergences.md")

sys.exit(rc)
PY
echo "errors OK"
