// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.38;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Constants} from "../Constants.sol";
import "../Errors.sol";

/// @title Sig
/// @notice The single ECDSA signature recovery used by the protocol.
/// @dev Requires a 65-byte signature, low `s` (EIP-2), `v` in {27, 28} and a non-zero signer,
/// each with its own error. Compact (EIP-2098) signatures are refused so every signature has
/// exactly one accepted encoding.
library Sig {
    /// @dev Returns the signer of `digest`; reverts on any malformed or invalid signature.
    function recover(bytes32 digest, bytes calldata sig) internal pure returns (address signer) {
        // The length check must come first: the calldata reads below assume 65 bytes.
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
