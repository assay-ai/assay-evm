// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.24;

/// Counts every fuzzed handler call, refused or not, so `InvariantsTest.afterInvariant` can tell
/// a full campaign run from a shrunk or replayed sequence.
///
/// A handler action that reverts rolls back its own writes, so a counter bumped inside it would
/// count only the calls that did not revert, and a run in which every call reverted would read
/// as a short one. The `step` modifier therefore counts in the outer frame and runs the action
/// in a self-call: a refused action is still discarded whole, exactly as forge discards a
/// reverting handler call, and only `steps` (and `refusedSteps`) survive it.
///
/// A deterministic test that drives the handler by hand calls `runDirectly()` first, so that an
/// action it expects to land reverts the test instead of being counted as refused.
abstract contract StepCounter {
    /// Fuzzed handler calls in this run, the refused ones included.
    uint256 public steps;
    /// Of those, the ones whose action reverted (and was discarded).
    uint256 public refusedSteps;
    /// Set by a deterministic test: actions run in place and a revert propagates.
    bool public direct;

    function runDirectly() external {
        direct = true;
    }

    modifier step() {
        if (direct || msg.sender == address(this)) {
            _;
        } else {
            steps += 1;
            (bool success,) = address(this).call(msg.data);
            if (!success) refusedSteps += 1;
        }
    }
}
