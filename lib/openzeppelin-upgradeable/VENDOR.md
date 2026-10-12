# Vendored OpenZeppelin Contracts Upgradeable

Upstream: https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable
Tag:      v5.1.0
Commit:   fa525310e45f91eb20a6d3baa2644be8e0adba31

The same release as `lib/openzeppelin/` (v5.1.0). The upgradeable package is a separate
repository with its own commit; its `lib/openzeppelin-contracts` submodule pins
`69c8def5f222ff96f2b5beff05dfba996368aa79`, which is exactly the commit `lib/openzeppelin/`
is vendored from. Copy-vendored, never edited.

## Files

Three files, the import closure of `Ownable2StepUpgradeable` (D-17, the owner role of
`X402Config`) minus `proxy/utils/Initializable.sol`:

    access/Ownable2StepUpgradeable.sol
    access/OwnableUpgradeable.sol     <- access/Ownable2StepUpgradeable.sol
    utils/ContextUpgradeable.sol      <- access/OwnableUpgradeable.sol

All three keep their state in ERC-7201 namespaced storage (`openzeppelin.storage.Ownable`,
`openzeppelin.storage.Ownable2Step`; `ContextUpgradeable` has none), so adopting them adds no
sequential storage slot to `X402Config` — `script/check-layout.sh` confirms it.

## The one import that is redirected, and why

Each of the three imports `../proxy/utils/Initializable.sol`. Resolved literally, that is a
SECOND `Initializable` contract in the build, and `X402Config` — which also inherits
`UUPSUpgradeable` and through it `lib/openzeppelin/proxy/utils/Initializable.sol` — fails to
compile with "Derived contract must override modifier `reinitializer`". `remappings.txt`
therefore maps

    lib/openzeppelin-upgradeable/proxy/utils/=lib/openzeppelin/proxy/utils/

so the one `Initializable` in the graph is the main package's. That is a no-op in content,
not just in behaviour: at this commit the upgradeable package's
`contracts/proxy/utils/Initializable.sol` is byte-identical to the main package's, and
`script/check-vendor.sh` asserts it on every run.

## Drift gate

`script/check-vendor.sh` checks this tree exactly as it checks `lib/openzeppelin/`: the tag
resolves to the commit, the set of files equals `MANIFEST`, and every file is byte-identical
to the pinned commit. `test/VendoredSourcesCompile.sol` imports all three.
