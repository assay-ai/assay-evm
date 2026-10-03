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
| 13 | §C.3, Anchor `Config` | ~~two-step admin is an addition~~ — **withdrawn by design decision D-1; the admin moves one step inside `updateConfig`, as in `update_config`** | — |
| 14 | §C.2 | `SlashStatus` has no `Expired` member; expiry is `Cancelled` + `CancelReason` on the event | **code**, matching the Anchor enum |
| 15 | §C.5 / measured | a plain ERC-20 `transfer` to the escrow contract credits nobody — every deposit goes through `deposit*` | **code** (`test_donationsDoNotBecomeAnybodysBalance`); the spec was corrected |
| 16 | §C.1, an earlier draft decision | the three contracts are **upgradeable** — UUPS proxies, upgrade authority = `Config.admin` (a Ledger), immediate, no timelock — for parity with the Solana program's `BPFLoaderUpgradeable` upgrade authority | **design decision D-1**, which explicitly reverses the earlier immutable design. §C.1's "no proxy, no upgrade key" and every draft repeating it are superseded |
| 17 | §C.1 / D-7 | a *layout* change is no longer automatically a redeploy: an **append** under the upgrade-safety gate is an upgrade, and only a non-appendable change forces a new proxy | **code** (D-7). `script/check-layout.py` is the gate, and `test/MUTATION-LOG.md` § *Upgrade-safety gate* records it refusing an insertion, refusing to launder one under `--update`, and allowing an append while still failing CI until the snapshot is regenerated |
| 18 | an earlier draft decision | the treasury on 4663 is a **single-signer Ledger EOA**, not a Safe — a custody downgrade against Solana's Squads multisig, accepted (a multisig is the planned direction) | **design decision**; the Safe measurement in `chain-facts.md` stays as information and blocks nothing |
| 19 | `state.rs::SlashStatus` | **`SlashStatus.None == 0`, so every member is one higher than its Solana twin: `Pending` is 1 here and 0 there, `Executed` 2/1, `Cancelled` 3/2.** | **code, necessarily.** On Solana "no record" is the absence of the `["slash", request_id]` PDA; a Solidity mapping has no absence — every unread slot is zero — so the zero value must *be* "no record", or an unproposed request id reads back as `Pending` and `SlashAlreadyExists` never fires. **MAP, NEVER CAST.** Any backend, indexer or reconciler that moves a status between the two chains converts by name. A numeric cast turns an executed judgement on one chain into a cancelled one on the other, silently, and the value is a `uint8` on both so nothing type-checks |
| 20 | `attestation.rs:477-481` | **`InvalidVoucherWindow` is SPLIT in two.** Anchor raises that one name for both `expires_at > issued_at` and `expires_at - issued_at <= VOUCHER_MAX_LIFETIME`; the port gives the width bound its own name, `VoucherLifetimeTooLong` | **code**, under `Errors.sol`'s one-condition-one-name rule. **No voucher is admitted here that Anchor refuses, or the reverse** — the two implementations partition the same refusal set and only the label of the second half differs. A voucher refused for being 400 seconds wide and one refused for expiring before it was issued are different mistakes by whoever wrote the 402 |
| 21 | `state.rs::split_fee` | **`Fee.splitFee` reverts `MathOverflow` where the Rust narrows silently.** `execute_slash.rs:310` uses `u64::try_from(scaled).map_err(…)`; the checked narrowing is the same idea, but Solidity's explicit `uint64(x)` truncates without complaint, so it is spelled out | **code.** Every narrowing of a money amount out of `uint256` bps arithmetic goes through `Cast.toUint64` or `Fee.narrow`, including the two that are provably unreachable today — because a file that checks two of three narrowings teaches the next implementer that the third was a judgement call |
| 22 | `error.rs:74`, `error.rs:138` | **the `SignerIsNot*` renames.** `MissingVerifierSignature` → `SignerIsNotVerifier`; `MissingBuyerSignature` → `SignerIsNotPayer` on the redeem path and `SignerIsNotBuyer` on the escrow-control paths | **code, by design.** On Solana the check is "does this transaction carry an ed25519 instruction proving key K signed these bytes?", and its failure really is a *missing* signature. On EVM `ecrecover` always yields *some* address, so the only question that can be asked is whether it is the right one. `MissingBuyerSignature` would name a condition the chain cannot produce and would read as "no signature supplied" when what happened is "a valid signature by the wrong key". §D.5's ordered list names `SignerIsNotPayer` at exactly this position |
| 23 | `error.rs:179`, `withdraw.rs:99` | **the `DestinationIsEscrowAta` fold.** On Solana the buyer's escrow and the stake vault are different kinds of token account and get a check each; here each is "the contract holding the money", one address, so `DestinationIsEscrowAta` folds into `DestinationIsVault` | **code** — with the correction that **`DestinationIsVault` has no producer either** (see table 2, row 2). The condition is structurally absent on EVM, not merely renamed: `withdraw()` pays `msg.sender` and takes no destination (D-15), so there is no destination to compare. The fold is real; what it folds into is a name nothing raises |
| 24 | `attestation.rs:483,487` | **the order of the four voucher-window checks is load-bearing here and a preference there.** Anchor uses `saturating_add`, so the order is free; Solidity's checked `+` means `v.expiresAt + REDEEM_GRACE_SECONDS` cannot overflow only *because* the lifetime bound pins `expiresAt <= issuedAt + 300` and the skew bound pins `issuedAt <= nowTs + 120` above it | **code.** Move either check below that line and a voucher with a large `expiresAt` or a large `issuedAt` answers `Panic(0x11)` instead of its named refusal. Both legs are pinned at exact and `type(uint64).max` by `test_boundary_theVoucherClockWindowIsBoundedAtBothEnds` |
| 25 | `update_config.rs` | **`updateConfig` takes the WHOLE parameter set and has no compare-and-swap, so two concurrent admin calls silently lose one of the two.** Whoever lands second overwrites every field, including the ones the first caller changed and did not mean to touch | **code, and it is safe ONLY because the admin is one key.** See the trigger below — it is a decision with an expiry condition, not a permanent ruling |
| 26 | key custody | signing keys (verifier, relayer) are held by the backend, not by these contracts | — nothing in this repository holds a key; key custody is documented in the backend (`assay-backend` repo) |

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

## 2. Errors declared with no producer — what `check-errors.sh` found

The error-catalogue gate (`script/check-errors.sh`) enumerates every `error X();` in `src/Errors.sol` and every
`revert X()` in `src/`, and reports the difference. Its first run found **five**, not the one that
was known.

**The decision, for all five: KEEP the declaration, do not delete.** Four reasons, and the fourth
is the one that decides it:

1. **Deleting changes nothing on chain.** A declared-but-unproduced custom error contributes no
   bytecode and no gas; it is an ABI entry and nothing else. So the entire question is what the
   file *teaches*, not what it costs.
2. **Four of the five carry an Anchor name or an Anchor mapping.** `Errors.sol`'s whole design is
   one name per condition across both chains, with an explicit accounting against `error.rs` so
   that "the port is complete" is a claim a reader can check by name. Deleting these deletes the
   ability to check it.
3. **The accounting numbers move either way** — and they are now gate-enforced, so keeping them is
   not a licence to let them rot.
4. **Deletion fixes today's five and leaves tomorrow's sixth undetected.** The gate does not: it
   prints the list on every run, so a name appearing on it for the first time is a review item the
   moment it appears. A one-off cleanup is strictly weaker than a standing report.

What keeping costs, said plainly: a reader of `Errors.sol` could believe these five conditions are
checked on chain. **That is what this table is for**, and each row names what actually fires
instead.

| # | Error | Why it has no producer | What fires instead |
|---|---|---|---|
| 1 | `EscrowLimitsRequireBuyer` (`error.rs:165`, `open_escrow.rs:96`) | **Structurally unreachable, not unchecked.** It names "non-zero limits set with NO buyer authorisation offered at all". Neither door can reach that state: `setLimits` takes `msg.sender` *as* the buyer, and `setLimitsBySig` refuses before `_setLimits`. On Solana `is_signer` is a flag that can be false while the account is still present; here the authority **is** the identity the write is keyed by. Earlier natspec predicted `setLimitsBySig` would be a producer — measured against the shipped code, it is not | `SignerIsNotBuyer`, on `setLimitsBySig`. Nothing at all on `setLimits`, because there is nothing to refuse |
| 2 | `DestinationIsVault` (folds `error.rs:179`) | `withdraw()` takes no destination and pays `msg.sender` (D-15), and `withdrawStake` is the same shape. There is no destination argument anywhere in `src/`, so there is nothing to compare against the vault address | nothing — the argument the check would guard does not exist |
| 3 | `NotBuyer` | Same root as row 1: every buyer-authority path is either `msg.sender` or a recovered EIP-712 signer | `SignerIsNotBuyer` on the relayed paths |
| 4 | `SignerIsNotVerifier` (renames `error.rs:74`) | `proposeSlash` recovers the signer with `Sig.recover` and then calls `CONFIG.assertCanSign(verifier)`, which asks **three sharper questions** in Anchor's order. "The recovered signer is not a registered verifier" is answered by the first of them, by name | `VerifierNotRegistered`, then `VerifierRevoked`, then `VerifierKeyExpired` |
| 5 | `AmountExceedsUint64` | **The weakest of the five, and the one to delete first.** It is a pure duplicate: `Cast.toUint64` raises `MathOverflow` for exactly this condition, and `MathOverflow` has an Anchor twin (`execute_slash.rs:310`) while this name does not. It violates `Errors.sol`'s own one-condition-one-name rule | `MathOverflow`, from `Cast.toUint64` |

**When row 5 is resolved:** the next change that touches `src/Errors.sol` for any other reason.
Deleting it moves the EVM-only count 21 → 20, and `script/check-errors.sh` fails until the header
is updated in the same commit — which is the review this table wants.

**`InvalidAdmin` is the intentional gap in the other direction.** It has exactly **one** producer,
and the `address(0)` sentinel on the `updateConfig` path is the refusal — `newAdmin == address(0)`
means "leave the admin alone", exactly as `Pubkey::default()` is refused on Solana. So a selector
table built from the deployed ABI and compared against the reverts an indexer has actually seen
will always show a gap there. It is not drift.
