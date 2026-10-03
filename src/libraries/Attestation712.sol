// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.24;

import {SlashAttestation, SLASH_ATTESTATION_TYPEHASH} from "../Types.sol";

/// Signed against X402Stake's domain — a different `verifyingContract` from X402Escrow's,
/// so an attestation can never be presented at the escrow's door and a voucher can never be
/// presented here. Two independent guards: the typehash and the domain.
///
/// Its Solana counterpart is `SlashAttestation::signed_message` (`attestation.rs`), which packs
/// the same eight fields by hand-written offset. The offsets are the thing an auditor diffs
/// against the backend's encoder there; here the EIP-712 type string in `Types.sol` is, and
/// `test/Types.t.sol` rebuilds that string from the compiled struct so the two cannot drift.
///
/// Written separately from `test/helpers/VoucherSigner.signAttestation` ON PURPOSE, for the
/// reason `VoucherSigner`'s header gives at length: if the signing side called this encoder, a
/// field dropped here would be dropped from both sides at once and every test would stay green.
library Attestation712 {
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
