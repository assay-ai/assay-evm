# Contributing

Thank you for your interest in GoAssay.AI.

## Code contributions

This repository is **source-available, not open source**. It is published under the PolyForm
Strict License 1.0.0 (see `LICENSE`), which does not permit derivative works. For that reason,
**external code contributions (pull requests) are not accepted at this time.**

What is welcome:

- **Bug reports** — open an issue using the bug report template. A failing Foundry test is the
  most useful form of report.
- **Questions and discussion** — open an issue describing what you are trying to understand.
- **Security issues** — do not open a public issue; follow `SECURITY.md`.

## Building and testing locally

You may read, build and test the code for noncommercial purposes under the licence.

Requirements: [Foundry](https://book.getfoundry.sh/getting-started/installation) (developed with
forge 1.2.1-nightly; solc 0.8.24 is pinned in `foundry.toml`). Dependencies are vendored under
`lib/`.

```sh
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1
forge fmt --check
forge build
forge test                 # fork suites under test/fork/ skip unless RH_TESTNET_RPC is set
```

The full gate sequence, and what each gate cannot see, is in `README.md` and `docs/ci-gates.md`.

## Conventions used in this repository

These describe how the code is written, to help when reading it or filing a precise report:

- Solidity files are PascalCase and named after the contract they contain (`X402Escrow.sol`);
  verification tooling relies on that.
- Formatting is `forge fmt` with `line_length = 100`.
- Errors are custom errors from `src/Errors.sol`, one name per condition; there are no revert
  strings.
- Storage layouts are append-only (`docs/design-decisions.md`, D-7), enforced by
  `script/check-layout.sh`.
- Commit messages follow [Conventional Commits](https://www.conventionalcommits.org/)
  (`<type>(<scope>): <subject>`).

## Code of conduct

Everyone interacting with this project is expected to follow `CODE_OF_CONDUCT.md`.
