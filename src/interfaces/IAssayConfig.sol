// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.38;

import {ParamSet} from "../Types.sol";

/// @title IAssayConfig
/// @notice Read-only view of AssayConfig consumed by AssayEscrow and AssayStake.
/// @dev Neither consumer can write configuration; every member here is a view.
interface IAssayConfig {
    /// @notice Returns the full economic parameter set as one value.
    /// @return The current parameters.
    function params() external view returns (ParamSet memory);

    /// @notice Whether the protocol is paused. A pause closes user entry points but moves no funds.
    /// @return True while paused.
    function paused() external view returns (bool);

    /// @notice Returns the operational admin. It is not the upgrade authority.
    /// @return The admin address.
    function admin() external view returns (address);

    /// @notice Returns the upgrade authority for all three contracts (two-step, not renounceable).
    /// @return The owner address.
    function owner() external view returns (address);

    /// @notice Whether `verifier` is registered, unrevoked and unexpired.
    /// @param verifier The verifier key address.
    /// @return True if the key may sign attestations.
    function canSign(address verifier) external view returns (bool);

    /// @notice Reverts unless `verifier` may sign attestations.
    /// @dev Reverts `VerifierNotRegistered`, `VerifierRevoked` or `VerifierKeyExpired`.
    /// @param verifier The verifier key address.
    function assertCanSign(address verifier) external view;

    /// @notice Returns the dispute arbiter, or `address(0)` before the first appointment.
    /// @return The arbiter address.
    function arbiter() external view returns (address);

    /// @notice Returns the slash delay frozen into each new record's `executableAt`.
    /// @return The delay in seconds.
    function slashDelaySeconds() external view returns (uint64);

    /// @notice Returns the minimum settable slash delay on this chain.
    /// @return The floor in seconds.
    function minSlashDelaySeconds() external view returns (uint64);

    /// @notice Returns the hold frozen into each new held payment's `collectableAt`.
    /// @return The hold in seconds.
    function collectHoldSeconds() external view returns (uint64);

    /// @notice Whether `account` is on the blocklist.
    /// @param account The address to check.
    /// @return True if blocked.
    function blocked(address account) external view returns (bool);

    /// @notice Reverts `ProgramPaused` while paused, then `AddressBlocked` if any party is blocked.
    /// @param a First party to check, or `address(0)` if unused.
    /// @param b Second party to check, or `address(0)` if unused.
    /// @param c Third party to check, or `address(0)` if unused.
    function assertActive(address a, address b, address c) external view;
}
