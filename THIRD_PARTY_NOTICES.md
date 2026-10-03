# Third-party notices

The PolyForm Strict License 1.0.0 in `LICENSE` applies to the first-party code of this repository
only. The third-party code vendored under `lib/` is **not** covered by it: each component keeps its
own licence and notices, reproduced or referenced below. Those files are copied unmodified from
upstream (see each directory's `VENDOR.md`; `script/check-vendor.sh` verifies the OpenZeppelin copy
byte for byte).

## forge-std

- Upstream: https://github.com/foundry-rs/forge-std
- Version: v1.9.6 (commit `3b20d60d14b343ee4f908cb8079495c07f5e8981`)
- Location: `lib/forge-std/src/`
- Licence: MIT OR Apache-2.0 (dual licensed, at your option). Used here under the MIT licence.
- Used by tests and scripts only; nothing from it reaches deployed bytecode.

The full licence texts, copied verbatim from the upstream repository at the tagged version, are
in this repository:

- MIT: `licenses/forge-std-1.9.6-MIT.txt`
- Apache-2.0: `licenses/forge-std-1.9.6-APACHE-2.0.txt`

## OpenZeppelin Contracts

- Upstream: https://github.com/OpenZeppelin/openzeppelin-contracts
- Version: v5.1.0 (commit `69c8def5f222ff96f2b5beff05dfba996368aa79`)
- Location: `lib/openzeppelin/` (31 files, listed in `lib/openzeppelin/MANIFEST`)
- Licence: MIT. Each vendored file carries its `SPDX-License-Identifier: MIT` header.

The full licence text, including OpenZeppelin's copyright notice, copied verbatim from the
upstream repository at tag v5.1.0, is in `licenses/openzeppelin-contracts-5.1.0.txt`.

## Licence texts

| Project | Version | Licence | Path |
|---|---|---|---|
| forge-std | v1.9.6 | MIT OR Apache-2.0 | `licenses/forge-std-1.9.6-MIT.txt`, `licenses/forge-std-1.9.6-APACHE-2.0.txt` |
| OpenZeppelin Contracts | v5.1.0 | MIT | `licenses/openzeppelin-contracts-5.1.0.txt` |

The texts live in `licenses/` at the repository root, not inside `lib/`, because
`script/check-vendor.sh` compares the `lib/` trees with upstream file by file.
