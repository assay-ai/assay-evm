// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {Fixture} from "./helpers/Fixture.sol";
import {VoucherSigner} from "./helpers/VoucherSigner.sol";
import {RedeemReentrantUSDG} from "./helpers/MockUSDG.sol";
import {X402Escrow} from "../src/X402Escrow.sol";
import {Voucher, ParamSet} from "../src/Types.sol";
import {Constants} from "../src/Constants.sol";
import "../src/Errors.sol";

/// The **committable** half of the effects-before-interactions proof.
///
/// `test/MUTATION-LOG.md` row R33 needs mutated source to show what the ordering is worth, so it
/// cannot live in the suite; row R31 shows only that *some* guard refuses a re-entrant redemption,
/// and measured, that guard is the seq rule rather than `nonReentrant`. Neither notices a reorder.
///
/// This mock asserts the property itself. It re-enters a **view** from inside the payout and
/// records what the escrow looked like at the moment of the first external call. `escrowOf` and
/// `totalEscrowed` carry no `nonReentrant`, so the read succeeds, the OUTER call succeeds, and the
/// mock's storage therefore survives to be asserted — which is precisely what a flag on
/// [`RedeemReentrantUSDG`] cannot do, because that test's outer call reverts and unwinds the mock
/// along with the escrow.
///
/// It fails the instant anybody moves a transfer above an effect, including the batch path.
contract RedeemObserverUSDG {
    uint8 public constant decimals = 6;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    address public escrow;
    address public observedBuyer;
    bool private armed;
    bool public observed;

    uint128 public seenBalance;
    uint64 public seenSeqHigh;
    uint64 public seenSpentInWindow;
    uint64 public seenWindowStartedAt;
    uint128 public seenTotalRedeemed;
    uint128 public seenTotalEscrowed;

    function arm(address escrow_, address buyer_) external {
        escrow = escrow_;
        observedBuyer = buyer_;
        armed = true;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    /// The payout door, and the observation point: the FIRST external call `_redeem` makes.
    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        if (armed) {
            armed = false;
            observed = true;
            X402Escrow.Escrow memory e = X402Escrow(escrow).escrowOf(observedBuyer);
            seenBalance = e.balance;
            seenSeqHigh = e.seqHigh;
            seenSpentInWindow = e.spentInWindow;
            seenWindowStartedAt = e.windowStartedAt;
            seenTotalRedeemed = e.totalRedeemed;
            seenTotalEscrowed = X402Escrow(escrow).totalEscrowed();
        }
        return true;
    }
}

/// `redeemVoucher` — the only door through which a buyer's money leaves on somebody else's
/// submission, and the one function in this contract where a missed guard is a theft rather than
/// a bad diagnosis.
///
/// Two properties every test here is written against, because they are what the degenerates in
/// `test/MUTATION-LOG.md` have repeatedly defeated:
///
///  1. **Assertions pin values, never relations between two numbers the implementation itself
///     produced.** `provider + treasury == amount` is satisfied by paying the provider the gross
///     and the treasury nothing; the happy path therefore pins 225_000 and 25_000 separately.
///  2. **Order is only visible to a voucher that violates two checks at once.** A suite of
///     single-violation tests passes against any permutation of the check list, so the three
///     `…CheckOrder…` / `…divergence…` tests below are not decoration — they are the only cover
///     the ordering has.
contract X402EscrowRedeemTest is Fixture {
    address internal stranger = address(0xDEAD);
    uint256 internal constant WRONG_KEY = 0xBADBAD;

    /// Cached in `setUp`, and it has to be. `vm.prank` applies to the NEXT call, and
    /// `escrow.DOMAIN_SEPARATOR()` is a call — signing inline inside a pranked statement spends
    /// the prank on the getter and submits the redemption as the test contract, which every
    /// redemption in an earlier draft of this file did (`NotRedeemer` on 26 of 30 tests).
    bytes32 internal ds;

    event VoucherRedeemed(
        address indexed payer,
        address indexed provider,
        bytes32 requestHash,
        bytes32 resourceHash,
        uint64 amount,
        uint64 fee,
        uint64 seq,
        uint16 takeRateBps,
        uint64 spentInWindow
    );
    event EscrowLimitsSet(address indexed buyer, uint64 maxVoucherAmount, uint64 maxPerWindow);

    function setUp() public virtual override {
        super.setUp();
        ds = escrow.DOMAIN_SEPARATOR();
        _fund(buyer, 10_000_000);
        vm.startPrank(buyer);
        usdg.approve(address(escrow), 10_000_000);
        escrow.deposit(10_000_000);
        escrow.setLimits(1_000_000, 5_000_000);
        vm.stopPrank();
    }

    function _v(uint64 amount, uint64 seq) internal view returns (Voucher memory) {
        return Voucher({
            payer: buyer,
            provider: provider,
            amount: amount,
            resourceHash: keccak256("resource"),
            requestHash: keccak256(abi.encode("request", seq)),
            seq: seq,
            issuedAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp) + 300
        });
    }

    function _sig(Voucher memory v) internal view returns (bytes memory) {
        return VoucherSigner.signVoucher(buyerKey, ds, v);
    }

    function _badSig(Voucher memory v) internal view returns (bytes memory) {
        return VoucherSigner.signVoucher(WRONG_KEY, ds, v);
    }

    function _redeem(Voucher memory v) internal {
        bytes memory sig = _sig(v);
        vm.prank(redeemer);
        escrow.redeemVoucher(v, sig);
    }

    function _expect(Voucher memory v, bytes4 err) internal {
        bytes memory sig = _sig(v);
        vm.prank(redeemer);
        vm.expectRevert(err);
        escrow.redeemVoucher(v, sig);
    }

    function _expectFrom(address from, Voucher memory v, bytes memory sig, bytes4 err) internal {
        vm.prank(from);
        vm.expectRevert(err);
        escrow.redeemVoucher(v, sig);
    }

    function _setPaused(bool value) internal {
        vm.prank(admin);
        config.setPaused(value);
    }

    // --- the happy path ---------------------------------------------------------------------

    function test_happyPath_theProviderIsPaidAmountMinusFeeAndTheTreasuryTheFee() public {
        Voucher memory v = _v(250_000, 1);
        _redeem(v);

        assertEq(usdg.balanceOf(provider), 225_000); // 250_000 - 10%
        assertEq(usdg.balanceOf(treasury), 25_000);
        assertEq(escrow.escrowOf(buyer).balance, 9_750_000);
        assertEq(escrow.escrowOf(buyer).seqHigh, 1);
        assertEq(escrow.escrowOf(buyer).spentInWindow, 250_000);
        assertEq(escrow.escrowOf(buyer).totalRedeemed, 250_000);
        assertEq(escrow.totalEscrowed(), 9_750_000);
        assertEq(usdg.balanceOf(address(escrow)), 9_750_000);
        assertEq(escrow.escrowOf(buyer).windowStartedAt, uint64(block.timestamp));
    }

    /// fee + providerAmount == amount for every amount, including the indivisible ones.
    function test_happyPath_theSplitNeverLosesABaseUnit() public {
        Voucher memory v = _v(7, 1);
        _redeem(v);
        assertEq(usdg.balanceOf(provider) + usdg.balanceOf(treasury), 7);
        assertEq(usdg.balanceOf(treasury), 0); // floor(0.7) = 0
        assertEq(usdg.balanceOf(provider), 7);
    }

    /// The event is how the whole off-chain ledger learns a redemption happened, so every field
    /// is pinned — including `spentInWindow`, which is the only published view of the cap
    /// approaching, and `takeRateBps`, which is what makes the split auditable after a rate
    /// change.
    function test_happyPath_theRedeemedEventCarriesTheSplitAndTheRunningWindow() public {
        _redeem(_v(300_000, 1));

        Voucher memory v = _v(250_000, 2);
        vm.expectEmit(true, true, true, true, address(escrow));
        emit VoucherRedeemed(
            buyer,
            provider,
            v.requestHash,
            v.resourceHash,
            250_000,
            25_000,
            2,
            TAKE_RATE_BPS,
            550_000
        );
        _redeem(v);
    }

    /// The second door this task opens. Deliberately NOT pause-gated: lowering a limit is the
    /// safety direction and an admin key must never be able to stop a buyer tightening their own.
    function test_happyPath_setLimitsWritesTheBuyersOwnCeilingsAndNobodyElses() public {
        vm.expectEmit(true, true, true, true, address(escrow));
        emit EscrowLimitsSet(buyer, 42, 4_242);
        vm.prank(buyer);
        escrow.setLimits(42, 4_242);

        assertEq(escrow.escrowOf(buyer).maxVoucherAmount, 42);
        assertEq(escrow.escrowOf(buyer).maxPerWindow, 4_242);
        assertEq(escrow.escrowOf(stranger).maxVoucherAmount, 0, "one buyer's write is their own");

        _setPaused(true);
        vm.prank(buyer);
        escrow.setLimits(1, 2); // a paused program cannot stop a buyer tightening
        assertEq(escrow.escrowOf(buyer).maxVoucherAmount, 1);
    }

    function test_wrongState_setLimitsRefusesAWriteThatChangesNothing() public {
        vm.prank(buyer);
        vm.expectRevert(EscrowLimitsUnchanged.selector);
        escrow.setLimits(1_000_000, 5_000_000);
    }

    // --- who may submit, and who must have signed --------------------------------------------

    function test_wrongSigner_aVoucherSignedByAnotherKeyIsRefused() public {
        Voucher memory v = _v(250_000, 1);
        bytes memory sig = VoucherSigner.signVoucher(WRONG_KEY, ds, v);
        vm.prank(redeemer);
        vm.expectRevert(SignerIsNotPayer.selector);
        escrow.redeemVoucher(v, sig);
    }

    function test_wrongSigner_onlyTheConfiguredRedeemerMaySubmit() public {
        Voucher memory v = _v(250_000, 1);
        vm.prank(stranger);
        vm.expectRevert(NotRedeemer.selector);
        escrow.redeemVoucher(v, _sig(v));
    }

    /// Even the buyer whose money it is may not submit — the pin is about `seq`, not custody: a
    /// buyer who could land a redemption would void every voucher they had already served.
    function test_wrongSigner_notEvenTheBuyerMaySubmitTheirOwnVoucher() public {
        Voucher memory v = _v(250_000, 1);
        vm.prank(buyer);
        vm.expectRevert(NotRedeemer.selector);
        escrow.redeemVoucher(v, _sig(v));
    }

    function test_wrongState_redeemIsClosedWhilePaused() public {
        _setPaused(true);
        Voucher memory v = _v(250_000, 1);
        vm.prank(redeemer);
        vm.expectRevert(ProgramPaused.selector);
        escrow.redeemVoucher(v, _sig(v));
    }

    /// FLIP ONE SIGNED FIELD. The submitted struct must be the one that was signed — all eight
    /// fields, one at a time.
    ///
    /// **Each tampered struct is built fresh.** `Voucher memory t = signed;` is a REFERENCE
    /// assignment for a memory struct, not a copy, so the "tampering" would rewrite the original
    /// and the final positive control below would then be redeeming a voucher naming
    /// `address(0xDEAD)` as its provider. That is exactly the aliasing defect
    /// `test/MUTATION-LOG.md` row F5 records in the voucher-encoder tests, reached here
    /// independently.
    function test_flipOneSignedField_everyFieldIsBound() public {
        Voucher memory signed = _v(250_000, 1);
        bytes memory sig = _sig(signed);

        Voucher memory t = _v(250_000, 1);
        t.payer = vm.addr(0xA11CE);
        _expectFrom(redeemer, t, sig, SignerIsNotPayer.selector);

        t = _v(250_000, 1);
        t.provider = address(0xDEAD);
        _expectFrom(redeemer, t, sig, SignerIsNotPayer.selector);

        t = _v(250_000, 1);
        t.amount = 250_001;
        _expectFrom(redeemer, t, sig, SignerIsNotPayer.selector);

        t = _v(250_000, 1);
        t.resourceHash = keccak256("a different resource");
        _expectFrom(redeemer, t, sig, SignerIsNotPayer.selector);

        t = _v(250_000, 1);
        t.requestHash = keccak256("a different call");
        _expectFrom(redeemer, t, sig, SignerIsNotPayer.selector);

        t = _v(250_000, 1);
        t.seq = 2;
        _expectFrom(redeemer, t, sig, SignerIsNotPayer.selector);

        t = _v(250_000, 1);
        t.issuedAt = t.issuedAt + 1;
        _expectFrom(redeemer, t, sig, SignerIsNotPayer.selector);

        t = _v(250_000, 1);
        t.expiresAt = t.expiresAt - 1;
        _expectFrom(redeemer, t, sig, SignerIsNotPayer.selector);

        // The positive control, and the anti-aliasing assertions beside it: the struct that was
        // signed must still be the struct that was signed. Measured (`MUTATION-LOG.md` row C2):
        // regressing the flips to `Voucher memory t = signed;` is caught by the control's OWN
        // revert before these assertions are reached — they are the second line, and they are
        // here because the control's revert says `SignerIsNotPayer` rather than saying what
        // actually went wrong.
        assertEq(signed.payer, buyer, "the signed struct was rewritten by a flip above");
        assertEq(signed.provider, provider, "the signed struct was rewritten by a flip above");
        assertEq(signed.amount, 250_000, "the signed struct was rewritten by a flip above");
        vm.prank(redeemer);
        escrow.redeemVoucher(signed, sig);
        assertEq(usdg.balanceOf(provider), 225_000);
    }

    // --- the boundaries ----------------------------------------------------------------------

    /// Boundary B5/B6. Gaps are allowed; every seq at or below the high-water mark is dead.
    function test_boundary_theSequenceMustStrictlyIncrease() public {
        _redeem(_v(1_000, 1));
        _redeem(_v(1_000, 5));
        assertEq(escrow.escrowOf(buyer).seqHigh, 5);

        for (uint64 dead = 1; dead <= 5; dead++) {
            Voucher memory v = _v(1_000, dead);
            vm.prank(redeemer);
            vm.expectRevert(VoucherSeqNotIncreasing.selector);
            escrow.redeemVoucher(v, _sig(v));
        }

        Voucher memory zero = _v(1_000, 0);
        vm.prank(redeemer);
        vm.expectRevert(VoucherSeqZero.selector);
        escrow.redeemVoucher(zero, _sig(zero));

        _redeem(_v(1_000, 6));
        assertEq(escrow.escrowOf(buyer).seqHigh, 6);
    }

    /// Boundary B7 at -1 / exact / +1.
    function test_boundary_thePerCallCeilingAdmitsItsOwnValue() public {
        _redeem(_v(999_999, 1));
        _redeem(_v(1_000_000, 2));

        Voucher memory over = _v(1_000_001, 3);
        vm.prank(redeemer);
        vm.expectRevert(VoucherExceedsPerCallLimit.selector);
        escrow.redeemVoucher(over, _sig(over));
    }

    /// Boundary B8. The window cap DRAINS rather than resetting.
    function test_boundary_theRollingWindowCapAdmitsItsOwnValueAndThenDrains() public {
        _redeem(_v(1_000_000, 1));
        _redeem(_v(1_000_000, 2));
        _redeem(_v(1_000_000, 3));
        _redeem(_v(1_000_000, 4));
        _redeem(_v(1_000_000, 5)); // 5_000_000 == maxPerWindow, admitted exactly
        assertEq(escrow.escrowOf(buyer).spentInWindow, 5_000_000);

        Voucher memory over = _v(1, 6);
        vm.prank(redeemer);
        vm.expectRevert(EscrowWindowLimitExceeded.selector);
        escrow.redeemVoucher(over, _sig(over));

        // Half a window later, exactly half the cap has drained back — and not one unit more.
        // The three redemptions below stay under the 1_000_000 per-call ceiling, which is a
        // SEPARATE limit: a single 2_500_000 voucher here would be refused by that one instead
        // and would prove nothing about the window.
        vm.warp(block.timestamp + Constants.SLASH_WINDOW_SECONDS / 2);
        assertEq(escrow.escrowOf(buyer).spentInWindow, 5_000_000, "the stored counter is stale");

        _redeem(_v(1_000_000, 7));
        _redeem(_v(1_000_000, 8));
        _redeem(_v(500_000, 9));
        assertEq(escrow.escrowOf(buyer).spentInWindow, 5_000_000, "2_500_000 drained back, exactly");

        Voucher memory oneTooMany = _v(1, 10);
        vm.prank(redeemer);
        vm.expectRevert(EscrowWindowLimitExceeded.selector);
        escrow.redeemVoucher(oneTooMany, _sig(oneTooMany));
    }

    /// Boundary B9 at exact and +1.
    function test_boundary_theBalanceAdmitsExactlyWhatIsThere() public {
        vm.prank(buyer);
        escrow.setLimits(type(uint64).max, type(uint64).max);

        _redeem(_v(10_000_000, 1)); // the whole balance
        assertEq(escrow.escrowOf(buyer).balance, 0);
        assertEq(escrow.totalEscrowed(), 0);

        Voucher memory over = _v(1, 2);
        vm.prank(redeemer);
        vm.expectRevert(EscrowInsufficient.selector);
        escrow.redeemVoucher(over, _sig(over));
    }

    /// The voucher's own clock window, at every edge `require_valid_voucher_window` draws. Each
    /// bound is exercised at its admitted value AND one second past it, because a suite that only
    /// shows the refusal cannot tell a correct bound from one that refuses everything.
    function test_boundary_theVoucherClockWindowIsBoundedAtBothEnds() public {
        uint64 t = uint64(block.timestamp);

        // expiresAt must be strictly after issuedAt.
        Voucher memory flat = _v(1_000, 1);
        flat.expiresAt = flat.issuedAt;
        _expect(flat, InvalidVoucherWindow.selector);

        Voucher memory inverted = _v(1_000, 1);
        inverted.expiresAt = inverted.issuedAt - 1;
        _expect(inverted, InvalidVoucherWindow.selector);

        // The lifetime ceiling: 300s is admitted, 301s is not.
        Voucher memory exact = _v(1_000, 1);
        exact.expiresAt = exact.issuedAt + Constants.VOUCHER_MAX_LIFETIME_SECONDS;
        _redeem(exact);

        Voucher memory tooLong = _v(1_000, 2);
        tooLong.expiresAt = tooLong.issuedAt + Constants.VOUCHER_MAX_LIFETIME_SECONDS + 1;
        _expect(tooLong, VoucherLifetimeTooLong.selector);

        // A `uint64` maximum for `expiresAt` is caught by the LIFETIME bound, before anything
        // adds the grace period to it — so the addition below the check can never overflow.
        Voucher memory farFuture = _v(1_000, 2);
        farFuture.expiresAt = type(uint64).max;
        _expect(farFuture, VoucherLifetimeTooLong.selector);

        // Forward skew: +120s is admitted, +121s is not.
        Voucher memory skewed = _v(1_000, 2);
        skewed.issuedAt = t + Constants.CLOCK_SKEW_TOLERANCE_SECONDS;
        skewed.expiresAt = skewed.issuedAt + 10;
        _redeem(skewed);

        Voucher memory tooEarly = _v(1_000, 3);
        tooEarly.issuedAt = t + Constants.CLOCK_SKEW_TOLERANCE_SECONDS + 1;
        tooEarly.expiresAt = tooEarly.issuedAt + 10;
        _expect(tooEarly, VoucherNotYetValid.selector);

        // The redeem grace: expiry + 1800s is admitted, +1801s is not.
        Voucher memory justInTime = _v(1_000, 3);
        justInTime.expiresAt = t - Constants.REDEEM_GRACE_SECONDS;
        justInTime.issuedAt = justInTime.expiresAt - 300;
        _redeem(justInTime);

        Voucher memory stale = _v(1_000, 4);
        stale.expiresAt = t - Constants.REDEEM_GRACE_SECONDS - 1;
        stale.issuedAt = stale.expiresAt - 300;
        _expect(stale, VoucherExpired.selector);

        // **Leg two of the overflow argument, and the (skew, grace) order pair.** `expiresAt` at
        // `type(uint64).max` is caught above by the LIFETIME bound; this is the other input that
        // reaches `v.expiresAt + REDEEM_GRACE_SECONDS`, and the only thing keeping it from
        // overflowing is that the skew bound runs FIRST. Transposing those two checks — the one
        // adjacent pair no test used to order — survived all 193 tests and turned this named
        // refusal into an anonymous `Panic(0x11)` on the money path.
        Voucher memory farIssued = _v(1_000, 4);
        farIssued.issuedAt = type(uint64).max - 400;
        farIssued.expiresAt = type(uint64).max - 200;
        _expect(farIssued, VoucherNotYetValid.selector);
    }

    /// Zero limits are REFUSE, not "unlimited". A never-configured escrow pays nobody.
    function test_wrongState_anUnconfiguredEscrowRefusesEveryRedeem() public {
        address fresh = vm.addr(0xF3E5);
        _fund(fresh, 1_000_000);
        vm.startPrank(fresh);
        usdg.approve(address(escrow), 1_000_000);
        escrow.deposit(1_000_000);
        vm.stopPrank();

        Voucher memory v = Voucher({
            payer: fresh,
            provider: provider,
            amount: 1,
            resourceHash: bytes32(0),
            requestHash: bytes32(0),
            seq: 1,
            issuedAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp) + 300
        });
        bytes memory sig = VoucherSigner.signVoucher(0xF3E5, ds, v);
        vm.prank(redeemer);
        vm.expectRevert(VoucherExceedsPerCallLimit.selector);
        escrow.redeemVoucher(v, sig);
    }

    function test_wrongState_anUnderStakedProviderIsNotPaid() public {
        _setBonded(provider, MINIMUM_STAKE - 1);
        Voucher memory v = _v(250_000, 1);
        vm.prank(redeemer);
        vm.expectRevert(ProviderBelowMinimumStake.selector);
        escrow.redeemVoucher(v, _sig(v));

        // and the floor is inclusive: exactly the minimum is paid.
        _setBonded(provider, MINIMUM_STAKE);
        _redeem(v);
        assertEq(usdg.balanceOf(provider), 225_000);
    }

    function test_wrongState_zeroAmountIsRefused() public {
        Voucher memory v = _v(0, 1);
        vm.prank(redeemer);
        vm.expectRevert(ZeroAmount.selector);
        escrow.redeemVoucher(v, _sig(v));
    }

    // --- the accounting a refusal must leave alone -------------------------------------------

    /// `tests/escrow.rs::an_underfunded_escrow_refuses_without_consuming_the_sequence`. On Solana
    /// this is free — a failed transaction rolls every account back. Here it is free for the same
    /// structural reason (a revert unwinds storage), and it is asserted anyway because the reason
    /// is structural rather than written down: an implementation that caught its own revert, or
    /// that split the effects across two calls, would lose it silently.
    function test_aRefusedRedemptionConsumesNoSequenceAndNoWindow() public {
        _redeem(_v(400_000, 3));
        vm.prank(buyer);
        escrow.setLimits(type(uint64).max, type(uint64).max);

        Voucher memory over = _v(9_600_001, 9); // one base unit more than is there
        vm.prank(redeemer);
        vm.expectRevert(EscrowInsufficient.selector);
        escrow.redeemVoucher(over, _sig(over));

        assertEq(escrow.escrowOf(buyer).seqHigh, 3, "the refused seq was not consumed");
        assertEq(escrow.escrowOf(buyer).spentInWindow, 400_000, "the window did not advance");
        assertEq(escrow.escrowOf(buyer).balance, 9_600_000);
        assertEq(escrow.escrowOf(buyer).totalRedeemed, 400_000);
        assertEq(escrow.totalEscrowed(), 9_600_000);
        assertEq(usdg.balanceOf(provider), 360_000);
        assertEq(usdg.balanceOf(treasury), 40_000);

        // seq 9 is still alive, which is what "not consumed" means.
        _redeem(_v(1_000, 9));
        assertEq(escrow.escrowOf(buyer).seqHigh, 9);
    }

    /// **The debt the deposit suite left.** Until this function existed, `totalFunded` and
    /// `balance` were the same number on every reachable path, so `e.totalFunded = e.balance;` in
    /// `_credit` passed all 162 tests. A redemption is the first thing that can pull them apart —
    /// and pulling them apart takes THREE steps, not two: the alias only becomes visible on the
    /// deposit that follows a spend, because after a redeem alone the aliased counter still holds
    /// the value it was assigned before the spend.
    function test_totalFundedIsALifetimeSumOfDepositsAndNeverFollowsTheBalanceDown() public {
        assertEq(escrow.escrowOf(buyer).totalFunded, 10_000_000);

        _redeem(_v(250_000, 1));
        assertEq(escrow.escrowOf(buyer).balance, 9_750_000);
        assertEq(escrow.escrowOf(buyer).totalFunded, 10_000_000, "a redemption does not unfund");

        _fund(buyer, 400_000);
        vm.startPrank(buyer);
        usdg.approve(address(escrow), 400_000);
        escrow.deposit(400_000);
        vm.stopPrank();

        assertEq(escrow.escrowOf(buyer).balance, 10_150_000);
        assertEq(
            escrow.escrowOf(buyer).totalFunded,
            10_400_000,
            "totalFunded is the SUM of deposits, not a restatement of the balance"
        );
    }

    /// A validator — or a chain reorg — whose clock stepped back must not hand window capacity to
    /// whoever noticed. `state.rs:605`: "Never moved backwards".
    function test_theWindowAnchorNeverMovesBackwards() public {
        uint64 t0 = uint64(block.timestamp);
        vm.warp(t0 + 10_000);
        _redeem(_v(1_000_000, 1));
        assertEq(escrow.escrowOf(buyer).windowStartedAt, t0 + 10_000);

        vm.warp(t0);
        _redeem(_v(1_000_000, 2));
        assertEq(escrow.escrowOf(buyer).windowStartedAt, t0 + 10_000, "the anchor never moves back");
        assertEq(escrow.escrowOf(buyer).spentInWindow, 2_000_000, "nor is capacity handed back");
    }

    function test_twoBuyersShareNeitherASequenceNorAWindow() public {
        uint256 otherKey = 0xA11CE;
        address other = vm.addr(otherKey);
        _fund(other, 5_000_000);
        vm.startPrank(other);
        usdg.approve(address(escrow), 5_000_000);
        escrow.deposit(5_000_000);
        escrow.setLimits(1_000_000, 1_000_000);
        vm.stopPrank();

        _redeem(_v(900_000, 7));

        Voucher memory v = _v(900_000, 1);
        v.payer = other;
        vm.prank(redeemer);
        escrow.redeemVoucher(v, VoucherSigner.signVoucher(otherKey, ds, v));

        assertEq(escrow.escrowOf(buyer).seqHigh, 7);
        assertEq(escrow.escrowOf(other).seqHigh, 1, "seq 1 is alive for a buyer who never used it");
        assertEq(escrow.escrowOf(buyer).spentInWindow, 900_000);
        assertEq(escrow.escrowOf(other).spentInWindow, 900_000);
        assertEq(escrow.escrowOf(buyer).balance, 9_100_000);
        assertEq(escrow.escrowOf(other).balance, 4_100_000);
        assertEq(escrow.totalEscrowed(), 13_200_000);
    }

    // --- the parameters are read at redemption time, never cached ----------------------------

    /// Signing a fee would mean every parameter change invalidated every voucher in flight
    /// (`attestation.rs:328-330`). So the split and its destination are read from Config at
    /// redemption, and the event publishes the rate that was applied.
    function test_theTakeRateAndTheTreasuryAreReadAtRedemptionTime() public {
        address newTreasury = address(0x7EA6);
        ParamSet memory p = config.params();
        p.treasury = newTreasury;
        p.takeRateBps = 2_500;
        vm.prank(admin);
        config.updateConfig(p, address(0));

        Voucher memory v = _v(400_000, 1);
        vm.expectEmit(true, true, true, true, address(escrow));
        emit VoucherRedeemed(
            buyer, provider, v.requestHash, v.resourceHash, 400_000, 100_000, 1, 2_500, 400_000
        );
        _redeem(v);

        assertEq(usdg.balanceOf(newTreasury), 100_000);
        assertEq(usdg.balanceOf(treasury), 0, "the old treasury is not paid");
        assertEq(usdg.balanceOf(provider), 300_000);
    }

    /// A 0% take rate pays the treasury nothing and must not emit a zero-value transfer that a
    /// blocklisted treasury could revert.
    function test_aZeroTakeRatePaysTheProviderTheWholeAmount() public {
        ParamSet memory p = config.params();
        p.takeRateBps = 0;
        vm.prank(admin);
        config.updateConfig(p, address(0));

        _redeem(_v(400_000, 1));
        assertEq(usdg.balanceOf(provider), 400_000);
        assertEq(usdg.balanceOf(treasury), 0);
    }

    /// A treasury that is owed NOTHING must not be able to halt the payout. USDG may carry an
    /// issuer blocklist, so `safeTransfer(treasury, 0)` is a real call that a blocklisted treasury
    /// would revert — and at a 0% take rate the treasury is owed nothing at all.
    /// `redeem_voucher.rs:186` guards the same call on `fee > 0` for the same reason, and without
    /// this test dropping that guard is invisible: `MockUSDG` accepts a zero transfer happily.
    /// `mockTokenOnly`: needs `MockUSDG.setBlocked`, a lever the real token has no equivalent
    /// of. The USDG deployed on 46630 has NO BLOCKLIST under any of five spellings — measured,
    /// `docs/chain-facts.md` §1a — so the fork cannot supply this premise at all, and a fork run
    /// that quietly passed here would be reporting on a case it never set up.
    function test_aBlocklistedTreasuryOwedNothingDoesNotHaltThePayout() public mockTokenOnly {
        ParamSet memory p = config.params();
        p.takeRateBps = 0;
        vm.prank(admin);
        config.updateConfig(p, address(0));
        usdg.setBlocked(treasury, true);

        _redeem(_v(400_000, 1));
        assertEq(usdg.balanceOf(provider), 400_000);
        assertEq(usdg.balanceOf(treasury), 0);
    }

    // --- ORDER. Only a voucher violating two checks at once can see it -----------------------

    /// Single-violation tests cannot distinguish one permutation of the check list from another,
    /// by construction. Each step below breaks TWO rules and asserts which one is diagnosed.
    function test_theCheckOrderIsTheOneTheSpecNames() public {
        // 1. redeemer BEFORE pause — a stranger submitting into a paused program.
        _setPaused(true);
        Voucher memory v = _v(250_000, 1);
        vm.prank(stranger);
        vm.expectRevert(NotRedeemer.selector);
        escrow.redeemVoucher(v, _sig(v));

        // 2. pause BEFORE the voucher body — paused, and a zero amount.
        Voucher memory z = _v(0, 1);
        vm.prank(redeemer);
        vm.expectRevert(ProgramPaused.selector);
        escrow.redeemVoucher(z, _sig(z));
        _setPaused(false);

        // 3. amount BEFORE the clock window — zero amount, and an inverted window.
        Voucher memory zi = _v(0, 1);
        zi.expiresAt = zi.issuedAt;
        _expect(zi, ZeroAmount.selector);

        // 4. the lifetime bound BEFORE the skew bound — 400s long, and issued 1000s ahead.
        Voucher memory ll = _v(1_000, 1);
        ll.issuedAt = uint64(block.timestamp) + 1_000;
        ll.expiresAt = ll.issuedAt + 400;
        _expect(ll, VoucherLifetimeTooLong.selector);

        // 5. the clock window BEFORE seq — long expired, and seq 0.
        Voucher memory ez = _v(1_000, 0);
        ez.issuedAt = uint64(block.timestamp) - 5_000;
        ez.expiresAt = ez.issuedAt + 300;
        _expect(ez, VoucherExpired.selector);

        // 6. `seq != 0` BEFORE `seq > seqHigh` — seq 0 against a non-zero high-water mark.
        _redeem(_v(1_000, 7));
        _expect(_v(1_000, 0), VoucherSeqZero.selector);

        // 7. the signature BEFORE the per-call ceiling — over the ceiling, wrong key.
        Voucher memory big = _v(2_000_000, 8);
        vm.prank(redeemer);
        vm.expectRevert(SignerIsNotPayer.selector);
        escrow.redeemVoucher(big, _badSig(big));

        // 8. the per-call ceiling BEFORE the window cap — over both at once.
        _expect(_v(6_000_000, 8), VoucherExceedsPerCallLimit.selector);

        // 9. the window cap BEFORE the stake floor — over the window, provider unstaked.
        vm.prank(buyer);
        escrow.setLimits(1_000_000, 500);
        _setBonded(provider, 0);
        _expect(_v(600, 8), EscrowWindowLimitExceeded.selector);
    }

    /// **Deliberate divergence 1 (the design's check order over `redeem_voucher.rs:144`).** The
    /// Anchor program admits the sequence AFTER proving the signature; the design puts it before,
    /// and this is the test that pins which one this contract implements. It is cheaper — a stale
    /// voucher is rejected without paying for `ecrecover` — and it leaks nothing, because `seqHigh`
    /// is public state anyone can read from `escrowOf`.
    function test_divergence_theSequenceIsCheckedBeforeTheSignature() public {
        _redeem(_v(1_000, 7));

        Voucher memory stale = _v(1_000, 7); // dead seq AND a signature by the wrong key
        vm.prank(redeemer);
        vm.expectRevert(VoucherSeqNotIncreasing.selector);
        escrow.redeemVoucher(stale, _badSig(stale));

        // The same voucher with a LIVE seq and the same wrong key gets the other diagnosis, so
        // the assertion above is about order and not about which check happens to be reachable.
        Voucher memory live = _v(1_000, 8);
        vm.prank(redeemer);
        vm.expectRevert(SignerIsNotPayer.selector);
        escrow.redeemVoucher(live, _badSig(live));
    }

    /// **Deliberate divergence 2 (`redeem_voucher.rs:148-153` over the design's check list,
    /// which has no stake check at all).** Reinstated at the Anchor program's position: after the
    /// window limit, before the balance check. Being paid is the counterpart of being slashable,
    /// and the backend the threat model assumes compromised must not be the only thing enforcing
    /// it.
    function test_divergence_theStakeFloorIsCheckedBeforeTheBalance() public {
        vm.prank(buyer);
        escrow.setLimits(type(uint64).max, type(uint64).max);
        _setBonded(provider, MINIMUM_STAKE - 1);

        // Over the balance AND under the stake floor: the stake floor is diagnosed.
        Voucher memory v = _v(10_000_001, 1);
        _expect(v, ProviderBelowMinimumStake.selector);

        // With the floor cleared, the same voucher reaches the balance check.
        _setBonded(provider, MINIMUM_STAKE);
        _expect(v, EscrowInsufficient.selector);
    }

    // --- effects strictly before interactions ------------------------------------------------

    /// The proof that `nonReentrant` is load-bearing HERE in a way it is not on the funding
    /// doors: this path pays out, so there is no measured delta to fall back on.
    ///
    /// The asset re-enters `redeemVoucher` from inside the provider payout, with the SAME
    /// voucher. The token is also made the configured redeemer, so the nested call would clear
    /// `onlyRedeemer` as well — the only thing left refusing it is the guard.
    function test_wrongState_aReentrantAssetCannotRecurseIntoRedeemVoucher() public {
        RedeemReentrantUSDG evil = new RedeemReentrantUSDG();
        X402Escrow e2 = _deployEscrow(address(evil), address(0));

        evil.mint(buyer, 10_000_000);
        vm.startPrank(buyer);
        evil.approve(address(e2), 10_000_000);
        e2.deposit(10_000_000);
        e2.setLimits(1_000_000, 5_000_000);
        vm.stopPrank();

        ParamSet memory p = config.params();
        p.redeemer = address(evil);
        vm.prank(admin);
        config.updateConfig(p, address(0));

        Voucher memory v = _v(250_000, 1);
        bytes memory sig = VoucherSigner.signVoucher(buyerKey, e2.DOMAIN_SEPARATOR(), v);
        evil.arm(address(e2), abi.encodeCall(X402Escrow.redeemVoucher, (v, sig)));

        // `evil.didReenter()` cannot be read afterwards — the outer call reverts, and that
        // unwinds the MOCK's storage along with the escrow's. `expectCall` is checked by the
        // inspector as calls happen, so it survives the revert and is the only way to assert the
        // nested call was actually attempted rather than skipped.
        vm.expectCall(address(e2), abi.encodeCall(X402Escrow.redeemVoucher, (v, sig)), 2);
        vm.prank(address(evil));
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        e2.redeemVoucher(v, sig);

        assertEq(e2.escrowOf(buyer).balance, 10_000_000, "and nothing moved");
        assertEq(evil.balanceOf(provider), 0);
        assertEq(e2.escrowOf(buyer).seqHigh, 0);
    }

    /// **The committable ordering guard (a review suggestion, sibling of F-1).** Every one of the
    /// six effects must already be written when the FIRST external call happens. This is the test
    /// the batch path inherits: a batch that reorders anything fails it without any mutation.
    function test_everyEffectIsWrittenBeforeTheFirstTransfer() public {
        RedeemObserverUSDG obs = new RedeemObserverUSDG();
        X402Escrow e2 = _deployEscrow(address(obs), address(0));

        obs.mint(buyer, 10_000_000);
        vm.startPrank(buyer);
        obs.approve(address(e2), 10_000_000);
        e2.deposit(10_000_000);
        e2.setLimits(1_000_000, 5_000_000);
        vm.stopPrank();

        obs.arm(address(e2), buyer);

        uint64 t = uint64(block.timestamp);
        Voucher memory v = _v(250_000, 1);
        bytes memory sig = VoucherSigner.signVoucher(buyerKey, e2.DOMAIN_SEPARATOR(), v);
        vm.prank(redeemer);
        e2.redeemVoucher(v, sig);

        assertTrue(obs.observed(), "the observer never ran, so nothing below is asserting anything");
        assertEq(obs.seenBalance(), 9_750_000, "balance not yet debited at payout time");
        assertEq(obs.seenSeqHigh(), 1, "seqHigh not yet advanced at payout time");
        assertEq(obs.seenSpentInWindow(), 250_000, "spentInWindow not yet advanced at payout time");
        assertEq(obs.seenWindowStartedAt(), t, "windowStartedAt not yet anchored at payout time");
        assertEq(obs.seenTotalRedeemed(), 250_000, "totalRedeemed not yet advanced at payout time");
        assertEq(obs.seenTotalEscrowed(), 9_750_000, "totalEscrowed not yet debited at payout time");

        // and the redemption really completed, so the observation above is of a real payout.
        assertEq(obs.balanceOf(provider), 225_000);
        assertEq(obs.balanceOf(treasury), 25_000);
    }

    // --- the signature guard, across the ADDRESS SPACE ---------------------------------------
    //
    // Every negative signature test above uses the fixture's own `buyer` and `provider`, so on its
    // own the guard is exercised at exactly ONE `(payer, provider)` point — and a review's
    // degenerate implementation walked straight through it:
    //
    //     if (v.provider != address(uint160(0xBADC0DE))
    //             && recoverVoucherSigner(v, sig) != v.payer) revert SignerIsNotPayer();
    //
    // passed all 193 tests, and a voucher naming that provider with SIXTY-FIVE ZERO BYTES for a
    // signature then moved 900_000 out of a funded buyer. It is the second signature-forgery
    // backdoor to walk through a suite here (the first was `r == 0 && s == 2` inside
    // `_recover`), and the lesson is the same one at a different layer: **a guard tested at a
    // single point is a guard tested nowhere.**
    //
    // Three tests replace that point, and they are three because none of them is sufficient alone:
    // a fuzz cannot draw a magic constant, a sweep cannot cover the space, and neither can see a
    // bypass keyed on an address that appears in neither.

    /// A voucher naming an arbitrary payer and provider, otherwise the fixture's shape.
    function _vFor(address payer_, address prov, uint64 amount, uint64 seq)
        internal
        view
        returns (Voucher memory)
    {
        return Voucher({
            payer: payer_,
            provider: prov,
            amount: amount,
            resourceHash: keccak256("resource"),
            requestHash: keccak256(abi.encode("request", payer_, prov, seq)),
            seq: seq,
            issuedAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp) + 300
        });
    }

    /// Fund and ARM an arbitrary buyer, so every refusal below is asserted against an escrow that
    /// really could have paid. A refusal from an empty or unarmed escrow proves nothing about the
    /// signature guard — it would be refused by `VoucherExceedsPerCallLimit` first.
    function _armBuyer(address who, uint64 funds) internal {
        _fund(who, funds);
        vm.startPrank(who);
        usdg.approve(address(escrow), funds);
        escrow.deposit(funds);
        escrow.setLimits(1_000_000, 5_000_000);
        vm.stopPrank();
    }

    /// Sixty-five zero bytes — no signature at all. It reaches `_recover`'s `v ∈ {27,28}` guard,
    /// so the shipped contract answers `BadSignatureV`; a bypass that short-circuits before the
    /// recovery answers nothing at all and pays.
    function _unsigned() internal pure returns (bytes memory) {
        return new bytes(65);
    }

    /// The DETERMINISTIC half. A uniform `address` draw essentially never lands on a round
    /// constant, which is exactly where a hardcoded exemption lives — measured on the
    /// voucher-recovery tests, where a 512-run fuzz could not see `s == 2`. So the structured
    /// values are swept by name.
    function test_noProviderAddressIsExemptFromTheSignatureGuard() public {
        address[12] memory provs = [
            address(1),
            address(2),
            address(3),
            address(0xBADC0DE),
            address(0xC0FFEE),
            address(0xDEADBEEF),
            address(type(uint160).max),
            address(uint160(1) << 159),
            vm.addr(0xA11CE),
            provider,
            treasury,
            redeemer
        ];

        for (uint256 i = 0; i < provs.length; i++) {
            address prov = provs[i];
            _setBonded(prov, MINIMUM_STAKE);
            uint256 heldBefore = usdg.balanceOf(prov);

            Voucher memory v = _vFor(buyer, prov, 250_000, uint64(i + 1));

            bytes memory wrongKey = VoucherSigner.signVoucher(WRONG_KEY, ds, v);
            vm.prank(redeemer);
            vm.expectRevert(SignerIsNotPayer.selector);
            escrow.redeemVoucher(v, wrongKey);

            vm.prank(redeemer);
            vm.expectRevert(BadSignatureV.selector);
            escrow.redeemVoucher(v, _unsigned());

            assertEq(usdg.balanceOf(prov), heldBefore, "an unsigned voucher paid this provider");
        }

        assertEq(escrow.escrowOf(buyer).balance, 10_000_000, "the escrow was drained");
        assertEq(escrow.escrowOf(buyer).seqHigh, 0, "a refused voucher consumed a sequence");
    }

    /// The same sweep on the OTHER address dimension. A bypass keyed on the payer steals from one
    /// named buyer rather than for one named provider; it is the same hole seen from the other end,
    /// and a review measured that spelling as invisible too.
    function test_noPayerAddressIsExemptFromTheSignatureGuard() public {
        address[8] memory payers = [
            address(1),
            address(2),
            address(0xBADC0DE),
            address(0xC0FFEE),
            address(0xDEADBEEF),
            address(type(uint160).max),
            vm.addr(0xA11CE),
            vm.addr(0xF00D)
        ];

        for (uint256 i = 0; i < payers.length; i++) {
            address p = payers[i];
            _armBuyer(p, 2_000_000);

            Voucher memory v = _vFor(p, provider, 250_000, 1);

            // Signed by a real key that is not this payer's — the recovery succeeds and the
            // comparison is the only thing that can refuse it.
            bytes memory otherKey = VoucherSigner.signVoucher(buyerKey, ds, v);
            vm.prank(redeemer);
            vm.expectRevert(SignerIsNotPayer.selector);
            escrow.redeemVoucher(v, otherKey);

            vm.prank(redeemer);
            vm.expectRevert(BadSignatureV.selector);
            escrow.redeemVoucher(v, _unsigned());

            assertEq(escrow.escrowOf(p).balance, 2_000_000, "an unsigned voucher spent this escrow");
            assertEq(escrow.escrowOf(p).seqHigh, 0);
        }
    }

    /// The FUZZ half. It cannot draw a magic constant, and that is not what it is for: it forces
    /// the guard to be unconditional over the interior of the address space, so a bypass has to be
    /// keyed on something the sweep names — and the sweep names the shapes people choose.
    function testFuzz_noVoucherIsEverRedeemedWithoutThePayersSignature(
        address payer_,
        address prov,
        uint64 amount
    ) public {
        vm.assume(payer_ != address(0) && prov != address(0));
        vm.assume(payer_ != buyer); // else the wrong-key signature below is the RIGHT one
        vm.assume(payer_ != address(escrow) && payer_ != address(usdg));
        vm.assume(payer_ != address(config) && payer_ != address(stake));
        vm.assume(payer_ != address(this) && payer_ != address(vm));
        vm.assume(prov != address(escrow) && prov != address(usdg));
        amount = uint64(bound(amount, 1, 1_000_000));

        _armBuyer(payer_, 2_000_000);
        _setBonded(prov, MINIMUM_STAKE);

        Voucher memory v = _vFor(payer_, prov, amount, 1);

        bytes memory otherKey = VoucherSigner.signVoucher(buyerKey, ds, v);
        vm.prank(redeemer);
        vm.expectRevert(SignerIsNotPayer.selector);
        escrow.redeemVoucher(v, otherKey);

        vm.prank(redeemer);
        vm.expectRevert(BadSignatureV.selector);
        escrow.redeemVoucher(v, _unsigned());

        assertEq(escrow.escrowOf(payer_).balance, 2_000_000, "an unsigned voucher moved money");
        assertEq(escrow.escrowOf(payer_).seqHigh, 0);
        assertEq(escrow.totalEscrowed(), 12_000_000);
    }

    /// The SOURCE-TEXT half, and the reason there is one. The two behavioural tests above prove
    /// the guard holds at every address they reach; a backdoor keyed on an address the sweep does
    /// not name and the fuzzer cannot draw would survive both. The recovery call-site gate does not
    /// see it either: `recoverVoucherSigner(` does not contain the substring `recover(`, so
    /// `test_recoveryHappensAtExactlyOneCallSiteInSrc` still counts exactly one call site with the
    /// backdoor in place — measured in review.
    ///
    /// So the comparison is PINNED, the way `test/Types.t.sol` pins the four wire hashes. A
    /// deliberate edit is a red test that asks the editor to say so here; an `&&`-ed exemption is a
    /// red test that cannot be argued with. It is not a substitute for the behavioural tests and
    /// they are not a substitute for it.
    function test_theSignatureComparisonIsUnconditionalInTheSource() public view {
        string memory src = vm.readFile(string.concat(vm.projectRoot(), "/src/X402Escrow.sol"));

        assertEq(
            _count(
                src,
                "        if (_recover(_hashTypedDataV4(Voucher712.hashVoucher(v)), sig) != v.payer) {\n            revert SignerIsNotPayer();\n        }\n"
            ),
            1,
            "the signature guard is not the exact unconditional comparison this test pins"
        );
        assertEq(
            _count(src, "SignerIsNotPayer()"),
            1,
            "SignerIsNotPayer is raised somewhere other than that one guard"
        );
    }

    function _count(string memory haystack, string memory needle)
        internal
        pure
        returns (uint256 n)
    {
        bytes memory h = bytes(haystack);
        bytes memory x = bytes(needle);
        if (x.length == 0 || x.length > h.length) return 0;
        for (uint256 i = 0; i + x.length <= h.length; i++) {
            uint256 j = 0;
            while (j < x.length && h[i + j] == x[j]) j++;
            if (j == x.length) n++;
        }
    }

    // --- the split, over the whole amount space ----------------------------------------------

    /// Fuzz samples the typical. Every amount the fuzzer draws is bounded into the escrow's own
    /// limits so the redemption actually happens, and the assertions pin both halves of the split
    /// separately rather than only their sum.
    function testFuzz_theSplitPaysBothSidesAndTheCountersFollow(uint64 amount) public {
        amount = uint64(bound(amount, 1, 1_000_000));

        _redeem(_v(amount, 1));

        uint64 expectedFee = uint64((uint256(amount) * TAKE_RATE_BPS) / 10_000);
        assertEq(usdg.balanceOf(treasury), expectedFee, "the treasury gets floor(amount * bps)");
        assertEq(usdg.balanceOf(provider), amount - expectedFee, "the provider gets the rest");
        assertEq(escrow.escrowOf(buyer).balance, 10_000_000 - amount);
        assertEq(escrow.totalEscrowed(), 10_000_000 - amount);
        assertEq(escrow.escrowOf(buyer).spentInWindow, amount);
        assertEq(escrow.escrowOf(buyer).totalRedeemed, amount);
        assertEq(escrow.escrowOf(buyer).totalFunded, 10_000_000, "a spend is not an unfunding");
        assertEq(usdg.balanceOf(address(escrow)), 10_000_000 - amount);
    }

    /// **Beside the fuzz, not instead of it.** A uniform draw over `uint64` essentially never
    /// lands on 1, 9, 10 or 10_001 — the amounts where a floor division changes character — so
    /// the structured edges are swept deterministically. The voucher-recovery tests needed exactly
    /// this pairing to see a backdoor a 512-run fuzz could not.
    function test_theSplitIsExactAcrossASweepOfStructuredAmounts() public {
        uint64[16] memory amounts = [
            uint64(1),
            2,
            3,
            7,
            9,
            10,
            11,
            99,
            100,
            101,
            9_999,
            10_000,
            10_001,
            123_457,
            999_999,
            1_000_000
        ];

        uint256 paidProvider;
        uint256 paidTreasury;
        uint256 total;

        for (uint256 i = 0; i < amounts.length; i++) {
            uint64 amount = amounts[i];
            uint64 expectedFee = uint64((uint256(amount) * TAKE_RATE_BPS) / 10_000);

            _redeem(_v(amount, uint64(i + 1)));

            paidProvider += amount - expectedFee;
            paidTreasury += expectedFee;
            total += amount;

            assertEq(usdg.balanceOf(provider), paidProvider, "provider, cumulative");
            assertEq(usdg.balanceOf(treasury), paidTreasury, "treasury, cumulative");
            assertEq(escrow.escrowOf(buyer).balance, 10_000_000 - total);
            assertEq(escrow.escrowOf(buyer).spentInWindow, total);
        }

        assertEq(paidProvider + paidTreasury, total, "not one base unit lost or invented");
        assertEq(usdg.balanceOf(address(escrow)), 10_000_000 - total);
    }
}
