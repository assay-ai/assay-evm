// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.24;

import {Voucher, SlashAttestation, SetLimits, RequestWithdraw, ParamSet} from "../src/Types.sol";

/// Probes that exist so the compiler will describe the EIP-712 structs back to us.
///
/// Solidity has no reflection, so a test cannot ask `struct Voucher` for its fields. It can ask
/// solc: a function taking the struct emits an ABI entry whose `inputs[0].components` is the
/// field list, in declaration order, with each field's name and canonical ABI type, and whose
/// `inputs[0].internalType` is the struct's name. `Types.t.sol` reads that back out of the build
/// artifact and rebuilds the EIP-712 type string from it.
///
/// **One probe contract per struct, one external function per probe, deliberately.** With
/// exactly one entry the artifact path `.abi[0].inputs[0]` is fixed, so the gate cannot silently
/// start reading a different function's parameters after an unrelated edit.
///
/// These are test-only. Nothing deploys them.
contract VoucherAbiProbe {
    function probe(Voucher calldata v) external pure returns (uint256) {
        return v.amount;
    }
}

contract SlashAttestationAbiProbe {
    function probe(SlashAttestation calldata a) external pure returns (uint256) {
        return a.penalty;
    }
}

contract SetLimitsAbiProbe {
    function probe(SetLimits calldata s) external pure returns (uint256) {
        return s.nonce;
    }
}

contract RequestWithdrawAbiProbe {
    function probe(RequestWithdraw calldata r) external pure returns (uint256) {
        return r.nonce;
    }
}

/// `ParamSet` is the odd one out: it is not an EIP-712 struct and no signature binds it. It has a
/// probe because it is `X402Config._params`, a **storage** struct behind a UUPS
/// proxy, so its declaration decides a storage layout that a later implementation has to agree
/// with byte for byte.
///
/// The positional `abi.encode` assertion that first covered it saw order and **not width**:
/// `abi.encode` pads every field to a 32-byte word, so widening `uint64 minimumStake` to
/// `uint128` encodes identically while moving `_params` from 3 slots to 4 and `__gap` from slot 4
/// to slot 5 — measured, 56 of 56 tests green. The compiled ABI carries the width, so this probe
/// is how the gate gets to see it.
contract ParamSetAbiProbe {
    function probe(ParamSet calldata p) external pure returns (uint256) {
        return p.minimumStake;
    }
}
