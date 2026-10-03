// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.24;

/// The shared error catalogue — one name per condition, across all three contracts.
///
/// File-level rather than per-contract so that a condition cannot acquire two names by being
/// checked in two places, and so an off-chain decoder has one selector table to build. There are
/// **no revert strings anywhere in this codebase**: a string costs bytecode proportional to its
/// length, is truncated by half the tooling that surfaces it, and cannot carry a parameter.
///
/// Names match the Anchor program's `programs/x402-payment/src/error.rs` (repository
/// `assay-solana`) wherever the condition has a
/// behavioural analogue, so a failure means the same thing on both chains and one incident
/// runbook covers both.
///
/// # The accounting against `error.rs`, in full
///
/// `error.rs` declares **55** `ErrorCode` variants. **50** of them appear below under the same
/// name, and **21** errors below have no Anchor counterpart at all. The remaining **five** are
/// listed here, every one of them, so that "the port is complete" is a claim a reader can check
/// rather than take. (The counts are the output of a set difference over the two files, not an
/// estimate; if you change either file, redo it rather than adjusting these by one.)
///
/// `MathOverflow` was once in this list and is not any more; the reason it came back is at its
/// declaration, and the counts above already include it.
///
/// **Two have no EVM condition at all.**
///
/// - `EscrowMismatch` (`error.rs:141`, `redeem_voucher.rs:132`) — guards the voucher's `pay_to`
///   against its payer's escrow PDA. The EVM voucher has no `payTo` field at all (one
///   contract holds every buyer, so the escrow is determined by `verifyingContract` + `payer`),
///   so the condition cannot arise.
/// - `StakeMintProgramNotSupported` (`error.rs:27`, `initialize_config.rs:31`) — "this mint is
///   SPL Token, not Token-2022". The EVM question about the settlement asset is a different one;
///   [`AssetDecimalsNotSix`] asks it.
///
/// **Three are absorbed by a differently-named error, and the name is the truer one here.**
///
/// - `DestinationIsEscrowAta` (`error.rs:179`, `withdraw.rs:99`) → [`DestinationIsVault`]. On
///   Solana the buyer's escrow and the stake vault are different kinds of token account and get a
///   check each. Here each is simply "the contract holding the money", one address, one check.
/// - `MissingVerifierSignature` (`error.rs:74`, `attestation.rs:554`) → [`SignerIsNotVerifier`].
/// - `MissingBuyerSignature` (`error.rs:138`, `redeem_voucher.rs:142`) → [`SignerIsNotPayer`] on
///   the redeem path and [`SignerIsNotBuyer`] on the escrow-control paths.
///
/// Every other variant keeps its name, including `EscrowLimitsRequireBuyer` (`error.rs:165`,
/// `open_escrow.rs:96`), whose EVM *mechanism* is a signature rather than an `is_signer` flag but
/// whose condition is unchanged — see its declaration below.
///
/// **Why the two `MissingXSignature` variants change name.** On Solana the check is "does this
/// transaction carry an ed25519 instruction proving key K signed these bytes?", and its failure
/// really is a *missing* signature. On EVM there is no such state: `ecrecover` always yields
/// *some* address, so the only question that can be asked is whether the address it yielded is
/// the one required. `MissingBuyerSignature` would name a condition the chain cannot produce,
/// and would read as "no signature was supplied" when what happened is "a valid signature by
/// the wrong key was supplied" — the difference an incident review needs. The EVM design
/// settles it independently: its ordered redeem check list names `SignerIsNotPayer` for exactly
/// this position, so the rename is by design rather than drift. `InvalidSignature`,
/// `MalleableSignature` and `BadSignatureV` cover the cases where recovery itself fails.
///
/// The 21 entries below with no Anchor counterpart are EIP-712 and ERC-20 conditions Solana does
/// not have: signature malleability, `v` normalisation, deadline/nonce replay, fee-on-transfer
/// tokens, the `uint256` → `uint64` narrowing, the batch bound the EVM has to state explicitly, and
/// [`WithdrawDelayTooShort`], which is a Rust `const _: () = assert!(…)` that Solidity can only
/// spell at runtime.
///
/// The six PDA seed constants in `constants.rs:5-60` have no counterpart in `Constants.sol` for
/// the same kind of reason; that omission is recorded there, not here.

// --- generic -----------------------------------------------------------------
error ZeroAmount();
error ZeroAddress();
/// Every amount *argument* is `uint64` (the backend's `MONEY_MAX_ATOMIC_UNITS`), but ERC-20
/// speaks `uint256`. The narrowing is checked, never truncated.
error AmountExceedsUint64();
/// `error.rs:10`. **This entry was previously listed as having no EVM condition, and that was
/// wrong.** The reasoning was that Solidity 0.8's checked arithmetic reverts with `Panic(0x11)`
/// before any hand-written check could run, which is true of `+`, `-`, `*` and `/` — and false of
/// the one operation the money path actually needs it for. An **explicit narrowing cast**,
/// `uint64(someUint256)`, is not checked: it truncates silently, and a wrapped amount on the money
/// path is exactly what `MathOverflow` exists to refuse. Its Anchor twin is
/// `execute_slash.rs:310`'s `u64::try_from(scaled).map_err(|_| error!(ErrorCode::MathOverflow))`.
///
/// Raised by [`Fee.bpsOf`] and [`Fee.splitFee`] when the widened `uint256` share does not fit back
/// into the `uint64` every amount argument is. Reach for it at any other checked narrowing of a
/// value that came out of `uint256` bps arithmetic; `Panic(0x11)` still covers ordinary overflow,
/// and this error should not be hand-rolled where the arithmetic already reverts on its own.
error MathOverflow();
error ProgramPaused();

// --- authority ---------------------------------------------------------------
error NotAdmin();
/// `error.rs:16`. Its Anchor site is `update_config` handing the admin role to the zero key.
/// **Its EVM producer is `updateConfig`, not [`ParamSet`].** `updateConfig`'s signature
/// is `updateConfig(ParamSet calldata p, address newAdmin)` — the admin is a separate argument
/// by design (`newAdmin == address(0)` means "leave the admin alone", so the zero
/// address doubles as the sentinel exactly as `Pubkey::default()` is refused on Solana). So
/// `ParamSet` omitting `admin` is correct and only looks like a gap.
error InvalidAdmin();
error NotRedeemer();
error NotBuyer();

// --- parameters --------------------------------------------------------------
error InvalidTakeRateBps();
error InvalidSplitBps();
error InvalidSlashCapBps();
error InvalidVerifierDailyCap();
error InvalidMinimumStake();
error MissingBeneficiary();
error MissingRedeemer();
error UnbondingPeriodTooShort();
error UnbondingPeriodTooLong();

// --- verifier registry -------------------------------------------------------
error VerifierRevoked();
error VerifierAlreadyRevoked();
error VerifierKeyExpired();
error VerifierNotRegistered();
error VerifierAlreadyRegistered();
error InvalidVerifierExpiry();

// --- signatures --------------------------------------------------------------
error InvalidSignature();
/// EIP-2: `s > secp256k1n/2`. Without this every signature has a second valid encoding.
error MalleableSignature();
error BadSignatureV();
/// `error.rs:138`'s `MissingBuyerSignature` on the redeem path — the recovered signer over a
/// [`Voucher`] is not its `payer`. The EVM design's ordered check list names this error at this
/// position.
error SignerIsNotPayer();
/// `error.rs:74`'s `MissingVerifierSignature` — the recovered signer over a [`SlashAttestation`]
/// is not a registered, unrevoked, unexpired verifier key.
error SignerIsNotVerifier();
/// `error.rs:138`'s `MissingBuyerSignature` on the escrow-control paths — the recovered signer
/// over a [`SetLimits`] or [`RequestWithdraw`] message is not the `buyer` it names.
error SignerIsNotBuyer();
error SignatureExpired();
error BadNonce();

// --- voucher -----------------------------------------------------------------
error VoucherSeqZero();
error VoucherSeqNotIncreasing();
error VoucherExpired();
error VoucherNotYetValid();
error InvalidVoucherWindow();
/// **A SPLIT, not a rename.** `attestation.rs:477-481` raises `InvalidVoucherWindow` for BOTH of
/// its first two checks — `expires_at > issued_at` and `expires_at - issued_at <=
/// VOUCHER_MAX_LIFETIME_SECONDS` — so one Anchor name covers two conditions. This port gives the
/// width bound its own name, under this file's rule that one condition gets one name: a voucher
/// refused for being 400 seconds wide and a voucher refused for expiring before it was issued are
/// different mistakes by whoever wrote the 402, and an operator reading a log should be able to
/// tell them apart without the amount.
///
/// The consequence for parity is worth stating exactly: **no voucher is accepted here that Anchor
/// refuses, or the reverse.** The two implementations partition the same refusal set; only the
/// label differs, and only for the second half of it. Recorded in `docs/divergences.md`; the
/// argument
/// at the check itself is at `X402Escrow.sol`'s
/// `require_valid_voucher_window` port.
error VoucherLifetimeTooLong();
error VoucherExceedsPerCallLimit();
error EscrowWindowLimitExceeded();
error EscrowInsufficient();
error EscrowLimitsUnchanged();
/// `error.rs:165`, enforced at `open_escrow.rs:96`:
/// `buyer.is_signer || (max_voucher_amount == 0 && max_per_window == 0)`. A bare identity may
/// open a *disarmed* escrow; only the buyer's own signature may open an armed one, so nobody can
/// pre-arm limits against an address they do not control.
///
/// The condition survives the port; only its mechanism changes. Solana reads `is_signer` off the
/// transaction; here the buyer's consent arrives as an EIP-712 [`SetLimits`] message, which is
/// the entire reason `SET_LIMITS_TYPEHASH` exists. It is distinct from [`SignerIsNotBuyer`]:
/// that one fires when a signature *was* supplied and recovered to the wrong address; this one
/// fires when non-zero limits are being set with no buyer authorisation offered at all.
error EscrowLimitsRequireBuyer();
error ProviderBelowMinimumStake();
error BatchTooLarge();
error BatchLengthMismatch();
error EmptyBatch();

// --- escrow withdrawal -------------------------------------------------------
error WithdrawNotYetAvailable();
error NoWithdrawRequested();
/// `constants.rs:285`'s build-time assertion, moved to `X402Escrow.initialize`. Rust states
/// `WITHDRAW_DELAY_SECONDS > CLOCK_SKEW + VOUCHER_MAX_LIFETIME + REDEEM_GRACE` as a `const _: ()
/// = assert!(…)`, so lowering the delay fails the build. Solidity has no constant assertion —
/// `assert` is a runtime opcode and a constant expression cannot invoke one — so the inequality
/// becomes a check `initialize` makes and this is what it raises. Every term is a compile-time
/// constant, so today the optimiser folds it away; it exists so that a future edit to
/// `Constants` produces a deployment that cannot be initialised rather than one that silently
/// lets a withdrawal mature under a live voucher.
error WithdrawDelayTooShort();

// --- transfers ---------------------------------------------------------------
/// A fee-on-transfer or rebasing token: the balance delta is not the amount asked for. The
/// program's whole accounting rests on `vault balance == sum of the ledger`.
error TransferAmountMismatch();
error Permit2NotConfigured();
error AssetDecimalsNotSix();
/// error.rs `DestinationIsVault` — the contract holding the money cannot be the other side of
/// its own transfer. Covers `DestinationIsEscrowAta` too; see the note at the top of this file.
error DestinationIsVault();

// --- stake -------------------------------------------------------------------
error InsufficientBondedStake();
error InsufficientUnbondingStake();
error UnbondingPeriodNotElapsed();

// --- slash -------------------------------------------------------------------
error AttestationExpired();
error AttestationNotYetValid();
error InvalidAttestationWindow();
error StatusDoesNotSlash();
error NothingToSlash();
error SlashCapExceeded();
error VerifierDailyCapExceeded();
error PenaltyTooSmallToSplit();
error PenaltyExceedsMaximum();
error SlashNotPending();
error SlashAlreadyExists();
error SlashNotYetExecutable();
error SlashExecutionWindowClosed();
error SlashNotExpired();
