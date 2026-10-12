// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.24;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Constants} from "../Constants.sol";
import "../Errors.sol";

/// The one signature recovery in `src/`, shared by `X402Escrow` and `X402Stake`. Four guards,
/// all load-bearing, each refusal under its own name:
///
///   1. exactly 65 bytes — the 64-byte EIP-2098 compact form is refused, so every signature has
///      exactly ONE acceptable encoding (backend idempotency keys rely on it). It must come first,
///      or `calldataload` reads words that are not the signature;
///   2. low-s (EIP-2) — a malleated twin is different bytes for the same message;
///   3. `v` in {27, 28};
///   4. signer != `address(0)` — garbage must not "recover" to the zero address.
///
/// Guards 2 and 4 duplicate checks `ECDSA.tryRecover` also makes; checking first is what gives
/// each condition its own name. **That holds only while `ECDSA.tryRecover` is the call below**:
/// replace it with a bare `ecrecover` and guards 2 and 4 become the only refusal of a malleated
/// twin and of `address(0)`. The relative order of guards 2 and 3 is a preference, not an
/// invariant.
///
/// `test_recoveryHappensAtExactlyOneCallSiteInSrc` counts recovery call sites across `src/` and
/// allows exactly one, in this file.
library Sig {
    function recover(bytes32 digest, bytes calldata sig) internal pure returns (address signer) {
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

        ECDSA.RecoverError err;
        (signer, err,) = ECDSA.tryRecover(digest, v, r, s);
        if (err != ECDSA.RecoverError.NoError || signer == address(0)) revert InvalidSignature();
    }
}
