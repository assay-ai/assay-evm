// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.38;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Constants} from "../Constants.sol";
import "../Errors.sol";

/// @title Sig
/// @notice The single ECDSA signature recovery used by the protocol.
/// @dev Requires a 65-byte signature, low `s` (EIP-2), `v` in {27, 28} and a non-zero signer.
/// Compact (EIP-2098) signatures are refused so every signature has exactly one accepted
/// encoding. `tryRecover` holds the acceptance rules and the one recovery call; `recover` is the
/// same rules with a distinct error per failure, and the channel door uses `tryRecover` so one
/// malformed signature skips its item instead of reverting the batch (D-31).
library Sig {
    /// @dev Why `tryRecover` refused a signature. 0 means accepted.
    uint256 internal constant OK = 0;
    uint256 internal constant BAD_LENGTH = 1;
    uint256 internal constant HIGH_S = 2;
    uint256 internal constant BAD_V = 3;
    uint256 internal constant NO_SIGNER = 4;

    /// @dev Returns the signer of `digest`; reverts on any malformed or invalid signature.
    function recover(bytes32 digest, bytes calldata sig) internal pure returns (address signer) {
        uint256 why;
        (signer, why) = tryRecover(digest, sig);
        if (why == OK) return signer;
        if (why == HIGH_S) revert MalleableSignature();
        if (why == BAD_V) revert BadSignatureV();
        revert InvalidSignature(); // BAD_LENGTH or NO_SIGNER
    }

    /// @dev The signer of `digest` and `OK`, or `address(0)` and the first rule broken, checked
    ///      in this order: length, `s`, `v`, recovery. Never reverts.
    function tryRecover(bytes32 digest, bytes calldata sig)
        internal
        pure
        returns (address signer, uint256 why)
    {
        // The length check must come first: the calldata reads below assume 65 bytes.
        if (sig.length != 65) return (address(0), BAD_LENGTH);

        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly ("memory-safe") {
            r := calldataload(sig.offset)
            s := calldataload(add(sig.offset, 0x20))
            v := byte(0, calldataload(add(sig.offset, 0x40)))
        }
        if (uint256(s) > Constants.SECP256K1_HALF_N) return (address(0), HIGH_S);
        if (v != 27 && v != 28) return (address(0), BAD_V);

        ECDSA.RecoverError err;
        (signer, err,) = ECDSA.tryRecover(digest, v, r, s);
        if (err != ECDSA.RecoverError.NoError || signer == address(0)) {
            return (address(0), NO_SIGNER);
        }
    }
}
