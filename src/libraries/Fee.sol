// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.38;

import {Constants} from "../Constants.sol";
import {Cast} from "./Cast.sol";

/// @title Fee
/// @notice Basis-point arithmetic for the platform fee and slash shares.
/// @dev Products are computed in `uint256` and narrowed with a check (`MathOverflow`). Shares round
/// down; the remainder is taken by subtraction so the parts always sum to the whole.
library Fee {
    /// @dev Returns `fee = floor(amount * takeRateBps / 10_000)` and
    /// `providerAmount = amount - fee`.
    function splitFee(uint64 amount, uint16 takeRateBps)
        internal
        pure
        returns (uint64 fee, uint64 providerAmount)
    {
        fee = Cast.toUint64((uint256(amount) * takeRateBps) / Constants.BPS_DENOMINATOR);
        providerAmount = amount - fee; // checked; fee <= amount because takeRateBps <= 10_000
    }

    /// @dev Returns `floor(amount * bps / 10_000)`.
    function bpsOf(uint64 amount, uint16 bps) internal pure returns (uint64) {
        return Cast.toUint64((uint256(amount) * bps) / Constants.BPS_DENOMINATOR);
    }
}
