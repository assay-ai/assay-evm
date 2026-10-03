// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.24;

import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {X402Escrow} from "../../src/X402Escrow.sol";

/// The **quiet** version of `X402EscrowBadDomainV2`, and the one that catches a lazy test.
///
/// `X402EscrowBadDomainV2` is loud: its `DOMAIN_SEPARATOR()` returns a different value, so any
/// test that compares that one getter across the upgrade sees it. This contract does not touch
/// `DOMAIN_SEPARATOR()` at all — it is `external` and non-`virtual` on the parent, so it keeps
/// returning the old, correct value and every "the separator did not move" assertion stays
/// green. What it changes is `_hashTypedDataV4`, which is `internal view virtual` on OZ's
/// `EIP712` and is what `redeemVoucher`, `setLimitsBySig` and `requestWithdrawBySig` actually
/// build their digests from.
///
/// So the exported domain and the enforced domain disagree, and the only symptom is that every
/// signature made before the upgrade recovers to the wrong address. **A test that checks
/// `DOMAIN_SEPARATOR()` and stops is fooled by this.** That is why
/// `test_anUpgradePreservesEveryBalanceTheDomainAndAnOutstandingVoucher` ends by redeeming a
/// voucher that was signed before the upgrade, and it is the degenerate that assertion answers.
///
/// The layout is the parent's, unchanged — nothing is appended — so it is a legal upgrade in
/// every respect the storage gate can see. Nothing on chain refuses it either.
contract X402EscrowSilentDomainV2 is X402Escrow {
    bytes32 private constant TYPE_HASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );

    function _hashTypedDataV4(bytes32 structHash) internal view override returns (bytes32) {
        bytes32 wrongSeparator = keccak256(
            abi.encode(
                TYPE_HASH,
                keccak256("x402 Settlement"),
                keccak256("3"), // the only difference, and it is invisible from outside
                block.chainid,
                address(this)
            )
        );
        return MessageHashUtils.toTypedDataHash(wrongSeparator, structHash);
    }
}
