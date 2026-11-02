// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.38;

// Ported from the independent security audit of 2026-11-01. Threat model: every key the backend
// holds is stolen (redeemer, relayer, verifier). Owner, admin, arbiter, treasury are NOT.
// F-3 and F-5 are fixed by D-31 and asserted safe here; F-1, F-2, F-4 and F-6 are accepted
// trade-offs (owner decision) and their tests pin the documented behaviour (`test_accepted_*`).

import {Vm} from "forge-std/Vm.sol";
import {Fixture} from "../helpers/Fixture.sol";
import {VoucherSigner} from "../helpers/VoucherSigner.sol";
import {AssayEscrow} from "../../src/AssayEscrow.sol";
import {AssayEscrowExtension} from "../../src/AssayEscrowExtension.sol";
import {AssayEscrowStorage} from "../../src/AssayEscrowStorage.sol";
import {AssayStake} from "../../src/AssayStake.sol";
import {AssayConfig} from "../../src/AssayConfig.sol";
import {IAssayEscrow} from "../../src/interfaces/IAssayEscrow.sol";
import {IAssayConfig} from "../../src/interfaces/IAssayConfig.sol";
import {IAssayStakeView} from "../../src/interfaces/IAssayStakeView.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ChannelDoor} from "../../src/libraries/ChannelDoor.sol";
import {Constants} from "../../src/Constants.sol";
import {
    Voucher,
    ChannelVoucher,
    ChannelRef,
    ParamSet,
    SlashAttestation,
    SlashStatus,
    CHANNEL_VOUCHER_TYPEHASH
} from "../../src/Types.sol";
import "../../src/Errors.sol";

abstract contract AuditBase is Fixture {
    address internal attacker = address(0xBAD);
    uint256 internal delegateKey = 0xD1E6;
    address internal delegate;
    uint256 internal strangerKey = 0x5157;

    function setUp() public virtual override {
        super.setUp();
        delegate = vm.addr(delegateKey);
        _fund(buyer, 1_000e6);
        vm.startPrank(buyer);
        usdg.approve(address(escrow), type(uint256).max);
        escrow.deposit(1_000e6);
        escrow.setLimits(10e6, 100e6);
        escrow.authorizeDelegate(delegate, 2e6, 5e6, uint64(block.timestamp + 30 days));
        vm.stopPrank();
    }

    function _now() internal view returns (uint64) {
        return uint64(vm.getBlockTimestamp());
    }

    function _pc(uint64 seq, uint64 amount) internal view returns (Voucher memory v) {
        v = Voucher({
            payer: buyer,
            provider: provider,
            amount: amount,
            resourceHash: bytes32("r"),
            requestHash: keccak256(abi.encode(seq)),
            seq: seq,
            issuedAt: _now(),
            expiresAt: _now() + 240
        });
    }

    function _cv(bytes32 id, uint64 cum, uint32 calls)
        internal
        view
        returns (ChannelVoucher memory v)
    {
        v = ChannelVoucher({
            payer: buyer,
            provider: provider,
            channelId: id,
            cumulative: cum,
            calls: calls,
            issuedAt: _now(),
            expiresAt: _now() + 240
        });
    }

    function _pcCopy(Voucher memory v) internal pure returns (Voucher memory) {
        return abi.decode(abi.encode(v), (Voucher));
    }

    function _cvCopy(ChannelVoucher memory v) internal pure returns (ChannelVoucher memory) {
        return abi.decode(abi.encode(v), (ChannelVoucher));
    }

    function _signC(uint256 pk, bytes32 ds, ChannelVoucher memory v)
        internal
        pure
        returns (bytes memory)
    {
        bytes32 sh = keccak256(
            abi.encode(
                CHANNEL_VOUCHER_TYPEHASH,
                v.payer,
                v.provider,
                v.channelId,
                v.cumulative,
                v.calls,
                v.issuedAt,
                v.expiresAt
            )
        );
        (uint8 vv, bytes32 r, bytes32 s) =
            vm.sign(pk, keccak256(abi.encodePacked("\x19\x01", ds, sh)));
        return abi.encodePacked(r, s, vv);
    }

    function _settle1(ChannelVoucher memory v, bytes memory sig, uint64 from, uint64 charge)
        internal
    {
        ChannelVoucher[] memory vs = new ChannelVoucher[](1);
        vs[0] = v;
        uint64[] memory f = new uint64[](1);
        f[0] = from;
        uint64[] memory c = new uint64[](1);
        c[0] = charge;
        vm.prank(redeemer);
        escrow.settleChannels(vs, sig, f, c);
    }

    function _ref(address signer, bytes32 id) internal view returns (ChannelRef memory r) {
        r = ChannelRef({payer: buyer, signer: signer, provider: provider, channelId: id});
    }

    function _key(address signer, bytes32 id) internal view returns (bytes32) {
        return ChannelDoor.keyOf(buyer, signer, provider, id);
    }

    function _settled(bytes32 key) internal view returns (uint256) {
        (uint256 st,,,) = escrow.channelBooks(key, address(0));
        return st & ((1 << 56) - 1);
    }

    function _ids(bytes32 id) internal pure returns (bytes32[] memory r) {
        r = new bytes32[](1);
        r[0] = id;
    }

    function _bal() internal view returns (uint128) {
        return escrow.escrowOf(buyer).balance;
    }

    function _chHeld() internal view returns (uint128 h) {
        (,,, h) = escrow.channelBooks(bytes32(0), address(0));
    }

    function _solvent() internal view {
        (,, uint128 tu, uint128 h) = escrow.channelBooks(bytes32(0), address(0));
        assertEq(
            usdg.balanceOf(address(escrow)),
            uint256(escrow.totalEscrowed()) + escrow.totalHeld() + h + tu,
            "solvency equality"
        );
    }
}

/// Items 1-4, 7: vouchers the buyer never signed, more than signed, redirection, caps.
contract CompromisedRedeemerPerCallTest is AuditBase {
    function test_forgedSignature_reverts() public {
        Voucher memory v = _pc(1, 1e6);
        bytes memory sig = VoucherSigner.signVoucher(strangerKey, escrow.DOMAIN_SEPARATOR(), v);
        vm.prank(redeemer);
        vm.expectRevert(SignerIsNotPayer.selector);
        escrow.redeemVoucher(v, sig);
    }

    function test_attackerSignsAsHimself_payerFieldIsVictim_reverts() public {
        // attacker key, payer = buyer, provider = attacker
        Voucher memory v = _pc(1, 1e6);
        v.provider = attacker;
        bytes memory sig = VoucherSigner.signVoucher(0xBAD, escrow.DOMAIN_SEPARATOR(), v);
        vm.prank(redeemer);
        vm.expectRevert(SignerIsNotPayer.selector);
        escrow.redeemVoucher(v, sig);
    }

    function test_tamperedProviderOrAmount_reverts() public {
        bytes32 ds = escrow.DOMAIN_SEPARATOR();
        Voucher memory v = _pc(1, 1e6);
        bytes memory sig = VoucherSigner.signVoucher(buyerKey, ds, v);
        Voucher memory t = _pcCopy(v);
        t.provider = attacker;
        vm.prank(redeemer);
        vm.expectRevert(SignerIsNotPayer.selector);
        escrow.redeemVoucher(t, sig);
        t = _pcCopy(v);
        t.amount = 9e6;
        vm.prank(redeemer);
        vm.expectRevert(SignerIsNotPayer.selector);
        escrow.redeemVoucher(t, sig);
    }

    function test_replaySameSeq_andMalleatedTwin_reverts() public {
        bytes32 ds = escrow.DOMAIN_SEPARATOR();
        Voucher memory v = _pc(1, 1e6);
        bytes memory sig = VoucherSigner.signVoucher(buyerKey, ds, v);
        vm.prank(redeemer);
        escrow.redeemVoucher(v, sig);
        vm.prank(redeemer);
        vm.expectRevert(VoucherSeqUsed.selector);
        escrow.redeemVoucher(v, sig);
        vm.prank(redeemer);
        vm.expectRevert(); // malleable or seq used: either way refused
        escrow.redeemVoucher(v, VoucherSigner.malleate(sig));
    }

    function test_otherContractAndOtherChain_reverts() public {
        Voucher memory v = _pc(1, 1e6);
        bytes memory sig = VoucherSigner.signVoucher(buyerKey, escrow.DOMAIN_SEPARATOR(), v);
        // second escrow proxy (same implementation, same config): different verifyingContract
        IAssayEscrow other = _deployEscrow(address(usdg));
        _fund(buyer, 10e6);
        vm.startPrank(buyer);
        usdg.approve(address(other), type(uint256).max);
        other.deposit(10e6);
        other.setLimits(10e6, 100e6);
        vm.stopPrank();
        vm.prank(redeemer);
        vm.expectRevert(SignerIsNotPayer.selector);
        other.redeemVoucher(v, sig);
        // fork with another chain id
        vm.chainId(4663);
        vm.prank(redeemer);
        vm.expectRevert(SignerIsNotPayer.selector);
        escrow.redeemVoucher(v, sig);
    }

    function test_delegateBeyondCaps_revokedAfterGrace_expired() public {
        bytes32 ds = escrow.DOMAIN_SEPARATOR();
        Voucher memory v = _pc(1, 3e6); // delegate per-call cap is 2
        vm.prank(redeemer);
        vm.expectRevert(DelegateVoucherExceedsPerCallLimit.selector);
        escrow.redeemVoucher(v, VoucherSigner.signVoucher(delegateKey, ds, v));
        // window: 2 + 2 + 2 > 5
        for (uint64 s = 2; s <= 3; ++s) {
            Voucher memory w = _pc(s, 2e6);
            vm.prank(redeemer);
            escrow.redeemVoucher(w, VoucherSigner.signVoucher(delegateKey, ds, w));
        }
        Voucher memory w4 = _pc(4, 2e6);
        bytes memory s4 = VoucherSigner.signVoucher(delegateKey, ds, w4);
        vm.prank(redeemer);
        vm.expectRevert(DelegateWindowLimitExceeded.selector);
        escrow.redeemVoucher(w4, s4);
        // revoke: after the grace the delegate signs nothing
        vm.prank(buyer);
        escrow.revokeDelegate(delegate);
        vm.warp(_now() + Constants.TIGHTEN_DELAY_SECONDS + 1);
        Voucher memory w5 = _pc(5, 1e6);
        bytes memory s5 = VoucherSigner.signVoucher(delegateKey, ds, w5);
        vm.prank(redeemer);
        vm.expectRevert(DelegateIsRevoked.selector);
        escrow.redeemVoucher(w5, s5);
    }

    function test_escrowCaps_bindRedeemer() public {
        bytes32 ds = escrow.DOMAIN_SEPARATOR();
        Voucher memory v = _pc(1, 11e6); // escrow per-call cap 10
        bytes memory sig = VoucherSigner.signVoucher(buyerKey, ds, v);
        vm.prank(redeemer);
        vm.expectRevert(VoucherExceedsPerCallLimit.selector);
        escrow.redeemVoucher(v, sig);
    }

    function test_collectPaysOnlyBoundProviderAndConfigTreasury() public {
        bytes32 ds = escrow.DOMAIN_SEPARATOR();
        Voucher memory v = _pc(1, 10e6);
        vm.prank(redeemer);
        escrow.redeemVoucher(v, VoucherSigner.signVoucher(buyerKey, ds, v));
        uint256 p0 = usdg.balanceOf(provider);
        uint256 t0 = usdg.balanceOf(treasury);
        // too early, for the redeemer and for a stranger
        vm.prank(redeemer);
        vm.expectRevert(HeldNotYetCollectable.selector);
        escrow.collectHeld(buyer, 1);
        vm.warp(_now() + 3600);
        vm.prank(attacker);
        vm.expectRevert(HeldNotYetCollectable.selector);
        escrow.collectHeld(buyer, 1);
        vm.prank(redeemer);
        escrow.collectHeld(buyer, 1);
        assertEq(usdg.balanceOf(provider) - p0, 9e6);
        assertEq(usdg.balanceOf(treasury) - t0, 1e6);
        assertEq(usdg.balanceOf(attacker), 0);
        assertEq(usdg.balanceOf(redeemer), 0);
        // collect then refund, collect twice
        vm.prank(redeemer);
        vm.expectRevert(HeldPaymentNotHeld.selector);
        escrow.refundHeld(buyer, 1);
        vm.prank(redeemer);
        vm.expectRevert(HeldPaymentNotHeld.selector);
        escrow.collectHeld(buyer, 1);
        _solvent();
    }

    function test_refundGoesToPayerBalanceOnly_andNoDoubleRefund() public {
        bytes32 ds = escrow.DOMAIN_SEPARATOR();
        Voucher memory v = _pc(1, 5e6);
        vm.prank(redeemer);
        escrow.redeemVoucher(v, VoucherSigner.signVoucher(buyerKey, ds, v));
        uint128 b = _bal();
        vm.prank(redeemer);
        escrow.refundHeld(buyer, 1);
        assertEq(_bal(), b + 5e6);
        vm.prank(redeemer);
        vm.expectRevert(HeldPaymentNotHeld.selector);
        escrow.refundHeld(buyer, 1);
        vm.prank(attacker);
        vm.expectRevert(NotRedeemer.selector);
        escrow.refundHeld(buyer, 1);
        _solvent();
    }
}

/// Channel door under a stolen redeemer key.
contract CompromisedRedeemerChannelTest is AuditBase {
    bytes32 constant ID = bytes32("ch1");

    function test_chargeAboveSigned_reverts_tamperedCumulative_skips() public {
        bytes32 ds = escrow.DOMAIN_SEPARATOR();
        ChannelVoucher memory v = _cv(ID, 3e6, 3);
        bytes memory sig = _signC(buyerKey, ds, v);
        uint128 b0 = _bal();
        // charge above cumulative - from
        ChannelVoucher[] memory vs = new ChannelVoucher[](1);
        vs[0] = v;
        uint64[] memory f = new uint64[](1);
        uint64[] memory c = new uint64[](1);
        c[0] = 3e6 + 1;
        vm.prank(redeemer);
        vm.expectRevert(ChannelChargeTooLarge.selector);
        escrow.settleChannels(vs, sig, f, c);
        // raise the cumulative in calldata: recovers another signer, no grant -> Authority skip
        ChannelVoucher memory t = _cvCopy(v);
        t.cumulative = 30e6;
        t.calls = 30;
        _settle1(t, sig, 0, 30e6);
        assertEq(_bal(), b0, "tampered cumulative moved money");
        // redirect provider
        t = _cvCopy(v);
        t.provider = attacker;
        _settle1(t, sig, 0, 3e6);
        assertEq(_bal(), b0, "tampered provider moved money");
        assertEq(_chHeld(), 0);
        _settle1(v, sig, 0, 3e6); // the genuine voucher still settles exactly once
        assertEq(b0 - _bal(), 3e6);
    }

    function test_sameCumulativeTwice_olderVoucher_noDoubleCharge() public {
        bytes32 ds = escrow.DOMAIN_SEPARATOR();
        ChannelVoucher memory v1 = _cv(ID, 2e6, 2);
        ChannelVoucher memory v2 = _cv(ID, 3e6, 3);
        bytes memory s1 = _signC(buyerKey, ds, v1);
        bytes memory s2 = _signC(buyerKey, ds, v2);
        uint128 b0 = _bal();
        _settle1(v2, s2, 0, 3e6);
        assertEq(b0 - _bal(), 3e6);
        // same voucher with the same base: base mismatch skip
        _settle1(v2, s2, 0, 3e6);
        // same voucher with base = settled: nothing to settle (calldata revert)
        ChannelVoucher[] memory vs = new ChannelVoucher[](1);
        vs[0] = v2;
        uint64[] memory f = new uint64[](1);
        f[0] = 3e6;
        uint64[] memory c = new uint64[](1);
        vm.prank(redeemer);
        vm.expectRevert(ChannelNothingToSettle.selector);
        escrow.settleChannels(vs, s2, f, c);
        // older voucher: refused either way
        _settle1(v1, s1, 0, 2e6);
        assertEq(b0 - _bal(), 3e6, "charged twice");
        // two copies in one batch
        ChannelVoucher memory v3 = _cv(ID, 4e6, 4);
        bytes memory s3 = _signC(buyerKey, ds, v3);
        vs = new ChannelVoucher[](2);
        vs[0] = v3;
        vs[1] = v3;
        f = new uint64[](2);
        f[0] = 3e6;
        f[1] = 3e6;
        c = new uint64[](2);
        c[0] = 1e6;
        c[1] = 1e6;
        vm.prank(redeemer);
        escrow.settleChannels(vs, bytes.concat(s3, s3), f, c);
        assertEq(b0 - _bal(), 4e6, "duplicate item charged twice");
        _solvent();
    }

    function test_replayOnOtherChannelProviderChainContract_skips() public {
        bytes32 ds = escrow.DOMAIN_SEPARATOR();
        ChannelVoucher memory v = _cv(ID, 3e6, 3);
        bytes memory sig = _signC(buyerKey, ds, v);
        uint128 b0 = _bal();
        ChannelVoucher memory t = _cvCopy(v);
        t.channelId = bytes32("other");
        _settle1(t, sig, 0, 3e6);
        assertEq(_bal(), b0);
        // other chain id
        vm.chainId(4663);
        _settle1(v, sig, 0, 3e6);
        assertEq(_bal(), b0);
        vm.chainId(31337);
        // a per-call voucher signature presented as a channel voucher: other typehash
        Voucher memory pc = _pc(1, 3e6);
        bytes memory pcs = VoucherSigner.signVoucher(buyerKey, ds, pc);
        _settle1(v, pcs, 0, 3e6);
        assertEq(_bal(), b0);
        // the genuine one still works once
        _settle1(v, sig, 0, 3e6);
        assertEq(b0 - _bal(), 3e6);
    }

    function test_delegateCapsAndRevocation_onChannel() public {
        bytes32 ds = escrow.DOMAIN_SEPARATOR();
        uint128 b0 = _bal();
        // dCalls = 1, charge 3 > per-call 2: PerCallCap skip
        ChannelVoucher memory v = _cv(ID, 3e6, 1);
        _settle1(v, _signC(delegateKey, ds, v), 0, 3e6);
        assertEq(_bal(), b0);
        // window 5: charge 6 with dCalls 3 fits per-call average but not the window
        v = _cv(ID, 6e6, 3);
        _settle1(v, _signC(delegateKey, ds, v), 0, 6e6);
        assertEq(_bal(), b0);
        // within caps works
        v = _cv(ID, 4e6, 2);
        _settle1(v, _signC(delegateKey, ds, v), 0, 4e6);
        assertEq(b0 - _bal(), 4e6);
        // revoke; after the grace nothing more, even a fresh signature
        vm.prank(buyer);
        escrow.revokeDelegate(delegate);
        vm.warp(_now() + Constants.TIGHTEN_DELAY_SECONDS + 1);
        vm.warp(_now() + 1 days); // window drained
        v = _cv(ID, 5e6, 3);
        _settle1(v, _signC(delegateKey, ds, v), 4e6, 1e6);
        assertEq(b0 - _bal(), 4e6, "revoked delegate charged");
    }

    function test_collectAndRefund_sameBucket_noDoublePay_andTimeWindows() public {
        bytes32 ds = escrow.DOMAIN_SEPARATOR();
        ChannelVoucher memory v = _cv(ID, 5e6, 5);
        _settle1(v, _signC(buyerKey, ds, v), 0, 5e6);
        bytes32 key = _key(buyer, ID);
        (uint256 st,,,) = escrow.channelBooks(key, address(0));
        uint256 m = (st >> 128) & 0xFFFFFF;
        uint256 r = (st >> 152) & 0xFFFF;
        ChannelRef[] memory refs = new ChannelRef[](1);
        refs[0] = _ref(buyer, ID);
        uint64[] memory keep = new uint64[](1);
        // before maturity: a no-op for the redeemer
        vm.prank(redeemer);
        escrow.collectChannels(refs, keep);
        assertEq(_chHeld(), 5e6);
        // after maturity, stranger before timeout: no-op
        vm.warp(m * 3600);
        vm.prank(attacker);
        escrow.collectChannels(refs, keep);
        assertEq(_chHeld(), 5e6);
        // redeemer collects 3, keeps 2
        keep[0] = 2e6;
        vm.prank(redeemer);
        escrow.collectChannels(refs, keep);
        assertEq(_chHeld(), 2e6);
        // refund more than what is left: skipped
        uint40[] memory bk = new uint40[](1);
        bk[0] = uint40((m << 16) | r);
        uint64[] memory am = new uint64[](1);
        am[0] = 3e6;
        uint128 b = _bal();
        vm.prank(redeemer);
        escrow.refundChannels(refs, bk, am, _ids("r1"));
        assertEq(_bal(), b);
        am[0] = 2e6;
        vm.prank(redeemer);
        escrow.refundChannels(refs, bk, am, _ids("r1")); // the skipped id is still free
        assertEq(_bal(), b + 2e6);
        vm.prank(redeemer);
        escrow.refundChannels(refs, bk, am, _ids("r2")); // nothing left: skip
        assertEq(_bal(), b + 2e6);
        assertEq(usdg.balanceOf(attacker), 0);
        _solvent();
    }

    function test_refundWindowAndAnyoneCollect_areDisjoint() public {
        bytes32 ds = escrow.DOMAIN_SEPARATOR();
        ChannelVoucher memory v = _cv(ID, 5e6, 5);
        _settle1(v, _signC(buyerKey, ds, v), 0, 5e6);
        (uint256 st,,,) = escrow.channelBooks(_key(buyer, ID), address(0));
        uint256 m = (st >> 128) & 0xFFFFFF;
        uint256 r = (st >> 152) & 0xFFFF;
        ChannelRef[] memory refs = new ChannelRef[](1);
        refs[0] = _ref(buyer, ID);
        uint64[] memory keep = new uint64[](1);
        uint40[] memory bk = new uint40[](1);
        bk[0] = uint40((m << 16) | r);
        uint64[] memory am = new uint64[](1);
        am[0] = 1e6;
        uint256 closeAt = m * 3600 + Constants.HELD_TIMEOUT_SECONDS;
        vm.warp(closeAt - 1);
        vm.prank(attacker);
        escrow.collectChannels(refs, keep); // stranger: not yet
        assertEq(_chHeld(), 5e6);
        uint128 b = _bal();
        vm.prank(redeemer);
        escrow.refundChannels(refs, bk, am, _ids("r1")); // last second of refund
        assertEq(_bal(), b + 1e6);
        vm.warp(closeAt);
        vm.prank(redeemer);
        escrow.refundChannels(refs, bk, am, _ids("r2")); // closed: skip
        assertEq(_bal(), b + 1e6);
        uint256 p0 = usdg.balanceOf(provider);
        vm.prank(attacker);
        escrow.collectChannels(refs, keep); // anyone, to the provider
        assertEq(usdg.balanceOf(provider) - p0, 4e6 - (uint256(4e6) * TAKE_RATE_BPS) / 10_000);
        assertEq(usdg.balanceOf(attacker), 0);
        _solvent();
    }

    function _bucketOf(bytes32 key) internal view returns (uint40) {
        (uint256 st,,,) = escrow.channelBooks(key, address(0));
        return uint40((((st >> 128) & 0xFFFFFF) << 16) | ((st >> 152) & 0xFFFF));
    }

    /// F-3, fixed by D-31: the same refund item (same refund id) sent twice is applied once,
    /// across calls (a retry) and inside one call (a duplicate), like the per-call
    /// `refundHeld(payer, seq)`.
    function test_channelRefundIsIdempotentPerRefundId() public {
        bytes32 ds = escrow.DOMAIN_SEPARATOR();
        ChannelVoucher memory v = _cv(ID, 5e6, 5);
        _settle1(v, _signC(buyerKey, ds, v), 0, 5e6);
        ChannelRef[] memory refs = new ChannelRef[](1);
        refs[0] = _ref(buyer, ID);
        uint40[] memory bk = new uint40[](1);
        bk[0] = _bucketOf(_key(buyer, ID));
        uint64[] memory am = new uint64[](1);
        am[0] = 2e6; // one disputed call worth 2
        uint128 b = _bal();
        vm.prank(redeemer);
        escrow.refundChannels(refs, bk, am, _ids("intent-1"));
        vm.prank(redeemer); // retry of the same intent
        escrow.refundChannels(refs, bk, am, _ids("intent-1"));
        assertEq(_bal() - b, 2e6, "same refund applied twice");
        assertEq(_chHeld(), 3e6);
        // the same item twice inside one call is also applied twice
        ChannelVoucher memory v2 = _cv(ID, 9e6, 9);
        _settle1(v2, _signC(buyerKey, ds, v2), 5e6, 4e6);
        refs = new ChannelRef[](2);
        refs[0] = _ref(buyer, ID);
        refs[1] = _ref(buyer, ID);
        bk = new uint40[](2);
        bk[0] = _bucketOf(_key(buyer, ID));
        bk[1] = bk[0];
        am = new uint64[](2);
        am[0] = 2e6;
        am[1] = 2e6;
        bytes32[] memory ids = new bytes32[](2);
        (ids[0], ids[1]) = (bytes32("intent-2"), bytes32("intent-2"));
        b = _bal();
        vm.prank(redeemer);
        escrow.refundChannels(refs, bk, am, ids);
        assertEq(_bal() - b, 2e6, "duplicate item in one batch applied twice");
        _solvent();
    }

    /// Accepted trade-off (F-4): a refund id does not bound a stolen redeemer key, which can
    /// return every pending bucket to its payer in one call with fresh ids. Bounded only by
    /// "payer only" and the refund window; the money never reaches the attacker.
    function test_accepted_compromisedRedeemerRefundsWholeBucket_payerOnly() public {
        bytes32 ds = escrow.DOMAIN_SEPARATOR();
        ChannelVoucher memory v = _cv(ID, 5e6, 5);
        _settle1(v, _signC(buyerKey, ds, v), 0, 5e6);
        ChannelRef[] memory refs = new ChannelRef[](1);
        refs[0] = _ref(buyer, ID);
        uint40[] memory bk = new uint40[](1);
        bk[0] = _bucketOf(_key(buyer, ID));
        uint64[] memory am = new uint64[](1);
        am[0] = 5e6;
        uint128 b = _bal();
        vm.prank(redeemer);
        escrow.refundChannels(refs, bk, am, _ids("any"));
        assertEq(_bal() - b, 5e6);
        assertEq(usdg.balanceOf(attacker), 0);
        assertEq(usdg.balanceOf(redeemer), 0);
    }

    /// Accepted trade-off (F-4, F-6): a stolen redeemer waives a provider's whole signed delta
    /// for good (charge 0), even for a blocked payer (pure waives skip the blocklist). Payer
    /// keeps the money.
    function test_accepted_redeemerCanWaiveProviderEarningsForGood() public {
        bytes32 ds = escrow.DOMAIN_SEPARATOR();
        ChannelVoucher memory v = _cv(ID, 8e6, 8);
        bytes memory sig = _signC(buyerKey, ds, v);
        vm.prank(admin);
        config.setBlocked(buyer, true);
        uint128 b = _bal();
        _settle1(v, sig, 0, 0);
        assertEq(_settled(_key(buyer, ID)), 8e6, "waive advanced settled");
        assertEq(_bal(), b);
        vm.prank(admin);
        config.setBlocked(buyer, false);
        _settle1(v, sig, 8e6 - 1, 1); // cannot be charged later: base moved
        assertEq(_bal(), b);
    }

    function test_strangerCannotKeepHeld() public {
        ChannelRef[] memory refs = new ChannelRef[](1);
        refs[0] = _ref(buyer, ID);
        uint64[] memory keep = new uint64[](1);
        keep[0] = 1;
        vm.prank(attacker);
        vm.expectRevert(NotRedeemer.selector);
        escrow.collectChannels(refs, keep);
    }

    function test_settleAndRefund_strangerRefused() public {
        bytes32 ds = escrow.DOMAIN_SEPARATOR();
        ChannelVoucher memory v = _cv(ID, 1e6, 1);
        ChannelVoucher[] memory vs = new ChannelVoucher[](1);
        vs[0] = v;
        uint64[] memory f = new uint64[](1);
        uint64[] memory c = new uint64[](1);
        vm.prank(attacker);
        vm.expectRevert(NotRedeemer.selector);
        escrow.settleChannels(vs, _signC(buyerKey, ds, v), f, c);
        ChannelRef[] memory refs = new ChannelRef[](1);
        uint40[] memory bk = new uint40[](1);
        vm.prank(attacker);
        vm.expectRevert(NotRedeemer.selector);
        escrow.refundChannels(refs, bk, c, new bytes32[](1));
    }

    /// F-5, fixed by D-31: one malformed signature (high s) skips its own item with
    /// `BadSignature`; the rest of the batch settles.
    function test_highS_signature_skipsOnlyThatItem() public {
        bytes32 ds = escrow.DOMAIN_SEPARATOR();
        ChannelVoucher memory good = _cv(ID, 1e6, 1);
        ChannelVoucher memory bad = _cv(bytes32("ch2"), 1e6, 1);
        ChannelVoucher[] memory vs = new ChannelVoucher[](2);
        vs[0] = good;
        vs[1] = bad;
        uint64[] memory f = new uint64[](2);
        uint64[] memory c = new uint64[](2);
        c[0] = 1e6;
        c[1] = 1e6;
        bytes memory sigs = bytes.concat(
            _signC(buyerKey, ds, good), VoucherSigner.malleate(_signC(buyerKey, ds, bad))
        );
        uint128 b = _bal();
        vm.expectEmit(true, true, false, true, address(escrow));
        emit ChannelDoor.ChannelSettleSkipped(
            1, buyer, bytes32(0), 1e6, uint8(ChannelDoor.SettleSkip.BadSignature)
        );
        vm.prank(redeemer);
        escrow.settleChannels(vs, sigs, f, c);
        assertEq(_bal(), b - 1e6, "only the good item charged");
        assertEq(_settled(_key(buyer, ID)), 1e6);
        assertEq(_settled(_key(buyer, bytes32("ch2"))), 0);
        _solvent();
    }
}

/// Item 4: a compromised redeemer cannot stop or delay the buyer's own exit.
contract BuyerExitTest is AuditBase {
    function test_withdrawUnaffectedByRedeemer_andOldVouchersDeadAtMaturity() public {
        bytes32 ds = escrow.DOMAIN_SEPARATOR();
        // voucher issued with maximum forward skew at the request instant
        Voucher memory v = _pc(1, 10e6);
        v.issuedAt = _now() + Constants.CLOCK_SKEW_TOLERANCE_SECONDS;
        v.expiresAt = v.issuedAt + Constants.VOUCHER_MAX_LIFETIME_SECONDS;
        bytes memory sig = VoucherSigner.signVoucher(buyerKey, ds, v);
        ChannelVoucher memory cv = _cv(bytes32("c"), 10e6, 1);
        cv.issuedAt = v.issuedAt;
        cv.expiresAt = v.expiresAt;
        bytes memory csig = _signC(buyerKey, ds, cv);

        vm.prank(buyer);
        escrow.requestWithdraw(1_000e6);
        uint64 at = escrow.escrowOf(buyer).withdrawAvailableAt;
        vm.warp(at);
        // both doors refuse the old vouchers at maturity
        vm.prank(redeemer);
        vm.expectRevert(VoucherExpired.selector);
        escrow.redeemVoucher(v, sig);
        uint128 b = _bal();
        _settle1(cv, csig, 0, 10e6);
        assertEq(_bal(), b);
        vm.prank(buyer);
        escrow.withdraw();
        assertEq(_bal(), 0);
        assertEq(usdg.balanceOf(buyer), 1_000e6);
    }
}

/// Item 6: escalation, initialisation, direct extension / library calls.
contract EscalationTest is AuditBase {
    function test_redeemerCannotUpgradeOrInit() public {
        AssayEscrow impl2 = new AssayEscrow();
        vm.prank(redeemer);
        vm.expectRevert(NotOwner.selector);
        escrow.upgradeToAndCall(address(impl2), "");
        vm.prank(redeemer);
        vm.expectRevert();
        escrow.initialize(IAssayConfig(attacker), IAssayStakeView(attacker), IERC20(attacker));
        vm.expectRevert();
        escrowImpl.initialize(IAssayConfig(attacker), IAssayStakeView(attacker), IERC20(attacker));
        // implementation's own UUPS door
        vm.prank(owner);
        vm.expectRevert();
        escrowImpl.upgradeToAndCall(address(impl2), "");
    }

    function test_extensionDirectCallRefused() public {
        address ext = escrow.EXTENSION();
        Voucher memory v = _pc(1, 1e6);
        vm.prank(redeemer);
        vm.expectRevert();
        AssayEscrowExtension(ext).redeemVoucher(v, new bytes(65));
        vm.expectRevert();
        AssayEscrowExtension(ext).revokeDelegateBySig(buyer, delegate, 0, 0, new bytes(65));
        assertEq(ext.code.length > 0, true);
        // the extension address is an immutable of the implementation: no setter exists
        (bool ok,) =
            address(escrow).call(abi.encodeWithSignature("setExtension(address)", attacker));
        assertFalse(ok);
    }

    function test_libraryDirectCallRefused() public {
        // settle via the library address directly with attacker-chosen storage pointers
        address lib = address(ChannelDoor);
        bytes memory data = abi.encodeWithSelector(
            ChannelDoor.claimUnpaid.selector, uint256(14), address(config), address(usdg), attacker
        );
        (bool ok,) = lib.call(data);
        assertFalse(ok, "library state-changing function callable directly");
    }

    function test_redeemerHasNoAdminPower() public {
        ParamSet memory p = config.params();
        p.treasury = attacker;
        vm.startPrank(redeemer);
        vm.expectRevert();
        config.updateConfig(p);
        vm.expectRevert();
        config.setPaused(true);
        vm.expectRevert();
        config.setBlocked(buyer, true);
        vm.expectRevert();
        config.registerVerifier(attacker, bytes32("x"), uint64(block.timestamp + 1 days));
        vm.expectRevert();
        config.setCollectHold(60);
        vm.expectRevert();
        config.setArbiter(attacker);
        vm.expectRevert();
        stake.cancelSlash(bytes32("id"));
        vm.expectRevert();
        stake.upholdSlash(bytes32("id"));
        vm.stopPrank();
    }

    /// Calls reaching the implementation's fallback run the extension in the implementation's
    /// own storage. Harmless (the proxy's storage is not touched) but shown here.
    function test_implementationFallbackRunsExtensionInImplStorage() public {
        address d2 = address(0xD2);
        (bool ok,) = address(escrowImpl).call(
            abi.encodeWithSelector(AssayEscrowExtension.effectiveCapsOf.selector, buyer, d2)
        );
        assertTrue(ok, "impl fallback reached the extension");
        vm.prank(redeemer);
        (ok,) = address(escrowImpl).call(
            abi.encodeWithSelector(
                AssayEscrowExtension.redeemVoucher.selector, _pc(1, 1), new bytes(65)
            )
        );
        assertFalse(ok);
    }
}

/// Item 5: provider stake under a stolen verifier key (the backend is the verifier).
contract CompromisedVerifierTest is AuditBase {
    uint256 internal verifierKey = 0x7E41F;
    address internal verifier;
    address internal arbiter = address(0xA4B1);

    function setUp() public override {
        super.setUp();
        verifier = vm.addr(verifierKey);
        vm.startPrank(admin);
        config.registerVerifier(verifier, bytes32("backend"), uint64(block.timestamp + 300 days));
        config.setArbiter(arbiter);
        vm.stopPrank();
    }

    function _att(bytes32 id, uint64 penalty, address beneficiary)
        internal
        view
        returns (SlashAttestation memory a)
    {
        a = SlashAttestation({
            requestId: id,
            provider: provider,
            beneficiary: beneficiary,
            status: 3,
            penalty: penalty,
            policy: bytes32("p"),
            issuedAt: _now(),
            expiresAt: _now() + 1 days
        });
    }

    function _propose(bytes32 id, address beneficiary) internal returns (bytes32) {
        SlashAttestation memory a = _att(id, config.params().penaltyAmount, beneficiary);
        bytes memory sig = VoucherSigner.signAttestation(verifierKey, stake.DOMAIN_SEPARATOR(), a);
        vm.prank(attacker);
        stake.proposeSlash(a, sig);
        return id;
    }

    function test_noVerifierKey_forgedAttestationRefused_andNoEarlyExecute() public {
        SlashAttestation memory a = _att(bytes32("f"), 1e6, attacker);
        bytes memory sig = VoucherSigner.signAttestation(strangerKey, stake.DOMAIN_SEPARATOR(), a);
        vm.expectRevert();
        stake.proposeSlash(a, sig);
        bytes32 id = _propose(bytes32("e"), attacker);
        vm.expectRevert(SlashNotYetExecutable.selector);
        stake.executeSlash(id);
    }

    /// Accepted trade-off (F-1, D-25): with the backend's verifier key the attacker names itself
    /// beneficiary and, if nobody disputes / cancels / revokes within the slash delay, is paid
    /// from provider stake. The defence is a person reacting within the delay.
    function test_accepted_stolenVerifierPaysAttackerUnlessSomeoneReacts() public {
        uint256 n;
        // propose as many as the provider's free stake allows; execution is window-limited
        for (uint256 i = 0; i < 200; ++i) {
            SlashAttestation memory a =
                _att(bytes32(i + 1), config.params().penaltyAmount, attacker);
            bytes memory sig =
                VoucherSigner.signAttestation(verifierKey, stake.DOMAIN_SEPARATOR(), a);
            try stake.proposeSlash(a, sig) {
                ++n;
            } catch {
                break;
            }
        }
        emit log_named_uint("records proposed", n);
        vm.warp(_now() + config.slashDelaySeconds());
        uint256 paid;
        for (uint256 d = 0; d < 7; ++d) {
            for (uint256 i = 0; i < n; ++i) {
                if (stake.slashRecordOf(bytes32(i + 1)).status != SlashStatus.Pending) continue;
                try stake.executeSlash(bytes32(i + 1)) {
                    ++paid;
                } catch {}
            }
            vm.warp(_now() + 12 hours);
        }
        emit log_named_uint("records executed in 3.5 days", paid);
        emit log_named_uint("attacker received (base units)", usdg.balanceOf(attacker));
        assertGt(usdg.balanceOf(attacker), 0, "attacker paid from stake");
    }

    /// Accepted trade-off (F-2): one proposal, no delay, takes a provider at the minimum stake
    /// out of every paid call (both doors) until an admin/arbiter cancels it or it expires.
    function test_accepted_oneProposalStopsMinStakeProviderInstantly() public {
        bytes32 ds = escrow.DOMAIN_SEPARATOR();
        assertEq(stake.freeBondedOf(provider), MINIMUM_STAKE);
        _propose(bytes32("dos"), attacker);
        assertLt(stake.freeBondedOf(provider), MINIMUM_STAKE);
        Voucher memory v = _pc(1, 1e6);
        bytes memory sig = VoucherSigner.signVoucher(buyerKey, ds, v);
        vm.prank(redeemer);
        vm.expectRevert(ProviderBelowMinimumStake.selector);
        escrow.redeemVoucher(v, sig);
        ChannelVoucher memory c = _cv(bytes32("c"), 1e6, 1);
        uint128 b = _bal();
        _settle1(c, _signC(buyerKey, ds, c), 0, 1e6); // skipped: Stake
        assertEq(_bal(), b);
    }

    function test_disputeOrRevokeStopsIt() public {
        bytes32 a = _propose(bytes32("a"), attacker);
        bytes32 b = _propose(bytes32("b"), attacker);
        vm.prank(provider);
        stake.disputeSlash(a);
        vm.prank(admin);
        config.revokeVerifier(verifier);
        vm.warp(_now() + config.slashDelaySeconds());
        vm.expectRevert();
        stake.executeSlash(a);
        vm.expectRevert();
        stake.executeSlash(b);
        // the redeemer (backend) cannot uphold a dispute
        vm.prank(redeemer);
        vm.expectRevert(NotArbiter.selector);
        stake.upholdSlash(a);
        assertEq(usdg.balanceOf(attacker), 0);
    }
}
