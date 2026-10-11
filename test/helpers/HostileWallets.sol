// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// EIP-1271 wallets that answer honestly while the platform checks them off chain, and turn
/// hostile once served: one burns every unit of gas it is given, one returns a mountain of data.
/// Both still "answer" the magic value. Ported from the delegation review's proofs.
abstract contract HostileWallet {
    bool public hostile;

    function setHostile(bool h) external {
        hostile = h;
    }

    function call(address target, bytes calldata data) external returns (bytes memory) {
        (bool ok, bytes memory ret) = target.call(data);
        require(ok, "call failed");
        return ret;
    }

    function approveToken(IERC20 t, address s, uint256 a) external {
        t.approve(s, a);
    }
}

contract GasBurnWallet is HostileWallet {
    bool public fail;

    function setFail(bool f) external {
        fail = f;
    }

    function isValidSignature(bytes32, bytes calldata) external view returns (bytes4) {
        if (hostile) {
            // `fail`: burn everything, so the call runs out of gas; otherwise stop just short and
            // answer.
            while (fail || gasleft() > 2_000) {}
        }
        return 0x1626ba7e;
    }
}

contract ReturnBombWallet is HostileWallet {
    /// Returns the magic word followed by as much data as the gas it was given can pay for, so
    /// whoever called it has to pay about as much again to copy it all.
    function isValidSignature(bytes32, bytes calldata) external view returns (bytes4) {
        if (hostile) {
            // Memory for n words costs 3n + n^2/512; spend most of what is left on it, keeping enough to
            // return successfully — the bomb is the RETURN DATA, not a failure.
            uint256 words = _sqrt((gasleft() * 6 / 10) * 512);
            uint256 size = words * 32;
            assembly ("memory-safe") {
                mstore(0, 0x1626ba7e00000000000000000000000000000000000000000000000000000000)
                return(0, size)
            }
        }
        return 0x1626ba7e;
    }

    function _sqrt(uint256 x) private pure returns (uint256 y) {
        y = x;
        uint256 z = (x + 1) / 2;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }
}
