// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Window} from "../src/libraries/Window.sol";
import {Constants} from "../src/Constants.sol";

contract WindowTest is Test {
    uint64 internal constant T = 1_760_000_000;
    uint64 internal constant W = Constants.SLASH_WINDOW_SECONDS; // 86_400

    function test_aZeroCounterStaysZeroWhateverTheClockSays() public pure {
        assertEq(Window.decay(0, T, T), 0);
        assertEq(Window.decay(0, T, 0), 0);
        assertEq(Window.decay(0, 0, type(uint64).max), 0);
    }

    function test_noTimeElapsedCarriesTheWholeCounter() public pure {
        assertEq(Window.decay(1_000, T, T), 1_000);
    }

    function test_aClockThatWentBackwardsReturnsCapacityToNobody() public pure {
        assertEq(Window.decay(1_000, T, T - 1), 1_000);
        assertEq(Window.decay(1_000, T, T - W), 1_000);
        assertEq(Window.decay(type(uint64).max, type(uint64).max, 0), type(uint64).max);
    }

    function test_aFullWindowDrainsToZeroAndStaysThere() public pure {
        assertEq(Window.decay(1_000, T, T + W), 0);
        assertEq(Window.decay(1_000, T, T + W + 1), 0);
        assertEq(Window.decay(type(uint64).max, 0, type(uint64).max), 0);
    }

    function test_theDrainIsLinearAcrossTheWindow() public pure {
        assertEq(Window.decay(1_000, T, T + W / 2), 500);
        assertEq(Window.decay(1_000, T, T + W / 4), 750);
        assertEq(Window.decay(4 * 86_400, T, T + 86_400 / 4), 3 * 86_400);
    }

    /// The drain rounds UP: capacity is returned late, never early.
    function test_theDrainRoundsUp() public pure {
        assertEq(Window.decay(1, T, T + W - 1), 1);
        assertEq(Window.decay(3, T, T + 2 * (W / 3)), 1);
        assertEq(Window.decay(100, T, T + 1), 100);
    }

    function test_aSaturatedCounterDoesNotOverflowOrTruncate() public pure {
        assertEq(Window.decay(type(uint64).max, T, T), type(uint64).max);

        uint64 oneSecond = Window.decay(type(uint64).max, T, T + 1);
        assertLt(oneSecond, type(uint64).max);
        assertEq(type(uint64).max - oneSecond, type(uint64).max / W);

        assertEq(Window.decay(type(uint64).max, T, T + W / 2), type(uint64).max / 2 + 1);

        uint64[6] memory elapsed = [uint64(1), 2, 43_200, 86_398, 86_399, 86_400];
        uint64 previous = type(uint64).max;
        for (uint256 i = 0; i < elapsed.length; i++) {
            uint64 carried = Window.decay(type(uint64).max, T, T + elapsed[i]);
            assertLe(carried, previous, "the drain went backwards");
            previous = carried;
        }
        assertEq(previous, 0);
    }

    function test_anAnchorOfZeroIsSimplyAVeryOldWindow() public pure {
        assertEq(Window.decay(1_000, 0, T), 0);
        assertEq(Window.decay(1_000, 0, W), 0);
        assertEq(Window.decay(1_000, 0, W - 1), 1);
    }

    /// Boundary B15, at -1 / exact / +1.
    function test_boundaryAtExactlyOneWindow() public pure {
        assertEq(Window.decay(1_000, T, T + W - 1), 1);
        assertEq(Window.decay(1_000, T, T + W), 0);
        assertEq(Window.decay(1_000, T, T + W + 1), 0);
    }

    /// The drain never returns capacity early and never invents any — **and carries the value the
    /// closed form says it should**, at every sampled instant.
    ///
    /// The first version of this test asserted only `a <= counter` and `b <= a`. That is a bound
    /// and an ordering, and it pins no value: `decay ≡ 0`, `decay ≡ counter`, and a `decay` that
    /// ignores `nowTs` all satisfy both. All three were measured passing against it — see
    /// MUTATION-LOG.md rows D1, D2 and D3 — so the assertions below were added. The range spans
    /// `2 * W`, so the same property covers the interior of the window, the edge, and the
    /// discontinuity across it.
    function testFuzz_decayIsMonotonicAndBounded(uint64 counter, uint64 elapsed) public pure {
        elapsed = uint64(bound(elapsed, 0, 2 * W));

        uint64 a = Window.decay(counter, T, T + elapsed);
        uint64 b = Window.decay(counter, T, T + elapsed + 1);

        assertEq(a, closedForm(counter, elapsed), "decay disagrees with the closed form");
        assertEq(b, closedForm(counter, elapsed + 1), "decay disagrees one second later");
        assertLe(a, counter, "decay invented capacity");
        assertLe(b, a, "decay went backwards");
    }

    /// `ceil(counter * (W - elapsed) / W)`, written as floor-plus-remainder.
    ///
    /// Deliberately **not** the biased-numerator form `Window.decay` uses: an oracle that is the
    /// implementation's own expression copied into the test file proves only that the compiler is
    /// deterministic. Saturation and the zero counter are spelled out as their own cases rather
    /// than falling out of the arithmetic, for the same reason.
    function closedForm(uint64 counter, uint64 elapsed) internal pure returns (uint64) {
        if (counter == 0 || elapsed >= W) return 0;
        uint256 numerator = uint256(counter) * (W - elapsed);
        uint256 quotient = numerator / W;
        if (numerator % W != 0) quotient += 1;
        return uint64(quotient);
    }

    /// Saturation, as a property rather than as the three examples above: a whole window or more
    /// of elapsed time drains any counter to nothing, everywhere in the domain — not only at
    /// `T + W` and `T + W + 1`.
    function testFuzz_decaySaturatesAtOrPastTheWindowEdge(uint64 counter, uint64 elapsed)
        public
        pure
    {
        elapsed = uint64(bound(elapsed, W, type(uint64).max - T));
        assertEq(Window.decay(counter, T, T + elapsed), 0, "a drained window carried something");
    }

    /// The ceil, as a property. Inside the window a non-zero counter always carries at least one
    /// base unit: rounding down would hand the last unit of debt back for free, and it would do
    /// so at every `counter`/`elapsed` pair where the quotient falls below 1, not just at the
    /// `decay(1, T, T + W - 1)` example.
    function testFuzz_theDrainNeverReturnsTheLastUnitEarly(uint64 counter, uint64 elapsed)
        public
        pure
    {
        counter = uint64(bound(counter, 1, type(uint64).max));
        elapsed = uint64(bound(elapsed, 1, W - 1));
        assertGt(Window.decay(counter, T, T + elapsed), 0, "the last unit was returned early");
    }
}
