// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.24;

import {MathOverflow} from "../Errors.sol";

/// The one checked narrowing to `uint64` in this codebase.
///
/// It exists because `src/libraries/Window.sol` asked for the copies to be collapsed, and because
/// the redeem path then grew a third: two bare `uint64(spent)` casts on the money path, argued at
/// the line on *exactly* the ground `Window.narrow` had already considered and rejected. That rule
/// is worth restating, because a fourth copy or a fourth
/// exception is the same mistake again:
///
/// > a silent `uint64(…)` narrowing of a money amount is not acceptable on the strength of a
/// > comment, and two identical operations receiving opposite treatment is how the next
/// > implementer learns the wrong default from whichever file they open first. Consistency is the
/// > default; the burden is on the exception, and "provably safe today" was not enough to earn one.
///
/// So there is no exception, anywhere. **Every** `uint256` (or `uint128`) that becomes a `uint64`
/// in `src/` goes through here, whether or not a guard three lines above already makes the
/// truncation unreachable, and whether or not the value is money. Some call sites can prove the
/// revert is dead code; that proof belongs in a comment at the site, not in a bare cast.
///
/// Its Anchor counterpart is `u64::try_from(x).map_err(|_| error!(ErrorCode::MathOverflow))` —
/// `execute_slash.rs:310` — which is likewise one spelling used everywhere rather than a judgement
/// made per site.
library Cast {
    function toUint64(uint256 value) internal pure returns (uint64) {
        if (value > type(uint64).max) revert MathOverflow();
        return uint64(value);
    }
}
