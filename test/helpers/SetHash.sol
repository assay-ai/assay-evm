// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.38;

import {Vm} from "forge-std/Vm.sol";

/// The slot formula of the escrow's and `ChannelDoor`'s in-memory hash tables, so tests can build
/// real collisions instead of guessing. `test_setHashMatchesTheSources` (AssayEscrow.memo.t.sol)
/// pins the multiplier against the sources: if the contracts change it, that test fails rather
/// than every collision test silently stopping colliding.
library SetHash {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 internal constant MUL = 0x9e3779b97f4a7c15f39cc0605cedc8341082276bf3a27251;

    /// Slot of `a` in an escrow set (`_seen`, `_indexOf`) of `size` words.
    function escrowSlot(address a, uint256 size) internal pure returns (uint256) {
        unchecked {
            return (((uint256(uint160(a)) | (1 << 160)) * MUL) >> 128) & (size - 1);
        }
    }

    /// Slot of `a` under `kind` (1 = blocklist, 2 = stake) in a `ChannelDoor` cache of `size`.
    function doorSlot(address a, uint256 kind, uint256 size) internal pure returns (uint256) {
        unchecked {
            return (((uint256(uint160(a)) | (kind << 160)) * MUL) >> 128) & (size - 1);
        }
    }

    /// First private key from `start` whose address shares `target`'s escrow slot.
    function grindKey(address target, uint256 size, uint256 start)
        internal
        pure
        returns (uint256 k)
    {
        uint256 want = escrowSlot(target, size);
        for (k = start;; k++) {
            if (escrowSlot(VM.addr(k), size) == want) return k;
        }
    }

    /// First address derived from `seed` that shares `target`'s escrow slot.
    function grindAddr(address target, uint256 size, uint256 seed)
        internal
        pure
        returns (address a)
    {
        uint256 want = escrowSlot(target, size);
        for (uint256 i = seed;; i++) {
            a = address(uint160(uint256(keccak256(abi.encode(i)))));
            if (escrowSlot(a, size) == want) return a;
        }
    }

    /// First address derived from `seed` that shares `target`'s door slot under both kinds.
    function grindDoorAddr(address target, uint256 size, uint256 seed)
        internal
        pure
        returns (address a)
    {
        for (uint256 i = seed;; i++) {
            a = address(uint160(uint256(keccak256(abi.encode(i)))));
            if (doorSlot(a, 2, size) == doorSlot(target, 2, size)) return a;
        }
    }
}
