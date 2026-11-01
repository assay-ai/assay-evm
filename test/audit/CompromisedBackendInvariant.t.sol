// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.38;

// Ported from the independent security audit of 2026-11-01. Stateful fuzzing with a stolen redeemer key: the attacker
// replays, tampers, forges, re-orders, picks any base/charge/keepHeld and any timing. The honest
// buyer and its delegate only sign; every signed amount is counted as "exposure".

import {Test} from "forge-std/Test.sol";
import {Fixture} from "../helpers/Fixture.sol";
import {VoucherSigner} from "../helpers/VoucherSigner.sol";
import {IAssayEscrow} from "../../src/interfaces/IAssayEscrow.sol";
import {AssayStake} from "../../src/AssayStake.sol";
import {AssayEscrowStorage} from "../../src/AssayEscrowStorage.sol";
import {MockUSDG} from "../helpers/MockUSDG.sol";
import {ChannelDoor} from "../../src/libraries/ChannelDoor.sol";
import {
    Voucher,
    ChannelVoucher,
    ChannelRef,
    SlashAttestation,
    CHANNEL_VOUCHER_TYPEHASH
} from "../../src/Types.sol";

contract RedeemerAttackHandler is Test {
    IAssayEscrow internal esc;
    MockUSDG internal usdg;
    AssayStake internal stake;
    uint256 internal buyerKey;
    uint256 internal delegateKey;
    address internal buyer;
    address internal delegate;
    address internal provider;
    address internal redeemer;
    address public attacker = address(0xBAD);
    uint256 internal constant ATTACKER_KEY = 0xBAD;

    Voucher[] internal pcs;
    bytes[] internal pcSigs;
    ChannelVoucher[] internal cvs;
    bytes[] internal cvSigs;
    address[] internal cvSigner;
    mapping(bytes32 => uint64) public maxCum;
    mapping(bytes32 => uint32) public lastCalls;
    bytes32[] internal keys;
    uint64 internal nextSeq = 1;

    uint256 public exposure; // every unit the buyer (or its delegate) ever authorised
    uint256 public withdrawn;
    uint256 public okRedeem;
    uint256 public okSettle;
    uint256 public okCollect;
    uint256 public okRefund;
    uint256 public okTampered;

    constructor(
        IAssayEscrow e,
        MockUSDG u,
        AssayStake s,
        uint256 bk,
        uint256 dk,
        address p,
        address r
    ) {
        esc = e;
        usdg = u;
        stake = s;
        buyerKey = bk;
        delegateKey = dk;
        buyer = vm.addr(bk);
        delegate = vm.addr(dk);
        provider = p;
        redeemer = r;
    }

    function _now() internal view returns (uint64) {
        return uint64(block.timestamp);
    }

    function _signC(uint256 pk, ChannelVoucher memory v) internal view returns (bytes memory) {
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
            vm.sign(pk, keccak256(abi.encodePacked("\x19\x01", esc.DOMAIN_SEPARATOR(), sh)));
        return abi.encodePacked(r, s, vv);
    }

    // ---------------------------------------------------------------- honest signing

    function signPerCall(uint64 amt, bool byDelegate) external {
        amt = uint64(bound(amt, 1, 3e6));
        Voucher memory v = Voucher({
            payer: buyer,
            provider: provider,
            amount: amt,
            resourceHash: bytes32("r"),
            requestHash: keccak256(abi.encode(nextSeq)),
            seq: nextSeq++,
            issuedAt: _now(),
            expiresAt: _now() + 240
        });
        pcs.push(v);
        pcSigs.push(
            VoucherSigner.signVoucher(
                byDelegate ? delegateKey : buyerKey, esc.DOMAIN_SEPARATOR(), v
            )
        );
        exposure += amt;
    }

    function signChannel(uint8 ch, uint64 inc, uint8 dCalls, bool byDelegate) external {
        bytes32 id = bytes32(uint256(bound(ch, 1, 3)));
        address signer = byDelegate ? delegate : buyer;
        bytes32 key = ChannelDoor.keyOf(buyer, signer, provider, id);
        inc = uint64(bound(inc, 1, 3e6));
        uint32 c = lastCalls[key] + uint32(bound(dCalls, 1, 3));
        uint64 cum = maxCum[key] + inc;
        if (maxCum[key] == 0) keys.push(key);
        maxCum[key] = cum;
        lastCalls[key] = c;
        ChannelVoucher memory v = ChannelVoucher({
            payer: buyer,
            provider: provider,
            channelId: id,
            cumulative: cum,
            calls: c,
            issuedAt: _now(),
            expiresAt: _now() + 240
        });
        cvs.push(v);
        cvSigs.push(_signC(byDelegate ? delegateKey : buyerKey, v));
        cvSigner.push(signer);
        exposure += inc;
    }

    function buyerRequestWithdraw(uint64 amt) external {
        vm.prank(buyer);
        try esc.requestWithdraw(uint64(bound(amt, 0, 2_000e6))) {} catch {}
    }

    function buyerWithdraw() external {
        uint256 b0 = usdg.balanceOf(buyer);
        vm.prank(buyer);
        try esc.withdraw() {} catch {}
        withdrawn += usdg.balanceOf(buyer) - b0;
    }

    // ---------------------------------------------------------------- attacker (redeemer key)

    function redeem(uint256 i, uint8 tamper, uint64 x) external {
        if (pcs.length == 0) return;
        i = bound(i, 0, pcs.length - 1);
        Voucher memory v = abi.decode(abi.encode(pcs[i]), (Voucher));
        uint256 t = tamper < 128 ? 0 : 1 + tamper % 4;
        if (t == 1) v.provider = attacker;
        else if (t == 2) v.amount = uint64(bound(x, 1, 50e6));
        else if (t == 3) v.seq = uint64(bound(x, 1, 1000));
        else if (t == 4) v.expiresAt = v.expiresAt + uint64(bound(x, 1, 1 days));
        vm.prank(redeemer);
        try esc.redeemVoucher(v, pcSigs[i]) {
            ++okRedeem;
            if (t != 0 && t != 4) ++okTampered;
        } catch {}
    }

    function redeemBatch(uint256 i, uint256 j) external {
        if (pcs.length == 0) return;
        Voucher[] memory vs = new Voucher[](2);
        bytes[] memory ss = new bytes[](2);
        i = bound(i, 0, pcs.length - 1);
        j = bound(j, 0, pcs.length - 1);
        vs[0] = pcs[i];
        vs[1] = pcs[j];
        ss[0] = pcSigs[i];
        ss[1] = pcSigs[j];
        vm.prank(redeemer);
        try esc.redeemVoucherBatch(vs, ss) {
            ++okRedeem;
        } catch {}
    }

    function forge(uint64 amt, bool channel) external {
        amt = uint64(bound(amt, 1, 50e6));
        if (!channel) {
            Voucher memory v = Voucher({
                payer: buyer,
                provider: attacker,
                amount: amt,
                resourceHash: 0,
                requestHash: 0,
                seq: 999_999,
                issuedAt: _now(),
                expiresAt: _now() + 240
            });
            bytes memory sig = VoucherSigner.signVoucher(ATTACKER_KEY, esc.DOMAIN_SEPARATOR(), v);
            vm.prank(redeemer);
            try esc.redeemVoucher(v, sig) {} catch {}
        } else {
            ChannelVoucher memory v = ChannelVoucher({
                payer: buyer,
                provider: attacker,
                channelId: bytes32("x"),
                cumulative: amt,
                calls: 1,
                issuedAt: _now(),
                expiresAt: _now() + 240
            });
            _settleRaw(v, _signC(ATTACKER_KEY, v), 0, amt);
        }
    }

    function _settleRaw(ChannelVoucher memory v, bytes memory sig, uint64 from, uint64 charge)
        internal
    {
        ChannelVoucher[] memory vs = new ChannelVoucher[](1);
        vs[0] = v;
        uint64[] memory f = new uint64[](1);
        f[0] = from;
        uint64[] memory c = new uint64[](1);
        c[0] = charge;
        vm.prank(redeemer);
        try esc.settleChannels(vs, sig, f, c) {
            ++okSettle;
        } catch {}
    }

    function _settled(bytes32 key) internal view returns (uint64) {
        (uint256 st,,,) = esc.channelBooks(key, address(0));
        return uint64(st & ((1 << 56) - 1));
    }

    function settle(uint256 i, uint8 mode, uint64 x, uint64 ch, uint8 tamper) external {
        if (cvs.length == 0) return;
        i = bound(i, 0, cvs.length - 1);
        ChannelVoucher memory v = abi.decode(abi.encode(cvs[i]), (ChannelVoucher));
        bytes32 key = ChannelDoor.keyOf(buyer, cvSigner[i], provider, v.channelId);
        uint64 from =
            mode % 3 == 0 ? _settled(key) : mode % 3 == 1 ? 0 : uint64(bound(x, 0, v.cumulative));
        uint256 t = tamper < 128 ? 0 : 1 + tamper % 5;
        if (t == 1) v.cumulative = v.cumulative + uint64(bound(x, 1, 50e6));
        else if (t == 2) v.provider = attacker;
        else if (t == 3) v.calls = v.calls + 100;
        else if (t == 4) v.channelId = bytes32(uint256(v.channelId) + 1);
        if (v.cumulative <= from) return;
        uint64 charge = uint64(bound(ch, 0, v.cumulative - from));
        _settleRaw(v, cvSigs[i], from, charge);
    }

    function settleBatch(uint256 i, uint256 j, uint64 ci, uint64 cj) external {
        if (cvs.length == 0) return;
        i = bound(i, 0, cvs.length - 1);
        j = bound(j, 0, cvs.length - 1);
        ChannelVoucher[] memory vs = new ChannelVoucher[](2);
        vs[0] = cvs[i];
        vs[1] = cvs[j];
        uint64[] memory f = new uint64[](2);
        f[0] = _settled(ChannelDoor.keyOf(buyer, cvSigner[i], provider, vs[0].channelId));
        f[1] = _settled(ChannelDoor.keyOf(buyer, cvSigner[j], provider, vs[1].channelId));
        uint64[] memory c = new uint64[](2);
        if (vs[0].cumulative <= f[0] || vs[1].cumulative <= f[1]) return;
        c[0] = uint64(bound(ci, 0, vs[0].cumulative - f[0]));
        c[1] = uint64(bound(cj, 0, vs[1].cumulative - f[1]));
        vm.prank(redeemer);
        try esc.settleChannels(vs, bytes.concat(cvSigs[i], cvSigs[j]), f, c) {} catch {}
    }

    function refundHeld(uint64 seq) external {
        vm.prank(redeemer);
        try esc.refundHeld(buyer, uint64(bound(seq, 1, nextSeq > 1 ? nextSeq - 1 : 1))) {
            ++okRefund;
        } catch {}
    }

    function collectHeld(uint64 seq, bool asAttacker) external {
        vm.prank(asAttacker ? attacker : redeemer);
        try esc.collectHeld(buyer, uint64(bound(seq, 1, nextSeq > 1 ? nextSeq - 1 : 1))) {
            ++okCollect;
        } catch {}
    }

    function _refOf(uint256 k) internal view returns (ChannelRef memory r, bytes32 key) {
        key = keys[k];
        for (uint256 i = 0; i < cvs.length; ++i) {
            if (ChannelDoor.keyOf(buyer, cvSigner[i], provider, cvs[i].channelId) == key) {
                r = ChannelRef(buyer, cvSigner[i], provider, cvs[i].channelId);
                return (r, key);
            }
        }
    }

    function collectChannel(uint256 k, uint64 keep, bool asAttacker, bool redirect) external {
        if (keys.length == 0) return;
        (ChannelRef memory r,) = _refOf(bound(k, 0, keys.length - 1));
        if (redirect) r.provider = attacker;
        ChannelRef[] memory refs = new ChannelRef[](1);
        refs[0] = r;
        uint64[] memory kh = new uint64[](1);
        kh[0] = asAttacker ? 0 : uint64(bound(keep, 0, 5e6));
        vm.prank(asAttacker ? attacker : redeemer);
        try esc.collectChannels(refs, kh) {} catch {}
    }

    /// Refund ids come from a small set, so the stolen key both reuses ids and invents new ones.
    function refundChannel(uint256 k, bool second, uint64 amt, uint8 idSeed) external {
        if (keys.length == 0) return;
        (ChannelRef memory r, bytes32 key) = _refOf(bound(k, 0, keys.length - 1));
        (uint256 st,,,) = esc.channelBooks(key, address(0));
        uint256 sh = second ? 168 : 80;
        uint40 bucket =
            uint40((((st >> (sh + 48)) & 0xFFFFFF) << 16) | ((st >> (sh + 72)) & 0xFFFF));
        ChannelRef[] memory refs = new ChannelRef[](1);
        refs[0] = r;
        uint40[] memory b = new uint40[](1);
        b[0] = bucket;
        uint64[] memory a = new uint64[](1);
        a[0] = uint64(bound(amt, 0, 10e6));
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = bytes32(uint256(idSeed % 16));
        vm.prank(redeemer);
        try esc.refundChannels(refs, b, a, ids) {} catch {}
    }

    function claimUnpaid(bool forAttacker) external {
        try esc.claimUnpaid(forAttacker ? attacker : provider) {} catch {}
    }

    function forgeSlash(uint64 penalty) external {
        SlashAttestation memory a = SlashAttestation({
            requestId: keccak256(abi.encode(penalty, block.timestamp)),
            provider: provider,
            beneficiary: attacker,
            status: 3,
            penalty: uint64(bound(penalty, 1, 1e6)),
            policy: 0,
            issuedAt: _now(),
            expiresAt: _now() + 1 days
        });
        bytes memory sig = VoucherSigner.signAttestation(ATTACKER_KEY, stake.DOMAIN_SEPARATOR(), a);
        try stake.proposeSlash(a, sig) {} catch {}
    }

    function warp(uint32 dt) external {
        vm.warp(block.timestamp + bound(dt, 1, 10 minutes));
    }

    function warpLong() external {
        vm.warp(block.timestamp + 7 days + 2 hours);
    }
}

contract CompromisedBackendInvariantTest is Fixture {
    RedeemerAttackHandler internal h;
    uint256 internal constant DEPOSIT = 1_000e6;
    uint256 internal p0;
    uint256 internal t0;
    uint256 internal staked0;

    function setUp() public override {
        super.setUp();
        uint256 dk = 0xD1E6;
        _fund(buyer, DEPOSIT);
        vm.startPrank(buyer);
        usdg.approve(address(escrow), type(uint256).max);
        escrow.deposit(uint64(DEPOSIT));
        escrow.setLimits(10e6, 200e6);
        escrow.authorizeDelegate(vm.addr(dk), 2e6, 20e6, uint64(block.timestamp + 300 days));
        vm.stopPrank();
        h = new RedeemerAttackHandler(escrow, usdg, stake, buyerKey, dk, provider, redeemer);
        p0 = usdg.balanceOf(provider);
        t0 = usdg.balanceOf(treasury);
        staked0 = stake.totalStaked();
        targetContract(address(h));
    }

    function afterInvariant() public {
        emit log_named_uint("ok redeem", h.okRedeem());
        emit log_named_uint("ok settle tx", h.okSettle());
        emit log_named_uint("ok collectHeld", h.okCollect());
        emit log_named_uint("ok refundHeld", h.okRefund());
        emit log_named_uint("tampered per-call accepted", h.okTampered());
        emit log_named_uint("buyer totalRedeemed", escrow.escrowOf(buyer).totalRedeemed);
        emit log_named_uint("exposure", h.exposure());
        (,,, uint128 hc) = escrow.channelBooks(bytes32(0), address(0));
        emit log_named_uint("channel held", hc);
        emit log_named_uint("provider received", usdg.balanceOf(provider) - p0);
    }

    function invariant_attackerAndRedeemerNeverPaid() public view {
        assertEq(usdg.balanceOf(h.attacker()), 0);
        assertEq(usdg.balanceOf(redeemer), 0);
    }

    function invariant_buyerSpendNeverExceedsWhatWasSigned() public view {
        assertLe(escrow.escrowOf(buyer).totalRedeemed, h.exposure());
        // what actually left the escrow to provider + treasury is within what was signed
        uint256 out = usdg.balanceOf(provider) - p0 + usdg.balanceOf(treasury) - t0;
        assertLe(out, h.exposure());
    }

    function invariant_buyerMoneyConserved() public view {
        // balance + spent (held, collected) + withdrawn == deposit
        AssayEscrowStorage.Escrow memory e;
        e = _e();
        assertEq(uint256(e.balance) + e.totalRedeemed + e.totalWithdrawn, DEPOSIT);
        assertEq(e.totalWithdrawn, h.withdrawn());
    }

    function _e() internal view returns (AssayEscrowStorage.Escrow memory) {
        return escrow.escrowOf(buyer);
    }

    function invariant_solvencyEquality() public view {
        (,, uint128 tu, uint128 hc) = escrow.channelBooks(bytes32(0), address(0));
        assertEq(escrow.totalEscrowed(), escrow.escrowOf(buyer).balance);
        assertEq(
            usdg.balanceOf(address(escrow)),
            uint256(escrow.totalEscrowed()) + escrow.totalHeld() + hc + tu
        );
    }

    function invariant_stakeUntouched() public view {
        assertEq(stake.totalStaked(), staked0);
        assertEq(stake.stakeOf(provider).pendingSlash, 0);
    }
}

contract HandlerSanityTest is Fixture {
    function test_handlerPaths() public {
        uint256 dk = 0xD1E6;
        _fund(buyer, 1_000e6);
        vm.startPrank(buyer);
        usdg.approve(address(escrow), type(uint256).max);
        escrow.deposit(1_000e6);
        escrow.setLimits(10e6, 200e6);
        escrow.authorizeDelegate(vm.addr(dk), 2e6, 20e6, uint64(block.timestamp + 300 days));
        vm.stopPrank();
        RedeemerAttackHandler h =
            new RedeemerAttackHandler(escrow, usdg, stake, buyerKey, dk, provider, redeemer);
        h.signPerCall(1e6, false);
        h.redeem(0, 0, 0);
        h.signPerCall(1e6, true);
        h.redeem(1, 0, 0);
        h.signChannel(1, 1e6, 1, false);
        h.settle(0, 0, 0, 1e6, 0);
        assertEq(h.okRedeem(), 2, "redeem");
        assertEq(h.okSettle(), 1, "settle");
        h.refundHeld(1);
        assertEq(h.okRefund(), 1, "refund");
        h.warp(600);
        h.warpLong();
        h.collectHeld(2, false);
        assertEq(h.okCollect(), 1, "collect");
    }
}
