// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.38;

import {Vm} from "forge-std/Vm.sol";
import {AssayEscrowChannelTest} from "./AssayEscrow.channel.t.sol";
import {VoucherSigner} from "./helpers/VoucherSigner.sol";
import {ChannelDoor} from "../src/libraries/ChannelDoor.sol";
import {AssayEscrow} from "../src/AssayEscrow.sol";
import {ChannelVoucher, ChannelRef, Voucher} from "../src/Types.sol";
import {Constants} from "../src/Constants.sol";
import {SetHash} from "./helpers/SetHash.sol";

/// The channel door's batch path with the calldata forward, the lookup table and the per-item
/// memory reuse, the open event, and both doors on one payer's books.
contract AssayEscrowChannelBatchTest is AssayEscrowChannelTest {
    /// E5: `ChannelOpened` exactly once per key, on the first SETTLEMENT (a zero-charge one
    /// included), never on a skipped item, never again.
    function test_E5_openedOncePerKey_evenWhenFirstItemSkipsThenSettles() public {
        // First attempt is skipped (BaseMismatch: from=0 claimed but... use Expired instead).
        ChannelVoucher memory v0 = _cv(CH, 100_000, 1);
        bytes memory s0 = _sign(delegateKey, v0);
        vm.warp(block.timestamp + 240 + Constants.REDEEM_GRACE_SECONDS + 1);
        vm.recordLogs();
        _settle(v0, s0, 0, 100_000);
        assertEq(_count(vm.getRecordedLogs(), ChannelDoor.ChannelOpened.selector), 0, "skip opened");

        ChannelVoucher memory v1 = _cv(CH, 100_000, 1);
        vm.recordLogs();
        _settle(v1, _sign(delegateKey, v1), 0, 0); // pure waiver first
        assertEq(_count(vm.getRecordedLogs(), ChannelDoor.ChannelOpened.selector), 1, "first");

        ChannelVoucher memory v2 = _cv(CH, 300_000, 3);
        vm.recordLogs();
        _settle(v2, _sign(delegateKey, v2), 100_000, 200_000);
        assertEq(_count(vm.getRecordedLogs(), ChannelDoor.ChannelOpened.selector), 0, "again");
    }

    function _count(Vm.Log[] memory logs, bytes32 t) internal pure returns (uint256 n) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == t) n++;
        }
    }

    /// The calldata forward and the per-item memory reuse across mixed settle paths in one batch
    /// (a third-hour item that folds or skips NoBucket, new buckets, a colliding provider, a
    /// Stake skip, Calls and BaseMismatch skips), then every channel's books against an
    /// independent per-item replay. Blocked and the full 64-item replay are in
    /// `AssayEscrowChannelReplayTest`; the fold itself is pinned in `AssayEscrowChannelTest`.
    function test_E1E4_mixedPathsBatchMatchesSingleItemReplay() public {
        // shares `provider`'s stake slot in the 64-word table of a 7-item batch
        address p2 = SetHash.grindDoorAddr(provider, 64, 1);
        address p3 = address(0xBEEF03); // below the floor
        _setBonded(p2, MINIMUM_STAKE);

        // pre-state: lane-A holds two buckets of other hours (forces fold on the next settle)
        bytes32 A = keccak256("A");
        _settleLane(A, provider, 0, 100_000, 1, 100_000);
        vm.warp(block.timestamp + 3600);
        _settleLane(A, provider, 100_000, 200_000, 2, 100_000);
        vm.warp(block.timestamp + 3600);

        uint256 n = 7;
        ChannelVoucher[] memory vs = new ChannelVoucher[](n);
        uint64[] memory from = new uint64[](n);
        uint64[] memory ch = new uint64[](n);
        bytes memory sigs;
        vs[0] = _cvP(A, provider, 300_000, 3);
        from[0] = 200_000;
        ch[0] = 100_000; // fold or NoBucket
        vs[1] = _cvP(keccak256("B"), p2, 50_000, 1);
        ch[1] = 50_000; // new, colliding provider
        vs[2] = _cvP(keccak256("B"), p2, 90_000, 2);
        from[2] = 50_000;
        ch[2] = 40_000; // same bucket
        vs[3] = _cvP(keccak256("C"), p3, 10_000, 1);
        ch[3] = 10_000; // Stake skip
        vs[4] = _cvP(keccak256("D"), provider, 20_000, 1);
        from[4] = 7;
        ch[4] = 1; // BaseMismatch
        vs[5] = _cvP(keccak256("B"), p2, 95_000, 2);
        from[5] = 90_000;
        ch[5] = 5_000; // Calls skip
        vs[6] = _cvP(keccak256("E"), provider, 30_000, 1);
        ch[6] = 0; // pure waiver
        for (uint256 i = 0; i < n; i++) {
            sigs = abi.encodePacked(sigs, _sign(delegateKey, vs[i]));
        }

        uint256 snap = vm.snapshotState();
        // replay item by item
        for (uint256 i = 0; i < n; i++) {
            bytes memory sg = _sign(delegateKey, vs[i]);
            vm.prank(redeemer);
            escrow.settleChannels(_one(vs[i]), sg, _u(from[i]), _u(ch[i]));
        }
        uint256[5] memory w;
        bytes32[5] memory keys = [
            _k(A, provider),
            _k(keccak256("B"), p2),
            _k(keccak256("C"), p3),
            _k(keccak256("D"), provider),
            _k(keccak256("E"), provider)
        ];
        for (uint256 j = 0; j < 5; j++) {
            (w[j],,,) = escrow.channelBooks(keys[j], address(0));
        }
        uint128 te = escrow.totalEscrowed();
        uint128 h = _held();
        vm.revertToState(snap);

        vm.prank(redeemer);
        escrow.settleChannels(vs, sigs, from, ch);
        for (uint256 j = 0; j < 5; j++) {
            (uint256 x,,,) = escrow.channelBooks(keys[j], address(0));
            assertEq(x, w[j], "slot differs from replay");
        }
        assertEq(escrow.totalEscrowed(), te, "totalEscrowed");
        assertEq(_held(), h, "held");
        _assertBooks();
    }

    function _k(bytes32 ch_, address prov) internal view returns (bytes32) {
        return keccak256(abi.encode(buyer, delegate, prov, ch_));
    }

    function _cvP(bytes32 ch_, address prov, uint64 cum, uint32 calls)
        internal
        view
        returns (ChannelVoucher memory v)
    {
        v = _cv(ch_, cum, calls);
        v.provider = prov;
    }

    function _settleLane(bytes32 ch_, address prov, uint64 from, uint64 cum, uint32 calls, uint64 c)
        internal
    {
        ChannelVoucher memory v = _cvP(ch_, prov, cum, calls);
        _settle(v, _sign(delegateKey, v), from, c);
    }

    /// Both doors on one payer, interleaved, with C1 batch redeem and C4 batch collect: the
    /// pooled identity is exact (==, not >=) at every step.
    function test_C1C4E1_bothDoorsOnePayerExactBooks() public {
        bytes32 ds = escrow.DOMAIN_SEPARATOR();
        uint256 bal0 = usdg.balanceOf(address(escrow));
        Voucher[] memory pv = new Voucher[](3);
        bytes[] memory ps = new bytes[](3);
        for (uint256 i = 0; i < 3; i++) {
            pv[i] = Voucher({
                payer: buyer,
                provider: provider,
                amount: uint64(200_000 + i),
                resourceHash: bytes32(0),
                requestHash: bytes32(i),
                seq: uint64(i + 1),
                issuedAt: _now(),
                expiresAt: _now() + 300
            });
            ps[i] = VoucherSigner.signVoucher(i == 1 ? delegateKey : buyerKey, ds, pv[i]);
        }
        vm.prank(redeemer);
        escrow.redeemVoucherBatch(pv, ps);
        _exact(bal0);
        _settleD(0, 400_000, 4);
        _exact(bal0);
        vm.warp(block.timestamp + 2 * 3600);
        address[] memory payers = new address[](3);
        uint64[] memory seqs = new uint64[](3);
        for (uint256 i = 0; i < 3; i++) {
            (payers[i], seqs[i]) = (buyer, uint64(i + 1));
        }
        vm.prank(redeemer);
        escrow.collectHeldBatch(payers, seqs);
        uint64[] memory keep = new uint64[](1);
        vm.prank(redeemer);
        escrow.collectChannels(_ref(delegate), keep);
        uint256 out = 600_003 + 400_000;
        _exact(bal0 - out);
    }

    function _exact(uint256 bal) internal view {
        (,, uint128 totalUnpaid, uint128 held) = escrow.channelBooks(bytes32(0), address(0));
        assertEq(usdg.balanceOf(address(escrow)), bal, "balance");
        assertEq(
            bal,
            uint256(escrow.totalEscrowed()) + escrow.totalHeld() + held + totalUnpaid,
            "identity"
        );
    }
}
