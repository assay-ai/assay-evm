// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.24;

import {Constants} from "../Constants.sol";
import {Cast} from "./Cast.sol";

/// The rolling 24-hour counter, ported verbatim from
/// the Anchor program's `programs/x402-payment/src/state.rs:413` (`decay_window`), in the
/// `assay-solana` repository.
///
/// It DRAINS rather than resetting: a counter anchored at `startedAt` gives capacity back
/// linearly across SLASH_WINDOW_SECONDS, rounding UP so capacity is returned late and never
/// early. The documented residual is unchanged — an adversary can spend 2x across an
/// arbitrary 24 hours, and that is accepted on both chains.
///
/// Three callers, one implementation: the buyer's spend window (`state.rs:599`), the provider's
/// slash window (`state.rs:263`), and the verifier key's daily cap (`state.rs:463`).
///
/// **What the unsigned port changes, and what it does not.** The Anchor original takes `i64`
/// timestamps (Solana's `unix_timestamp` is signed) and reaches the "clock went backwards" case
/// through `now.saturating_sub(window_started_at) <= 0`. Here every timestamp is `uint64`, so
/// there is no negative elapsed time to saturate and the same case is `nowTs <= startedAt`. The
/// mapping is exact at the extremes the Rust tests use: `i64::MIN`/`i64::MAX` as the two ends of
/// the clock become `0`/`type(uint64).max`, and each of the three saturating cases lands on the
/// same branch it lands on in Rust.
library Window {
    function decay(uint64 counter, uint64 startedAt, uint64 nowTs) internal pure returns (uint64) {
        if (counter == 0) return 0;
        // A clock that did not advance — or went backwards — returns capacity to nobody.
        if (nowTs <= startedAt) return counter;

        uint64 elapsed = nowTs - startedAt;
        if (elapsed >= Constants.SLASH_WINDOW_SECONDS) return 0;

        uint256 window = Constants.SLASH_WINDOW_SECONDS;
        uint256 remaining = window - elapsed;
        // div_ceil, in uint256 so `counter * remaining` cannot wrap.
        uint256 carried = (uint256(counter) * remaining + window - 1) / window;
        return narrow(carried);
    }

    /// The checked narrowing, identical in behaviour and error to `Fee.narrow`.
    ///
    /// **Why it is here even though it can never fire.** `remaining < window` is enforced two
    /// lines above by the `elapsed >= SLASH_WINDOW_SECONDS` branch, so `carried <= counter`, and
    /// `counter` is already a `uint64` — the bound is a local invariant of this function rather
    /// than an obligation on a caller, which is the opposite of `Fee`'s situation. A bare
    /// `uint64(carried)` would be provably safe.
    ///
    /// It is checked anyway because the rule adopted for `Fee` is that a silent `uint64(…)`
    /// narrowing of a money amount is not acceptable on the strength of a comment, and two
    /// identical operations receiving opposite treatment is how the next implementer learns the
    /// wrong default from whichever file they open first. Consistency is the default; the burden
    /// is on the exception, and "provably safe today" was not enough to earn one. The gas cost
    /// is visible in `forge test` gas per call.
    ///
    /// **That third site appeared on the redeem path and the collapse this paragraph asked for has
    /// happened**: the body is now `Cast.toUint64` and this is a one-line forwarder. The
    /// paragraphs above are unchanged and still describe why the check is here at all — they are
    /// the argument `Cast.toUint64`'s own NatSpec quotes.
    function narrow(uint256 value) private pure returns (uint64) {
        return Cast.toUint64(value);
    }
}
