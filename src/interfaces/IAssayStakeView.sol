// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.38;

/// @title IAssayStakeView
/// @notice The single read edge from AssayEscrow into AssayStake.
interface IAssayStakeView {
    /// @notice Returns the provider's bonded stake not reserved by pending slashes.
    /// @param provider The provider address.
    /// @return `bonded - pendingSlash`, floored at zero, in base units.
    function freeBondedOf(address provider) external view returns (uint64);
}
