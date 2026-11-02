// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.38;

import {Vm} from "forge-std/Vm.sol";
import {Fixture} from "./helpers/Fixture.sol";
import {VoucherSigner} from "./helpers/VoucherSigner.sol";
import {ChannelDoor} from "../src/libraries/ChannelDoor.sol";
import {Constants} from "../src/Constants.sol";
import {ChannelVoucher, Voucher} from "../src/Types.sol";
import "../src/Errors.sol";

/// Differential: with `dCalls = 1`, the channel door's cap gate must decide exactly as the
/// per-call door's `_redeem` does — same pass, same refusal class — for the same escrow state,
/// including a held cap pair after a lowering (D-21).
contract AssayEscrowChannelParityTest is Fixture {
    bytes32 internal constant CHANNEL_TYPEHASH = keccak256(
        "ChannelVoucher(address payer,address provider,bytes32 channelId,uint64 cumulative,"
        "uint32 calls,uint64 issuedAt,uint64 expiresAt)"
    );
    uint256 internal constant KEY_A = 0xA0A0A0;
    uint256 internal constant KEY_B = 0xB0B0B0;
    bytes32 internal constant CH = keccak256("parity");

    enum Outcome {
        Pass,
        PerCall,
        Window,
        Other
    }

    function _setUpPayer(uint256 key, uint64 v, uint64 w) internal returns (address a) {
        a = vm.addr(key);
        _fund(a, 1_000e6);
        vm.startPrank(a);
        usdg.approve(address(escrow), type(uint256).max);
        escrow.deposit(1_000e6);
        escrow.setLimits(v, w);
        vm.stopPrank();
    }

    function _now() internal view returns (uint64) {
        return uint64(vm.getBlockTimestamp());
    }

    function _perCall(address a, uint64 seq, uint64 amount) internal returns (Outcome) {
        Voucher memory pv = Voucher({
            payer: a,
            provider: provider,
            amount: amount,
            resourceHash: bytes32(0),
            requestHash: bytes32(uint256(seq)),
            seq: seq,
            issuedAt: _now(),
            expiresAt: _now() + 240
        });
        bytes memory sig = VoucherSigner.signVoucher(KEY_A, escrow.DOMAIN_SEPARATOR(), pv);
        vm.prank(redeemer);
        try escrow.redeemVoucher(pv, sig) {
            return Outcome.Pass;
        } catch (bytes memory err) {
            bytes4 sel = bytes4(err);
            if (sel == VoucherExceedsPerCallLimit.selector) return Outcome.PerCall;
            if (sel == EscrowWindowLimitExceeded.selector) return Outcome.Window;
            return Outcome.Other;
        }
    }

    function _channel(address a, uint64 from, uint64 cum, uint32 calls)
        internal
        returns (Outcome)
    {
        ChannelVoucher memory v = ChannelVoucher({
            payer: a,
            provider: provider,
            channelId: CH,
            cumulative: cum,
            calls: calls,
            issuedAt: _now(),
            expiresAt: _now() + 240
        });
        bytes32 sh = keccak256(
            abi.encode(
                CHANNEL_TYPEHASH,
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
            vm.sign(KEY_B, keccak256(abi.encodePacked("\x19\x01", escrow.DOMAIN_SEPARATOR(), sh)));
        ChannelVoucher[] memory vs = new ChannelVoucher[](1);
        vs[0] = v;
        uint64[] memory f = new uint64[](1);
        f[0] = from;
        uint64[] memory c = new uint64[](1);
        c[0] = cum - from;
        vm.recordLogs();
        vm.prank(redeemer);
        escrow.settleChannels(vs, abi.encodePacked(r, s, vv), f, c);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 skipTopic = ChannelDoor.ChannelSettleSkipped.selector;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics[0] == skipTopic) {
                (, uint64 cumLogged, uint8 reason) =
                    abi.decode(logs[i].data, (bytes32, uint64, uint8));
                cumLogged;
                if (reason == uint8(ChannelDoor.SettleSkip.PerCallCap)) return Outcome.PerCall;
                if (reason == uint8(ChannelDoor.SettleSkip.EscrowWindow)) return Outcome.Window;
                return Outcome.Other;
            }
        }
        return Outcome.Pass;
    }

    function testFuzz_capsDecideAsThePerCallDoorDoes(
        uint64 v,
        uint64 w,
        uint64 pre,
        uint64 amount,
        uint32 dt,
        bool lower,
        uint64 lowV,
        uint64 lowW
    ) public {
        v = uint64(bound(v, 1, 50e6));
        w = uint64(bound(w, v, 200e6));
        pre = uint64(bound(pre, 0, v)); // a first spend that both doors accept
        amount = uint64(bound(amount, 1, 60e6));
        dt = uint32(bound(dt, 0, 2 days));
        address a = _setUpPayer(KEY_A, v, w);
        address b = _setUpPayer(KEY_B, v, w);

        uint64 cum;
        if (pre > 0) {
            assertEq(uint8(_perCall(a, 1, pre)), uint8(Outcome.Pass));
            assertEq(uint8(_channel(b, 0, pre, 1)), uint8(Outcome.Pass));
            cum = pre;
        }
        if (lower) {
            lowV = uint64(bound(lowV, 0, v));
            lowW = uint64(bound(lowW, 0, w));
            if (lowV != v || lowW != w) {
                vm.prank(a);
                escrow.setLimits(lowV, lowW);
                vm.prank(b);
                escrow.setLimits(lowV, lowW);
            }
        }
        vm.warp(_now() + dt);

        Outcome oa = _perCall(a, 2, amount);
        Outcome ob = _channel(b, cum, cum + amount, cum == 0 ? 1 : 2);
        assertEq(uint8(ob), uint8(oa), "the channel door decides differently from _redeem");
        assertEq(
            escrow.escrowOf(a).spentInWindow,
            escrow.escrowOf(b).spentInWindow,
            "window counters diverged"
        );
        assertEq(escrow.escrowOf(a).balance, escrow.escrowOf(b).balance, "balances diverged");
    }
}
