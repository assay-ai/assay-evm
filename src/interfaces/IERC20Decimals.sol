// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.38;

/// One function, so `AssayEscrow.initialize` can assert the settlement asset really is a
/// six-decimal token without vendoring the whole of `IERC20Metadata`.
///
/// It is the EVM half of `initialize_config.rs`, which refuses a Token-2022 mint on
/// Solana. That refusal is not about the token *program*; it is about what a non-plain token
/// does to `vault balance == sum of the ledger`. On EVM the two halves of the same worry are
/// this decimals pin and the measured-delta transfer in [`AssayEscrow._pullExact`].
interface IERC20Decimals {
    function decimals() external view returns (uint8);
}
