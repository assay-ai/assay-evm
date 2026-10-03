// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.24;

import {Fixture} from "./helpers/Fixture.sol";
import {VoucherSigner} from "./helpers/VoucherSigner.sol";
import {Voucher, SlashAttestation, ResponseClass} from "../src/Types.sol";
import {Constants} from "../src/Constants.sol";
import {Window} from "../src/libraries/Window.sol";
import "../src/Errors.sol";

/// **The D-13 boundary table, executed — every row, at `-1`, exact and `+1`, in one file.**
///
/// The Anchor `close_escrow` admitted at exactly the instant a voucher was still redeemable, and
/// the lesson generalises: **where two windows meet, exactly one of them owns the shared
/// instant.** Most of these comparisons already have a test in the suite that shipped the guard;
/// they are re-asserted here because the value of the table is that it is one artefact a reader
/// can hold against the code, and because a row whose only proof is scattered across six files is
/// a row that quietly loses its proof when one of those files is rewritten.
///
/// Rows B1-B4, B15, B16 and B17 had no boundary test of their own before this file. The rest are
/// re-assertions and say so at each test.
///
/// **One divergence from the table, and the code wins.** D-13 gives B3's far-side error as
/// `InvalidVoucherWindow`, because `attestation.rs:477-481` raises that one name for both of its
/// first two checks. This port splits the width bound out under its own name,
/// `VoucherLifetimeTooLong` — the `Errors.sol` rule that one condition gets one name — and
/// `Errors.sol` records the split with its argument. No voucher is admitted here that Anchor
/// refuses, or the reverse; only the label of the second half differs. Recorded in
/// `docs/divergences.md`.
contract BoundariesTest is Fixture {
    uint256 internal verifierKeyPk = 0x7E5717;
    address internal verifierAddr;
    address internal beneficiary = address(0xA6E7);
    uint64 internal constant BOND = 1_000_000_000;

    function setUp() public virtual override {
        super.setUp();
        verifierAddr = vm.addr(verifierKeyPk);

        _fund(buyer, 100_000_000);
        vm.startPrank(buyer);
        usdg.approve(address(escrow), 100_000_000);
        escrow.deposit(100_000_000);
        escrow.setLimits(type(uint64).max, type(uint64).max);
        vm.stopPrank();
    }

    function _v(uint64 seq, uint64 issuedAt, uint64 expiresAt)
        internal
        view
        returns (Voucher memory)
    {
        return Voucher({
            payer: buyer,
            provider: provider,
            amount: 1_000,
            resourceHash: keccak256("r"),
            requestHash: keccak256(abi.encode(seq, issuedAt, expiresAt)),
            seq: seq,
            issuedAt: issuedAt,
            expiresAt: expiresAt
        });
    }

    /// The signature is built BEFORE the prank and before any `expectRevert`. `signVoucher` reads
    /// `escrow.DOMAIN_SEPARATOR()`, which is a call, and both cheat codes bind to the NEXT call.
    /// The slash suite records the same trap; it costs 11 of 17 tests when it is missed.
    function _sig(Voucher memory v) internal view returns (bytes memory) {
        return VoucherSigner.signVoucher(buyerKey, escrow.DOMAIN_SEPARATOR(), v);
    }

    function _ok(Voucher memory v) internal {
        bytes memory sig = _sig(v);
        vm.prank(redeemer);
        escrow.redeemVoucher(v, sig);
    }

    function _refused(Voucher memory v, bytes4 err) internal {
        bytes memory sig = _sig(v);
        vm.prank(redeemer);
        vm.expectRevert(err);
        escrow.redeemVoucher(v, sig);
    }

    // === the voucher clock ==================================================================

    /// **B1 — `issuedAt <= now + 120`, admits exact.** New: no test owned this row before.
    /// One-sided by design (`constants.rs:244`): a voucher may claim to be younger than the
    /// chain believes, never older.
    function test_B1_clockSkewToleranceAdmitsItsOwnValue() public {
        uint64 t = uint64(block.timestamp);
        uint64 skew = Constants.CLOCK_SKEW_TOLERANCE_SECONDS;

        _ok(_v(1, t + skew - 1, t + skew - 1 + 60)); // -1
        _ok(_v(2, t + skew, t + skew + 60)); // exact
        _refused(_v(3, t + skew + 1, t + skew + 61), VoucherNotYetValid.selector); // +1
    }

    /// **B2 — `now <= expiresAt + 1800`, admits exact.** New. The shared instant belongs to the
    /// voucher: at exactly `expiresAt + REDEEM_GRACE` the redemption still lands.
    function test_B2_theRedeemGraceAdmitsItsOwnValue() public {
        uint64 t = uint64(block.timestamp);
        Voucher memory v = _v(1, t, t + 60);
        bytes memory sig = _sig(v);

        vm.warp(uint256(v.expiresAt) + Constants.REDEEM_GRACE_SECONDS + 1); // +1
        vm.prank(redeemer);
        vm.expectRevert(VoucherExpired.selector);
        escrow.redeemVoucher(v, sig);

        vm.warp(uint256(v.expiresAt) + Constants.REDEEM_GRACE_SECONDS - 1); // -1
        vm.prank(redeemer);
        escrow.redeemVoucher(v, sig);

        // exact, on a second voucher — the first is spent, and `seqHigh` would refuse it for the
        // wrong reason. One warp per assertion, one voucher per warp.
        Voucher memory w = _v(2, t, t + 60);
        bytes memory wsig = _sig(w);
        vm.warp(uint256(w.expiresAt) + Constants.REDEEM_GRACE_SECONDS);
        vm.prank(redeemer);
        escrow.redeemVoucher(w, wsig);
    }

    /// **B3 — `expiresAt - issuedAt <= 300`, admits exact.** New. Far-side error is
    /// `VoucherLifetimeTooLong`, not D-13's `InvalidVoucherWindow`; see the contract header.
    function test_B3_theVoucherLifetimeCeilingAdmitsItsOwnValue() public {
        uint64 t = uint64(block.timestamp);
        uint64 life = Constants.VOUCHER_MAX_LIFETIME_SECONDS;

        _ok(_v(1, t, t + life - 1)); // -1
        _ok(_v(2, t, t + life)); // exact
        _refused(_v(3, t, t + life + 1), VoucherLifetimeTooLong.selector); // +1
    }

    /// **B4 — `expiresAt > issuedAt`, EXCLUDES equal.** New, and the one row in the voucher block
    /// that excludes rather than admits: a voucher that expires the instant it is issued has no
    /// window at all, and admitting it would make `expiresAt - issuedAt == 0` a legal lifetime.
    function test_B4_expiresAtMustBeStrictlyAfterIssuedAt() public {
        uint64 t = uint64(block.timestamp);

        _refused(_v(1, t, t - 1), InvalidVoucherWindow.selector); // -1: expires before issue
        _refused(_v(1, t, t), InvalidVoucherWindow.selector); // exact: equal is refused
        _ok(_v(1, t, t + 1)); // +1: one second is enough
    }

    /// The invariant every one of the four rows above rests on, and the reason B10 is safe:
    /// a voucher signed the instant before `requestWithdraw` is dead 1,380 seconds before the
    /// withdrawal matures. `constants.rs:285` states it as a build-time assertion; Solidity has
    /// no constant assertion, so it is this plus `X402Escrow.initialize`'s check.
    function test_theWithdrawDelayOutlivesTheLongestRedeemableVoucher() public pure {
        assertGt(
            Constants.WITHDRAW_DELAY_SECONDS,
            uint256(Constants.CLOCK_SKEW_TOLERANCE_SECONDS) + Constants.VOUCHER_MAX_LIFETIME_SECONDS
                + Constants.REDEEM_GRACE_SECONDS
        );
        assertEq(
            Constants.MAX_VOUCHER_REDEEMABLE_LIFE_SECONDS,
            Constants.CLOCK_SKEW_TOLERANCE_SECONDS + Constants.VOUCHER_MAX_LIFETIME_SECONDS
                + Constants.REDEEM_GRACE_SECONDS,
            "the derived constant is still the sum of its three terms"
        );
    }

    // === the sequence and the spending limits ===============================================

    /// **B5 — `seq > seqHigh`, EXCLUDES equal.** Re-assertion (`X402Escrow.redeem.t.sol`).
    /// Gaps are allowed; equality is not, which is what makes exactly one redemption per
    /// `(buyer, seq)` a fact of the chain with one `uint64` and no bitmap.
    function test_B5_theSequenceIsStrictlyIncreasing() public {
        uint64 t = uint64(block.timestamp);
        _ok(_v(5, t, t + 60)); // seqHigh = 5

        _refused(_v(4, t, t + 60), VoucherSeqNotIncreasing.selector); // -1
        _refused(_v(5, t, t + 60), VoucherSeqNotIncreasing.selector); // exact
        _ok(_v(6, t, t + 60)); // +1
    }

    /// **B6 — `seq > 0`, EXCLUDES zero.** Re-assertion. Zero is the value of every unwritten
    /// slot, so admitting it would make an escrow's first redemption indistinguishable from a
    /// replay of it.
    function test_B6_sequenceZeroIsRefusedOnItsOwnName() public {
        uint64 t = uint64(block.timestamp);
        _refused(_v(0, t, t + 60), VoucherSeqZero.selector);
        _ok(_v(1, t, t + 60));
    }

    /// **B7 — `amount <= maxVoucherAmount`, admits exact.** Re-assertion.
    function test_B7_thePerCallLimitAdmitsItsOwnValue() public {
        vm.prank(buyer);
        escrow.setLimits(1_000, type(uint64).max);
        uint64 t = uint64(block.timestamp);

        Voucher memory under = _v(1, t, t + 60);
        under.amount = 999;
        _ok(under); // -1

        Voucher memory exact = _v(2, t, t + 60);
        exact.amount = 1_000;
        _ok(exact); // exact

        Voucher memory over = _v(3, t, t + 60);
        over.amount = 1_001;
        _refused(over, VoucherExceedsPerCallLimit.selector); // +1
    }

    /// **B8 — `carried + amount <= maxPerWindow`, admits exact.** Re-assertion. Asserted with a
    /// non-zero `carried`, because the row is about the SUM and a test that spends the whole
    /// window in one voucher would prove B7 a second time instead.
    function test_B8_theWindowLimitAdmitsItsOwnValueAgainstACarriedCounter() public {
        vm.prank(buyer);
        escrow.setLimits(type(uint64).max, 1_000);
        uint64 t = uint64(block.timestamp);

        Voucher memory first = _v(1, t, t + 60);
        first.amount = 600;
        _ok(first); // carried == 600, at this instant

        Voucher memory toExact = _v(2, t, t + 60);
        toExact.amount = 400; // 600 + 400 == 1_000, exact
        _ok(toExact);

        Voucher memory overByOne = _v(3, t, t + 60);
        overByOne.amount = 1; // 1_000 + 1
        _refused(overByOne, EscrowWindowLimitExceeded.selector);
    }

    /// **B9 — `balance >= amount`, admits exact.** Re-assertion. The escrow is drained to exactly
    /// zero and the next base unit is refused by name rather than by `Panic(0x11)`.
    function test_B9_theBalanceAdmitsBeingDrainedToExactlyZero() public {
        uint64 t = uint64(block.timestamp);
        uint128 balance = escrow.escrowOf(buyer).balance;

        Voucher memory nearly = _v(1, t, t + 60);
        nearly.amount = uint64(balance) - 1;
        _ok(nearly); // -1

        Voucher memory last = _v(2, t, t + 60);
        last.amount = 1; // exact: the balance is now 1 and the voucher is 1
        _ok(last);
        assertEq(escrow.escrowOf(buyer).balance, 0);

        Voucher memory oneMore = _v(3, t, t + 60);
        oneMore.amount = 1; // +1
        _refused(oneMore, EscrowInsufficient.selector);
    }

    // === the buyer's exit ====================================================================

    /// **B10 — `now >= withdrawAvailableAt`, admits exact.** Re-assertion
    /// (`X402Escrow.withdraw.t.sol`), restated at all three instants in one place.
    function test_B10_theWithdrawalMaturesAtExactlyItsOwnInstant() public {
        vm.prank(buyer);
        escrow.requestWithdraw(1_000_000);
        uint64 availableAt = escrow.escrowOf(buyer).withdrawAvailableAt;

        vm.warp(uint256(availableAt) - 1); // -1
        vm.prank(buyer);
        vm.expectRevert(WithdrawNotYetAvailable.selector);
        escrow.withdraw();

        vm.warp(availableAt); // exact — the instant belongs to the buyer
        vm.prank(buyer);
        escrow.withdraw();
        assertEq(usdg.balanceOf(buyer), 1_000_000);
    }

    /// **B17 — `now <= deadline`, admits exact.** New: no boundary test owned the meta-transaction
    /// deadline. Asserted on `setLimitsBySig`, the door a buyer uses when they hold no gas — the
    /// one place where an off-by-one on the deadline would strand exactly the buyer it exists for.
    function test_B17_theMetaTransactionDeadlineAdmitsItsOwnInstant() public {
        uint64 deadline = uint64(block.timestamp) + 600;
        bytes32 sep = escrow.DOMAIN_SEPARATOR();
        bytes memory sig = VoucherSigner.signSetLimits(buyerKey, sep, buyer, 7, 8, 0, deadline);

        vm.warp(uint256(deadline) + 1); // +1
        vm.expectRevert(SignatureExpired.selector);
        escrow.setLimitsBySig(buyer, 7, 8, 0, deadline, sig);

        vm.warp(deadline); // exact — the instant belongs to the signature
        escrow.setLimitsBySig(buyer, 7, 8, 0, deadline, sig);
        assertEq(escrow.escrowOf(buyer).maxVoucherAmount, 7);
        assertEq(escrow.escrowOf(buyer).maxPerWindow, 8);
    }

    // === the rolling window ==================================================================

    /// **B15 — `elapsed >= 86400` drains to zero; `elapsed == 0` carries the whole counter.** New.
    /// Both ends of `Window.decay`, plus the two instants either side of the full window, called
    /// directly rather than through a redemption so the row is about the function D-13 names.
    function test_B15_theWindowDrainsFullyAtExactlyItsOwnWidthAndCarriesEverythingAtZero()
        public
        pure
    {
        uint64 W = Constants.SLASH_WINDOW_SECONDS;
        uint64 t = 1_000_000;

        assertEq(Window.decay(1_000, t, t), 1_000, "elapsed == 0 carries the whole counter");
        assertEq(Window.decay(1_000, t, t - 1), 1_000, "a backwards clock returns nothing");
        assertEq(Window.decay(1_000, t, t + W), 0, "elapsed == W drains fully");
        assertEq(Window.decay(1_000, t, t + W + 1), 0, "and stays drained past it");

        // -1 must not be zero, or "drains fully AT W" would be a claim about W-1.
        assertGt(Window.decay(1_000, t, t + W - 1), 0, "one second short still carries something");
        // …and it rounds UP, so the last base unit is never returned early.
        assertEq(Window.decay(1, t, t + W - 1), 1, "div_ceil: the last unit survives to the edge");
    }

    // === the verifier registry ==============================================================

    /// **B16 — `expiresAt > now && expiresAt <= now + 31_536_000`: excludes now, admits the
    /// ceiling.** New: no boundary test owned this row. Both ends, at all three instants each.
    ///
    /// A fresh address per case, because enrolment is one-shot — `registered` is never cleared,
    /// so a rejected address and an accepted one cannot be the same address (a verifier key can
    /// never be re-enrolled).
    function test_B16_theVerifierExpiryExcludesNowAndAdmitsTheRotationCeiling() public {
        uint64 t = uint64(block.timestamp);
        uint64 max = Constants.MAX_VERIFIER_KEY_LIFETIME_SECONDS;
        bytes32 label = bytes32("verifier-evm-2026-09");

        vm.startPrank(admin);

        // the lower end — strictly future
        vm.expectRevert(InvalidVerifierExpiry.selector);
        config.registerVerifier(address(0xE1), label, t - 1); // -1
        vm.expectRevert(InvalidVerifierExpiry.selector);
        config.registerVerifier(address(0xE2), label, t); // exact: now is EXCLUDED
        config.registerVerifier(address(0xE3), label, t + 1); // +1

        // the upper end — the rotation ceiling is ADMITTED
        config.registerVerifier(address(0xE4), label, t + max - 1); // -1
        config.registerVerifier(address(0xE5), label, t + max); // exact
        vm.expectRevert(InvalidVerifierExpiry.selector);
        config.registerVerifier(address(0xE6), label, t + max + 1); // +1

        vm.stopPrank();

        assertTrue(config.canSign(address(0xE5)), "the key enrolled at the ceiling can sign");
    }

    /// **B13 — `now <= key.expiresAt`, admits exact.** Re-assertion
    /// (`X402Stake.slash.t.sol::test_boundary_theVerifierExpiryInstantBelongsToExecute` proves the
    /// pair with `expireSlash`; this proves the comparison itself at all three instants).
    function test_B13_theVerifierKeyExpiryInstantBelongsToTheKey() public {
        uint64 expiresAt = uint64(block.timestamp) + 180 * 86_400;
        vm.prank(admin);
        config.registerVerifier(verifierAddr, bytes32("verifier-evm-2026-09"), expiresAt);

        vm.warp(uint256(expiresAt) - 1); // -1
        assertTrue(config.canSign(verifierAddr));
        config.assertCanSign(verifierAddr);

        vm.warp(expiresAt); // exact — the instant belongs to the key
        assertTrue(config.canSign(verifierAddr));
        config.assertCanSign(verifierAddr);

        vm.warp(uint256(expiresAt) + 1); // +1
        assertFalse(config.canSign(verifierAddr));
        vm.expectRevert(VerifierKeyExpired.selector);
        config.assertCanSign(verifierAddr);
    }

    // === the stake clocks ====================================================================

    /// **B11 — `now >= executableAt`, admits exact. B12 — `now < executableAt + 604800`, EXCLUDES
    /// exact.** Re-assertion of both, and of the pair: at exactly `executableAt + GRACE`,
    /// `executeSlash` is closed and `expireSlash` is open — exactly one of the two, never both,
    /// which is the `close_escrow` defect the whole table exists to forbid.
    function test_B11_B12_theExecutionWindowOpensAtExactAndClosesBeforeItsFarEdge() public {
        _stake(BOND);
        vm.prank(admin);
        config.registerVerifier(
            verifierAddr, bytes32("verifier-evm-2026-09"), uint64(block.timestamp) + 180 * 86_400
        );

        uint64 t0 = uint64(block.timestamp);
        _propose(bytes32("b11"));
        _propose(bytes32("b12"));
        uint64 executableAt = stake.slashRecordOf(bytes32("b11")).executableAt;
        assertEq(executableAt, t0 + Constants.SLASH_DELAY_SECONDS, "the 72h delay, as declared");

        vm.warp(uint256(executableAt) - 1); // B11 -1
        vm.expectRevert(SlashNotYetExecutable.selector);
        stake.executeSlash(bytes32("b11"));

        vm.warp(executableAt); // B11 exact — the instant belongs to execute
        stake.executeSlash(bytes32("b11"));

        uint64 far = executableAt + Constants.SLASH_EXECUTION_GRACE_SECONDS;
        vm.warp(uint256(far) - 1); // B12 -1: still open
        vm.expectRevert(SlashNotExpired.selector);
        stake.expireSlash(bytes32("b12"));

        vm.warp(far); // B12 exact — EXCLUDED from execute, and expire owns it
        vm.expectRevert(SlashExecutionWindowClosed.selector);
        stake.executeSlash(bytes32("b12"));
        stake.expireSlash(bytes32("b12")); // exactly one of the two doors, and it is this one
    }

    /// **B14 — `now >= unbondingStartedAt + period`, admits exact.** Re-assertion
    /// (`X402Stake.stake.t.sol`), restated at all three instants.
    function test_B14_theUnbondingMaturesAtExactlyItsOwnInstant() public {
        _stake(BOND);
        uint64 startedAt = uint64(block.timestamp);
        vm.prank(provider);
        stake.requestUnstake(BOND);
        uint64 period = config.params().unbondingPeriodSeconds;

        vm.warp(uint256(startedAt) + period - 1); // -1
        assertEq(stake.withdrawableOf(provider), 0);
        vm.prank(provider);
        // `UnbondingPeriodNotElapsed`, not `InsufficientUnbondingStake`. `withdrawStake` asks the
        // clock question BEFORE it asks `withdrawableOf`, so a provider one second early is told
        // the clock is not up rather than that they have nothing — which is the truer diagnosis
        // and the one an operator can act on. Measured; the first spelling of this test expected
        // the other name and was wrong.
        vm.expectRevert(UnbondingPeriodNotElapsed.selector);
        stake.withdrawStake(BOND);

        vm.warp(uint256(startedAt) + period); // exact — the instant belongs to the provider
        assertEq(stake.withdrawableOf(provider), BOND);
        vm.prank(provider);
        stake.withdrawStake(BOND);
        assertEq(usdg.balanceOf(provider), BOND);
    }

    function _stake(uint64 amount) internal {
        stake = _deployStake(address(usdg));
        _fund(provider, amount);
        vm.startPrank(provider);
        usdg.approve(address(stake), amount);
        stake.depositStake(amount);
        vm.stopPrank();
    }

    function _propose(bytes32 requestId) internal {
        SlashAttestation memory a = SlashAttestation({
            requestId: requestId,
            provider: provider,
            beneficiary: beneficiary,
            status: uint8(ResponseClass.DataFail),
            penalty: 1_000_000,
            policy: keccak256("policy v1"),
            issuedAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp) + 3 * 86_400
        });
        stake.proposeSlash(
            a, VoucherSigner.signAttestation(verifierKeyPk, stake.DOMAIN_SEPARATOR(), a)
        );
    }
}
