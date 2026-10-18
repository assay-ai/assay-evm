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

    /// `Config.paused` — `state.rs`. Since D-19 it closes every user door, the owner exits
    /// included (a deliberate reversal of `set_paused.rs`), and leaves open only what
    /// releases a hold or removes authority. It never moves money.
    function paused() external view returns (bool);

    /// `Config.admin` — `state.rs`. The operational key. NOT the upgrade authority (D-17).
    function admin() external view returns (address);

    /// The upgrade authority for all three contracts (D-17), because the other two read this
    /// live rather than storing their own copy. Two-step transferable, never renounceable.
    function owner() external view returns (address);

    /// `VerifierKey::assert_can_sign` as a predicate — `state.rs`.
    function canSign(address verifier) external view returns (bool);

    /// `VerifierKey::assert_can_sign` — `state.rs`. Reverts `VerifierNotRegistered`,
    /// `VerifierRevoked` or `VerifierKeyExpired` rather than returning false, so a caller cannot
    /// ignore it.
    function assertCanSign(address verifier) external view;

    /// The dispute arbiter (EVM only): rules on `X402Stake.upholdSlash` and may `cancelSlash`.
    /// A person's wallet or a Safe, never the backend. Reads `address(0)` only before the first
    /// `setArbiter`; after that it can be replaced but never unset.
    function arbiter() external view returns (address);

    /// The delay `X402Stake.proposeSlash` freezes into a new record's `executableAt`, and so the
    /// provider's dispute window. `Constants.SLASH_DELAY_SECONDS` until the admin sets it.
    function slashDelaySeconds() external view returns (uint64);

    /// How long `X402Escrow` holds a new redemption before the redeemer may collect it, frozen
    /// into each record's `collectableAt`. `Constants.DEFAULT_COLLECT_HOLD_SECONDS` until set.
    function collectHoldSeconds() external view returns (uint64);

    /// Whether the blocklist names `account`.
    function blocked(address account) external view returns (bool);

    /// Reverts `ProgramPaused` while paused, then `AddressBlocked` if any of the three is blocked.
    /// One call per guarded door; pass `address(0)` for an unused slot.
    function assertActive(address a, address b, address c) external view;
}
