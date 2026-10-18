// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.24;

/// Every value here is copied from the Anchor program's `programs/x402-payment/src/constants.rs`
/// (repository `assay-solana`), with the source line noted on each. They are **copied, never
/// re-derived**: the two chains keep
/// identical numbers so one behavioural test matrix covers both, and a number reasoned out a
/// second time is a number that can come out different. `test/Types.t.sol` pins each one.
///
/// The Anchor originals are `i64` (Solana's `unix_timestamp` is signed). Here they are `uint64`,
/// matching `block.timestamp` and the backend's `MONEY_MAX_ATOMIC_UNITS = 2^64 - 1`; every value
/// is positive, so nothing is lost, and the unsigned type removes the negative-duration cases
/// the Anchor code has to reason about.
///
/// **What was deliberately left behind.** `constants.rs:5-60` also declares six PDA seeds —
/// `CONFIG_SEED`, `STAKE_SEED`, `STAKE_VAULT_SEED`, `VERIFIER_SEED`, `SLASH_RECORD_SEED`,
/// `ESCROW_SEED`. They are Solana address-derivation artefacts and have no EVM meaning: there
/// are no program-derived addresses here, so the state they seed is a `mapping` keyed by the
/// same value, and the seed string would be a label for nothing. Two of them carry a security
/// property that does *not* travel with the name and has to be rebuilt: `SLASH_RECORD_SEED`'s
/// replay lock is `init`-succeeds-once on `["slash", request_id]`, which on EVM becomes an
/// explicit `SlashStatus.None` check in `X402Stake`, and `ESCROW_SEED`'s "the authority is derived
/// from the buyer and nothing else" becomes `msg.sender` plus an EIP-712 signature.
/// Listed so their absence reads as a decision rather than an oversight.
///
/// Going the other way, everything under "EVM only" below has no Anchor counterpart.
library Constants {
    // --- delays and windows ----------------------------------------------------------------

    /// constants.rs:266 — `SLASH_DELAY_SECONDS: i64 = 72 * 3_600`. The window in which a human
    /// holding the admin key can see a proposal and revoke the key that signed it, and in which
    /// the provider can `disputeSlash`.
    ///
    /// **Since the dispute upgrade this is the DEFAULT, not the delay.** The live value is
    /// `X402Config.slashDelaySeconds()`, which the admin may set inside
    /// `[MIN_SLASH_DELAY_SECONDS, MAX_SLASH_DELAY_SECONDS]` and which
    /// reads back as this constant until it is first set — so a proxy upgraded from the earlier
    /// code keeps 72 hours. A stolen admin key can shorten it to the minimum, never to zero, and
    /// a proposal's `executableAt` is frozen when it is made.
    uint64 internal constant SLASH_DELAY_SECONDS = 72 * 3600;

    /// EVM only. The shortest settable slash delay (and therefore dispute window). Ten minutes:
    /// long enough for a test run to dispute, short enough to be useful on a testnet.
    uint64 internal constant MIN_SLASH_DELAY_SECONDS = 10 * 60;

    /// EVM only. The longest settable slash delay: 22 days, the largest value the earlier
    /// delay-to-unbonding coupling ever admitted (`MAX_UNBONDING_PERIOD_SECONDS - 8 d`). A fixed
    /// bound since audit F R3: the reservation, not the unbonding clock, is what holds a
    /// proposed penalty.
    uint64 internal constant MAX_SLASH_DELAY_SECONDS = 22 * 86_400;

    /// EVM only. How long a `Disputed` slash may wait for the arbiter. After it, anybody may
    /// release the reservation with `expireSlash` (`CancelReason.DisputeUnresolved`): a hold
    /// nobody rules on must not become a hold for ever.
    uint64 internal constant DISPUTE_TIMEOUT_SECONDS = 30 * 86_400;

    /// constants.rs:273 — `WITHDRAW_DELAY_SECONDS: i64 = 3_600`. Sized by the invariant noted
    /// below [`MAX_VOUCHER_REDEEMABLE_LIFE_SECONDS`], not chosen.
    uint64 internal constant WITHDRAW_DELAY_SECONDS = 3600;

    /// EVM only. How long a payer's TIGHTENING (revoking a delegate, shortening its horizon,
    /// lowering a delegate's or the escrow's caps) waits before it binds a voucher that was
    /// already valid: until then the previous authority and caps still redeem it. It is the exit
    /// delay, for the exit delay's reason — it outlives every voucher (3,600 > 2,220), so no payer
    /// call can make an already-admitted voucher unredeemable before its deadline.
    uint64 internal constant TIGHTEN_DELAY_SECONDS = WITHDRAW_DELAY_SECONDS;

    /// EVM only. The shortest settable collect hold (`X402Config.setCollectHold`): how long a
    /// redeemed payment waits in `X402Escrow.held` before the redeemer may collect it to the
    /// provider. One minute, so a testnet run can collect inside a test.
    uint64 internal constant MIN_COLLECT_HOLD_SECONDS = 60;

    /// EVM only. The longest settable collect hold: one day. A buyer dispute that cannot be
    /// decided inside a day is still refundable until the timeout below, so a longer hold would
    /// only delay every undisputed provider payment.
    uint64 internal constant MAX_COLLECT_HOLD_SECONDS = 86_400;

    /// EVM only. The collect hold `X402Config.collectHoldSeconds()` reads back until the admin
    /// first sets one, so an upgraded proxy holds every payment for an hour with no initializer
    /// call — the same shape as [`SLASH_DELAY_SECONDS`].
    uint64 internal constant DEFAULT_COLLECT_HOLD_SECONDS = 3_600;

    /// EVM only. How long after `collectableAt` a held payment waits for the redeemer. Until then
    /// only the redeemer may collect or refund it; from then on ANYBODY may collect it, in the
    /// provider's favour, and the refund door is closed. A hold nobody acts on must not become a
    /// hold for ever — the same rule as [`DISPUTE_TIMEOUT_SECONDS`], with the silence favouring
    /// the provider as it does in the slash design.
    uint64 internal constant HELD_TIMEOUT_SECONDS = 7 * 86_400;

    /// constants.rs:215 — `REDEEM_GRACE_SECONDS: i64 = 30 * 60`.
    uint64 internal constant REDEEM_GRACE_SECONDS = 30 * 60;

    /// constants.rs:230 — `VOUCHER_MAX_LIFETIME_SECONDS: i64 = 5 * 60`. The widest window a
    /// voucher may claim for itself, `expiresAt - issuedAt`. The original design put this bound in
    /// the backend, which is the component the threat model assumes is compromised; it lives on
    /// chain for that reason.
    uint64 internal constant VOUCHER_MAX_LIFETIME_SECONDS = 5 * 60;

    /// constants.rs:244 — `CLOCK_SKEW_TOLERANCE_SECONDS: i64 = 120`. Deliberately one-sided: a
    /// voucher may claim to be younger than the chain believes, never older.
    uint64 internal constant CLOCK_SKEW_TOLERANCE_SECONDS = 120;

    /// constants.rs:258 — derived, not typed, exactly as the Anchor source derives it, so it
    /// cannot disagree with the three constants it is the sum of. 2,220s = 37 minutes.
    uint64 internal constant MAX_VOUCHER_REDEEMABLE_LIFE_SECONDS =
        CLOCK_SKEW_TOLERANCE_SECONDS + VOUCHER_MAX_LIFETIME_SECONDS + REDEEM_GRACE_SECONDS;

    // **The invariant constants.rs:285 makes a build failure, and where it went.**
    //
    // ```text
    // WITHDRAW_DELAY_SECONDS (3600) > MAX_VOUCHER_REDEEMABLE_LIFE_SECONDS (2220)
    // ```
    //
    // A buyer's withdrawal must not land while a voucher they signed *before* asking for it is
    // still redeemable; otherwise the platform serves a call it can never collect for and the
    // delay buys nothing. Rust states it as `const _: () = assert!(…)`, so lowering the delay
    // fails the build. Solidity has no constant assertion — `assert` is a runtime opcode and a
    // constant expression cannot invoke one — so it becomes two things, and both of them exist:
    //
    //   1. HERE, NOW: `test/Types.t.sol::test_withdrawDelayOutlivesTheLongestRedeemableVoucher`
    //      derives the 2,220 from its three terms rather than typing it, and asserts the
    //      inequality. A red test instead of a red build.
    //   2. `X402Escrow.initialize` checks the same inequality and reverts
    //      [`WithdrawDelayTooShort`]. Runtime rather than a constructor because these contracts
    //      sit behind UUPS proxies (D-1) and a constructor does not run against the storage
    //      a proxy uses.
    //
    // Neither half is a *runtime* guard in any useful sense — every term is a compile-time
    // constant, so the optimiser folds the check in `initialize` to nothing and no input can
    // reach it. Both exist to make a future edit to the numbers above fail loudly: the test goes
    // red, and any redeployment of the escrow becomes uninitialisable. Nothing here constrains a
    // *parameter*; `unbondingPeriodSeconds` and the rest are X402Config's `_validate` to bound.

    /// constants.rs:79 — `SLASH_WINDOW_SECONDS: i64 = 86_400`. One width for two rolling
    /// counters: the per-provider slash cap and the buyer escrow's own daily ceiling.
    uint64 internal constant SLASH_WINDOW_SECONDS = 86_400;

    /// constants.rs:206 — `SLASH_EXECUTION_GRACE_SECONDS: i64 = 7 * 86_400`. Measured from
    /// `executableAt`, so the provider's worst case is the delay plus this.
    uint64 internal constant SLASH_EXECUTION_GRACE_SECONDS = 7 * 86_400;

    /// constants.rs:142 — `MAX_ATTESTATION_LIFETIME_SECONDS: i64 = 7 * 86_400`. Bounds how long
    /// one judgement stays actionable, which is not the same thing as how long a key may sign.
    uint64 internal constant MAX_ATTESTATION_LIFETIME_SECONDS = 7 * 86_400;

    /// constants.rs:155 — `MAX_VERIFIER_KEY_LIFETIME_SECONDS: i64 = 365 * 86_400`. Makes the
    /// rotation schedule a chain-enforced control rather than a calendar reminder, and it fails
    /// safe: an unrotated key stops being able to slash.
    uint64 internal constant MAX_VERIFIER_KEY_LIFETIME_SECONDS = 365 * 86_400;

    /// constants.rs:171 — `MIN_UNBONDING_PERIOD_SECONDS: i64 = 11 * 86_400`. Sized by Anchor as
    /// the path from breach to executed penalty (7d SLA window + 3d dispute + 1d margin). On EVM
    /// what it must cover is the breach-to-PROPOSAL leg: once proposed, `pendingSlash` holds the
    /// penalty whatever the slash delay. Below it, a provider exits before a judgement lands.
    uint64 internal constant MIN_UNBONDING_PERIOD_SECONDS = 11 * 86_400;

    /// constants.rs:186 — `MAX_UNBONDING_PERIOD_SECONDS: i64 = 30 * 24 * 3_600`. Defends the
    /// provider against the key that sets the parameter: an unbounded period freezes stake for
    /// as long as the admin cares to leave it there.
    uint64 internal constant MAX_UNBONDING_PERIOD_SECONDS = 30 * 24 * 3600;

    // --- basis points ----------------------------------------------------------------------

    /// constants.rs:89 — `MAX_TAKE_RATE_BPS: u16 = 3_000`. Not the shipped default (10%); the
    /// point past which the parameter has stopped being a take rate.
    uint16 internal constant MAX_TAKE_RATE_BPS = 3_000;

    /// constants.rs:132 — `MAX_SLASH_CAP_BPS: u16 = 5_000`. It bounds ONE record's frozen
    /// `capAllowance` and the provider's meter per rolling window. It is **not** "the provider
    /// keeps half": the window decays linearly, so up to about twice the cap can be applied in any
    /// 24 h, it re-arms every window, and at 5 000 bps a provider can lose all of its stake in a
    /// day (audit C, C7). The bound on a provider's total loss is the number of legitimate
    /// judgements, not this constant.
    uint16 internal constant MAX_SLASH_CAP_BPS = 5_000;

    /// constants.rs:63 — `BPS_DENOMINATOR: u64 = 10_000`. Narrowed to `uint16` here because every
    /// value measured against it is a `uint16` bps.
    ///
    /// **The hazard the narrowing carries, and the rule that avoids it.** Solidity evaluates
    /// `uint16 * uint16` in `uint16`, so `someBps * BPS_DENOMINATOR` reverts with `Panic(0x11)`
    /// for any `someBps > 6` — an unhelpful panic in place of a diagnosis, and only on the inputs
    /// nobody tests. **Every bps arithmetic goes through `uint256`.** In practice that is free,
    /// because the intended shape is a division whose numerator is already wide:
    ///
    /// ```solidity
    /// fee = uint64(uint256(amount) * takeRateBps / Constants.BPS_DENOMINATOR); // amount: uint64
    /// atRisk = uint256(bonded) * slashCapBps / Constants.BPS_DENOMINATOR;
    /// ```
    ///
    /// The `uint64`/`uint256` numerator promotes the whole expression, so the `uint16` operands
    /// never meet each other alone. What is forbidden is writing the two `uint16`s adjacent —
    /// `bps * BPS_DENOMINATOR`, or a bare `a * b` where both are bps. `Fee` and `X402Config` own
    /// the sites.
    uint16 internal constant BPS_DENOMINATOR = 10_000;

    // --- EVM only --------------------------------------------------------------------------

    /// The furthest one redeemed voucher may move a payer's `seqHigh`: a redemption needs
    /// `seq <= seqHigh + MAX_SEQ_GAP`. Without it a single voucher with `seq = 2^64 - 1` (signed by
    /// the payer or by any delegate) moves the high-water mark to the top of the type, and every
    /// later voucher of that payer fails `VoucherSeqNotIncreasing` for ever. A constant, not a
    /// parameter: the backend allocates seqs one at a time, so a million unredeemed numbers ahead
    /// of the chain is already far outside normal operation, and a bound an admin could raise is a
    /// bound a stolen admin key removes. No Anchor counterpart.
    uint64 internal constant MAX_SEQ_GAP = 1_000_000;

    /// No Anchor counterpart: Solana's 1,232-byte packet limit caps a batch implicitly,
    /// and that limit does not exist here, so the bound has to be written down.
    uint256 internal constant MAX_REDEEM_BATCH = 64;

    /// The bound on `X402Stake`'s `disputeSlashBatch`, `upholdSlashBatch` and `cancelSlashBatch`,
    /// for `MAX_REDEEM_BATCH`'s reason. EVM only; `docs/gas.md` has the measurement.
    uint256 internal constant MAX_SLASH_BATCH = 64;

    /// The longest horizon a payer may give a voucher DELEGATE in one authorisation. A delegate
    /// key lives on a machine the payer does not watch, so its authority must lapse on its own;
    /// renewing is one more signature. No Anchor counterpart — delegation is EVM only.
    uint64 internal constant MAX_DELEGATION_LIFETIME_SECONDS = 365 * 86_400;

    /// How many delegates one payer may hold at once (revoking frees a place). It bounds
    /// `delegatesOf`, which an off-chain reader enumerates in one call, so it is a bound on a
    /// view's size rather than on anybody's money. No Anchor counterpart.
    uint256 internal constant MAX_DELEGATES_PER_PAYER = 16;

    /// How far ahead of the landing block a relayed (`…BySig`) authorisation's `deadline` may be:
    /// it is checked when the call LANDS (`deadline <= block.timestamp + this`), so it bounds how
    /// early before its deadline a signature can be landed. It is **not** a signature lifetime: a
    /// signature with a far deadline is refused now but lands in the last hour before that
    /// deadline. What kills a withheld signature is the shared `authNonce`, which every later
    /// payer decision consumes. The backend signs with 300 s. No Anchor counterpart — Solana has
    /// no relayed doors.
    uint64 internal constant MAX_SIGNATURE_LIFETIME_SECONDS = 3600;

    /// EIP-2's low-s ceiling, `floor(secp256k1n / 2)`. Enforced on every recover: without
    /// it every signature has a second valid encoding, and any structure keyed by a signature's
    /// bytes has a hole in it. No Anchor counterpart — ed25519 is not malleable this way.
    uint256 internal constant SECP256K1_HALF_N =
        0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0;
}
