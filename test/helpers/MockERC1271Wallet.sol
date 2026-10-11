// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.24;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// A minimal EIP-1271 smart wallet for the escrow's contract-payer path. It answers
/// `isValidSignature` with the magic value when the signature is an ECDSA signature by its
/// `owner`, OR when the digest was pre-approved (the Safe "approved hash" shape, which carries a
/// signature that is not ECDSA at all). `mode` lets a test make it lie or misbehave.
contract MockERC1271Wallet {
    enum Mode {
        Honest,
        AlwaysValid,
        WrongMagic,
        Reverts,
        ShortReturn
    }

    address public owner;
    Mode public mode;
    mapping(bytes32 => bool) public approved;

    constructor(address owner_) {
        owner = owner_;
    }

    function setMode(Mode m) external {
        mode = m;
    }

    function approveHash(bytes32 h) external {
        approved[h] = true;
    }

    function isValidSignature(bytes32 hash, bytes calldata sig) external view returns (bytes4) {
        if (mode == Mode.Reverts) revert("nope");
        if (mode == Mode.ShortReturn) {
            assembly ("memory-safe") {
                mstore(0, 0x1626ba7e00000000000000000000000000000000000000000000000000000000)
                return(0, 4)
            }
        }
        if (mode == Mode.WrongMagic) return 0xdeadbeef;
        if (mode == Mode.AlwaysValid) return 0x1626ba7e;
        if (approved[hash]) return 0x1626ba7e;
        (address signer, ECDSA.RecoverError err,) = ECDSA.tryRecover(hash, sig);
        if (err == ECDSA.RecoverError.NoError && signer == owner) return 0x1626ba7e;
        return 0xffffffff;
    }

    /// The wallet acts on the escrow as any contract account would: by calling it.
    function call(address target, bytes calldata data) external returns (bytes memory) {
        (bool ok, bytes memory ret) = target.call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        return ret;
    }

    function approveToken(IERC20 token, address spender, uint256 amount) external {
        token.approve(spender, amount);
    }
}
