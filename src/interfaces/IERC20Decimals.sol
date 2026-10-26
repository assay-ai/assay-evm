// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.38;

/// @title IERC20Decimals
/// @notice Minimal interface used to check that the settlement asset has 6 decimals.
interface IERC20Decimals {
    /// @notice Returns the token's decimals.
    /// @return The number of decimals.
    function decimals() external view returns (uint8);
}
