# Vendored OpenZeppelin Contracts

Upstream: https://github.com/OpenZeppelin/openzeppelin-contracts
Tag:      v5.1.0
Commit:   69c8def5f222ff96f2b5beff05dfba996368aa79

Copy-vendored rather than submoduled, so a plain clone builds with no submodule step. Do not edit these files. `script/check-vendor.sh`
re-clones the pinned commit and diffs.

**One repository, one commit.** These files come from `openzeppelin-contracts` only —
never from `openzeppelin-contracts-upgradeable`. The proxy machinery (`proxy/**`,
`interfaces/IERC1967.sol`, `interfaces/draft-IERC1822.sol`) lives in the main repository
in OZ 5.x, so the UUPS decision (D-1) adds files here, not a second dependency.

## Files

The 25 files the contracts import directly, plus 6 more that the first 25 `import` and that were
therefore required to close the graph — without them nothing compiles:

    interfaces/IERC1363.sol          <- token/ERC20/utils/SafeERC20.sol
    interfaces/IERC5267.sol          <- utils/cryptography/EIP712.sol
    utils/Panic.sol                  <- utils/math/Math.sol
    interfaces/IERC20.sol            <- interfaces/IERC1363.sol
    interfaces/IERC165.sol           <- interfaces/IERC1363.sol
    utils/introspection/IERC165.sol  <- interfaces/IERC165.sol

They are from the same tag and the same commit as the rest; adding them widens the copied
file set, not the dependency. The vendored set is *exactly* the transitive import closure of
the 25 seeds at v5.1.0 — nothing spare, nothing missing — and that closure is a property of
the pinned tag, not of the library: on OZ `master` it is 35 files. `MANIFEST` lists all 31;
the gate reads it.

## Drift gate

    script/check-vendor.sh

asks three questions, and the second one is there because the first version of this gate
asked only the third:

1. **Does `Tag:` resolve to `Commit:`?** `git ls-remote` the tag and compare. A pin that
   disagrees with itself is a pin nobody can re-derive.
2. **Is the set of files exactly `MANIFEST`?** Compared both ways, so a *deleted* vendored
   file fails by name and so does a stray file that never came from upstream. The gate used
   to walk the files that happened to be present, which can only ever answer "does what I
   have match?" — deleting `ECDSA.sol` printed `vendor OK` and exited 0.
3. **Is every file byte-identical to that commit?** Re-clone, check out the pin, `diff`.
   No digest is stored anywhere, so there is no second artefact to fall out of sync.

`MANIFEST` is the authoritative list of what must be present — one relative path per line,
sorted. Regenerate it only when the vendored set genuinely changes:

    find lib/openzeppelin -name '*.sol' | sed 's|^lib/openzeppelin/||' \
      | LC_ALL=C sort > lib/openzeppelin/MANIFEST

and regenerate `test/VendoredSourcesCompile.sol` with it (that file's header carries the
command).

**A deletion has to defeat two independent things.** The gate compares against `MANIFEST`,
and `test/VendoredSourcesCompile.sol` imports every path in `MANIFEST`, so a missing file is
also a build failure. Before that file existed, `forge build` pulled exactly **one** of the
31 vendored sources into the graph — `ECDSA.sol` — and the other 30 were committed but never
compiled.

**What the gate does not do.** It detects *local* drift only. The pinned commit does not
move, so an upstream change to OpenZeppelin is invisible to it by design; noticing that is a
dependency-bump review, not a script.
