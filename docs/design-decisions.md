# Design decisions

Comments, tests and the other documents in this repository cite design decisions by a short id
(`D-1`, `D-7`, ...). The ids come from the original design specification for the EVM port, which is
not published. This page states each decision that the code relies on, in one place, so that every
citation resolves. Ids that the code never cites are omitted, which is why the numbering has gaps.

| Id | Decision | Where it shows up |
|---|---|---|
| **D-1** | The three contracts are **upgradeable UUPS proxies**. The upgrade authority is `X402Config.admin`, and `_authorizeUpgrade` checks the admin and nothing else: no timelock, no multisig, no pending-implementation slot. Chosen as a revision, replacing an earlier immutable design, for parity with the Solana program's upgrade authority. | `src/X402Config.sol`, `test/Upgrade.t.sol`, `docs/risk-register.md` §4 and §5 |
| **D-2** | `X402Escrow` reads `X402Stake.bondedOf(provider)` as a `view`, in one direction only. `X402Stake` holds no reference back to the escrow. | `src/X402Escrow.sol`, `src/interfaces/IX402StakeView.sol` |
| **D-3** | `X402Config` is read by both other contracts and **written by neither**. Counters that the Anchor program keeps on its config account (the four stake accounting totals, the per-verifier daily-cap counter) live on `X402Stake`, next to the custody they count. | `src/X402Stake.sol`, `docs/divergences.md` rows 7 and 8 |
| **D-4** | The `Escrow` struct is packed into **four** storage slots (128 bytes). `script/check-layout.sh` fails if it is anything else. | `src/Types.sol`, `script/check-layout.sh` |
| **D-6** | The admin is a single key, and an admin change through `updateConfig` takes effect immediately, in one step. A mistyped `newAdmin` cannot be recovered. | `src/X402Config.sol`, `docs/deploy-runbook.md` §6.3 |
| **D-7** | Storage layouts are **append-only**. An append is an upgrade; a change that cannot be expressed as an append is a redeploy behind a new proxy. The proxy, not the implementation, carries the CREATE2 salt. | `script/check-layout.sh`, `script/check-layout.py`, `script/Deploy.s.sol` |
| **D-9** | A buyer's voucher `seq` is a high-water mark and never goes backwards. | `src/X402Escrow.sol` |
| **D-10** | `redeemVoucher` is restricted to the redeemer role (`onlyRedeemer`), matching the Anchor program's `redeem_voucher`. | `src/X402Escrow.sol` |
| **D-11** | Gasless deposits go through **Permit2**: the settlement token offers neither EIP-2612 nor EIP-3009, so a buyer approves Permit2 once and a relayer submits afterwards. | `src/X402Escrow.sol`, `docs/chain-facts.md` |
| **D-13** | The **boundary table**: where two time windows meet, exactly one of them owns the shared instant. Every row is tested at `-1`, exact and `+1`. | `test/Boundaries.t.sol` |
| **D-14** | The **four accounting identities** (for example: the sum of escrow balances equals `totalEscrowed`). Solvency is defined by internal accounting, never by `balanceOf`. | `test/invariant/Invariants.t.sol` |
| **D-15** | `withdraw()` takes no destination argument and pays `msg.sender`; `withdrawStake` has the same shape. | `src/X402Escrow.sol`, `src/X402Stake.sol`, `docs/divergences.md` |
