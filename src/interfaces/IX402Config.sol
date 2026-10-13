// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.24;

import {ParamSet} from "../Types.sol";

/// The read surface X402Escrow and X402Stake consume. Both edges are views; neither
/// contract can write here, which is the whole point of the split (D-1, D-3).
///
/// On Solana the same split is spelled by account permissions: `redeem_voucher` and the two
/// slash phases take `Config` **without** `mut`, so the runtime refuses a write. Here the
/// interface is the only handle the other two contracts hold, so a write is not expressible.
interface IX402Config {
    /// The whole economic parameter set, read as one value. Callers that need two fields must
    /// not be able to read them from two different blocks of state — the split's shares are only
    /// meaningful together, and `state.rs::Config::validate` is written the same way.
    function params() external view returns (ParamSet memory);

    /// `Config::slash_provider_bps()` — `state.rs:127-131`. The provider's own share of a
    /// penalty, `10_000 - agent - platform`, **derived and never stored** so it cannot disagree
    /// with the two shares it is the complement of. It lives here rather than at X402Stake's use
    /// site for the same reason: one derivation, on the contract that owns the parameters. That
    /// the provider keeps a share of every penalty is a deliberate economic property of this
    /// system (the provider keeps the remainder of every penalty), not an accounting remainder.
    function slashProviderBps() external view returns (uint16);

    /// `Config.paused` — `state.rs:85`. Closes the doors that move money on somebody else's
    /// say-so and never a door that returns money to its owner (`set_paused.rs:13-22`).
    function paused() external view returns (bool);

    /// `Config.admin` — `state.rs:23`. The operational key. NOT the upgrade authority since D-17.
    function admin() external view returns (address);

    /// The upgrade authority for all three contracts (D-17), because the other two read this
    /// live rather than storing their own copy. Two-step transferable, never renounceable.
    function owner() external view returns (address);

    /// `VerifierKey::assert_can_sign` as a predicate — `state.rs:248`.
    function canSign(address verifier) external view returns (bool);

    /// `VerifierKey::assert_can_sign` — `state.rs:248`. Reverts `VerifierRevoked` or
    /// `VerifierKeyExpired` rather than returning false, so a caller cannot ignore it.
    function assertCanSign(address verifier) external view;

    /// The dispute arbiter (EVM only): rules on `X402Stake.upholdSlash` and may `cancelSlash`.
    /// A person's wallet or a Safe, never the backend. `address(0)` means none.
    function arbiter() external view returns (address);

    /// The delay `X402Stake.proposeSlash` freezes into a new record's `executableAt`, and so the
    /// provider's dispute window. `Constants.SLASH_DELAY_SECONDS` until the admin sets it.
    function slashDelaySeconds() external view returns (uint64);

    /// Whether the blocklist names `account`.
    function blocked(address account) external view returns (bool);

    /// Reverts `ProgramPaused` while paused, then `AddressBlocked` if any of the three is blocked.
    /// One call per guarded door; pass `address(0)` for an unused slot.
    function assertActive(address a, address b, address c) external view;
}
