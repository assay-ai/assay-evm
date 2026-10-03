// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {
    Voucher,
    SlashAttestation,
    VOUCHER_TYPEHASH,
    SLASH_ATTESTATION_TYPEHASH,
    SET_LIMITS_TYPEHASH,
    REQUEST_WITHDRAW_TYPEHASH
} from "../../src/Types.sol";

/// `sig.length != 65` in [`VoucherSigner.malleate`]. A named error rather than
/// `require(cond, "…")`: this repo has **no revert strings anywhere, tests included**, and a
/// helper that quietly kept one would be the exception that makes the rule unenforceable by
/// grep.
error SignatureIsNotSixtyFiveBytes();

/// The signing side of the EIP-712 domain, written **independently of `Voucher712`** and kept
/// that way on purpose.
///
/// The whole value of `test_happyPath_recoversThePayer` is that two separately written encoders
/// agree. If this library called `Voucher712.hashVoucher`, a field dropped from that encoder
/// would be dropped from both sides at once and every test would stay green — which is precisely
/// the mutation `test/MUTATION-LOG.md` runs eight times. So the duplication below is the test,
/// not a smell, and it must not be refactored away.
///
/// It stands in for the *backend*, which is where the real second encoder lives:
/// `ChainAdapter.buildVoucherMessage` on the Solana side, and its EIP-712 counterpart on this
/// one. `attestation.rs:433` says the same thing about its own hand-written offsets — "these
/// offsets are what an auditor diffs against `ChainAdapter.buildVoucherMessage`".
library VoucherSigner {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// The secp256k1 group order. `s` and `N - s` recover to the same address, which is the
    /// malleability [`malleate`] exhibits and `X402Escrow._recover` refuses. Also the exclusive
    /// upper bound on a private key, so fuzz tests bound into `[1, N - 1]` before `vm.addr`.
    uint256 internal constant N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    function digest(bytes32 domainSeparator, bytes32 structHash) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }

    function voucherStructHash(Voucher memory v) internal pure returns (bytes32) {
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

    function signVoucher(uint256 pk, bytes32 domainSeparator, Voucher memory v)
        internal
        pure
        returns (bytes memory)
    {
        (uint8 vv, bytes32 r, bytes32 s) =
            vm.sign(pk, digest(domainSeparator, voucherStructHash(v)));
        return abi.encodePacked(r, s, vv);
    }

    function signSetLimits(
        uint256 pk,
        bytes32 domainSeparator,
        address buyer,
        uint64 maxVoucherAmount,
        uint64 maxPerWindow,
        uint64 nonce,
        uint64 deadline
    ) internal pure returns (bytes memory) {
        bytes32 sh = keccak256(
            abi.encode(SET_LIMITS_TYPEHASH, buyer, maxVoucherAmount, maxPerWindow, nonce, deadline)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest(domainSeparator, sh));
        return abi.encodePacked(r, s, v);
    }

    function signRequestWithdraw(
        uint256 pk,
        bytes32 domainSeparator,
        address buyer,
        uint64 amount,
        uint64 nonce,
        uint64 deadline
    ) internal pure returns (bytes memory) {
        bytes32 sh =
            keccak256(abi.encode(REQUEST_WITHDRAW_TYPEHASH, buyer, amount, nonce, deadline));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest(domainSeparator, sh));
        return abi.encodePacked(r, s, v);
    }

    /// The verifier's judgement, signed against X402Stake's domain.
    ///
    /// Written independently of `src/libraries/Attestation712.sol` for the reason this file's
    /// header gives: if this called that encoder, a field dropped there would be dropped from
    /// both sides at once and every test would stay green. The eight `abi.encode` arguments
    /// below and the eight in `Attestation712.hashAttestation` are two spellings of one type
    /// string, and `test/Types.t.sol` pins the string itself against the compiled struct.
    function signAttestation(uint256 pk, bytes32 domainSeparator, SlashAttestation memory a)
        internal
        pure
        returns (bytes memory)
    {
        bytes32 sh = keccak256(
            abi.encode(
                SLASH_ATTESTATION_TYPEHASH,
                a.requestId,
                a.provider,
                a.beneficiary,
                a.status,
                a.penalty,
                a.policy,
                a.issuedAt,
                a.expiresAt
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest(domainSeparator, sh));
        return abi.encodePacked(r, s, v);
    }

    /// Recover the address whose key produced `sig` over `v` under `domainSeparator`.
    ///
    /// `Upgrade.t.sol` needs this: the negative upgrade test asks whether a voucher signed under
    /// the OLD domain still recovers to the buyer under the NEW one, and at that point in the test
    /// the proxy no longer carries `recoverVoucherSigner` — the implementation behind it has been
    /// replaced by one that has no such function. Asking the contract is not an option, so the
    /// question is asked here.
    ///
    /// It uses OZ's `ECDSA.recover` rather than a bare `ecrecover`, so `script/check-ecrecover.sh`
    /// keeps meaning what it says: `ecrecover` is spelled in exactly one place in this repo.
    /// Malleability is not checked — the caller here supplies a signature it made itself, and the
    /// EIP-2 refusal is `Sig.recover`'s job and is proved against the contract, not here.
    function recoverVoucher(bytes32 domainSeparator, Voucher memory v, bytes memory sig)
        internal
        pure
        returns (address)
    {
        return ECDSA.recover(digest(domainSeparator, voucherStructHash(v)), sig);
    }

    /// The malleated twin: `(r, N - s, v flipped)` verifies the same message and recovers to the
    /// same address, so it is a SECOND valid 65-byte encoding of one authorisation. Anybody who
    /// can see a signature can produce it — no key required — which is why "the signature bytes"
    /// is not an idempotency key.
    function malleate(bytes memory sig) internal pure returns (bytes memory) {
        if (sig.length != 65) revert SignatureIsNotSixtyFiveBytes();
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly ("memory-safe") {
            r := mload(add(sig, 0x20))
            s := mload(add(sig, 0x40))
            v := byte(0, mload(add(sig, 0x60)))
        }
        return abi.encodePacked(r, bytes32(N - uint256(s)), v == 27 ? uint8(28) : uint8(27));
    }
}
