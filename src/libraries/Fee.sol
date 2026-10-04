// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.24;

import {Constants} from "../Constants.sol";
import {Cast} from "./Cast.sol";

/// Ported verbatim from the Anchor program (repository `assay-solana`):
/// `programs/x402-payment/src/state.rs:633` (`split_fee`) and `instructions/execute_slash.rs:305`
/// (`bps_of`).
///
/// The fee floors and the provider takes the remainder BY SUBTRACTION, so
/// `fee + providerAmount == amount` identically rather than by agreement — one division and one
/// subtraction, never two divisions. Every multiplication of a token amount by a bps goes through
/// `uint256`, exactly as the Anchor arithmetic goes through `u128`: `amount` is chosen by whoever
/// writes the 402, and `amount * 10_000` overflows a `uint64` above ~1.8e15 base units.
///
/// **Neither function may truncate on the cast back, and neither is allowed to rely on its callers
/// to ensure that.** `bps <= BPS_DENOMINATOR` is what the parameter validation at today's call
/// sites enforces (`MAX_TAKE_RATE_BPS` for the take rate, the split validation for the slash
/// shares), and within that domain the quotient is at most `amount` and fits a `uint64` trivially.
/// But an explicit `uint64(...)` cast in Solidity truncates **silently**, so a library that is
/// correct only because every caller happens to be careful puts the guard in the wrong place —
/// and the config, redeem, withdrawal and slash paths each add call sites. The narrowing is
/// therefore checked
/// here, in [`narrow`], and reverts [`MathOverflow`].
library Fee {
    /// Splits a redeemed voucher into the platform's fee and the provider's payment.
    ///
    /// ```text
    /// fee             = floor(amount * takeRateBps / 10_000)
    /// providerAmount  = amount - fee
    /// ```
    function splitFee(uint64 amount, uint16 takeRateBps)
        internal
        pure
        returns (uint64 fee, uint64 providerAmount)
    {
        fee = narrow((uint256(amount) * takeRateBps) / Constants.BPS_DENOMINATOR);
        providerAmount = amount - fee; // checked; fee <= amount because takeRateBps <= 10_000
    }

    /// `execute_slash.rs:305`. The penalty split's share function: the agents' share and the
    /// platform's share are each `bpsOf(applied, …)` and the provider keeps what is left, so the
    /// same "one division per share, remainder by subtraction" shape holds there too.
    function bpsOf(uint64 amount, uint16 bps) internal pure returns (uint64) {
        return narrow((uint256(amount) * bps) / Constants.BPS_DENOMINATOR);
    }

    /// The checked narrowing both functions share — `execute_slash.rs:310`'s
    /// `u64::try_from(scaled).map_err(|_| error!(ErrorCode::MathOverflow))`, and the single site
    /// where a bps share stops being a `uint256`.
    ///
    /// **Which half of this is parity and which half is stricter.** For [`bpsOf`] it is exact
    /// parity: the Anchor `bps_of` narrows with `u64::try_from` and yields `MathOverflow`. For
    /// [`splitFee`] it is deliberately **stricter than the reference**: `state.rs:634-635` narrows
    /// the fee with a bare `as u64`, which in Rust truncates just as silently as the Solidity cast
    /// did, and the `checked_sub` on the next line only catches the subset of truncations that
    /// happen to leave `fee > amount`. Both behaviours are identical for every `takeRateBps <=
    /// BPS_DENOMINATOR`, which is every value the validated config can hold; they differ only
    /// above it, where this port refuses and the Anchor original returns a silently wrong split.
    /// Recorded here rather than in a commit message because it is the one place these contracts
    /// knowingly do not match the program they port.
    ///
    /// **The body moved to `Cast.toUint64`** and this is now a one-line forwarder.
    /// `Window.narrow` was the second copy and `_redeem` was about to be the third; the check
    /// itself, its error and every behaviour above are unchanged, and `test/Fee.t.sol` is what
    /// proves that — it drives this path at `type(uint64).max` across the whole bps range.
    function narrow(uint256 value) private pure returns (uint64) {
        return Cast.toUint64(value);
    }
}
