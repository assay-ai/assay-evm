// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

contract ToolchainTest is Test {
    /// secp256k1n/2 — the low-s ceiling (EIP-2). Voucher signature recovery relies on this exact
    /// value.
    uint256 internal constant HALF_N =
        0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0;
    uint256 internal constant N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    function test_vendoredEcdsaRecoversAndRejectsMalleation() public pure {
        uint256 pk = 0xA11CE;
        address signer = vm.addr(pk);
        bytes32 digest = keccak256("x402 toolchain vector");

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        assertLe(uint256(s), HALF_N, "vm.sign must already produce low-s");

        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(digest, v, r, s);
        assertEq(recovered, signer);
        assertEq(uint256(err), uint256(ECDSA.RecoverError.NoError));

        // The malleated twin: same message, different 65 bytes.
        bytes32 sHigh = bytes32(N - uint256(s));
        uint8 vFlip = v == 27 ? 28 : 27;
        (address bad, ECDSA.RecoverError err2,) = ECDSA.tryRecover(digest, vFlip, r, sHigh);
        assertEq(bad, address(0), "a high-s twin must not recover");
        assertEq(uint256(err2), uint256(ECDSA.RecoverError.InvalidSignatureS));
    }
}
