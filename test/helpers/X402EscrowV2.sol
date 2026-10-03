// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.24;

import {X402Escrow} from "../../src/X402Escrow.sol";

/// A LEGAL upgrade target: one added function, one added field, and no existing slot touched.
///
/// It inherits `X402Escrow`, so every inherited variable keeps the slot it had — which is the
/// point of the stub. **Where the new field actually lands is not where it is commonly assumed
/// to.** It is easy to assume `upgradedAt` sits "inside the space the parent's `__gap` reserved";
/// it does not. The parent's `uint256[50] private __gap` starts at slot 9 and therefore occupies
/// slots 9 through 58, and a derived contract's first variable is laid out *after* every base
/// variable — so `upgradedAt` is at slot **59**, beyond the gap rather than inside it.
/// `test_theAppendedFieldLandsPastTheParentsGapNotInsideIt` measures the number rather than
/// repeating the claim.
///
/// Both shapes are storage-safe for this test, which is why the error was invisible: neither
/// overwrites a live slot. They differ in what they cost. Appending in a *derived* contract is
/// free but unbounded — nothing stops a V3 from doing it again, and the gap stops being a
/// budget. The real V2 shipped from `src/` would instead edit the parent, add the field before
/// `__gap`, and shrink `uint256[50]` to `uint256[49]` — which is the shape Step 5 proves the
/// layout gate accepts, and the shape that keeps the contract's total footprint fixed.
///
/// Constructed through the inherited constructor, so the EIP-712 name and version are
/// `("x402 Settlement", "2")` — identical to the parent's. That is the whole property
/// `test_anUpgradePreservesEveryBalanceTheDomainAndAnOutstandingVoucher` protects, and
/// `X402EscrowBadDomainV2` is what its violation looks like.
contract X402EscrowV2 is X402Escrow {
    /// The appended field. One slot, at 59.
    uint256 public upgradedAt;

    function markUpgraded() external {
        upgradedAt = block.timestamp;
    }

    function version2() external pure returns (string memory) {
        return "v2";
    }
}
