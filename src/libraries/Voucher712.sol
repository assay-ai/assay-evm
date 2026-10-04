// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.24;

import {
    Voucher, VOUCHER_TYPEHASH, SET_LIMITS_TYPEHASH, REQUEST_WITHDRAW_TYPEHASH
} from "../Types.sol";

/// EIP-712 struct hashing. Each function uses a DISTINCT typehash, which is what closes
/// cross-kind replay — a signature collected for `SetLimits` cannot be presented at
/// `redeemVoucher`'s door. That guard lives inside the hashed preimage, which is strictly
/// stronger than the Solana design's "the message lengths differ" length check
/// (`attestation.rs:126` — `const _: () = assert!(ATTESTATION_MESSAGE_LEN !=
/// VOUCHER_MESSAGE_LEN)`; two lengths can be made to collide by a future field, two typehashes
/// cannot).
///
/// # What each of these is a port of
///
/// [`hashVoucher`] is `Voucher::signed_message` (`attestation.rs:422-437`), which writes 239
/// bytes at hand-chosen literal offsets. Everything that hand-written encoder has to say out
/// loud, EIP-712 says structurally instead:
///
///   - its `b"x402:voucher:v2"` domain tag at offset 0 and `crate::ID` at 15 become the domain
///     separator's `name`/`version` and `verifyingContract`, which the caller mixes in with
///     `_hashTypedDataV4` — so they are not this library's business and are not in these
///     preimages;
///   - its fixed-width little-endian field packing becomes one 32-byte word per field;
///   - its `VOUCHER_MESSAGE_LEN != ATTESTATION_MESSAGE_LEN` assertion becomes the typehash.
///
/// One field of the Anchor struct has no counterpart here: `pay_to` (`attestation.rs:345`).
/// It is dropped because on EVM one contract holds every buyer, so "which escrow" is fully
/// determined by `verifyingContract` + `payer` and a `payTo` field would be a second source for
/// one identity. `Types.sol`'s header carries that decision; `Errors.sol` records that
/// `EscrowMismatch` (`redeem_voucher.rs:130-133`) goes with it.
///
/// [`hashSetLimits`] and [`hashRequestWithdraw`] port no encoder at all, because on Solana the
/// buyer signs the *instruction* (`open_escrow.rs:96`'s `buyer.is_signer`) and there is nothing
/// to type. Here the consent travels as a message somebody else submits, so it needs a type —
/// with a `nonce` and a `deadline`, which an instruction signature did not need.
///
/// # Why `abi.encode` and never `abi.encodePacked`
///
/// EIP-712 `encodeData` is the concatenation of each member's 32-byte encoding, which is
/// exactly `abi.encode` for this struct: eight value-typed members, each padded to a word.
/// `abi.encodePacked` would concatenate `uint64`s at their natural width, so `(amount, seq)` and
/// a differently-split pair of the same bytes would hash alike — the ambiguity EIP-712's fixed
/// 32-byte member encoding exists to remove. There is no dynamic member here (`bytes32` is a
/// value type), so no member needs pre-hashing.
library Voucher712 {
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

    function hashRequestWithdraw(address buyer, uint64 amount, uint64 nonce, uint64 deadline)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(REQUEST_WITHDRAW_TYPEHASH, buyer, amount, nonce, deadline));
    }
}
