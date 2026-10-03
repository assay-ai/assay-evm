# assay-evm

The EVM settlement contracts of **GoAssay.AI**, for payments made over the x402 protocol: three
Solidity contracts that hold buyer escrow, redeem signed payment vouchers, and hold provider
stake behind a two-phase slash. They are a port of the GoAssay.AI
Anchor program for Solana (repository `assay-solana`) to Robinhood Chain, an Arbitrum Orbit L2 (mainnet chain id **4663**, testnet **46630**), settling in **USDG**, a
6-decimal stablecoin.

## Status

**Experimental. Testnet only. Not audited.**

- No deployment record is published in this repository, and nothing is deployed on mainnet. The
  scripts in `script/` produce a per-chain record (`deployments/<chainId>.json`) when you deploy;
  the gates that read `deployments/*.json` skip cleanly when none exists.
- The code has been reviewed by its authors and mutation tested (`test/MUTATION-LOG.md`). It has
  **not** had an independent third-party audit, and an external audit is a precondition for any
  mainnet deployment (`docs/deploy-runbook.md` §0).
- `docs/risk-register.md` lists the known, accepted design risks, including two items that must be
  resolved before mainnet.

Do not use these contracts to hold real funds.

## These contracts sit behind UUPS proxies

The three contracts are **upgradeable**. The single upgrade authority is `X402Config.admin`, a
hardware wallet, and upgrades are **immediate** — there is no timelock, no multisig and no
pending-implementation slot. This was chosen (design decision D-1, see
`docs/design-decisions.md`) for parity with the Solana program's upgrade authority. Risk register
§4 and §5 describe the accepted cost.

**Every address an integrator is given is a PROXY address** — the backend's configuration, a
voucher's EIP-712 `verifyingContract`, an explorer link. Proxy addresses do not move across an
upgrade, so a voucher signed before an upgrade still redeems after it. Implementation addresses
are recorded in the per-chain deployment record that `script/new-deployment-record.sh` writes, and change by design.

**Fixing a defect means:** an append-only storage change, a green `./script/check-layout.sh`, and
an `upgradeToAndCall` from the admin (`docs/deploy-runbook.md` §7). A redeploy is reserved for a
layout change that cannot be appended, which is exactly the case the layout gate refuses.

## The three contracts

```
X402Config   parameters, the admin, the pause flag, the verifier registry.
             Holds no token and never gains a function that moves one.
                 ▲                    ▲
                 │ CONFIG.params()    │ CONFIG.admin(), CONFIG.paused()
                 │                    │
X402Escrow ──────┘                    └────── X402Stake
  buyer money, one pooled balance       provider collateral, the two-phase slash
        │                                        ▲
        └──────── STAKE.bondedOf(provider) ──────┘
                  a view, one direction only (D-2)
```

`X402Escrow` and `X402Stake` each hold USDG. `X402Config` is read by both and **written by
neither** (D-3), which is why the stake accounting totals and the verifier daily-cap counter live
on `X402Stake` rather than on `X402Config`, where the Anchor program keeps them.

## Quick start

Requirements: [Foundry](https://book.getfoundry.sh/getting-started/installation). The repository
was developed with forge **1.2.1-nightly**; the compiler (solc 0.8.24) is pinned in
`foundry.toml` and downloaded by forge. Dependencies (forge-std, OpenZeppelin Contracts) are
vendored under `lib/`, so no `forge install` or submodule step is needed.

```sh
git clone <this repository> assay-evm
cd assay-evm
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1
forge build          # via_ir is on; a cold build takes several minutes
forge test           # unit, fuzz and invariant suites
```

### Fork tests

The suites under `test/fork/` run against Robinhood Chain testnet and **skip** when
`RH_TESTNET_RPC` is unset, so a plain `forge test` is offline. To run them:

```sh
RH_TESTNET_RPC=<your-rpc-url> forge test --match-path "test/fork/*"
```

## Toolchain

The pin is load-bearing (`docs/gas.md` and the deployment records are pinned to the bytecode it
produces):

| | |
|---|---|
| `forge` | 1.2.1-nightly. Export `FOUNDRY_DISABLE_NIGHTLY_WARNING=1` |
| solc | **0.8.24**, `evm_version = "shanghai"` |
| optimizer | on, **200** runs, `via_ir = true` |
| metadata | `bytecode_hash = "ipfs"`, `cbor_metadata = true`: solc appends a CBOR metadata hash, so any source change, comments included, changes the bytecode. Verify with **standard-JSON input** (below) or metadata matching |
| remappings | `auto_detect_remappings = false` plus an explicit `remappings.txt`, so one dependency cannot compile under two spellings |
| OpenZeppelin | copy-vendored under `lib/openzeppelin/`, pinned to v5.1.0 (`69c8def5f222ff96f2b5beff05dfba996368aa79`), 31 files, checked by `./script/check-vendor.sh` |
| forge-std | copy-vendored under `lib/forge-std/`, see `lib/forge-std/VENDOR.md` |
| `[fmt]` | `line_length = 100` |

## The full gate sequence

CI (`.github/workflows/ci.yml`) runs `forge fmt --check`, `forge build`, `forge test` and the gas-snapshot check, on the Foundry
nightly build the figures were measured with (pinned by commit in the workflow). The full
local sequence before a merge is:

```sh
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1
forge fmt --check
rm -rf out cache && forge build
./script/check-vendor.sh          # OZ is byte-identical to the pinned upstream commit (needs network)
./script/check-layout.sh          # append-only storage — the upgrade-safety gate (D-7)
./script/check-layout-branch.sh   # the same question against the merge base (needs a git clone with origin/main)
./script/check-sizes.sh           # EIP-170, per implementation, gated at 22,000 of 24,576
./script/check-errors.sh          # Errors.sol against the Anchor error.rs (needs RUST_ERRORS)
./script/check-bytecode.sh        # implementation drift vs a deployments/*.json record, if you generated one
forge test
./script/check-snapshot.sh          # forge snapshot --check, minus the checkout-path-dependent tests
./script/check-fork-isolation.sh
```

`check-errors.sh` compares against the Anchor program's `error.rs`, which lives in the
`assay-solana` repository: set `RUST_ERRORS` to that file in a local checkout.

**Read `docs/ci-gates.md` before trusting a green run.** Every gate has a blind spot, and the
file states each one.

## Repository layout

```
src/                 the three contracts, shared types, errors, constants and libraries
test/                unit, fuzz, invariant (test/invariant) and fork (test/fork) suites
test/MUTATION-LOG.md every guard, broken on purpose, with the observed failure
script/              Deploy.s.sol, VerifyDeployment.s.sol and the gate scripts
snapshots/           committed storage-layout snapshots read by check-layout.sh
(deployments/)        written by script/new-deployment-record.sh when you deploy; not part of this repository
docs/                runbook, risk register, design decisions, divergences, gas, chain facts
lib/                 vendored forge-std and OpenZeppelin Contracts (see THIRD_PARTY_NOTICES.md)
```

## Documents

| | |
|---|---|
| `docs/deploy-runbook.md` | the human procedure: preflight, environment, deploy, verification, the record, the admin handover, upgrades |
| `docs/risk-register.md` | known, accepted design risks, two of them mainnet preconditions |
| `docs/design-decisions.md` | the decision ids (`D-1`, `D-7`, ...) cited throughout the code |
| `docs/divergences.md` | every place this port differs from the Anchor program or the original design, and which side is authoritative |
| `docs/chain-facts.md` | what was measured on 4663 and 46630 |
| `docs/gas.md` | per-call gas, batch tables and contract sizes, measured against `MockUSDG` |
| `docs/ci-gates.md` | the gate set, and what each gate cannot see |

## What is not here

`restore_pool` / `reverseSlash`, the verifier **activation** delay, and any `exposure` authority
from the Solana program are not ported. `docs/divergences.md` lists each omission and its
consequence.

## Related repositories

- `assay-solana` — the Anchor (Solana) program this repository ports
- `assay-backend` — the API, facilitator and settlement services
- `assay-frontend` — the web application

## Contributing and security

External code contributions are not accepted at this time; bug reports and discussion are welcome
(see `CONTRIBUTING.md`). Please report vulnerabilities privately as described in `SECURITY.md`,
not in a public issue.

## License

Source-available, not open source. You may read it and use it for noncommercial purposes under
the PolyForm Strict License 1.0.0; redistribution, modification and commercial use are not
permitted. Questions and licensing enquiries: open an issue or discussion in this repository's GitHub Issues.
Security reports: see `SECURITY.md`. See `LICENSE`.

The PolyForm licence applies to first-party code only. Vendored third-party code under `lib/`
(forge-std, OpenZeppelin Contracts) keeps its own licence; see `THIRD_PARTY_NOTICES.md`.
