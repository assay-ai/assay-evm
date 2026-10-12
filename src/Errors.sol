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
/// `error.rs` declares **55** `ErrorCode` variants. **47** of them appear below under the same
/// name, and **34** errors below have no Anchor counterpart at all. The remaining **8** are
/// absent, and named here so that "the port is complete" is a claim a reader can check. (The
/// counts are the output of a set difference over the two files, as `script/check-errors.sh`
/// computes it; if you change either file, redo it rather than adjusting these by one.)
///
/// - **No EVM condition at all:** `EscrowMismatch` (the EVM voucher has no `pay_to`),
///   `StakeMintProgramNotSupported` (the asset question here is [`AssetDecimalsNotSix`]),
///   `EscrowLimitsRequireBuyer` (`setLimits` reads `msg.sender` and `setLimitsBySig` refuses with
///   [`SignerIsNotBuyer`] first, so "armed limits with no buyer authorisation" cannot arise),
///   `NotBuyer` (every buyer door is keyed by `msg.sender` or a recovered signer), and
///   `DestinationIsVault` / `DestinationIsEscrowAta` (`withdraw` and `withdrawStake` take no
///   destination and pay `msg.sender`, D-15).
/// - **Absorbed by a truer name:** `MissingBuyerSignature` → [`SignerIsNotPayer`] on the redeem
///   path and [`SignerIsNotBuyer`] on the escrow-control paths; `MissingVerifierSignature` →
///   `VerifierNotRegistered` / `VerifierRevoked` / `VerifierKeyExpired`, which `assertCanSign`
///   raises for the recovered attestation signer. `ecrecover` always yields *some* address, so a
///   "missing" signature is never the condition — a signature by the wrong key is.
///
/// Five errors with no producer were removed in D-18 rather than kept for name parity
/// (`AmountExceedsUint64`, `NotBuyer`, `SignerIsNotVerifier`, `EscrowLimitsRequireBuyer`,
/// `DestinationIsVault`), with `WalletCheckUnderfunded` (EIP-1271) and `Permit2NotConfigured`
/// (the Permit2 deposit), whose doors went. `docs/divergences.md` carries the history.
///
/// The 34 EVM-only entries are EIP-712 and ERC-20 conditions Solana does not have (signature
/// malleability, `v` normalisation, deadline/nonce replay and the signature lifetime cap,
/// fee-on-transfer tokens, the explicit batch bound, [`WithdrawDelayTooShort`]), the eleven of
/// voucher delegation, and the four of the owner/admin split and the seq jump cap.
///
/// The six PDA seed constants in `constants.rs:5-60` have no counterpart in `Constants.sol` for
/// the same kind of reason; that omission is recorded there, not here.

// --- generic -----------------------------------------------------------------
error ZeroAmount();
error ZeroAddress();
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
/// EVM only. The caller of an upgrade on `X402Stake` or `X402Escrow` is not `CONFIG.owner()`.
/// (`X402Config`'s own owner-gated doors use OpenZeppelin's `onlyOwner`, which raises
/// `OwnableUnauthorizedAccount(account)` for the same condition.)
error NotOwner();
/// EVM only. `renounceOwnership` is disabled: an owner of `address(0)` would leave all three
/// contracts unupgradeable and the admin unreplaceable, for ever.
error OwnershipCannotBeRenounced();
/// EVM only. `updateConfig(p, newAdmin)` with a non-zero `newAdmin`. Appointing the admin is the
/// OWNER's power (`setAdmin`); the admin cannot hand its own role on.
error AdminChangeRequiresOwner();

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
/// `error.rs:138`'s `MissingBuyerSignature` on the escrow-control paths — the recovered signer
/// over a [`SetLimits`] or [`RequestWithdraw`] message is not the `buyer` it names.
error SignerIsNotBuyer();
error SignatureExpired();
/// EVM only (D-18). A relayed authorisation whose `deadline` is more than
/// `MAX_SIGNATURE_LIFETIME_SECONDS` past the block that lands it.
error SignatureDeadlineTooFar();
error BadNonce();

// --- voucher -----------------------------------------------------------------
error VoucherSeqZero();
error VoucherSeqNotIncreasing();
/// EVM only. `seq > seqHigh + Constants.MAX_SEQ_GAP`: one voucher may not move the high-water mark
/// so far that it strands the payer's sequence space (a `seq` of `2^64 - 1` would void every
/// later voucher for ever).
error VoucherSeqGapTooLarge();
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
error ProviderBelowMinimumStake();
error BatchTooLarge();
error BatchLengthMismatch();
error EmptyBatch();

// --- voucher delegation (EVM only) -----------------------------------------------
/// The delegate named in an authorisation is the payer itself — the payer's own key already
/// signs, so the record would grant nothing and would read as a second authority.
error DelegateIsPayer();
/// A delegate cap of `0`, or a per-call cap above the per-window cap.
error DelegateCapsInvalid();
/// A delegate cap above the escrow's own ceiling at the moment of authorisation. The escrow
/// ceilings keep applying at redemption too; this refuses a record that promises more.
error DelegateCapsExceedEscrowLimits();
/// `validUntil` not in the future, or further out than `MAX_DELEGATION_LIFETIME_SECONDS`.
error DelegateValidUntilInvalid();
/// An authorisation identical to the standing one — refused like [`EscrowLimitsUnchanged`].
error DelegationUnchanged();
/// A revocation of a delegate that is not authorised (never was, or already revoked).
error DelegateNotActive();
/// The payer already holds `MAX_DELEGATES_PER_PAYER` delegates; revoke one first.
error TooManyDelegates();
/// A voucher signed by a delegate the payer revoked.
error DelegateIsRevoked();
/// A voucher redeemed after its delegate's `validUntil`.
error DelegateIsExpired();
/// A delegate-signed voucher above the delegate's own per-call cap.
error DelegateVoucherExceedsPerCallLimit();
/// A delegate-signed voucher that would take the delegate's own rolling window past its cap.
error DelegateWindowLimitExceeded();

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
error AssetDecimalsNotSix();

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
