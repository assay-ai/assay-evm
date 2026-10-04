// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.24;

import {Test, stdError} from "forge-std/Test.sol";
import {Fee} from "../src/libraries/Fee.sol";
import {MathOverflow} from "../src/Errors.sol";
import {Constants} from "../src/Constants.sol";

/// `Fee`'s functions are `internal`, so a direct call from the test is inlined into the test's own
/// frame and `vm.expectRevert` — which arms the *next external call* — would never see the revert.
/// This harness gives them a call boundary. It is held and called by `FeeTest`, so it is compiled
/// and executed rather than merely present.
contract FeeHarness {
    function splitFee(uint64 amount, uint16 takeRateBps) external pure returns (uint64, uint64) {
        return Fee.splitFee(amount, takeRateBps);
    }

    function bpsOf(uint64 amount, uint16 bps) external pure returns (uint64) {
        return Fee.bpsOf(amount, bps);
    }
}

contract FeeTest is Test {
    FeeHarness internal harness = new FeeHarness();

    /// The first amount whose `20_000` bps share does not fit a `uint64`: its quotient is exactly
    /// `2**64`, one bit past the type. The line below it is the largest that still fits.
    uint64 internal constant FIRST_OVERFLOWING_AMOUNT = 9_223_372_036_854_775_808; // 2**63
    uint64 internal constant LARGEST_FITTING_AMOUNT = 9_223_372_036_854_775_807; // 2**63 - 1

    /// Bound to the constant rather than typed, exactly as `Window.t.sol` binds `W`. The literal
    /// `10_000` was written out at ten sites here and nowhere derived, so the denominator these
    /// tests assert against was decoupled from the one the library divides by.
    uint16 internal constant BPS = Constants.BPS_DENOMINATOR;

    /// Ported from state.rs::the_fee_split_never_loses_or_invents_a_base_unit.
    function test_theFeeSplitNeverLosesOrInventsABaseUnit() public pure {
        uint64[11] memory amount = [
            uint64(0),
            1,
            9,
            10,
            1_000_000,
            1_000_000,
            1_000_000,
            type(uint64).max,
            type(uint64).max,
            type(uint64).max,
            7
        ];
        uint16[11] memory bps =
            [uint16(1_000), 1_000, 1_000, 1_000, 1_000, 0, 3_000, 3_000, 10_000, 0, 3_000];
        uint64[11] memory expFee = [
            uint64(0),
            0,
            0,
            1,
            100_000,
            0,
            300_000,
            5_534_023_222_112_865_484,
            type(uint64).max,
            0,
            2
        ];
        uint64[11] memory expProvider = [
            uint64(0),
            1,
            9,
            9,
            900_000,
            1_000_000,
            700_000,
            12_912_720_851_596_686_131,
            0,
            type(uint64).max,
            5
        ];

        for (uint256 i = 0; i < amount.length; i++) {
            (uint64 fee, uint64 providerAmount) = Fee.splitFee(amount[i], bps[i]);
            assertEq(fee, expFee[i], "fee");
            assertEq(providerAmount, expProvider[i], "provider amount");
            assertEq(uint256(fee) + providerAmount, amount[i], "the split lost a unit");
            assertLe(fee, amount[i]);
        }
    }

    /// Dust pays no fee, and that is a decision rather than a rounding accident.
    ///
    /// The three cases above the divider are `state.rs:953-958` verbatim and all use one rate, so
    /// on their own they cannot see a `splitFee` that ignores its `takeRateBps` argument entirely
    /// (measured: MUTATION-LOG.md row E4). The cases below add a second rate so this test carries
    /// its own rate sensitivity instead of borrowing it from the 11-row table; they are derived
    /// from the same formula rather than taken from Rust, and the ported table's `(7, 3_000)` row
    /// is the Rust-sourced anchor for this rate.
    function test_aCallTooSmallToDividePaysTheProviderInFull() public pure {
        (uint64 f1, uint64 p1) = Fee.splitFee(1, 1_000);
        assertEq(f1, 0);
        assertEq(p1, 1);
        (uint64 f9, uint64 p9) = Fee.splitFee(9, 1_000);
        assertEq(f9, 0);
        assertEq(p9, 9);
        (uint64 f10, uint64 p10) = Fee.splitFee(10, 1_000);
        assertEq(f10, 1);
        assertEq(p10, 9);

        // --- a second rate: 3_000 bps, where the dust threshold sits at 4 rather than 10 ---
        (uint64 f3, uint64 p3) = Fee.splitFee(3, 3_000);
        assertEq(f3, 0, "floor(0.9) is no fee");
        assertEq(p3, 3);
        (uint64 f4, uint64 p4) = Fee.splitFee(4, 3_000);
        assertEq(f4, 1, "floor(1.2) is one base unit");
        assertEq(p4, 3);
        // The same amount at two different rates must not produce the same fee.
        (uint64 feeLow,) = Fee.splitFee(10, 1_000);
        (uint64 feeHigh,) = Fee.splitFee(10, 3_000);
        assertEq(feeLow, 1);
        assertEq(feeHigh, 3, "the rate argument must change the fee");
    }

    /// The identity is structural: providerAmount is defined as amount - fee, so it cannot
    /// disagree with fee for any input at all.
    function testFuzz_feePlusProviderAlwaysEqualsAmount(uint64 amount, uint16 bps) public pure {
        bps = uint16(bound(bps, 0, BPS));
        (uint64 fee, uint64 providerAmount) = Fee.splitFee(amount, bps);
        assertEq(uint256(fee) + providerAmount, amount);
        assertLe(fee, amount);
    }

    function testFuzz_bpsOfNeverExceedsTheAmount(uint64 amount, uint16 bps) public pure {
        bps = uint16(bound(bps, 0, BPS));
        assertLe(Fee.bpsOf(amount, bps), amount);
    }

    /// `bpsOf` at the ends of its range, so that the bound above is not the only thing asserted
    /// about it — `assertLe(bpsOf(…), amount)` alone would hold for a function that always
    /// returned zero.
    function test_bpsOfAtTheEndsOfItsRange() public pure {
        assertEq(Fee.bpsOf(type(uint64).max, 0), 0, "0 bps of anything is nothing");
        assertEq(Fee.bpsOf(type(uint64).max, BPS), type(uint64).max, "10k bps is the whole");
        assertEq(Fee.bpsOf(0, BPS), 0);
        // Dust floors away, exactly as it does in splitFee.
        assertEq(Fee.bpsOf(9, 1_000), 0);
        assertEq(Fee.bpsOf(10, 1_000), 1);
        // The execute_slash.rs:170-171 shares of a $1.00 penalty at the shipped 70/20 split.
        assertEq(Fee.bpsOf(1_000_000, 7_000), 700_000);
        assertEq(Fee.bpsOf(1_000_000, 2_000), 200_000);
    }

    /// The floor, stated exactly rather than bounded: `r` is the unique integer with
    /// `r * 10_000 <= amount * bps < (r + 1) * 10_000`. Any change of rounding direction, any
    /// truncation of the widened product, and any constant return breaks one of the two halves.
    function testFuzz_bpsOfIsExactlyTheFloorOfTheShare(uint64 amount, uint16 bps) public pure {
        bps = uint16(bound(bps, 0, BPS));
        uint256 exact = uint256(amount) * bps;
        uint256 r = Fee.bpsOf(amount, bps);
        assertLe(r * BPS, exact, "bpsOf rounded up");
        assertLt(exact, (r + 1) * BPS, "bpsOf lost part of the share");
    }

    /// The two entry points must not be able to disagree — **and neither may be wrong in the way
    /// the other is**.
    ///
    /// The equality alone is relational, and two functions that are both degenerate in the same
    /// way agree perfectly: with `bpsOf` and `splitFee`'s fee both forced to `0` this test was
    /// measured passing at `runs: 514` (MUTATION-LOG.md row E5). The third assertion anchors one
    /// side to a value computed here, so agreement is no longer sufficient to pass.
    function testFuzz_splitFeeTakesExactlyBpsOf(uint64 amount, uint16 takeRateBps) public pure {
        takeRateBps = uint16(bound(takeRateBps, 0, BPS));
        (uint64 fee,) = Fee.splitFee(amount, takeRateBps);
        assertEq(fee, Fee.bpsOf(amount, takeRateBps), "the two splits disagree");
        assertEq(fee, independentFloor(amount, takeRateBps), "both splits agree on a wrong value");
    }

    /// `floor(amount * bps / BPS)`, written as "subtract the remainder, then divide exactly"
    /// rather than as the library's single truncating division — a second expression of the same
    /// quantity, not a copy of the first.
    function independentFloor(uint64 amount, uint16 bps) internal pure returns (uint64) {
        uint256 numerator = uint256(amount) * bps;
        return uint64((numerator - (numerator % BPS)) / BPS);
    }

    /// `bpsOf`'s own caller, ported as a property: execute_slash.rs:170-178 takes two independent
    /// bps shares of the applied penalty and gives the provider the remainder BY SUBTRACTION.
    /// Whenever the two shares fit inside 10,000 bps, that three-way split neither loses nor
    /// invents a base unit — the same guarantee `splitFee` makes for the two-way one.
    function testFuzz_theSlashSplitNeverLosesOrInventsABaseUnit(
        uint64 applied,
        uint16 agentBps,
        uint16 platformBps
    ) public pure {
        agentBps = uint16(bound(agentBps, 0, BPS));
        platformBps = uint16(bound(platformBps, 0, BPS - agentBps));

        uint64 agentAmount = Fee.bpsOf(applied, agentBps);
        uint64 platformAmount = Fee.bpsOf(applied, platformBps);
        uint256 taken = uint256(agentAmount) + platformAmount;
        assertLe(taken, applied, "the split took more than the penalty");

        uint64 providerAmount = applied - agentAmount - platformAmount;
        assertEq(uint256(agentAmount) + platformAmount + providerAmount, applied, "a unit moved");
    }

    // --- the checked narrowing -------------------------------------------------------------

    /// `execute_slash.rs:310` narrows with `u64::try_from(...)` and yields `MathOverflow`; a bare
    /// `uint64(...)` cast in Solidity truncates silently instead. Asserted at the exact boundary:
    /// the largest share that still fits, then the very next amount, whose share is `2**64`.
    function test_bpsOfRevertsMathOverflowWhenTheNarrowingWouldLoseABit() public {
        // The largest value that does NOT overflow — one below the boundary, and exact.
        assertEq(
            harness.bpsOf(LARGEST_FITTING_AMOUNT, 20_000),
            type(uint64).max - 1,
            "the largest fitting share must still be returned"
        );

        // The first value that DOES: quotient == 2**64, one bit past the type.
        vm.expectRevert(MathOverflow.selector);
        harness.bpsOf(FIRST_OVERFLOWING_AMOUNT, 20_000);

        // The measured case from the original review: this used to return
        // 10_210_272_844_798_236_812, i.e. the true quotient mod 2**64.
        vm.expectRevert(MathOverflow.selector);
        harness.bpsOf(type(uint64).max, 65_535);

        // The domain edge itself: 10_000 bps of everything is everything and must NOT revert,
        // 10_001 bps of everything cannot fit and must.
        assertEq(harness.bpsOf(type(uint64).max, BPS), type(uint64).max);
        vm.expectRevert(MathOverflow.selector);
        harness.bpsOf(type(uint64).max, BPS + 1);
    }

    /// The same guard on the other entry point. Note this half is deliberately STRICTER than the
    /// Anchor original — `state.rs:634-635` narrows the fee with a bare `as u64`, which truncates
    /// in Rust too — so it is asserted here rather than inherited. See `Fee.narrow`'s NatSpec.
    function test_splitFeeRevertsMathOverflowWhenTheNarrowingWouldLoseABit() public {
        vm.expectRevert(MathOverflow.selector);
        harness.splitFee(FIRST_OVERFLOWING_AMOUNT, 20_000);

        vm.expectRevert(MathOverflow.selector);
        harness.splitFee(type(uint64).max, 65_535);

        // The largest amount whose fee still fits: 10_000 bps of everything, which is the whole
        // amount and leaves the provider nothing. Must not revert.
        (uint64 fee, uint64 providerAmount) = harness.splitFee(type(uint64).max, BPS);
        assertEq(fee, type(uint64).max);
        assertEq(providerAmount, 0);
    }

    /// Between the two there is a band where the narrowing succeeds and the SUBTRACTION is what
    /// refuses: the fee fits a `uint64` but exceeds the amount. That reverts `Panic(0x11)`, not
    /// `MathOverflow`, and deliberately so — `Errors.sol` keeps the custom error for the silent
    /// narrowing and leaves ordinary checked arithmetic to panic on its own. Asserted so the
    /// boundary is described completely rather than half-described.
    function test_aFeeThatFitsButExceedsTheAmountPanicsRatherThanReverting() public {
        vm.expectRevert(stdError.arithmeticError);
        harness.splitFee(LARGEST_FITTING_AMOUNT, 20_000);
    }
}
