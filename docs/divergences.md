# Divergences — every place this port beats a doc, and every place a doc beats it

Before this file existed, these lived in natspec at the site of each decision and in commit
messages — places a reader has to already know about. **The rule for every
row below is that it names which side is authoritative**, because a divergence nobody has ruled on
is not a divergence — it is a bug waiting for whoever reads the doc first.

Two tables. The first is the port against its own design specification and against the Anchor
source (the Solana program in the `assay-solana` repo, `programs/x402-payment/src/`). The
second is what `script/check-errors.sh` found on its first run.

**A note on references.** Section marks such as `§C.2` or `§D.5` refer to the original design
specification for this port, which is not published. Decision ids `D-1` … `D-15` are defined in
`design-decisions.md`. Rust file names (`redeem_voucher.rs`, `state.rs:442`, `error.rs:74`) refer to
the Anchor program.

---

## 1. The port

| # | Where | Divergence | Which wins |
|---|---|---|---|
| 1 | §C.2 | the `Escrow` struct is **four** slots, not five | **code** (D-4). Asserted by `check-layout.sh`, which fails the build if `numberOfBytes` is anything but 128 |
| 2 | §C.1 | `X402Escrow` calls `X402Stake.bondedOf` — a `view`, one direction | **code** (D-2); the property §C.1 argues for is preserved |
| 3 | §D.5, `redeem_voucher.rs` | **`seq` is checked BEFORE the signature.** `redeem_voucher.rs` checks it after | **spec §D.5.** The two cheap state-free rejections go before `ecrecover`, so a replay is refused without paying for a recovery. It leaks nothing: `escrowOf` already returns `seqHigh` to anybody who asks. `_consumeAuth` orders deadline → nonce → signature for the same reason |
| 4 | §D.5 | `ProviderBelowMinimumStake` is in the redeem check list, **at the Anchor position** — after the spending limits and before the balance | **code**; `redeem_voucher.rs:148-153` has it and §D.5's list omits it. Reinstated rather than invented: being paid is the counterpart of being slashable, and `bonded` only, because stake already asked back is not backing anybody's traffic (`state.rs:442-447`) |
| 5 | §D.5 | `redeemVoucher` is `onlyRedeemer` | **code** (D-10); §D.5's list omits it, `redeem_voucher.rs` has it |
| 6 | Anchor `update_config` | ~~parameters are timelocked 72 h on EVM~~ — **withdrawn by design decision D-1; `updateConfig` is `update_config`, no divergence** | — |
| 7 | Anchor `Config` | the four accounting totals live in `X402Stake` | **code** (D-3). X402Config must never be written by another contract, and custody and its counter belong together |
| 8 | Anchor `VerifierKey` | the per-key daily-cap counter lives in `X402Stake` | **code** (D-3). Same argument; on Solana both halves sit on one `VerifierKey` account because there is only one program |
| 9 | Anchor `SlashRecord` | `agentAmount`, `platformAmount`, the two bps, `attestedAt`, `cancelledAt` live in **events**, not storage | **code**; §C.2's layout omits them and events are the audit trail |
| 10 | Hardening §5.4 | `cancelSlash` is **admin-signed**, not verifier-attested | **the shipped `cancel_slash.rs`.** A verifier-signed cancel would mean a leaked verifier key — the thing the whole two-phase design assumes — could void every honest judgement in flight |
| 11 | §C.5 | `ASSET_SUPPORTS_3009` / `_2612` are **not built** | **measured on chain** (`chain-facts.md`): both are absent from USDG, so the flags would be dead code |
| 12 | file naming | Solidity files are PascalCase (`X402Escrow.sol`), unlike the kebab-case file names used in the sibling TypeScript repositories | **the Solidity toolchain.** `forge inspect` and every verification path key on the contract name matching the file name |
| 13 | §C.3, Anchor `Config` | **two roles, two-step owner (D-17).** The upgrade authority and the admin are split again, as on Solana (BPF-loader authority vs `Config.admin`): `owner()` is OpenZeppelin `Ownable2Step`, never renounceable, and it appoints the admin with `setAdmin`. `update_config`'s one-step admin handover is closed (`AdminChangeRequiresOwner`) | **code** (D-17) |
| 14 | §C.2 | `SlashStatus` has no `Expired` member; expiry is `Cancelled` + `CancelReason` on the event | **code**, matching the Anchor enum |
| 15 | §C.5 / measured | a plain ERC-20 `transfer` to the escrow contract credits nobody — every deposit goes through `deposit*` | **code** (`test_donationsDoNotBecomeAnybodysBalance`); the spec was corrected |
| 16 | §C.1, an earlier draft decision | the three contracts are **upgradeable** — UUPS proxies, immediate, no timelock — for parity with the Solana program's upgrade authority. The upgrade authority is `Config.owner()` since D-17 (it was `Config.admin`) | **code** (D-1, D-17) |
| 17 | §C.1 / D-7 | a *layout* change is no longer automatically a redeploy: an **append** under the upgrade-safety gate is an upgrade, and only a non-appendable change forces a new proxy | **code** (D-7). `script/check-layout.py` is the gate, and `test/MUTATION-LOG.md` § *Upgrade-safety gate* records it refusing an insertion, refusing to launder one under `--update`, and allowing an append while still failing CI until the snapshot is regenerated |
| 18 | an earlier draft decision | the treasury on 4663 is a **single-signer Ledger EOA**, not a Safe — a custody downgrade against Solana's Squads multisig, accepted (a multisig is the planned direction) | **design decision**; the Safe measurement in `chain-facts.md` stays as information and blocks nothing |
| 19 | `state.rs::SlashStatus` | **`SlashStatus.None == 0`, so every member is one higher than its Solana twin: `Pending` is 1 here and 0 there, `Executed` 2/1, `Cancelled` 3/2.** | **code, necessarily.** On Solana "no record" is the absence of the `["slash", request_id]` PDA; a Solidity mapping has no absence — every unread slot is zero — so the zero value must *be* "no record", or an unproposed request id reads back as `Pending` and `SlashAlreadyExists` never fires. **MAP, NEVER CAST.** Any backend, indexer or reconciler that moves a status between the two chains converts by name. A numeric cast turns an executed judgement on one chain into a cancelled one on the other, silently, and the value is a `uint8` on both so nothing type-checks |
| 20 | `attestation.rs:477-481` | **`InvalidVoucherWindow` is SPLIT in two.** Anchor raises that one name for both `expires_at > issued_at` and `expires_at - issued_at <= VOUCHER_MAX_LIFETIME`; the port gives the width bound its own name, `VoucherLifetimeTooLong` | **code**, under `Errors.sol`'s one-condition-one-name rule. **No voucher is admitted here that Anchor refuses, or the reverse** — the two implementations partition the same refusal set and only the label of the second half differs. A voucher refused for being 400 seconds wide and one refused for expiring before it was issued are different mistakes by whoever wrote the 402 |
| 21 | `state.rs::split_fee` | **`Fee.splitFee` reverts `MathOverflow` where the Rust narrows silently.** `execute_slash.rs:310` uses `u64::try_from(scaled).map_err(…)`; the checked narrowing is the same idea, but Solidity's explicit `uint64(x)` truncates without complaint, so it is spelled out | **code.** Every narrowing of a money amount out of `uint256` bps arithmetic goes through `Cast.toUint64` or `Fee.narrow`, including the two that are provably unreachable today — because a file that checks two of three narrowings teaches the next implementer that the third was a judgement call |
| 22 | `error.rs:74`, `error.rs:138` | **the `SignerIsNot*` renames.** `MissingBuyerSignature` → `SignerIsNotPayer` on the redeem path and `SignerIsNotBuyer` on the escrow-control paths. `MissingVerifierSignature` was renamed `SignerIsNotVerifier`, which never had a producer and was removed in D-18: the attestation path raises `VerifierNotRegistered` / `VerifierRevoked` / `VerifierKeyExpired` from `assertCanSign` | **code** |
| 23 | `error.rs:179`, `withdraw.rs:99` | **no destination, no destination error.** `DestinationIsEscrowAta` and `DestinationIsVault` have no EVM condition: `withdraw()` and `withdrawStake` take no destination and pay `msg.sender` (D-15). `DestinationIsVault` was declared for parity and removed in D-18 | **code** |
| 24 | `attestation.rs:483,487` | **the order of the four voucher-window checks is load-bearing here and a preference there.** Anchor uses `saturating_add`, so the order is free; Solidity's checked `+` means `v.expiresAt + REDEEM_GRACE_SECONDS` cannot overflow only *because* the lifetime bound pins `expiresAt <= issuedAt + 300` and the skew bound pins `issuedAt <= nowTs + 120` above it | **code.** Move either check below that line and a voucher with a large `expiresAt` or a large `issuedAt` answers `Panic(0x11)` instead of its named refusal. Both legs are pinned at exact and `type(uint64).max` by `test_boundary_theVoucherClockWindowIsBoundedAtBothEnds` |
| 25 | `update_config.rs` | **`updateConfig` takes the WHOLE parameter set and has no compare-and-swap, so two concurrent admin calls silently lose one of the two.** Whoever lands second overwrites every field, including the ones the first caller changed and did not mean to touch | **code, and it is safe ONLY because the admin is one key.** See the trigger below — it is a decision with an expiry condition, not a permanent ruling |
| 26 | key custody | signing keys (verifier, relayer) are held by the backend, not by these contracts | — nothing in this repository holds a key; key custody is documented in the backend (`assay-backend` repo) |
| 27 | `cancel_slash.rs`, `state.rs::SlashStatus` | **the dispute (D-19).** A provider may `disputeSlash` a `Pending` record before its `executableAt`, which freezes it as `Disputed` (appended last to `SlashStatus`; the reservation stays). The ARBITER — a new, narrow role on `X402Config`, a person's wallet or a Safe — `upholdSlash`es it back to `Pending` (executable from now, every `executeSlash` check still applies) or `cancelSlash`es it; the admin may cancel too. An unruled dispute is released by anyone after `DISPUTE_TIMEOUT_SECONDS` (30 d, `CancelReason.DisputeUnresolved`). Anchor has none of this | **code**, by the owner's decision: a compromised backend (the verifier key) can no longer slash a provider who disputes, and routine cancels no longer need the admin key |
| 28 | `set_paused.rs:14-21`, `withdraw.rs:22-33`, `withdraw_stake.rs:14-16` | **pause closes the exits (D-19).** `withdraw`, `requestWithdraw(BySig)`, `setLimits(BySig)`, `authorizeDelegate(BySig)`, `depositStake(For)`, `requestUnstake` and `withdrawStake` refuse `ProgramPaused`. Anchor never pauses an owner exit. Still open while paused: `revokeDelegate(BySig)`, `disputeSlash`, `upholdSlash`, `cancelSlash`, `expireSlash`, every config call and every upgrade. The pause moves no money | **code**, by the owner's explicit decision; the cost is risk register §18 |
| 29 | — (EVM only) | **the address blocklist (D-19).** `X402Config.blocked(address)`: the admin blocks and unblocks, the arbiter may only block. A blocked address is refused at the same doors the pause closes (as buyer, payer, payee, delegate, provider or funder); it may still `revokeDelegate` and `disputeSlash`. Nothing moves a blocked party's funds | **code**, by the owner's decision; risk register §18 |
| 30 | `constants.rs:266` | **the slash delay is an admin parameter (D-19)**: `X402Config.setSlashDelay`, default `SLASH_DELAY_SECONDS` (72 h, also what an upgraded proxy reads), bounds `[10 min, unbondingPeriodSeconds − 8 d]`. `executableAt` stays frozen at proposal | **code**, for testing; the constant's own NatSpec ("a delay the admin key could shorten is a delay a stolen admin key sets to zero") is answered by the 10-minute floor, not by the constant, and that is accepted in risk register §18 |

### The trigger on row 25, stated exactly

**The moment more than one signer can initiate a parameter change, `updateConfig` gains a
compare-and-swap argument.** Three lines:

```solidity
function updateConfig(ParamSet calldata p, address newAdmin, bytes32 expectedParams)
    external
    onlyAdmin
{
    if (keccak256(abi.encode(params())) != expectedParams) revert ParamsChangedUnderneath();
    …
```

The caller reads `params()`, hashes it, and includes the hash in the transaction it signs; a second
change landing in between makes the first revert instead of silently reverting the second's work.

**"Read `params()` in the same block you sign from" is NOT a defence, and must appear nowhere as
one.** It is not a defence for three separate reasons, each sufficient: a Ledger signature is
produced minutes before it is broadcast, so "the same block" is not a state the signer can occupy;
the sequencer decides ordering, so two transactions signed against the same block still land in an
order neither signer chose; and it is a procedure, so it holds exactly as long as everyone
remembers it, which is the property a multi-signer setup exists to stop relying on. If this
paragraph is ever reduced to "read it in the same block", the reduction is wrong.

Today the admin is a single Ledger (D-1, D-6) and no second signer exists, so the exposure is not
reachable. It becomes reachable the moment the admin moves to a Safe, a multisig, or any
arrangement where two humans can initiate. **That migration is the change that must carry these
three lines with it** — under D-7 adding the argument is a function-signature change and therefore
an upgrade, not a redeploy.

---

## 2. Errors declared with no producer — removed in D-18

The error-catalogue gate (`script/check-errors.sh`) enumerates every `error X();` in
`src/Errors.sol` and every `revert X()` in `src/`, and reports the difference. Its first run found
five, and the decision then was to KEEP them for name parity with `error.rs`.

**D-18 reversed that decision**: a reader of `Errors.sol`, or an auditor, reads a declared error as
a condition that is checked on chain, and these five are not. They were removed, with their entries
in the backend's `error-selectors.ts`:

| # | Error | Why it had no producer | What fires instead |
|---|---|---|---|
| 1 | `EscrowLimitsRequireBuyer` (`error.rs:165`, `open_escrow.rs:96`) | It names "non-zero limits set with NO buyer authorisation offered at all". `setLimits` takes `msg.sender` as the buyer, and `setLimitsBySig` refuses first | `SignerIsNotBuyer` on the relayed path |
| 2 | `DestinationIsVault` (folds `error.rs:179`) | `withdraw()` and `withdrawStake` take no destination and pay `msg.sender` (D-15) | — the condition cannot be expressed |
| 3 | `NotBuyer` | Every buyer-authority path is `msg.sender` or a recovered EIP-712 signer | `SignerIsNotBuyer` |
| 4 | `SignerIsNotVerifier` (renames `error.rs:74`) | `proposeSlash` recovers with `Sig.recover`, then `CONFIG.assertCanSign` asks three sharper questions | `VerifierNotRegistered` / `VerifierRevoked` / `VerifierKeyExpired` |
| 5 | `AmountExceedsUint64` | A duplicate of `MathOverflow`, which `Cast.toUint64` raises | `MathOverflow` |

Two errors also went with the doors that produced them: `WalletCheckUnderfunded` (EIP-1271) and
`Permit2NotConfigured` (the Permit2 deposit). The `Errors.sol` header carries the new accounting
(47 shared, 34 EVM-only, 8 absent, all named).

## 3. Parity notes moved out of the source (D-18)

The source used to carry these as natspec. They describe code that no longer exists, or Solana
history that a reader of the EVM contract does not need, so they live here.

- **EIP-1271 wallet authority** (`_voucherAuthority` branch (c), `_isValidERC1271`,
  `ERC1271_GAS_LIMIT` = 150,000, `ERC1271_GAS_RESERVE` = 10,000). A capped STATICCALL copying
  at most one word of return data, added for agent delegation (D-16), hardened twice (gas burn,
  return-data bomb). It was the only call to payer-chosen code in the money path, it ran inside the
  batch loop, and the backend never used it (`allowErc1271: false`). Removed. A contract-wallet
  payer calls `authorizeDelegate` directly. Anchor never had it.
- **The lenient `Sig.tryRecover`** existed only for that branch. One strict recovery remains, and
  the single-call-site gate still counts exactly one.
- **The Permit2 deposit** (`depositWithPermit2`, `IPermit2`, D-11). It credited the Permit2
  `owner` (never the caller), used the measured-delta check, and was never called by any product
  path. Removed. The `PERMIT2` slot stays declared under its label, because the layout is
  append-only.
- **`recoverVoucherSigner`** was an off-chain pre-flight view. Its own natspec recorded it as not
  load-bearing, and the backend recovers off chain. Removed. `test/X402Escrow.domain.t.sol` drives
  the same recovery properties through a test harness over `Sig.recover`.
- **`verifierExpiry`** was the `IX402Config` half of `VerifierKey.expiresAt`. Nothing called it.
  `X402Stake.expireSlash` reads `canSign`, not this view, and an older comment wrongly said it did.
  `verifierKey(addr).expiresAt` is the same value.
- **`Fee.narrow` / `Window.narrow`** were one-line forwarders to `Cast.toUint64`, kept from before
  `Cast` existed. They are inlined now. The rule they argued for, that no money narrowing is a bare
  cast, is unchanged.
- **The "exactly TWO relayed doors" comments** predate agent delegation. There are four
  (`setLimitsBySig`, `requestWithdrawBySig`, `authorizeDelegateBySig`, `revokeDelegateBySig`),
  all through `_consumeAuth`, and since D-18 the four direct twins consume the same `authNonce`.
