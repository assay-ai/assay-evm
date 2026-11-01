// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.38;

import {AssayEscrowChannelTest} from "./AssayEscrow.channel.t.sol";
import {ChannelDoor} from "../src/libraries/ChannelDoor.sol";
import {Sig} from "../src/libraries/Sig.sol";
import {ChannelVoucher, ChannelRef} from "../src/Types.sol";
import "../src/Errors.sol";

/// Exposes both recoveries with calldata signatures, for the parity tests.
contract SigHarness {
    function recover(bytes32 d, bytes calldata sig) external pure returns (address) {
        return Sig.recover(d, sig);
    }

    function tryRecover(bytes32 d, bytes calldata sig) external pure returns (address, uint256) {
        return Sig.tryRecover(d, sig);
    }
}

/// D-31: refund ids make `refundChannels` idempotent per channel (audit F-3), and a malformed
/// voucher signature skips its item instead of reverting the settle batch (audit F-5).
contract AssayEscrowChannelD31Test is AssayEscrowChannelTest {
    uint256 internal constant SECP256K1_N =
        0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
    bytes32 internal constant CH2 = keccak256("lane-2");
    bytes32 internal constant RID = keccak256("intent-1");

    // ------------------------------------------------------------------ refund-id helpers

    function _ids(bytes32 id) internal pure returns (bytes32[] memory r) {
        r = new bytes32[](1);
        r[0] = id;
    }

    function _bucket() internal view returns (uint40) {
        S memory s = _slot(delegate);
        return uint40((s.m1 << 16) | s.r1);
    }

    function _refund(uint40 b, uint64 a, bytes32 id) internal {
        uint40[] memory bs = new uint40[](1);
        bs[0] = b;
        vm.prank(redeemer);
        escrow.refundChannels(_ref(delegate), bs, _u(a), _ids(id));
    }

    function _expectRefundSkip(uint40 b, uint64 a, ChannelDoor.RefundSkip why) internal {
        vm.expectEmit(true, false, false, true, address(escrow));
        emit ChannelDoor.ChannelRefundSkipped(_key(delegate), b, a, uint8(why));
    }

    function _balance() internal view returns (uint128) {
        return escrow.escrowOf(buyer).balance;
    }

    // ------------------------------------------------------------------ F-3: refund ids

    function test_refundId_appliedOnce_acrossCalls() public {
        _settleD(0, 300_000, 3);
        uint40 b = _bucket();
        uint128 bal0 = _balance();
        _refund(b, 100_000, RID);
        assertEq(_held(), 200_000);
        assertEq(_balance(), bal0 + 100_000);

        _expectRefundSkip(b, 100_000, ChannelDoor.RefundSkip.AlreadyRefunded);
        _refund(b, 100_000, RID);
        assertEq(_held(), 200_000, "a retried id refunded twice");
        assertEq(_balance(), bal0 + 100_000);
        assertEq(_slot(delegate).h1, 200_000);
        _assertBooks();
    }

    function test_refundId_duplicateInsideOneBatch_secondSkips() public {
        _settleD(0, 300_000, 3);
        uint40 b = _bucket();
        ChannelRef[] memory refs = new ChannelRef[](2);
        refs[0] = _ref(delegate)[0];
        refs[1] = refs[0];
        uint40[] memory bs = new uint40[](2);
        (bs[0], bs[1]) = (b, b);
        uint64[] memory a = new uint64[](2);
        (a[0], a[1]) = (100_000, 100_000);
        bytes32[] memory ids = new bytes32[](2);
        (ids[0], ids[1]) = (RID, RID);

        vm.expectEmit(true, true, false, true, address(escrow));
        emit ChannelDoor.ChannelRefunded(_key(delegate), buyer, b, 100_000, RID);
        _expectRefundSkip(b, 100_000, ChannelDoor.RefundSkip.AlreadyRefunded);
        vm.prank(redeemer);
        escrow.refundChannels(refs, bs, a, ids);
        assertEq(_held(), 200_000);
        _assertBooks();
    }

    /// Only an APPLIED refund uses its id: an item skipped `Insufficient` or `NoSuchBucket`, or
    /// a zero amount, leaves the id free, and the same id then applies.
    function test_refundId_skippedItemCanBeRetriedWithTheSameId() public {
        _settleD(0, 300_000, 3);
        uint40 b = _bucket();
        _expectRefundSkip(b, 300_001, ChannelDoor.RefundSkip.Insufficient);
        _refund(b, 300_001, RID);
        uint40 wrong = b + (uint40(1) << 16);
        _expectRefundSkip(wrong, 1, ChannelDoor.RefundSkip.NoSuchBucket);
        _refund(wrong, 1, RID);
        _refund(b, 0, RID); // zero: a no-op, id stays free
        assertEq(_held(), 300_000);

        vm.expectEmit(true, true, false, true, address(escrow));
        emit ChannelDoor.ChannelRefunded(_key(delegate), buyer, b, 300_000, RID);
        _refund(b, 300_000, RID);
        assertEq(_held(), 0);
        _assertBooks();
    }

    /// A WindowClosed skip leaves the id free too (a later settlement may reopen a bucket of
    /// the same name only if its hour moves, so the retry here is on a new bucket).
    function test_refundId_windowClosedSkipLeavesIdFree() public {
        _settleD(0, 300_000, 3);
        S memory s = _slot(delegate);
        uint40 b = _bucket();
        vm.warp(s.m1 * 3600 + 7 days);
        _expectRefundSkip(b, 1, ChannelDoor.RefundSkip.WindowClosed);
        _refund(b, 1, RID);
        _settleD(300_000, 400_000, 4);
        S memory s2 = _slot(delegate);
        uint40 b2 = uint40((s2.m2 << 16) | s2.r2);
        _refund(b2, 100_000, RID);
        assertEq(_slot(delegate).h2, 0, "the id was used by a skipped item");
    }

    function test_refundId_isScopedPerChannel() public {
        _settleD(0, 300_000, 3);
        ChannelVoucher memory v = _cv(CH2, 200_000, 2);
        _settle(v, _sign(delegateKey, v), 0, 200_000);
        uint40 b = _bucket();
        _refund(b, 100_000, RID);

        ChannelRef[] memory r2 = new ChannelRef[](1);
        r2[0] = ChannelRef(buyer, delegate, provider, CH2);
        bytes32 k2 = keccak256(abi.encode(buyer, delegate, provider, CH2));
        (uint256 w,,,) = escrow.channelBooks(k2, address(0));
        uint40[] memory bs = new uint40[](1);
        bs[0] = uint40((((w >> 128) & 0xFFFFFF) << 16) | ((w >> 152) & 0xFFFF));
        vm.expectEmit(true, true, false, true, address(escrow));
        emit ChannelDoor.ChannelRefunded(k2, buyer, bs[0], 50_000, RID);
        vm.prank(redeemer);
        escrow.refundChannels(r2, bs, _u(50_000), _ids(RID));
        assertEq(_held(), 300_000 + 200_000 - 100_000 - 50_000);
        _assertBooks();
    }

    function test_refundId_zeroIdIsAnOrdinaryId() public {
        _settleD(0, 300_000, 3);
        uint40 b = _bucket();
        _refund(b, 1, bytes32(0));
        _expectRefundSkip(b, 1, ChannelDoor.RefundSkip.AlreadyRefunded);
        _refund(b, 1, bytes32(0));
        assertEq(_held(), 300_000 - 1);
    }

    function test_refundId_eventCarriesTheId() public {
        _settleD(0, 300_000, 3);
        uint40 b = _bucket();
        vm.expectEmit(true, true, false, true, address(escrow));
        emit ChannelDoor.ChannelRefunded(_key(delegate), buyer, b, 7, RID);
        _refund(b, 7, RID);
    }

    function test_refundIds_lengthIsPartOfTheShape() public {
        _settleD(0, 300_000, 3);
        bytes32[] memory two = new bytes32[](2);
        uint40[] memory bs = new uint40[](1);
        bs[0] = _bucket();
        ChannelRef[] memory refs = _ref(delegate);
        vm.prank(redeemer);
        vm.expectRevert(BatchLengthMismatch.selector);
        escrow.refundChannels(refs, bs, _u(1), two);
        vm.prank(redeemer);
        vm.expectRevert(BatchLengthMismatch.selector);
        escrow.refundChannels(refs, bs, _u(1), new bytes32[](0));
    }

    // ------------------------------------------------------------------ F-5: bad signatures

    function _split(bytes memory sig) internal pure returns (bytes32 r, bytes32 s, uint8 v) {
        assembly {
            r := mload(add(sig, 0x20))
            s := mload(add(sig, 0x40))
            v := byte(0, mload(add(sig, 0x60)))
        }
    }

    /// Three items on three lanes; item 1's signature is replaced by `bad`. Items 0 and 2 must
    /// settle, item 1 must skip `BadSignature` with a zero key and change nothing.
    function _batchWithBadMiddle(bytes memory bad) internal {
        ChannelVoucher[] memory vs = new ChannelVoucher[](3);
        bytes32[3] memory lanes = [CH, CH2, keccak256("lane-3")];
        bytes memory sigs;
        uint64[] memory f = new uint64[](3);
        uint64[] memory c = new uint64[](3);
        for (uint256 i = 0; i < 3; ++i) {
            vs[i] = _cv(lanes[i], 200_000, 1);
            sigs = bytes.concat(sigs, i == 1 ? bad : _sign(delegateKey, vs[i]));
            c[i] = 200_000;
        }
        uint128 bal0 = _balance();
        vm.expectEmit(true, true, false, true, address(escrow));
        emit ChannelDoor.ChannelSettleSkipped(
            1, buyer, bytes32(0), 200_000, uint8(ChannelDoor.SettleSkip.BadSignature)
        );
        vm.prank(redeemer);
        escrow.settleChannels(vs, sigs, f, c);
        assertEq(_held(), 400_000, "the good items did not settle");
        assertEq(_balance(), bal0 - 400_000);
        assertEq(_slot(delegate).settled, 200_000, "item 0");
        (uint256 w,,,) = escrow.channelBooks(
            keccak256(abi.encode(buyer, delegate, provider, lanes[2])), address(0)
        );
        assertEq(w & ((1 << 56) - 1), 200_000, "item 2");
        _assertBooks();
    }

    function _goodMiddle() internal view returns (bytes memory) {
        return _sign(delegateKey, _cv(CH2, 200_000, 1));
    }

    function test_badSig_highS_skipsOnlyThatItem() public {
        (bytes32 r, bytes32 s, uint8 v) = _split(_goodMiddle());
        // The malleated twin: same signer under ecrecover, refused by the low-s rule.
        _batchWithBadMiddle(
            abi.encodePacked(r, bytes32(SECP256K1_N - uint256(s)), v == 27 ? uint8(28) : 27)
        );
    }

    function test_badSig_badV_skipsOnlyThatItem() public {
        (bytes32 r, bytes32 s,) = _split(_goodMiddle());
        _batchWithBadMiddle(abi.encodePacked(r, s, uint8(29)));
    }

    function test_badSig_vZeroOrOne_skipsOnlyThatItem() public {
        (bytes32 r, bytes32 s, uint8 v) = _split(_goodMiddle());
        _batchWithBadMiddle(abi.encodePacked(r, s, v - 27));
    }

    function test_badSig_zeroSigner_skipsOnlyThatItem() public {
        // r = 0 is not a curve point: ecrecover returns no address.
        _batchWithBadMiddle(abi.encodePacked(bytes32(0), bytes32(uint256(1)), uint8(27)));
    }

    function test_badSig_allZeroBytes_skipsOnlyThatItem() public {
        _batchWithBadMiddle(new bytes(65));
    }

    /// A short signature cannot be expressed per item: signatures are a 65-byte-per-item
    /// concatenation, so a short one breaks the batch's calldata shape, which still reverts.
    /// Per item, the length rule is checked in `tryRecover` itself (below).
    function test_badSig_shortBlob_isACalldataShapeRevert() public {
        ChannelVoucher memory v = _cv(CH, 200_000, 1);
        bytes memory sig = _sign(delegateKey, v);
        bytes memory short_ = new bytes(64);
        for (uint256 i = 0; i < 64; ++i) {
            short_[i] = sig[i];
        }
        vm.prank(redeemer);
        vm.expectRevert(BatchLengthMismatch.selector);
        escrow.settleChannels(_one(v), short_, _u(0), _u(200_000));
    }

    /// A well-formed signature by the wrong key is not `BadSignature`: it recovers a signer
    /// that is not authorised, as before.
    function test_badSig_wrongKeyIsStillAuthority() public {
        ChannelVoucher memory v = _cv(CH, 200_000, 1);
        bytes32 k = keccak256(abi.encode(buyer, vm.addr(0xBAD), provider, CH));
        _expectSkip(0, k, 200_000, ChannelDoor.SettleSkip.Authority);
        _settle(v, _sign(0xBAD, v), 0, 200_000);
    }

    // ------------------------------------------------------------------ Sig parity

    function test_sig_tryRecoverReportsEachRule() public {
        SigHarness h = new SigHarness();
        bytes32 d = keccak256("d");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xA11CE, d);
        (address a, uint256 why) = h.tryRecover(d, abi.encodePacked(r, s, v));
        assertEq(a, vm.addr(0xA11CE));
        assertEq(why, Sig.OK);
        (a, why) = h.tryRecover(d, abi.encodePacked(r, s));
        assertEq(a, address(0));
        assertEq(why, Sig.BAD_LENGTH);
        (a, why) = h.tryRecover(d, abi.encodePacked(r, s, v, uint8(0)));
        assertEq(why, Sig.BAD_LENGTH);
        (a, why) = h.tryRecover(d, abi.encodePacked(r, bytes32(SECP256K1_N - uint256(s)), v));
        assertEq(why, Sig.HIGH_S);
        (a, why) = h.tryRecover(d, abi.encodePacked(r, s, uint8(29)));
        assertEq(why, Sig.BAD_V);
        (a, why) = h.tryRecover(d, abi.encodePacked(bytes32(0), bytes32(uint256(1)), uint8(27)));
        assertEq(a, address(0));
        assertEq(why, Sig.NO_SIGNER);

        // The reverting form keeps its distinct errors, in the same order.
        vm.expectRevert(InvalidSignature.selector);
        h.recover(d, abi.encodePacked(r, s));
        vm.expectRevert(MalleableSignature.selector);
        h.recover(d, abi.encodePacked(r, bytes32(SECP256K1_N - uint256(s)), v));
        vm.expectRevert(BadSignatureV.selector);
        h.recover(d, abi.encodePacked(r, s, uint8(29)));
        vm.expectRevert(InvalidSignature.selector);
        h.recover(d, abi.encodePacked(bytes32(0), bytes32(uint256(1)), uint8(27)));
    }

    /// Same acceptance rules: `tryRecover` returns a non-zero signer exactly when `recover`
    /// does not revert, and the same signer.
    function testFuzz_sig_tryRecoverMatchesRecover(bytes32 d, bytes32 r, bytes32 s, uint8 v)
        public
    {
        SigHarness h = new SigHarness();
        if (uint256(s) % 3 == 0) s = bytes32(uint256(s) >> 1); // reach low s often
        if (v % 2 == 0) v = 27 + (v % 4 == 0 ? 0 : 1); // reach valid v often
        bytes memory sig = abi.encodePacked(r, s, v);
        (address t, uint256 why) = h.tryRecover(d, sig);
        try h.recover(d, sig) returns (address a) {
            assertEq(t, a);
            assertTrue(a != address(0));
            assertEq(why, Sig.OK);
        } catch {
            assertEq(t, address(0));
            assertTrue(why != Sig.OK);
        }
    }
}
