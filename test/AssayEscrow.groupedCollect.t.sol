// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.38;

import {Vm} from "forge-std/Vm.sol";
import {Fixture} from "./helpers/Fixture.sol";
import {VoucherSigner} from "./helpers/VoucherSigner.sol";
import {AssayEscrowChannelTest} from "./AssayEscrow.channel.t.sol";
import {IAssayEscrow} from "../src/interfaces/IAssayEscrow.sol";
import {AssayEscrow} from "../src/AssayEscrow.sol";
import {ChannelDoor} from "../src/libraries/ChannelDoor.sol";
import {Voucher, ChannelVoucher} from "../src/Types.sol";
import {Constants} from "../src/Constants.sol";
import "../src/Errors.sol";

/// Grouped payouts equal the item-by-item path for any mix of payers and providers (fuzzed), the
/// single-item redeem books both totals, and one address in several roles is still refused once
/// blocked.
contract AssayEscrowGroupedCollectTest is Fixture {
    uint256[3] internal pks = [uint256(0xA11CE1), 0xA11CE2, 0xA11CE3];
    address[5] internal provs;

    function setUp() public override {
        super.setUp();
        for (uint256 i = 0; i < 3; i++) {
            address b = vm.addr(pks[i]);
            _fund(b, 1_000e6);
            vm.startPrank(b);
            usdg.approve(address(escrow), 1_000e6);
            escrow.deposit(1_000e6);
            escrow.setLimits(100e6, 1_000e6);
            vm.stopPrank();
        }
        for (uint256 j = 0; j < 5; j++) {
            provs[j] = address(uint160(0xD00D00 + j));
            _setBonded(provs[j], MINIMUM_STAKE);
        }
        // provider == treasury and provider == a buyer are both legal shapes
        provs[3] = treasury;
        _setBonded(treasury, MINIMUM_STAKE);
    }

    /// C4: for random batches, the batch collect pays every recipient exactly what the
    /// item-by-item path pays, and leaves identical books.
    function testFuzz_C4_batchEqualsItemByItem(uint256 seed, uint8 nRaw) public {
        uint256 n = bound(nRaw, 2, 40);
        bytes32 ds = escrow.DOMAIN_SEPARATOR();
        address[] memory payers = new address[](n);
        uint64[] memory seqs = new uint64[](n);
        uint64[3] memory next = [uint64(1), 1, 1];
        for (uint256 i = 0; i < n; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            uint256 b = r % 3;
            address payer = vm.addr(pks[b]);
            address prov = provs[(r >> 8) % 5];
            uint64 amt = uint64(1 + ((r >> 16) % 3e6));
            uint64 seq = next[b]++;
            Voucher memory v = Voucher({
                payer: payer,
                provider: prov,
                amount: amt,
                resourceHash: bytes32(r),
                requestHash: bytes32(i),
                seq: seq,
                issuedAt: uint64(block.timestamp),
                expiresAt: uint64(block.timestamp) + 300
            });
            bytes memory sig = VoucherSigner.signVoucher(pks[b], ds, v);
            vm.prank(redeemer);
            escrow.redeemVoucher(v, sig);
            (payers[i], seqs[i]) = (payer, seq);
        }
        vm.warp(block.timestamp + Constants.DEFAULT_COLLECT_HOLD_SECONDS);

        uint256 snap = vm.snapshotState();
        for (uint256 i = 0; i < n; i++) {
            vm.prank(redeemer);
            escrow.collectHeld(payers[i], seqs[i]);
        }
        uint256[5] memory want;
        for (uint256 j = 0; j < 5; j++) {
            want[j] = usdg.balanceOf(provs[j]);
        }
        uint256 wantEsc = usdg.balanceOf(address(escrow));
        uint128 wantHeld = escrow.totalHeld();
        uint128 wantTe = escrow.totalEscrowed();
        vm.revertToState(snap);

        vm.prank(redeemer);
        escrow.collectHeldBatch(payers, seqs);
        for (uint256 j = 0; j < 5; j++) {
            assertEq(usdg.balanceOf(provs[j]), want[j], "recipient");
        }
        assertEq(usdg.balanceOf(address(escrow)), wantEsc, "escrow balance");
        assertEq(escrow.totalHeld(), wantHeld, "totalHeld");
        assertEq(escrow.totalEscrowed(), wantTe, "totalEscrowed");
        assertEq(wantHeld, 0);
    }

    /// C1: a single-item redeem still books both totals.
    function test_C1_singleRedeemBooks() public {
        bytes32 ds = escrow.DOMAIN_SEPARATOR();
        address b = vm.addr(pks[0]);
        Voucher memory v =
            Voucher(b, provs[0], 7, 0, 0, 1, uint64(block.timestamp), uint64(block.timestamp) + 300);
        uint128 te = escrow.totalEscrowed();
        vm.prank(redeemer);
        escrow.redeemVoucher(v, VoucherSigner.signVoucher(pks[0], ds, v));
        assertEq(escrow.totalEscrowed(), te - 7);
        assertEq(escrow.totalHeld(), 7);
    }

    /// C1: a provider that is ALSO a payer in the same batch and becomes refused in one role
    /// must not be cached as passing in another. (Only passes are cached; a blocked address
    /// never passes, whatever role.)
    function test_C1_sameAddressManyRolesBlocked() public {
        bytes32 ds = escrow.DOMAIN_SEPARATOR();
        address b0 = vm.addr(pks[0]);
        address b1 = vm.addr(pks[1]);
        _setBonded(b1, MINIMUM_STAKE);
        Voucher[] memory vs = new Voucher[](2);
        bytes[] memory sigs = new bytes[](2);
        vs[0] = Voucher(b0, b1, 7, 0, 0, 1, uint64(block.timestamp), uint64(block.timestamp) + 300);
        vs[1] = Voucher(b1, b0, 7, 0, 0, 1, uint64(block.timestamp), uint64(block.timestamp) + 300);
        sigs[0] = VoucherSigner.signVoucher(pks[0], ds, vs[0]);
        sigs[1] = VoucherSigner.signVoucher(pks[1], ds, vs[1]);
        vm.prank(admin);
        config.setBlocked(b1, true);
        vm.prank(redeemer);
        vm.expectRevert(AddressBlocked.selector);
        escrow.redeemVoucherBatch(vs, sigs);
    }
}

/// The calldata forward's head-offset guard, two items on one new key, and a full 64-item settle
/// batch against an item-by-item replay.
contract AssayEscrowChannelReplayTest is AssayEscrowChannelTest {
    /// A head-pointing offset that Solidity's own decoder accepts (charges -> its own head word at
    /// 0x60, length 0x60 = 96, padded so it fits) reverts empty and moves nothing. The core's
    /// `o < 0x80` guard refuses it first; without the guard the library's decoder still refuses
    /// it (a shifted head offset reads a length of 0x160 or more), so the guard is defence in
    /// depth and its mutant is equivalent (MUTATION-LOG, D-30).
    function test_E1_headOffsetAcceptedBySolidityHitsTheGuard() public {
        ChannelVoucher memory v = _cv(CH, 100_000, 1);
        bytes memory good = abi.encodeCall(
            AssayEscrow.settleChannels, (_one(v), _sign(delegateKey, v), _u(0), _u(100_000))
        );
        assembly {
            mstore(add(good, add(0x20, add(4, 0x60))), 0x60)
        }
        bytes memory data = abi.encodePacked(good, new bytes(96 * 32));
        vm.prank(redeemer);
        (bool ok, bytes memory ret) = address(escrow).call(data);
        assertFalse(ok);
        assertEq(ret.length, 0, "not the guard's empty revert");
        assertEq(_slot(delegate).settled, 0);
    }

    /// E5: two items for one NEW key in one batch: exactly one ChannelOpened, on the first.
    function test_E5_twoItemsSameNewKeyOneBatch() public {
        ChannelVoucher[] memory vs = new ChannelVoucher[](2);
        vs[0] = _cv(CH, 100_000, 1);
        vs[1] = _cv(CH, 250_000, 2);
        bytes memory sigs = abi.encodePacked(_sign(delegateKey, vs[0]), _sign(delegateKey, vs[1]));
        uint64[] memory from = new uint64[](2);
        uint64[] memory ch = new uint64[](2);
        from[1] = 100_000;
        ch[0] = 100_000;
        ch[1] = 150_000;
        vm.recordLogs();
        vm.prank(redeemer);
        escrow.settleChannels(vs, sigs, from, ch);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 opened;
        uint256 settled;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == ChannelDoor.ChannelOpened.selector) {
                opened++;
                (address signer, bytes32 id) = abi.decode(logs[i].data, (address, bytes32));
                assertEq(signer, delegate);
                assertEq(id, CH);
                assertEq(logs[i].topics[1], _key(delegate));
            }
            if (logs[i].topics[0] == ChannelDoor.ChannelSettled.selector) settled++;
        }
        assertEq(opened, 1);
        assertEq(settled, 2);
        assertEq(_slot(delegate).settled, 250_000);
    }

    /// E4 + fmp reset: a full 64-item batch, many distinct keys and repeated payer/provider,
    /// equals the item-by-item replay on every slot and the totals.
    function test_E4_full64BatchEqualsReplay() public {
        uint256 n = 64;
        ChannelVoucher[] memory vs = new ChannelVoucher[](n);
        uint64[] memory from = new uint64[](n);
        uint64[] memory ch = new uint64[](n);
        bytes memory sigs;
        address p3 = address(0xBEEF03); // unstaked
        for (uint256 i = 0; i < n; i++) {
            vs[i] = _cv(
                keccak256(abi.encode("lane", i % 16)),
                uint64(1_000 * (i / 16 + 1)),
                uint32(i / 16 + 1)
            );
            if (i % 7 == 3) vs[i].provider = p3;
            from[i] = i < 16 ? 0 : uint64(1_000 * (i / 16));
            ch[i] = uint64(i % 5 == 0 ? 0 : 1_000);
            sigs = abi.encodePacked(sigs, _sign(i % 2 == 0 ? delegateKey : buyerKey, vs[i]));
        }
        uint256 snap = vm.snapshotState();
        for (uint256 i = 0; i < n; i++) {
            bytes memory sg = _sign(i % 2 == 0 ? delegateKey : buyerKey, vs[i]);
            vm.prank(redeemer);
            escrow.settleChannels(_one(vs[i]), sg, _u(from[i]), _u(ch[i]));
        }
        uint256[] memory w = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            (w[i],,,) = escrow.channelBooks(
                ChannelDoor.keyOf(
                    buyer, i % 2 == 0 ? delegate : buyer, vs[i].provider, vs[i].channelId
                ),
                address(0)
            );
        }
        uint128 te = escrow.totalEscrowed();
        uint128 h = _held();
        vm.revertToState(snap);
        vm.prank(redeemer);
        escrow.settleChannels(vs, sigs, from, ch);
        for (uint256 i = 0; i < n; i++) {
            (uint256 x,,,) = escrow.channelBooks(
                ChannelDoor.keyOf(
                    buyer, i % 2 == 0 ? delegate : buyer, vs[i].provider, vs[i].channelId
                ),
                address(0)
            );
            assertEq(x, w[i], "slot");
        }
        assertEq(escrow.totalEscrowed(), te);
        assertEq(_held(), h);
        assertGt(h, 0, "nothing settled: test measures nothing");
        _assertBooks();
    }
}
