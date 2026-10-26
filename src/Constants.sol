// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.38;

/// @title Constants
/// @notice Protocol-wide constants. Durations are in seconds, amounts in settlement-asset base
/// units, rates in basis points.
library Constants {
    // --- delays and windows ----------------------------------------------------------------

    /// @dev Default slash delay (72 h): the dispute and review window between proposal and
    /// execution. The live value is `AssayConfig.slashDelaySeconds`.
    uint64 internal constant SLASH_DELAY_SECONDS = 72 * 3600;

    /// @dev Minimum settable slash delay on production chains (48 h), above the L2
    /// force-inclusion delay so a censored dispute can still land.
    uint64 internal constant MIN_SLASH_DELAY_SECONDS = 48 * 3600;

    /// @dev Minimum settable slash delay on test chains (10 min).
    uint64 internal constant MIN_SLASH_DELAY_SECONDS_TESTNET = 10 * 60;

    /// @dev Chain ids on which `MIN_SLASH_DELAY_SECONDS_TESTNET` applies; all others use the
    /// production floor.
    uint256 internal constant ROBINHOOD_TESTNET_CHAIN_ID = 46_630;
    uint256 internal constant LOCAL_CHAIN_ID = 31_337;

    /// @dev Maximum settable slash delay (22 days).
    uint64 internal constant MAX_SLASH_DELAY_SECONDS = 22 * 86_400;

    /// @dev How long a `Disputed` slash waits for the arbiter before anyone may expire it.
    uint64 internal constant DISPUTE_TIMEOUT_SECONDS = 30 * 86_400;

    /// @dev Delay between a buyer's withdrawal request and its execution (3 h). Must exceed
    /// `MAX_VOUCHER_REDEEMABLE_LIFE_SECONDS`.
    uint64 internal constant WITHDRAW_DELAY_SECONDS = 3 * 3600;

    /// @dev Delay before a payer's tightening of limits or delegations binds vouchers that were
    /// already valid, so no payer call can invalidate an admitted voucher before its deadline.
    uint64 internal constant TIGHTEN_DELAY_SECONDS = WITHDRAW_DELAY_SECONDS;

    /// @dev Minimum settable collect hold (1 min) for a redeemed payment.
    uint64 internal constant MIN_COLLECT_HOLD_SECONDS = 60;

    /// @dev Maximum settable collect hold (1 day).
    uint64 internal constant MAX_COLLECT_HOLD_SECONDS = 86_400;

    /// @dev Default collect hold (1 h) until the admin sets one.
    uint64 internal constant DEFAULT_COLLECT_HOLD_SECONDS = 3_600;

    /// @dev Time after `collectableAt` during which only the redeemer may collect or refund a
    /// held payment; afterwards anyone may collect it to the provider and refunds are closed.
    uint64 internal constant HELD_TIMEOUT_SECONDS = 7 * 86_400;

    /// @dev How long after `expiresAt` a voucher may still be redeemed (2 h).
    uint64 internal constant REDEEM_GRACE_SECONDS = 2 * 3600;

    /// @dev Maximum voucher window, `expiresAt - issuedAt` (5 min).
    uint64 internal constant VOUCHER_MAX_LIFETIME_SECONDS = 5 * 60;

    /// @dev How far ahead of the block time a voucher's `issuedAt` may be.
    uint64 internal constant CLOCK_SKEW_TOLERANCE_SECONDS = 120;

    /// @dev Longest time a voucher can remain redeemable after it is issued (7,620 s).
    uint64 internal constant MAX_VOUCHER_REDEEMABLE_LIFE_SECONDS =
        CLOCK_SKEW_TOLERANCE_SECONDS + VOUCHER_MAX_LIFETIME_SECONDS + REDEEM_GRACE_SECONDS;

    // Invariant: WITHDRAW_DELAY_SECONDS > MAX_VOUCHER_REDEEMABLE_LIFE_SECONDS, so a withdrawal
    // never matures while a voucher signed before the request is still redeemable.
    // `AssayEscrow.initialize` reverts `WithdrawDelayTooShort` if it is broken.

    /// @dev Width of the rolling windows for the provider slash cap and the escrow spend limit.
    uint64 internal constant SLASH_WINDOW_SECONDS = 86_400;

    /// @dev How long after `executableAt` a slash may still be executed.
    uint64 internal constant SLASH_EXECUTION_GRACE_SECONDS = 7 * 86_400;

    /// @dev Maximum attestation window, `expiresAt - issuedAt`.
    uint64 internal constant MAX_ATTESTATION_LIFETIME_SECONDS = 7 * 86_400;

    /// @dev Maximum verifier key lifetime; an unrotated key stops being able to slash.
    uint64 internal constant MAX_VERIFIER_KEY_LIFETIME_SECONDS = 365 * 86_400;

    /// @dev Minimum unbonding period, long enough for a breach to be proposed as a slash before
    /// the provider can exit.
    uint64 internal constant MIN_UNBONDING_PERIOD_SECONDS = 11 * 86_400;

    /// @dev Maximum unbonding period, bounding how long the admin can lock provider stake.
    uint64 internal constant MAX_UNBONDING_PERIOD_SECONDS = 30 * 24 * 3600;

    // --- basis points ----------------------------------------------------------------------

    /// @dev Maximum platform take rate (30%).
    uint16 internal constant MAX_TAKE_RATE_BPS = 3_000;

    /// @dev Maximum share of at-risk stake one slash record and one rolling window may take.
    uint16 internal constant MAX_SLASH_CAP_BPS = 5_000;

    /// @dev Basis-point denominator. It is `uint16`, so multiply in `uint256` first:
    /// `uint16 * uint16` overflows.
    uint16 internal constant BPS_DENOMINATOR = 10_000;

    // --- EVM only --------------------------------------------------------------------------

    /// @dev Maximum distance a redeemed voucher's `seq` may be above the payer's `seqHigh`.
    uint64 internal constant MAX_SEQ_GAP = 1_000_000;

    /// @dev Maximum vouchers per redeem batch.
    uint256 internal constant MAX_REDEEM_BATCH = 64;

    /// @dev Maximum records per AssayStake dispute, uphold or cancel batch.
    uint256 internal constant MAX_SLASH_BATCH = 64;

    /// @dev Maximum horizon of one delegate authorisation.
    uint64 internal constant MAX_DELEGATION_LIFETIME_SECONDS = 365 * 86_400;

    /// @dev Maximum active delegates per payer.
    uint256 internal constant MAX_DELEGATES_PER_PAYER = 16;

    /// @dev Maximum distance of a relayed authorisation's `deadline` beyond the landing block.
    uint64 internal constant MAX_SIGNATURE_LIFETIME_SECONDS = 3600;

    /// @dev EIP-2 low-s ceiling, `floor(secp256k1n / 2)`.
    uint256 internal constant SECP256K1_HALF_N =
        0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0;
}
