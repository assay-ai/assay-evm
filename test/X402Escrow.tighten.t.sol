// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.24;

import {Fixture} from "./helpers/Fixture.sol";
import {VoucherSigner} from "./helpers/VoucherSigner.sol";
import {X402Escrow} from "../src/X402Escrow.sol";
import {Voucher} from "../src/Types.sol";
import {Constants} from "../src/Constants.sol";
import "../src/Errors.sol";

/// "Signed means collectable": a payer's TIGHTENING — revoking a delegate, shortening its
/// horizon, lowering the delegate's caps or the escrow's — binds a voucher that is already valid
/// only after `TIGHTEN_DELAY_SECONDS` (3,600 s, longer than any voucher lives). Raising a cap
/// applies at once. Together with the exit delay this means no payer call can make an admitted
/// voucher unredeemable before its deadline, nor take out the money it needs.
contract X402EscrowTightenTest is Fixture {
    uint256 internal constant DELEGATE_KEY = 0xDE1E6A7E;
    address internal delegate;
    bytes32 internal ds;

    uint64 internal constant DELAY = Constants.TIGHTEN_DELAY_SECONDS;
    uint64 internal constant ESCROW_PER_CALL = 1_000_000;
    uint64 internal constant ESCROW_PER_WINDOW = 5_000_000;
    uint64 internal constant D_PER_CALL = 400_000;
    uint64 internal constant D_PER_WINDOW = 1_000_000;
    uint64 internal constant DEPOSIT = 10_000_000;

    function setUp() public virtual override {
        super.setUp();
        ds = escrow.DOMAIN_SEPARATOR();
        delegate = vm.addr(DELEGATE_KEY);
        _fund(buyer, DEPOSIT);
        vm.startPrank(buyer);
        usdg.approve(address(escrow), DEPOSIT);
        escrow.deposit(DEPOSIT);
        escrow.setLimits(ESCROW_PER_CALL, ESCROW_PER_WINDOW);
        escrow.authorizeDelegate(delegate, D_PER_CALL, D_PER_WINDOW, _now() + 30 days);
        vm.stopPrank();
    }

    // --- helpers ---------------------------------------------------------------------------

    /// The cheatcode, not `block.timestamp`: under `via_ir` the optimiser may reuse a
    /// `TIMESTAMP` read across a `vm.warp` inside one test function.
    function _now() internal view returns (uint64) {
        return uint64(vm.getBlockTimestamp());
    }

    function _v(uint64 amount, uint64 seq) internal view returns (Voucher memory) {
        return Voucher({
            payer: buyer,
            provider: provider,
            amount: amount,
            resourceHash: keccak256("resource"),
            requestHash: keccak256(abi.encode("request", seq)),
            seq: seq,
            issuedAt: _now(),
            expiresAt: _now() + Constants.VOUCHER_MAX_LIFETIME_SECONDS
        });
    }

    /// The voucher's last redeemable instant.
    function _deadline(Voucher memory v) internal pure returns (uint64) {
        return v.expiresAt + Constants.REDEEM_GRACE_SECONDS;
    }

    function _byDelegate(Voucher memory v) internal view returns (bytes memory) {
        return VoucherSigner.signVoucher(DELEGATE_KEY, ds, v);
    }

    function _byPayer(Voucher memory v) internal view returns (bytes memory) {
        return VoucherSigner.signVoucher(buyerKey, ds, v);
    }

    function _redeem(Voucher memory v, bytes memory sig) internal {
        vm.prank(redeemer);
        escrow.redeemVoucher(v, sig);
    }

    function _expect(Voucher memory v, bytes memory sig, bytes4 err) internal {
        vm.prank(redeemer);
        vm.expectRevert(err);
        escrow.redeemVoucher(v, sig);
    }

    function _caps() internal view returns (uint64 capV, uint64 capW, uint64 dCapV, uint64 dCapW) {
        return escrow.effectiveCapsOf(buyer, delegate);
    }

    // --- revoking ----------------------------------------------------------------------------

    /// A voucher signed before the revocation redeems at its deadline; past the delay a revoked
    /// delegate's voucher is refused under the revocation's own name.
    function test_revoke_aVoucherSignedBeforeTheRevocationRedeemsUntilItsDeadline() public {
        Voucher memory v = _v(D_PER_CALL, 1);
        bytes memory sig = _byDelegate(v);
        uint64 t = _now();
        vm.prank(buyer);
        escrow.revokeDelegate(delegate);

        vm.warp(_deadline(v));
        _redeem(v, sig);
        assertEq(escrow.escrowOf(buyer).balance, DEPOSIT - D_PER_CALL);

        // The grant is still in force through `t + DELAY` (the backend admits nothing new).
        vm.warp(t + DELAY);
        Voucher memory edge = _v(1_000, 2);
        _redeem(edge, _byDelegate(edge));
        vm.warp(t + DELAY + 1);
        Voucher memory late = _v(1_000, 3);
        _expect(late, _byDelegate(late), DelegateIsRevoked.selector);
    }

    /// The revocation never extends a grant: one that lapses sooner than the grace keeps its own
    /// instant, and is then refused as revoked.
    function test_revoke_neverExtendsAShorterHorizon() public {
        vm.prank(buyer);
        escrow.authorizeDelegate(delegate, D_PER_CALL, D_PER_WINDOW, _now() + DELAY);
        uint64 until = _now() + DELAY;
        vm.warp(_now() + 600);
        vm.prank(buyer);
        escrow.revokeDelegate(delegate);
        assertEq(escrow.delegationOf(buyer, delegate).validUntil, until, "validUntil moved");

        vm.warp(until + 1);
        Voucher memory v = _v(1_000, 1);
        _expect(v, _byDelegate(v), DelegateIsRevoked.selector);
    }

    /// Revoke, re-grant, revoke again: each revocation clamps from its own instant, and a voucher
    /// signed under either grant stays collectable.
    function test_revoke_revokeRegrantRevoke() public {
        Voucher memory a = _v(100_000, 1);
        bytes memory sigA = _byDelegate(a);
        vm.prank(buyer);
        escrow.revokeDelegate(delegate);

        vm.warp(_now() + 1_000);
        vm.prank(buyer);
        escrow.authorizeDelegate(delegate, D_PER_CALL, D_PER_WINDOW, _now() + 30 days);
        X402Escrow.Delegation memory d = escrow.delegationOf(buyer, delegate);
        assertFalse(d.revoked);
        assertEq(d.listPosition, 1);
        Voucher memory b = _v(100_000, 2);
        bytes memory sigB = _byDelegate(b);

        vm.warp(_now() + 500);
        uint64 t2 = _now();
        vm.prank(buyer);
        escrow.revokeDelegate(delegate);

        _redeem(a, sigA);
        _redeem(b, sigB);
        assertEq(escrow.escrowOf(buyer).balance, DEPOSIT - 200_000);

        vm.warp(t2 + DELAY + 1);
        Voucher memory c = _v(1_000, 3);
        _expect(c, _byDelegate(c), DelegateIsRevoked.selector);
    }

    /// The relayed revocation shares `_revokeDelegate`, so it clamps the same way.
    function test_revoke_theRelayedRevocationAlsoWaitsOutTheDelay() public {
        Voucher memory v = _v(D_PER_CALL, 1);
        bytes memory sig = _byDelegate(v);
        uint64 n = escrow.escrowOf(buyer).authNonce;
        bytes memory rsig =
            VoucherSigner.signRevokeDelegate(buyerKey, ds, buyer, delegate, n, _now() + 300);
        escrow.revokeDelegateBySig(buyer, delegate, n, _now() + 300, rsig);
        assertTrue(escrow.delegationOf(buyer, delegate).revoked);
        vm.warp(_deadline(v));
        _redeem(v, sig);
        vm.warp(_now() + DELAY);
        (,, uint64 dCapV, uint64 dCapW) = _caps();
        assertEq(dCapV, 0, "a grant past its grace reports no caps");
        assertEq(dCapW, 0);
    }

    // --- shortening -------------------------------------------------------------------------

    /// A re-grant may shorten the horizon to exactly `now + DELAY` and not one second less.
    function test_shorten_theHorizonMayShrinkToTheDelayAndNoFurther() public {
        Voucher memory v = _v(D_PER_CALL, 1);
        bytes memory sig = _byDelegate(v);
        vm.startPrank(buyer);
        vm.expectRevert(DelegateValidUntilInvalid.selector);
        escrow.authorizeDelegate(delegate, D_PER_CALL, D_PER_WINDOW, _now() + DELAY - 1);
        vm.expectRevert(DelegateValidUntilInvalid.selector);
        escrow.authorizeDelegate(delegate, D_PER_CALL, D_PER_WINDOW, _now() + 1);
        escrow.authorizeDelegate(delegate, D_PER_CALL, D_PER_WINDOW, _now() + DELAY);
        vm.stopPrank();

        vm.warp(_deadline(v));
        _redeem(v, sig);
    }

    // --- lowering the delegate's caps -------------------------------------------------------

    function test_delegateCaps_aLoweredPerCallCapBindsOnlyAfterTheDelay() public {
        Voucher memory v = _v(D_PER_CALL, 1);
        bytes memory sig = _byDelegate(v);
        uint64 t = _now();
        vm.prank(buyer);
        escrow.authorizeDelegate(delegate, 1, 1, _now() + 30 days);
        (,, uint64 dCapV, uint64 dCapW) = _caps();
        assertEq(dCapV, D_PER_CALL, "held per-call cap");
        assertEq(dCapW, D_PER_WINDOW, "held window cap");

        vm.warp(_deadline(v));
        _redeem(v, sig);

        vm.warp(t + DELAY + 1);
        (,, dCapV, dCapW) = _caps();
        assertEq(dCapV, 1);
        assertEq(dCapW, 1);
        Voucher memory late = _v(2, 2);
        _expect(late, _byDelegate(late), DelegateVoucherExceedsPerCallLimit.selector);
    }

    function test_delegateCaps_aLoweredWindowCapBindsOnlyAfterTheDelay() public {
        // Three vouchers that fill the delegate's window, signed before the lowering.
        Voucher[] memory vs = new Voucher[](3);
        bytes[] memory sigs = new bytes[](3);
        uint64[3] memory amounts = [uint64(400_000), 400_000, 200_000];
        for (uint256 i = 0; i < 3; i++) {
            vs[i] = _v(amounts[i], uint64(i + 1));
            sigs[i] = _byDelegate(vs[i]);
        }
        uint64 t = _now();
        vm.prank(buyer);
        escrow.authorizeDelegate(delegate, 100_000, 100_000, _now() + 30 days);

        // The batch path applies the same effective caps.
        vm.warp(t + 1_000);
        vm.prank(redeemer);
        escrow.redeemVoucherBatch(vs, sigs);
        assertEq(escrow.delegationOf(buyer, delegate).spentInWindow, D_PER_WINDOW);

        vm.warp(t + DELAY + 1);
        Voucher memory late = _v(100_000, 4);
        _expect(late, _byDelegate(late), DelegateWindowLimitExceeded.selector);
    }

    /// Revoking during a hold keeps the larger held caps for the grace; re-granting a grant whose
    /// grace has ended, with lower caps, holds nothing.
    function test_delegateCaps_aLongRevokedGrantHoldsNothingOnReGrant() public {
        vm.startPrank(buyer);
        escrow.revokeDelegate(delegate);
        vm.warp(_now() + DELAY + 1);
        escrow.authorizeDelegate(delegate, 1, 1, _now() + 30 days);
        vm.stopPrank();
        (,, uint64 dCapV, uint64 dCapW) = _caps();
        assertEq(dCapV, 1);
        assertEq(dCapW, 1);
    }

    /// Lowering a lapsed grant's caps holds nothing: it had no voucher left to protect.
    function test_delegateCaps_reGrantingALapsedGrantHoldsNoOldCaps() public {
        vm.prank(buyer);
        escrow.authorizeDelegate(delegate, D_PER_CALL, D_PER_WINDOW, _now() + DELAY);
        vm.warp(_now() + DELAY + 1);
        vm.prank(buyer);
        escrow.authorizeDelegate(delegate, 1, 1, _now() + 30 days);
        (,, uint64 dCapV, uint64 dCapW) = _caps();
        assertEq(dCapV, 1);
        assertEq(dCapW, 1);
    }

    // --- lowering the escrow's caps ---------------------------------------------------------

    /// `setLimits(1, 1)` — the cheapest way to strand every in-flight voucher before this change —
    /// strands nothing: payer-signed and delegate-signed vouchers both redeem.
    function test_escrowCaps_setLimitsOneOneStrandsNothing() public {
        Voucher memory a = _v(ESCROW_PER_CALL, 1);
        bytes memory sigA = _byPayer(a);
        Voucher memory b = _v(D_PER_CALL, 2);
        bytes memory sigB = _byDelegate(b);
        uint64 t = _now();
        vm.prank(buyer);
        escrow.setLimits(1, 1);
        (uint64 capV, uint64 capW,,) = _caps();
        assertEq(capV, ESCROW_PER_CALL);
        assertEq(capW, ESCROW_PER_WINDOW);
        assertEq(escrow.escrowOf(buyer).maxVoucherAmount, 1, "the stored limit is the new one");

        vm.warp(_deadline(a));
        _redeem(a, sigA);
        _redeem(b, sigB);

        vm.warp(t + DELAY + 1);
        Voucher memory late = _v(2, 3);
        _expect(late, _byPayer(late), VoucherExceedsPerCallLimit.selector);
        Voucher memory late2 = _v(1, 4);
        _expect(late2, _byPayer(late2), EscrowWindowLimitExceeded.selector);
    }

    /// The relayed `setLimitsBySig` shares `_setLimits`, so it holds the old caps too.
    function test_escrowCaps_theRelayedLoweringAlsoWaitsOutTheDelay() public {
        Voucher memory v = _v(ESCROW_PER_CALL, 1);
        bytes memory sig = _byPayer(v);
        uint64 n = escrow.escrowOf(buyer).authNonce;
        bytes memory lsig = VoucherSigner.signSetLimits(buyerKey, ds, buyer, 1, 1, n, _now() + 300);
        escrow.setLimitsBySig(buyer, 1, 1, n, _now() + 300, lsig);
        vm.warp(_deadline(v));
        _redeem(v, sig);
    }

    /// Raising applies at once and does not cut a running hold short; lowering again re-holds
    /// what was in force at that moment.
    function test_escrowCaps_raisingAppliesAtOnceAndKeepsTheHold() public {
        vm.prank(buyer);
        escrow.setLimits(100, 100);
        uint64 t = _now();

        vm.warp(t + 100);
        vm.prank(buyer);
        escrow.setLimits(2 * ESCROW_PER_CALL, 100); // raise per-call, keep the window
        (uint64 capV, uint64 capW,,) = _caps();
        assertEq(capV, 2 * ESCROW_PER_CALL, "a raise applies at once");
        assertEq(capW, ESCROW_PER_WINDOW, "the hold on the window still runs");

        vm.warp(t + DELAY);
        (, capW,,) = _caps();
        assertEq(capW, ESCROW_PER_WINDOW, "the hold runs to its own end");
        vm.warp(t + DELAY + 1);
        (capV, capW,,) = _caps();
        assertEq(capV, 2 * ESCROW_PER_CALL);
        assertEq(capW, 100);
    }

    /// A lowering while a hold runs re-holds the larger caps for a full delay from now, so a
    /// voucher valid at this instant still gets its delay.
    function test_escrowCaps_aSecondLoweringRestartsTheHoldFromItsOwnInstant() public {
        vm.prank(buyer);
        escrow.setLimits(500_000, 500_000);
        vm.warp(_now() + 2_000);
        Voucher memory v = _v(ESCROW_PER_CALL, 1); // valid now, under the held caps
        bytes memory sig = _byPayer(v);
        uint64 t2 = _now();
        vm.prank(buyer);
        escrow.setLimits(1, 1);

        vm.warp(_deadline(v)); // past the first hold, inside the second
        assertGt(_now(), t2 - 2_000 + DELAY);
        _redeem(v, sig);
    }

    /// Lowering one cap and raising the other: each field is the larger of current and held.
    function test_escrowCaps_eachFieldIsHeldOnItsOwn() public {
        vm.prank(buyer);
        escrow.setLimits(1, 2 * ESCROW_PER_WINDOW);
        (uint64 capV, uint64 capW,,) = _caps();
        assertEq(capV, ESCROW_PER_CALL);
        assertEq(capW, 2 * ESCROW_PER_WINDOW);
    }

    // --- withdrawal: the money the vouchers need stays in until they are redeemed -----------

    /// Business finding 7 / review H1, end to end. The payer revokes, lowers both limits and asks
    /// for everything back in one block, right after its agent was served. Every voucher redeems,
    /// the withdrawal cannot mature before their deadline, and it pays out only what is left.
    function test_h1_revokeLowerAndWithdrawCannotWalkAwayFromSignedVouchers() public {
        Voucher[] memory vs = new Voucher[](2);
        bytes[] memory sigs = new bytes[](2);
        vs[0] = _v(D_PER_CALL, 1);
        sigs[0] = _byDelegate(vs[0]);
        vs[1] = _v(ESCROW_PER_CALL, 2);
        sigs[1] = _byPayer(vs[1]);
        uint64 t = _now();

        vm.startPrank(buyer);
        escrow.revokeDelegate(delegate);
        escrow.setLimits(1, 1);
        escrow.requestWithdraw(DEPOSIT);
        vm.stopPrank();
        assertGt(escrow.escrowOf(buyer).withdrawAvailableAt, _deadline(vs[1]));

        vm.warp(_deadline(vs[1]));
        vm.prank(buyer);
        vm.expectRevert(WithdrawNotYetAvailable.selector);
        escrow.withdraw();
        vm.prank(redeemer);
        escrow.redeemVoucherBatch(vs, sigs);

        vm.warp(t + Constants.WITHDRAW_DELAY_SECONDS);
        vm.prank(buyer);
        escrow.withdraw();
        assertEq(usdg.balanceOf(buyer), DEPOSIT - D_PER_CALL - ESCROW_PER_CALL);
        assertEq(escrow.escrowOf(buyer).balance, 0);
    }

    // --- fuzz: whatever the payer does, a valid voucher stays redeemable --------------------

    /// A voucher valid at `t` (payer- or delegate-signed, within every cap) stays redeemable at
    /// any instant up to its deadline, whatever sequence of revocations, re-grants, limit
    /// changes and withdrawal requests the payer lands in between. Every voucher deadline is
    /// within 2,220 s of `t`, inside the 3,600 s each tightening waits.
    function testFuzz_noPayerSequenceStrandsAValidVoucher(
        uint256 ops,
        uint64 amount,
        bool delegateSigns,
        uint64 redeemAt
    ) public {
        amount = uint64(bound(amount, 1, delegateSigns ? D_PER_CALL : ESCROW_PER_CALL));
        Voucher memory v = _v(amount, 1);
        bytes memory sig = delegateSigns ? _byDelegate(v) : _byPayer(v);
        uint64 deadline = _deadline(v);
        redeemAt = uint64(bound(redeemAt, _now(), deadline));

        for (uint256 i = 0; i < 6; i++) {
            uint256 op = uint256(keccak256(abi.encode(ops, i)));
            // Each op lands at some instant in [t, redeemAt], in order.
            uint64 at = _now() + uint64((op >> 8) % (uint256(redeemAt - _now()) + 1) / 2);
            vm.warp(at);
            vm.startPrank(buyer);
            uint256 kind = op % 4;
            uint64 x = uint64(op >> 64) % (2 * ESCROW_PER_WINDOW);
            uint64 y = uint64(op >> 128) % (2 * ESCROW_PER_WINDOW);
            if (kind == 0) {
                try escrow.revokeDelegate(delegate) {} catch {}
            } else if (kind == 1) {
                uint64 life = DELAY + uint64(op >> 192) % (60 days);
                try escrow.authorizeDelegate(delegate, x % (y + 1), y, _now() + life) {} catch {}
            } else if (kind == 2) {
                try escrow.setLimits(x, y) {} catch {}
            } else {
                try escrow.requestWithdraw(x) {} catch {}
            }
            vm.stopPrank();
        }

        vm.warp(redeemAt);
        _redeem(v, sig);
        assertEq(escrow.escrowOf(buyer).seqHigh, 1);
        assertEq(escrow.escrowOf(buyer).balance, DEPOSIT - amount);
    }
}
