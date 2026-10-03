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
    function recover(bytes32 digest, bytes calldata sig) internal pure returns (address) {
        if (sig.length != 65) revert InvalidSignature();

        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly ("memory-safe") {
            r := calldataload(sig.offset)
            s := calldataload(add(sig.offset, 0x20))
            v := byte(0, calldataload(add(sig.offset, 0x40)))
        }
        if (uint256(s) > Constants.SECP256K1_HALF_N) revert MalleableSignature();
        if (v != 27 && v != 28) revert BadSignatureV();

        (address signer, ECDSA.RecoverError err,) = ECDSA.tryRecover(digest, v, r, s);
        if (err != ECDSA.RecoverError.NoError || signer == address(0)) revert InvalidSignature();
        return signer;
    }
}
