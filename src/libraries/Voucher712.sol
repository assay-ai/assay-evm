// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.38;

import {
    Voucher,
    VOUCHER_TYPEHASH,
    SET_LIMITS_TYPEHASH,
    REQUEST_WITHDRAW_TYPEHASH,
    AUTHORIZE_DELEGATE_TYPEHASH,
    REVOKE_DELEGATE_TYPEHASH
} from "../Types.sol";

/// @title Voucher712
/// @notice EIP-712 struct hashes for vouchers and the buyer and payer authorisations.
/// @dev Each kind has a distinct typehash, which prevents cross-kind signature replay. The domain
/// separator is applied by the caller.
library Voucher712 {
    /// @dev Returns the EIP-712 struct hash of `v`.
    function hashVoucher(Voucher calldata v) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                VOUCHER_TYPEHASH,
                v.payer,
                v.provider,
                v.amount,
                v.resourceHash,
                v.requestHash,
                v.seq,
                v.issuedAt,
                v.expiresAt
            )
        );
    }

    /// @dev Returns the EIP-712 struct hash of a `SetLimits` message.
    function hashSetLimits(
        address buyer,
        uint64 maxVoucherAmount,
        uint64 maxPerWindow,
        uint64 nonce,
        uint64 deadline
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(SET_LIMITS_TYPEHASH, buyer, maxVoucherAmount, maxPerWindow, nonce, deadline)
        );
    }

    /// @dev Returns the EIP-712 struct hash of a `RequestWithdraw` message.
    function hashRequestWithdraw(address buyer, uint64 amount, uint64 nonce, uint64 deadline)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(REQUEST_WITHDRAW_TYPEHASH, buyer, amount, nonce, deadline));
    }

    /// @dev Returns the EIP-712 struct hash of an `AuthorizeDelegate` message.
    function hashAuthorizeDelegate(
        address payer,
        address delegate,
        uint64 maxVoucherAmount,
        uint64 maxPerWindow,
        uint64 validUntil,
        uint64 nonce,
        uint64 deadline
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                AUTHORIZE_DELEGATE_TYPEHASH,
                payer,
                delegate,
                maxVoucherAmount,
                maxPerWindow,
                validUntil,
                nonce,
                deadline
            )
        );
    }

    /// @dev Returns the EIP-712 struct hash of a `RevokeDelegate` message.
    function hashRevokeDelegate(address payer, address delegate, uint64 nonce, uint64 deadline)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(REVOKE_DELEGATE_TYPEHASH, payer, delegate, nonce, deadline));
    }
}
