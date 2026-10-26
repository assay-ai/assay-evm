// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.38;

import {SlashAttestation, SLASH_ATTESTATION_TYPEHASH} from "../Types.sol";

/// @title Attestation712
/// @notice EIP-712 struct hash for `SlashAttestation`, used under AssayStake's domain.
library Attestation712 {
    /// @dev Returns the EIP-712 struct hash of `a`.
    function hashAttestation(SlashAttestation calldata a) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                SLASH_ATTESTATION_TYPEHASH,
                a.requestId,
                a.provider,
                a.beneficiary,
                a.status,
                a.penalty,
                a.policy,
                a.issuedAt,
                a.expiresAt
            )
        );
    }
}
