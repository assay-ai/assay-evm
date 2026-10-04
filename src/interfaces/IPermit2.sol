// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.24;

/// The `SignatureTransfer` subset of Permit2, and nothing else. Deployed on 4663 and 46630 at
/// the canonical `0x000000000022D473030F116dDEE9F6B43aC78BA3` (measured: 9,152 bytes of code —
/// see `docs/chain-facts.md`).
///
/// Only `permitTransferFrom` is declared. The `AllowanceTransfer` half of Permit2 is a standing
/// approval, which is the thing this contract deliberately does not want: every fund-in here is
/// either the caller's own `transferFrom` or a signature over one exact amount.
///
/// **`permitTransferFrom`'s spender is `msg.sender`.** Permit2 binds the caller into the digest
/// it verifies, so a signature made for one escrow cannot be replayed against another, and the
/// `owner` argument is both the account the signature is checked against and — by the rule in
/// [`X402Escrow.depositWithPermit2`] — the account credited. There is no Anchor counterpart:
/// Solana funding is a plain SPL transfer signed by whoever holds the tokens.
interface IPermit2 {
    struct TokenPermissions {
        address token;
        uint256 amount;
    }

    struct PermitTransferFrom {
        TokenPermissions permitted;
        uint256 nonce;
        uint256 deadline;
    }

    struct SignatureTransferDetails {
        address to;
        uint256 requestedAmount;
    }

    function permitTransferFrom(
        PermitTransferFrom calldata permit,
        SignatureTransferDetails calldata transferDetails,
        address owner,
        bytes calldata signature
    ) external;
}
