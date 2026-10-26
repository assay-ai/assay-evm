// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.38;

import {MathOverflow} from "../Errors.sol";

/// @title Cast
/// @notice Checked narrowing to `uint64`. Every narrowing to `uint64` in the protocol uses it.
library Cast {
    /// @dev Returns `value` as `uint64`; reverts `MathOverflow` if it does not fit.
    function toUint64(uint256 value) internal pure returns (uint64) {
        if (value > type(uint64).max) revert MathOverflow();
        return uint64(value);
    }
}
