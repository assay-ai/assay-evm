# Security policy

## Supported versions

Only the `main` branch is supported. Fixes are not backported to older commits or tags.

## Scope

The contracts in `src/` (`X402Config`, `X402Escrow`, `X402Stake` and their libraries), the
deployment and verification scripts in `script/`, and any deployment records you generate with them.
These contracts are intended for Robinhood Chain testnet (46630) only; no deployment is published from this repository. They have not had an independent
third-party audit. Known, accepted design risks are listed in `docs/risk-register.md`; please read
it before reporting, although a report that shows one of those risks is worse than described is
welcome.

## Reporting a vulnerability

Please **do not** open a public issue, discussion or pull request for a suspected vulnerability.

Use GitHub's private vulnerability reporting instead: on this repository's **Security** tab, choose
**Report a vulnerability**. Include:

- the affected contract, function or script, and the commit you tested against;
- a description of the issue and its impact;
- steps to reproduce, ideally a Foundry test.

## What to expect

This is a small project maintained on a best-effort basis. We aim to acknowledge a report within a
few business days, keep you informed while we investigate, and credit you in the fix unless you
prefer otherwise. Please give us reasonable time to fix an issue before disclosing it publicly.
