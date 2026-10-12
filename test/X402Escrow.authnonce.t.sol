// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.24;

import {Fixture} from "./helpers/Fixture.sol";
import {VoucherSigner} from "./helpers/VoucherSigner.sol";
import {Constants} from "../src/Constants.sol";
import "../src/Errors.sol";

/// D-18: **every payer decision consumes `authNonce`**, direct or relayed, so a relayed
/// signature the relayer WITHHELD can never land after a later decision and undo it; and a
/// relayed authorisation lives at most `MAX_SIGNATURE_LIFETIME_SECONDS`.
contract X402EscrowAuthNonceTest is Fixture {
    address internal relayer = address(0x7E1A);
    address internal delegate = address(0xDE1E);
    bytes32 internal ds;

    function setUp() public override {
        super.setUp();
        ds = escrow.DOMAIN_SEPARATOR();
        vm.prank(buyer);
        escrow.setLimits(5_000_000, 20_000_000);
    }

    function _n() internal view returns (uint64) {
        return escrow.escrowOf(buyer).authNonce;
    }

    function _deadline() internal view returns (uint64) {
        return uint64(block.timestamp) + 300;
    }

    // --- the four direct doors each consume one nonce ----------------------------------------

    function test_everyDirectDecisionConsumesTheNonce() public {
        uint64 n0 = _n();
        vm.startPrank(buyer);
        escrow.setLimits(1, 2);
        assertEq(_n(), n0 + 1, "setLimits");
        escrow.requestWithdraw(1);
        assertEq(_n(), n0 + 2, "requestWithdraw");
        escrow.setLimits(5_000_000, 20_000_000);
        escrow.authorizeDelegate(delegate, 1, 1, uint64(block.timestamp + 1 days));
        assertEq(_n(), n0 + 4, "authorizeDelegate");
        escrow.revokeDelegate(delegate);
        assertEq(_n(), n0 + 5, "revokeDelegate");
        vm.stopPrank();
    }

    // --- a withheld signature dies at the next direct decision -------------------------------

    /// The emergency case: the buyer lowers its limits DIRECTLY to zero; a `SetLimitsBySig(high)`
    /// the relayer held back can no longer land and re-arm the escrow.
    function test_aWithheldSetLimitsCannotUndoADirectEmergencyLowering() public {
        uint64 n = _n();
        uint64 d = _deadline();
        bytes memory held =
            VoucherSigner.signSetLimits(buyerKey, ds, buyer, 9_000_000, 90_000_000, n, d);

        vm.prank(buyer);
        escrow.setLimits(0, 0);

        vm.prank(relayer);
        vm.expectRevert(BadNonce.selector);
        escrow.setLimitsBySig(buyer, 9_000_000, 90_000_000, n, d, held);
        assertEq(escrow.escrowOf(buyer).maxVoucherAmount, 0, "the lowering stands");
        assertEq(escrow.escrowOf(buyer).maxPerWindow, 0);
    }

    /// A withheld `RequestWithdrawBySig` can neither cancel nor restart a direct request.
    function test_aWithheldRequestWithdrawCannotCancelOrRestartADirectOne() public {
        uint64 n = _n();
        uint64 d = _deadline();
        bytes memory cancel = VoucherSigner.signRequestWithdraw(buyerKey, ds, buyer, 0, n, d);

        vm.prank(buyer);
        escrow.requestWithdraw(1_000_000);
        uint64 availableAt = escrow.escrowOf(buyer).withdrawAvailableAt;

        vm.warp(block.timestamp + 100);
        vm.prank(relayer);
        vm.expectRevert(BadNonce.selector);
        escrow.requestWithdrawBySig(buyer, 0, n, d, cancel);
        assertEq(escrow.escrowOf(buyer).withdrawRequested, 1_000_000, "not cancelled");
        assertEq(escrow.escrowOf(buyer).withdrawAvailableAt, availableAt, "not restarted");
    }

    /// And the delegation pair, which already consumed the nonce before D-18: a withheld
    /// `AuthorizeDelegateBySig` cannot land after a direct `setLimits`.
    function test_aWithheldDelegateGrantDiesAtADirectLimitChange() public {
        uint64 n = _n();
        uint64 d = _deadline();
        uint64 until = uint64(block.timestamp + 1 days);
        bytes memory held = VoucherSigner.signAuthorizeDelegate(
            buyerKey, ds, buyer, delegate, 1_000, 1_000, until, n, d
        );
        vm.prank(buyer);
        escrow.setLimits(4_000_000, 20_000_000);

        vm.prank(relayer);
        vm.expectRevert(BadNonce.selector);
        escrow.authorizeDelegateBySig(buyer, delegate, 1_000, 1_000, until, n, d, held);
        assertEq(escrow.delegationOf(buyer, delegate).validUntil, 0);
    }

    // --- the signature lifetime cap, on all four relayed doors --------------------------------

    function test_boundary_aRelayedSignatureMayLiveExactlyTheCapAndNoLonger() public {
        uint64 cap = Constants.MAX_SIGNATURE_LIFETIME_SECONDS;
        assertEq(cap, 3600);
        uint64 now_ = uint64(block.timestamp);
        uint64 until = now_ + 1 days;

        // +1 over the cap: refused at every door, before the nonce or the signature is read.
        uint64 far = now_ + cap + 1;
        uint64 n = _n();
        vm.startPrank(relayer);
        vm.expectRevert(SignatureDeadlineTooFar.selector);
        escrow.setLimitsBySig(
            buyer, 1, 2, n, far, VoucherSigner.signSetLimits(buyerKey, ds, buyer, 1, 2, n, far)
        );
        vm.expectRevert(SignatureDeadlineTooFar.selector);
        escrow.requestWithdrawBySig(
            buyer, 1, n, far, VoucherSigner.signRequestWithdraw(buyerKey, ds, buyer, 1, n, far)
        );
        vm.expectRevert(SignatureDeadlineTooFar.selector);
        escrow.authorizeDelegateBySig(
            buyer,
            delegate,
            1,
            1,
            until,
            n,
            far,
            VoucherSigner.signAuthorizeDelegate(buyerKey, ds, buyer, delegate, 1, 1, until, n, far)
        );
        vm.expectRevert(SignatureDeadlineTooFar.selector);
        escrow.revokeDelegateBySig(
            buyer,
            delegate,
            n,
            far,
            VoucherSigner.signRevokeDelegate(buyerKey, ds, buyer, delegate, n, far)
        );
        vm.stopPrank();
        assertEq(_n(), n, "nothing consumed");

        // Exactly the cap: admitted.
        uint64 edge = now_ + cap;
        bytes memory sig = VoucherSigner.signSetLimits(buyerKey, ds, buyer, 1, 2, n, edge);
        vm.prank(relayer);
        escrow.setLimitsBySig(buyer, 1, 2, n, edge, sig);
        assertEq(escrow.escrowOf(buyer).maxVoucherAmount, 1);
    }

    /// Fuzzed: a relayed decision lands iff `now <= deadline <= now + cap`.
    function testFuzz_theDeadlineWindow(uint64 deadline) public {
        uint64 now_ = uint64(block.timestamp);
        uint64 n = _n();
        bytes memory sig = VoucherSigner.signRequestWithdraw(buyerKey, ds, buyer, 7, n, deadline);
        vm.prank(relayer);
        if (deadline < now_) {
            vm.expectRevert(SignatureExpired.selector);
            escrow.requestWithdrawBySig(buyer, 7, n, deadline, sig);
        } else if (uint256(deadline) > uint256(now_) + Constants.MAX_SIGNATURE_LIFETIME_SECONDS) {
            vm.expectRevert(SignatureDeadlineTooFar.selector);
            escrow.requestWithdrawBySig(buyer, 7, n, deadline, sig);
        } else {
            escrow.requestWithdrawBySig(buyer, 7, n, deadline, sig);
            assertEq(escrow.escrowOf(buyer).withdrawRequested, 7);
        }
    }
}
