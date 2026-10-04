// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.24;

import {Fixture} from "../helpers/Fixture.sol";
import {X402Escrow} from "../../src/X402Escrow.sol";

/// `depositWithPermit2` against the CANONICAL singleton at
/// 0x000000000022D473030F116dDEE9F6B43aC78BA3 — 9,152 bytes, identical on 4663 and 46630 — with
/// a signature built against Permit2's OWN domain separator read from the deployment, and its
/// OWN `PermitTransferFrom` / `TokenPermissions` typehashes.
///
/// # Why this file exists
///
/// Every Permit2 test in the suite runs against `test/helpers/MockPermit2.sol`, whose own header
/// says it enforces signer-is-owner and spender-is-escrow **and not** Permit2's EIP-712 domain,
/// typehash, deadline handling or nonce bitmap. So those tests prove the escrow's half and none
/// of Permit2's. This file is the other half.
///
/// **The signature is constructed from the chain's domain, never from a constant in this file.**
/// A test that derives its expectation from the same expression the code uses asserts that `===`
/// works. Here the independent source is Permit2 itself.
///
/// **Every refusal names Permit2's own error selector.** A bare `vm.expectRevert()` is satisfied
/// by ANY revert — including the escrow refusing first for an unrelated reason — which is the
/// recurring defect this project keeps finding. The three selectors below were produced by
/// `cast sig` and are pinned as literals so a change in Permit2's ABI is a red test rather than a
/// silently weaker one.
contract Permit2ForkTest is Fixture {
    // cast keccak "TokenPermissions(address token,uint256 amount)"
    bytes32 internal constant TOKEN_PERMISSIONS_TYPEHASH =
        0x618358ac3db8dc274f0cd8829da7e234bd48cd73c4a740aede1adec9846d06a1;
    // cast keccak "PermitTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,
    //              uint256 deadline)TokenPermissions(address token,uint256 amount)"
    bytes32 internal constant PERMIT_TRANSFER_FROM_TYPEHASH =
        0x939c21a48a8dbe3a9a2404a1d46691e4d39f6583d6ec6b35714604c986d80106;

    // Permit2's own errors. `cast sig "InvalidNonce()"` etc.
    bytes4 internal constant INVALID_NONCE = 0x756688fe;
    bytes4 internal constant SIGNATURE_EXPIRED = 0xcd21db4f;
    bytes4 internal constant INVALID_SIGNER = 0x815e1d64;

    address internal constant CANONICAL_PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    /// Measured on 46630 on 2026-09-09 and again on 2026-09-10. Asserted equal to the value read
    /// FROM the deployment below, which is what makes the literal a check rather than a premise.
    bytes32 internal constant PERMIT2_DOMAIN_SEPARATOR_46630 =
        0x385ef69ffea4b42e91eff23e95ef22db58d3ad382de54eedf9bf9ff2ed24173f;

    X402Escrow internal p2escrow;

    function setUp() public override {
        forkMode = true;
        super.setUp();
        // See `Blocklist.fork.t.sol` — reading the fixture's own state back is the skip check.
        if (address(config) == address(0)) return;

        p2escrow = _deployEscrow(address(usdg), CANONICAL_PERMIT2);
        _fund(buyer, 50_000_000);
        vm.prank(buyer);
        usdg.approve(CANONICAL_PERMIT2, type(uint256).max); // the one-time approve (D-11)
    }

    /// The control that proves the harness reached the real Permit2 and not a stub.
    function test_theSingletonIsRealAndItsDomainIsTheOneWeSignAgainst() public view {
        assertEq(CANONICAL_PERMIT2.code.length, 9152, "not the canonical Permit2");
        assertEq(_domain(), PERMIT2_DOMAIN_SEPARATOR_46630, "domain separator moved");
    }

    function test_aRealPermit2SignatureFundsTheEscrow() public {
        uint256 nonce = 0;
        uint256 deadline = block.timestamp + 600;
        bytes memory sig = _signPermit(buyerKey, 10_000_000, nonce, deadline, address(p2escrow));

        uint256 before = p2escrow.escrowOf(buyer).balance;
        vm.prank(buyer);
        p2escrow.depositWithPermit2(buyer, 10_000_000, nonce, deadline, sig);

        assertEq(p2escrow.escrowOf(buyer).balance, before + 10_000_000);
    }

    /// Permit2's nonce is a BITMAP, not a counter — `MockPermit2` models it as a `mapping` of
    /// bools, which happens to give the same answer for nonce 0 and would not for a nonce whose
    /// word is shared. This is the assertion the double could never make.
    function test_theSameNonceCannotBeSpentTwice() public {
        uint256 deadline = block.timestamp + 600;
        bytes memory sig = _signPermit(buyerKey, 5_000_000, 7, deadline, address(p2escrow));
        vm.prank(buyer);
        p2escrow.depositWithPermit2(buyer, 5_000_000, 7, deadline, sig);
        vm.prank(buyer);
        vm.expectRevert(INVALID_NONCE);
        p2escrow.depositWithPermit2(buyer, 5_000_000, 7, deadline, sig);
    }

    /// Nonce 263 shares Permit2's word 1 with nonce 264. Spending 263 must NOT spend 264 — the
    /// bitmap flips one bit, and a `mapping(uint256 => bool)` double cannot tell the two models
    /// apart from a single-nonce test.
    function test_aNonceSharingAWordWithASpentOneIsStillSpendable() public {
        uint256 deadline = block.timestamp + 600;
        bytes memory a = _signPermit(buyerKey, 1_000_000, 263, deadline, address(p2escrow));
        bytes memory b = _signPermit(buyerKey, 1_000_000, 264, deadline, address(p2escrow));
        vm.prank(buyer);
        p2escrow.depositWithPermit2(buyer, 1_000_000, 263, deadline, a);
        vm.prank(buyer);
        p2escrow.depositWithPermit2(buyer, 1_000_000, 264, deadline, b);
        assertEq(p2escrow.escrowOf(buyer).balance, 2_000_000);
    }

    function test_aSignatureOverTheWrongSpenderIsRefusedByPermit2Itself() public {
        uint256 deadline = block.timestamp + 600;
        // Signed for a DIFFERENT spender — the escrow is msg.sender to Permit2, so this must fail.
        bytes memory sig = _signPermit(buyerKey, 5_000_000, 9, deadline, address(0xBEEF));
        vm.prank(buyer);
        vm.expectRevert(INVALID_SIGNER);
        p2escrow.depositWithPermit2(buyer, 5_000_000, 9, deadline, sig);
    }

    function test_anExpiredDeadlineIsRefusedByPermit2Itself() public {
        uint256 deadline = block.timestamp - 1;
        bytes memory sig = _signPermit(buyerKey, 5_000_000, 11, deadline, address(p2escrow));
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(SIGNATURE_EXPIRED, deadline));
        p2escrow.depositWithPermit2(buyer, 5_000_000, 11, deadline, sig);
    }

    /// A signature by anyone but the buyer. `MockPermit2` enforces signer-is-owner too, so this
    /// is the one refusal both can make — kept because it is the positive control for
    /// `INVALID_SIGNER` above: without it, a wrong typehash would produce `InvalidSigner` for
    /// every test in this file and the spender test would pass for the wrong reason.
    function test_aSignatureByTheWrongKeyIsRefusedByPermit2Itself() public {
        uint256 deadline = block.timestamp + 600;
        bytes memory sig = _signPermit(0xBADBAD, 5_000_000, 13, deadline, address(p2escrow));
        vm.prank(buyer);
        vm.expectRevert(INVALID_SIGNER);
        p2escrow.depositWithPermit2(buyer, 5_000_000, 13, deadline, sig);
    }

    function _domain() internal view returns (bytes32) {
        (bool ok, bytes memory ds) =
            CANONICAL_PERMIT2.staticcall(abi.encodeWithSignature("DOMAIN_SEPARATOR()"));
        require(ok, "DOMAIN_SEPARATOR() failed");
        return abi.decode(ds, (bytes32));
    }

    /// Reads the domain FROM the deployment, so this helper stays correct if Permit2 is ever
    /// redeployed under a different chain id.
    function _signPermit(
        uint256 pk,
        uint256 amount,
        uint256 nonce,
        uint256 deadline,
        address spender
    ) internal view returns (bytes memory) {
        bytes32 permitted = keccak256(abi.encode(TOKEN_PERMISSIONS_TYPEHASH, address(usdg), amount));
        bytes32 structHash = keccak256(
            abi.encode(PERMIT_TRANSFER_FROM_TYPEHASH, permitted, spender, nonce, deadline)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domain(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }
}
