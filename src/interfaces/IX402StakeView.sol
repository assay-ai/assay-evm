// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.24;

/// The ONE edge from X402Escrow into X402Stake, and it is a view returning a number.
///
/// It exists so `redeemVoucher` can port `redeem_voucher.rs`'s `ProviderBelowMinimumStake` guard
/// (`instructions/redeem_voucher.rs:148-153`) instead of moving that guarantee into the backend,
/// which the threat model assumes compromised. X402Stake holds no reference back (D-2), so
/// the dependency is a single acyclic edge and the two contracts can be deployed in either order
/// as long as the escrow is initialised last.
///
/// `uint64` rather than `uint128` because a bonded amount is an *amount argument* — the same
/// `MONEY_MAX_ATOMIC_UNITS` width `ProviderStake.bonded` has on Solana (`state.rs:375`) — not a
/// cumulative counter.
interface IX402StakeView {
    function bondedOf(address provider) external view returns (uint64);
}
