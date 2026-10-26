// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.38;

/// @notice Shared custom errors for AssayConfig, AssayStake and AssayEscrow.
/// @dev Declared at file level so each condition has exactly one name and one selector across all
/// three contracts. No revert strings are used anywhere.

// --- generic -----------------------------------------------------------------
/// @notice An amount argument is zero.
error ZeroAmount();
/// @notice A required address argument is `address(0)`.
error ZeroAddress();
/// @notice A `uint256` or `uint128` value does not fit in `uint64` on an explicit narrowing.
error MathOverflow();
/// @notice The protocol is paused.
error ProgramPaused();

// --- authority ---------------------------------------------------------------
/// @notice The caller is not the admin (or, where permitted, the arbiter).
error NotAdmin();
/// @notice The admin would be `address(0)` or a live verifier.
error InvalidAdmin();
/// @notice The caller is not the redeemer.
error NotRedeemer();
/// @notice The caller of an upgrade on AssayStake or AssayEscrow is not the config owner.
error NotOwner();
/// @notice `renounceOwnership` is disabled.
error OwnershipCannotBeRenounced();

// --- parameters --------------------------------------------------------------
/// @notice `takeRateBps` is above `MAX_TAKE_RATE_BPS`.
error InvalidTakeRateBps();
/// @notice `slashAgentBps` is zero, or the agent and platform shares sum above 10,000 bps.
error InvalidSplitBps();
/// @notice `slashCapBps` is zero or above `MAX_SLASH_CAP_BPS`.
error InvalidSlashCapBps();
/// @notice `verifierDailyCap` is zero.
error InvalidVerifierDailyCap();
/// @notice `minimumStake` is zero or too small to cover two maximal penalties under the slash cap.
error InvalidMinimumStake();
/// @notice The treasury or slash beneficiary is `address(0)`.
error MissingBeneficiary();
/// @notice The redeemer is `address(0)`.
error MissingRedeemer();
/// @notice `unbondingPeriodSeconds` is below `MIN_UNBONDING_PERIOD_SECONDS`.
error UnbondingPeriodTooShort();
/// @notice `unbondingPeriodSeconds` is above `MAX_UNBONDING_PERIOD_SECONDS`.
error UnbondingPeriodTooLong();

// --- verifier registry -------------------------------------------------------
/// @notice The verifier key has been revoked.
error VerifierRevoked();
/// @notice The verifier key is already revoked.
error VerifierAlreadyRevoked();
/// @notice The verifier key is past its expiry.
error VerifierKeyExpired();
/// @notice The address is not a registered verifier.
error VerifierNotRegistered();
/// @notice The verifier key is already registered.
error VerifierAlreadyRegistered();
/// @notice The expiry is not in the future or exceeds `MAX_VERIFIER_KEY_LIFETIME_SECONDS`.
error InvalidVerifierExpiry();

// --- signatures --------------------------------------------------------------
/// @notice The signature is not 65 bytes or does not recover to a non-zero signer.
error InvalidSignature();
/// @notice The signature's `s` is above half the curve order (EIP-2).
error MalleableSignature();
/// @notice The signature's `v` is not 27 or 28.
error BadSignatureV();
/// @notice The recovered voucher signer is neither the payer nor an active delegate.
error SignerIsNotPayer();
/// @notice The recovered signer of a buyer authorisation is not the buyer it names.
error SignerIsNotBuyer();
/// @notice The authorisation's `deadline` has passed.
error SignatureExpired();
/// @notice The authorisation's `deadline` is more than `MAX_SIGNATURE_LIFETIME_SECONDS` ahead.
error SignatureDeadlineTooFar();
/// @notice The authorisation's nonce is not the escrow's current `authNonce`.
error BadNonce();

// --- voucher -----------------------------------------------------------------
/// @notice The voucher's `seq` is zero.
error VoucherSeqZero();
/// @notice This `(payer, seq)` has already been redeemed.
error VoucherSeqUsed();
/// @notice The voucher's `seq` exceeds `seqHigh + MAX_SEQ_GAP`.
error VoucherSeqGapTooLarge();
/// @notice The voucher is past `expiresAt + REDEEM_GRACE_SECONDS`.
error VoucherExpired();
/// @notice The voucher's `issuedAt` is beyond the clock-skew tolerance.
error VoucherNotYetValid();
/// @notice The voucher's `expiresAt` is not after its `issuedAt`.
error InvalidVoucherWindow();
/// @notice The voucher's `expiresAt - issuedAt` exceeds `VOUCHER_MAX_LIFETIME_SECONDS`.
error VoucherLifetimeTooLong();
/// @notice The voucher amount exceeds the escrow's per-voucher limit.
error VoucherExceedsPerCallLimit();
/// @notice The voucher would take the escrow's rolling window past its limit.
error EscrowWindowLimitExceeded();
/// @notice The escrow balance is below the amount requested.
error EscrowInsufficient();
/// @notice The new limits equal the current ones.
error EscrowLimitsUnchanged();
/// @notice The provider's free bonded stake is below `minimumStake`.
error ProviderBelowMinimumStake();
/// @notice The batch exceeds its maximum length.
error BatchTooLarge();
/// @notice The batch arrays differ in length.
error BatchLengthMismatch();
/// @notice The batch is empty.
error EmptyBatch();

// --- voucher delegation (EVM only) -----------------------------------------------
/// @notice The delegate is the payer itself.
error DelegateIsPayer();
/// @notice A delegate cap is zero, or the per-call cap exceeds the per-window cap.
error DelegateCapsInvalid();
/// @notice A delegate cap exceeds the escrow's own limit at the time of authorisation.
error DelegateCapsExceedEscrowLimits();
/// @notice `validUntil` is not in the future or exceeds `MAX_DELEGATION_LIFETIME_SECONDS`.
error DelegateValidUntilInvalid();
/// @notice The authorisation is identical to the current one.
error DelegationUnchanged();
/// @notice The delegate being revoked is not active.
error DelegateNotActive();
/// @notice The payer already holds `MAX_DELEGATES_PER_PAYER` delegates.
error TooManyDelegates();
/// @notice The voucher was signed by a revoked delegate.
error DelegateIsRevoked();
/// @notice The voucher was signed by a delegate past its `validUntil`.
error DelegateIsExpired();
/// @notice The delegate-signed voucher exceeds the delegate's per-call cap.
error DelegateVoucherExceedsPerCallLimit();
/// @notice The delegate-signed voucher would take the delegate's window past its cap.
error DelegateWindowLimitExceeded();

// --- escrow withdrawal -------------------------------------------------------
/// @notice The withdrawal delay has not elapsed.
error WithdrawNotYetAvailable();
/// @notice No withdrawal has been requested.
error NoWithdrawRequested();
/// @notice `WITHDRAW_DELAY_SECONDS` does not outlive the longest redeemable voucher.
error WithdrawDelayTooShort();

// --- transfers ---------------------------------------------------------------
/// @notice The received balance delta differs from the transfer amount (fee-on-transfer token).
error TransferAmountMismatch();
/// @notice The settlement asset does not have 6 decimals.
error AssetDecimalsNotSix();

// --- stake -------------------------------------------------------------------
/// @notice The amount exceeds the provider's bonded stake.
error InsufficientBondedStake();
/// @notice The amount exceeds the provider's withdrawable unbonding stake.
error InsufficientUnbondingStake();
/// @notice The unbonding period has not elapsed.
error UnbondingPeriodNotElapsed();

// --- slash -------------------------------------------------------------------
/// @notice The attestation is past its `expiresAt`.
error AttestationExpired();
/// @notice The attestation's `issuedAt` is in the future.
error AttestationNotYetValid();
/// @notice The attestation window is empty or exceeds `MAX_ATTESTATION_LIFETIME_SECONDS`.
error InvalidAttestationWindow();
/// @notice The attestation's status is not `ResponseClass.DataFail`.
error StatusDoesNotSlash();
/// @notice The provider has no stake at risk, or too little free stake for the reservation.
error NothingToSlash();
/// @notice The slash cap allows nothing for this provider.
error SlashCapExceeded();
/// @notice The penalty is too small to give each share a non-zero amount.
error PenaltyTooSmallToSplit();
/// @notice The penalty exceeds `penaltyAmount`.
error PenaltyExceedsMaximum();
/// @notice The slash record is not `Pending`.
error SlashNotPending();
/// @notice A slash record already exists for this request id.
error SlashAlreadyExists();
/// @notice The slash record's `executableAt` has not been reached.
error SlashNotYetExecutable();
/// @notice The slash record's execution grace period has ended.
error SlashExecutionWindowClosed();
/// @notice The slash record cannot be expired yet.
error SlashNotExpired();
// --- dispute, arbiter, blocklist, slash delay (EVM only) -------------------------
/// @notice `disputeSlash` was called by someone other than the record's provider.
error NotSlashedProvider();
/// @notice `disputeSlash` was called at or after the record's `executableAt`.
error DisputeWindowClosed();
/// @notice `upholdSlash` was called on a record that is not `Disputed`.
error SlashNotDisputed();
/// @notice The caller is not the arbiter.
error NotArbiter();
/// @notice A party to the call is on the blocklist.
error AddressBlocked();
/// @notice The slash delay is outside `[minSlashDelaySeconds, MAX_SLASH_DELAY_SECONDS]`.
error InvalidSlashDelay();
/// @notice `upholdSlash` was called after `disputedAt + DISPUTE_TIMEOUT_SECONDS`.
error DisputeTimedOut();
/// @notice The slash record has already been disputed once.
error SlashAlreadyDisputed();
/// @notice The full reservation does not fit under the provider's rolling window yet.
error SlashWindowNotDrained();
/// @notice The arbiter tried to unblock an address; only the admin may unblock.
error ArbiterCannotUnblock();
/// @notice The arbiter would be `address(0)`, the admin, the redeemer or a live verifier.
error InvalidArbiter();

// --- redeem into hold (EVM only) -------------------------------------------------
/// @notice The held payment is not in the `Held` state.
error HeldPaymentNotHeld();
/// @notice The held payment is not yet collectable by this caller.
error HeldNotYetCollectable();
/// @notice The refund window for the held payment has closed.
error HeldRefundWindowClosed();
/// @notice The collect hold is outside `[MIN_COLLECT_HOLD_SECONDS, MAX_COLLECT_HOLD_SECONDS]`.
error InvalidCollectHold();
