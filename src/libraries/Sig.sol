// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.24;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Constants} from "../Constants.sol";
import "../Errors.sol";

/// One recovery implementation for both contracts. Four guards, all load-bearing:
/// exactly 65 bytes (the 64-byte EIP-2098 compact form is refused, so there is exactly ONE
/// acceptable encoding), low-s per EIP-2, v in {27,28}, and signer != address(0).
///
/// The body moved here from `X402Escrow._recover`, as its natspec had proposed:
/// `X402Stake` needs the same four guards over a `SlashAttestation` digest and cannot call an
/// `internal` function on another contract. `X402Escrow._recover` is now a one-line forwarder,
/// so no call site there changed and every recovery in `src/` still passes through these lines.
///
/// The full argument for each guard, for the ordering of guards 2 and 3 being a preference
/// rather than an invariant, and for the two duplications of checks `ECDSA.tryRecover` also
/// makes, lives at `X402Escrow._recover`'s declaration and is not repeated here — it is one
/// argument about one implementation, and two copies of it would drift.
///
/// `test_recoveryHappensAtExactlyOneCallSiteInSrc` follows the body: this file is now the one
/// `src/` file allowed to contain a recovery call site, and the count is still exactly one.
library Sig {
    /// Why a signature did not recover, in guard order. `None` means it did.
    enum Refusal {
        None,
        Length,
        Malleable,
        V,
        Invalid
    }

    /// The strict form: every refusal reverts with its own name. This is the one every EOA
    /// path uses, and its behaviour is unchanged by the delegation work.
    function recover(bytes32 digest, bytes calldata sig) internal pure returns (address) {
        (address signer, Refusal why) = check(digest, sig);
        if (why == Refusal.Length) revert InvalidSignature();
        if (why == Refusal.Malleable) revert MalleableSignature();
        if (why == Refusal.V) revert BadSignatureV();
        if (why == Refusal.Invalid) revert InvalidSignature();
        return signer;
    }

    /// The lenient form: `address(0)` on any refusal, never a revert. It exists for exactly one
    /// caller — `X402Escrow`'s voucher check when the PAYER HAS CODE. Such a payer may answer
    /// through EIP-1271 with a signature that is not a 65-byte ECDSA one at all (a Safe's
    /// `v = 0` contract signature, a passkey blob), so a malformed ECDSA encoding must fall
    /// through to the wallet instead of ending the check. The four guards are the same guards:
    /// a signature this returns an address for is one [`recover`] returns the same address for.
    function tryRecover(bytes32 digest, bytes calldata sig) internal pure returns (address) {
        (address signer, Refusal why) = check(digest, sig);
        return why == Refusal.None ? signer : address(0);
    }

    /// The four guards and the one recovery call site, shared by both forms above so they
    /// cannot disagree about what a valid signature is.
    function check(bytes32 digest, bytes calldata sig) private pure returns (address, Refusal) {
        if (sig.length != 65) return (address(0), Refusal.Length);

        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly ("memory-safe") {
            r := calldataload(sig.offset)
            s := calldataload(add(sig.offset, 0x20))
            v := byte(0, calldataload(add(sig.offset, 0x40)))
        }
        if (uint256(s) > Constants.SECP256K1_HALF_N) return (address(0), Refusal.Malleable);
        if (v != 27 && v != 28) return (address(0), Refusal.V);

        (address signer, ECDSA.RecoverError err,) = ECDSA.tryRecover(digest, v, r, s);
        if (err != ECDSA.RecoverError.NoError || signer == address(0)) {
            return (address(0), Refusal.Invalid);
        }
        return (signer, Refusal.None);
    }
}
