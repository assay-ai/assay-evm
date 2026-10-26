// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.38;

import {Constants} from "../Constants.sol";
import {Cast} from "./Cast.sol";

/// @title Window
/// @notice Rolling 24-hour counter that drains linearly over `SLASH_WINDOW_SECONDS`.
/// @dev Remaining usage rounds up, so capacity is returned late, never early. Up to twice the
/// limit can be consumed within any 24-hour span.
library Window {
    /// @dev Returns what remains of `counter`, started at `startedAt`, at time `nowTs`.
    function decay(uint64 counter, uint64 startedAt, uint64 nowTs) internal pure returns (uint64) {
        if (counter == 0) return 0;
        // No time elapsed (or the clock went backwards): nothing has drained.
        if (nowTs <= startedAt) return counter;

        uint64 elapsed = nowTs - startedAt;
        if (elapsed >= Constants.SLASH_WINDOW_SECONDS) return 0;

        uint256 window = Constants.SLASH_WINDOW_SECONDS;
        uint256 remaining = window - elapsed;
        // Ceiling division in uint256, so `counter * remaining` cannot overflow.
        uint256 carried = (uint256(counter) * remaining + window - 1) / window;
        // `carried <= counter`, so this cannot revert; narrowed with a check regardless.
        return Cast.toUint64(carried);
    }
}
