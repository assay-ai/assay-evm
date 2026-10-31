// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.38;

import {Fixture} from "./helpers/Fixture.sol";
import {VoucherSigner} from "./helpers/VoucherSigner.sol";
import {BlockingUSDG} from "./helpers/BlockingUSDG.sol";
import {IAssayEscrow} from "../src/interfaces/IAssayEscrow.sol";
import {AssayEscrowStorage} from "../src/AssayEscrowStorage.sol";
import {Voucher} from "../src/Types.sol";
import {Constants} from "../src/Constants.sol";
import {Fee} from "../src/libraries/Fee.sol";
import "../src/Errors.sol";
import {SetHash} from "./helpers/SetHash.sol";
import {Vm, VmSafe} from "forge-std/Vm.sol";

/// The per-call memo of the redeem door and the grouped payouts of `collectHeldBatch`: answers stay
/// exact under real hash collisions (built with `SetHash`), refusals are unchanged, the books are
/// exact, and a redemption makes no call that could change a cached answer.
contract AssayEscrowMemoTest is Fixture {
    bytes32 internal ds;
    uint256 internal buyer2Key = 0xB0FFE2;
    address internal buyer2;

    function setUp() public override {
        super.setUp();
        ds = escrow.DOMAIN_SEPARATOR();
        buyer2 = vm.addr(buyer2Key);
        _arm(escrow, buyer, 100e6);
        _arm(escrow, buyer2, 100e6);
    }

    function _arm(IAssayEscrow e, address who, uint64 amt) internal {
        _fund(who, amt);
        vm.startPrank(who);
        usdg.approve(address(e), amt);
        e.deposit(amt);
        e.setLimits(10e6, 100e6);
        vm.stopPrank();
    }

    function _v(address payer, address prov, uint64 amount, uint64 seq)
        internal
        view
        returns (Voucher memory)
    {
        return Voucher({
            payer: payer,
            provider: prov,
            amount: amount,
            resourceHash: keccak256("r"),
            requestHash: keccak256(abi.encode(payer, seq)),
            seq: seq,
            issuedAt: uint64(vm.getBlockTimestamp()),
            expiresAt: uint64(vm.getBlockTimestamp()) + 300
        });
    }

    function _books(IAssayEscrow e, address token) internal view {
        assertGe(
            BlockingUSDG(token).balanceOf(address(e)),
            uint256(e.totalEscrowed()) + e.totalHeld(),
            "solvency"
        );
    }

    // ------------------------------------------------------------------ C1

    /// Item 0 seeds the memo with buyer, provider and 0. Item 1 is signed by a delegate whose
    /// address collides with the buyer's in the memo's set (a batch of 2 has an 8-word set) and
    /// which is blocked: the probe must miss and `assertActive` must run and refuse.
    function test_C1_collidingBlockedDelegateIsStillRefused() public {
        uint256 dk = SetHash.grindKey(buyer, 8, 0xD000);
        assertEq(SetHash.escrowSlot(vm.addr(dk), 8), SetHash.escrowSlot(buyer, 8), "no collision");
        address d = vm.addr(dk);
        vm.prank(buyer);
        escrow.authorizeDelegate(d, 1e6, 10e6, uint64(block.timestamp + 30 days));
        vm.prank(admin);
        config.setBlocked(d, true);

        Voucher[] memory vs = new Voucher[](2);
        bytes[] memory sigs = new bytes[](2);
        vs[0] = _v(buyer, provider, 1e6, 1);
        sigs[0] = VoucherSigner.signVoucher(buyerKey, ds, vs[0]);
        vs[1] = _v(buyer, provider, 1e6, 2);
        sigs[1] = VoucherSigner.signVoucher(dk, ds, vs[1]);
        vm.prank(redeemer);
        vm.expectRevert(AddressBlocked.selector);
        escrow.redeemVoucherBatch(vs, sigs);
    }

    /// A second provider colliding with the first in the stake memo (and in the active set) and
    /// below the floor must still be refused.
    function test_C1_collidingUnstakedProviderIsStillRefused() public {
        address p2 = SetHash.grindAddr(provider, 4, 1); // same slot in the 4-word stake set
        assertTrue(p2 != provider);
        Voucher[] memory vs = new Voucher[](2);
        bytes[] memory sigs = new bytes[](2);
        vs[0] = _v(buyer, provider, 1e6, 1);
        vs[1] = _v(buyer, p2, 1e6, 2);
        sigs[0] = VoucherSigner.signVoucher(buyerKey, ds, vs[0]);
        sigs[1] = VoucherSigner.signVoucher(buyerKey, ds, vs[1]);
        vm.prank(redeemer);
        vm.expectRevert(ProviderBelowMinimumStake.selector);
        escrow.redeemVoucherBatch(vs, sigs);
    }

    /// A 64-item batch over 2 payers and 8 colliding providers: the deferred totals equal the
    /// per-item sums, and the pooled solvency identity holds.
    function test_C1_deferredTotalsAreExactOn64Items() public {
        address[8] memory ps;
        for (uint256 j = 0; j < 8; j++) {
            // all in `provider`'s slot of the 128-word stake set of a 64-item batch
            ps[j] = SetHash.grindAddr(provider, 128, (j + 1) * 1_000_000);
            _setBonded(ps[j], MINIMUM_STAKE);
        }
        Voucher[] memory vs = new Voucher[](64);
        bytes[] memory sigs = new bytes[](64);
        uint256 sum;
        for (uint256 i = 0; i < 64; i++) {
            address payer = i % 2 == 0 ? buyer : buyer2;
            uint64 amt = uint64(10_000 + i * 1_000);
            vs[i] = _v(payer, ps[i % 8], amt, uint64(i / 2 + 1));
            sigs[i] = VoucherSigner.signVoucher(i % 2 == 0 ? buyerKey : buyer2Key, ds, vs[i]);
            sum += amt;
        }
        uint128 te = escrow.totalEscrowed();
        uint128 th = escrow.totalHeld();
        vm.prank(redeemer);
        escrow.redeemVoucherBatch(vs, sigs);
        assertEq(escrow.totalEscrowed(), te - sum);
        assertEq(escrow.totalHeld(), th + sum);
        _books(escrow, address(usdg));
    }

    // ------------------------------------------------------------------ C4

    function _redeemOne(
        IAssayEscrow e,
        address payer,
        uint256 pk,
        address prov,
        uint64 amt,
        uint64 seq
    ) internal {
        Voucher memory v = _v(payer, prov, amt, seq);
        bytes memory sig = VoucherSigner.signVoucher(pk, e.DOMAIN_SEPARATOR(), v);
        vm.prank(redeemer);
        e.redeemVoucher(v, sig);
    }

    /// Four providers that all land on one slot of the 32-word provider map, with repeats:
    /// each provider gets exactly the sum of its own items, the treasury the fee total.
    function test_C4_collidingProvidersArePaidExactlyTheirOwn() public {
        address[4] memory ps;
        for (uint256 j = 0; j < 4; j++) {
            ps[j] = j == 0
                ? address(0xC0FFEE0005)
                : SetHash.grindAddr(address(0xC0FFEE0005), 32, j * 1_000_000);
            _setBonded(ps[j], MINIMUM_STAKE);
        }
        uint256 n = 12;
        address[] memory payers = new address[](n);
        uint64[] memory seqs = new uint64[](n);
        uint256[4] memory want;
        uint256 fees;
        for (uint256 i = 0; i < n; i++) {
            bool b1 = i % 3 != 0;
            uint64 amt = uint64(1_000_003 + i * 7_777);
            address prov = ps[(i * 7) % 4];
            uint64 seq = uint64(i + 1);
            _redeemOne(escrow, b1 ? buyer : buyer2, b1 ? buyerKey : buyer2Key, prov, amt, seq);
            payers[i] = b1 ? buyer : buyer2;
            seqs[i] = seq;
            (uint64 fee, uint64 pa) = Fee.splitFee(amt, TAKE_RATE_BPS);
            want[(i * 7) % 4] += pa;
            fees += fee;
        }
        vm.warp(block.timestamp + Constants.DEFAULT_COLLECT_HOLD_SECONDS);
        uint256 t0 = usdg.balanceOf(treasury);
        vm.prank(redeemer);
        escrow.collectHeldBatch(payers, seqs);
        for (uint256 j = 0; j < 4; j++) {
            assertEq(usdg.balanceOf(ps[j]), want[j], "provider share");
        }
        assertEq(usdg.balanceOf(treasury) - t0, fees, "fees");
        assertEq(escrow.totalHeld(), 0);
        _books(escrow, address(usdg));
    }

    /// A provider that recurs in the batch, at any position after the first, is paid ONCE: the
    /// provider map must find its existing entry, not open a second one (which would keep the
    /// totals but split the payout into several transfers).
    function test_C4_aRecurringProviderIsPaidInOneTransfer() public {
        address pB = address(0xB0B0);
        _setBonded(pB, MINIMUM_STAKE);
        // provider, pB, pB, provider, pB: two distinct providers, pB first seen at index 1.
        address[5] memory order = [provider, pB, pB, provider, pB];
        address[] memory payers = new address[](5);
        uint64[] memory seqs = new uint64[](5);
        for (uint256 i = 0; i < 5; i++) {
            _redeemOne(escrow, buyer, buyerKey, order[i], 1e6, uint64(i + 1));
            (payers[i], seqs[i]) = (buyer, uint64(i + 1));
        }
        vm.warp(block.timestamp + Constants.DEFAULT_COLLECT_HOLD_SECONDS);
        (uint64 fee, uint64 pa) = Fee.splitFee(1e6, TAKE_RATE_BPS);
        // Exactly one transfer each, carrying the recipient's whole total.
        vm.expectCall(
            address(usdg),
            abi.encodeWithSignature("transfer(address,uint256)", provider, 2 * uint256(pa)),
            1
        );
        vm.expectCall(
            address(usdg),
            abi.encodeWithSignature("transfer(address,uint256)", pB, 3 * uint256(pa)),
            1
        );
        vm.expectCall(
            address(usdg),
            abi.encodeWithSignature("transfer(address,uint256)", treasury, 5 * uint256(fee)),
            1
        );
        vm.prank(redeemer);
        escrow.collectHeldBatch(payers, seqs);
        assertEq(usdg.balanceOf(pB), 3 * uint256(pa));
    }

    function test_C4_duplicateItemReverts() public {
        _redeemOne(escrow, buyer, buyerKey, provider, 1e6, 1);
        _redeemOne(escrow, buyer, buyerKey, provider, 1e6, 2);
        vm.warp(block.timestamp + Constants.DEFAULT_COLLECT_HOLD_SECONDS);
        address[] memory payers = new address[](3);
        uint64[] memory seqs = new uint64[](3);
        (payers[0], payers[1], payers[2]) = (buyer, buyer, buyer);
        (seqs[0], seqs[1], seqs[2]) = (1, 2, 1);
        vm.prank(redeemer);
        vm.expectRevert(HeldPaymentNotHeld.selector);
        escrow.collectHeldBatch(payers, seqs);
    }

    /// Blocking a buyer freezes its collection even when its provider and the 0 third were
    /// already memoised by an earlier item of another buyer.
    function test_C4_blockedPayerMidBatchFreezesTheBatch() public {
        _redeemOne(escrow, buyer2, buyer2Key, provider, 1e6, 1);
        _redeemOne(escrow, buyer, buyerKey, provider, 1e6, 1);
        vm.prank(admin);
        config.setBlocked(buyer, true);
        vm.warp(block.timestamp + Constants.DEFAULT_COLLECT_HOLD_SECONDS);
        address[] memory payers = new address[](2);
        uint64[] memory seqs = new uint64[](2);
        (payers[0], payers[1]) = (buyer2, buyer);
        (seqs[0], seqs[1]) = (1, 1);
        vm.prank(redeemer);
        vm.expectRevert(AddressBlocked.selector);
        escrow.collectHeldBatch(payers, seqs);
    }

    /// A stranger (permissionless +7 d path) cannot slip a not-yet-timed-out item behind a
    /// timed-out one.
    function test_C4_strangerCannotMixAnUntimedItem() public {
        _redeemOne(escrow, buyer, buyerKey, provider, 1e6, 1);
        vm.warp(
            block.timestamp + Constants.DEFAULT_COLLECT_HOLD_SECONDS
                + Constants.HELD_TIMEOUT_SECONDS
        );
        _redeemOne(escrow, buyer2, buyer2Key, provider, 1e6, 1);
        vm.warp(block.timestamp + Constants.DEFAULT_COLLECT_HOLD_SECONDS);
        address[] memory payers = new address[](2);
        uint64[] memory seqs = new uint64[](2);
        (payers[0], payers[1]) = (buyer, buyer2);
        (seqs[0], seqs[1]) = (1, 1);
        vm.prank(address(0xBAD));
        vm.expectRevert(HeldNotYetCollectable.selector);
        escrow.collectHeldBatch(payers, seqs);
    }

    /// A token-level frozen provider (Paxos-style blocklist) makes the aggregated payout revert,
    /// and the WHOLE batch with it: no item is left Collected without its money, and the other
    /// providers' items can still be collected without it.
    function test_C4_tokenFrozenProviderRevertsTheWholeBatchAtomically() public {
        address p2 = address(0xF2F2);
        _setBonded(p2, MINIMUM_STAKE);
        BlockingUSDG tok = new BlockingUSDG(p2);
        IAssayEscrow e2 = _deployEscrow(address(tok));
        tok.mint(buyer, 50e6);
        vm.startPrank(buyer);
        tok.approve(address(e2), 50e6);
        e2.deposit(50e6);
        e2.setLimits(10e6, 100e6);
        vm.stopPrank();
        _redeemOne(e2, buyer, buyerKey, provider, 1e6, 1);
        _redeemOne(e2, buyer, buyerKey, p2, 1e6, 2);
        _redeemOne(e2, buyer, buyerKey, provider, 1e6, 3);
        vm.warp(block.timestamp + Constants.DEFAULT_COLLECT_HOLD_SECONDS);

        address[] memory payers = new address[](3);
        uint64[] memory seqs = new uint64[](3);
        (payers[0], payers[1], payers[2]) = (buyer, buyer, buyer);
        (seqs[0], seqs[1], seqs[2]) = (1, 2, 3);
        uint128 th = e2.totalHeld();
        vm.prank(redeemer);
        vm.expectRevert(abi.encodeWithSelector(BlockingUSDG.TransferBlocked.selector, p2));
        e2.collectHeldBatch(payers, seqs);
        assertEq(e2.totalHeld(), th, "totalHeld moved on a reverted batch");
        assertEq(uint8(e2.held(buyer, 1).status), uint8(AssayEscrowStorage.HeldStatus.Held));

        address[] memory p1 = new address[](2);
        uint64[] memory s1 = new uint64[](2);
        (p1[0], p1[1]) = (buyer, buyer);
        (s1[0], s1[1]) = (1, 3);
        vm.prank(redeemer);
        e2.collectHeldBatch(p1, s1);
        (, uint64 pa) = Fee.splitFee(1e6, TAKE_RATE_BPS);
        assertEq(tok.balanceOf(provider), 2 * uint256(pa));
        _books(e2, address(tok));
        // The frozen provider's item stays refundable inside its window: no stuck money.
        vm.prank(redeemer);
        e2.refundHeld(buyer, 2);
        assertEq(e2.totalHeld(), 0);
    }

    // ------------------------------------------------------------------ pins

    /// `SetHash` builds the collisions above from the same multiplier as the contracts.
    function test_setHashMatchesTheSources() public {
        string memory lit = "0x9e3779b97f4a7c15f39cc0605cedc8341082276bf3a27251";
        assertTrue(vm.contains(vm.readFile("src/AssayEscrowStorage.sol"), lit), "escrow multiplier");
        assertTrue(
            vm.contains(vm.readFile("src/libraries/ChannelDoor.sol"), lit), "door multiplier"
        );
        assertEq(SetHash.MUL, 0x9e3779b97f4a7c15f39cc0605cedc8341082276bf3a27251);
    }

    /// The memo is only sound while a redemption cannot change what it caches: the batch makes no
    /// state-changing call (every call out of the escrow is a STATICCALL to config or stake) and
    /// touches no token.
    function test_redeemBatchMakesOnlyStaticCallsOut() public {
        Voucher[] memory vs = new Voucher[](3);
        bytes[] memory sigs = new bytes[](3);
        for (uint256 i = 0; i < 3; i++) {
            vs[i] = _v(i == 1 ? buyer2 : buyer, provider, 1e6, uint64(i + 1));
            sigs[i] = VoucherSigner.signVoucher(i == 1 ? buyer2Key : buyerKey, ds, vs[i]);
        }
        address ext = escrow.EXTENSION();
        address impl = address(uint160(uint256(vm.load(address(escrow), IMPL_SLOT))));
        vm.prank(redeemer);
        vm.startStateDiffRecording();
        escrow.redeemVoucherBatch(vs, sigs);
        Vm.AccountAccess[] memory acc = vm.stopAndReturnStateDiff();
        uint256 statics;
        for (uint256 i = 0; i < acc.length; i++) {
            Vm.AccountAccess memory a = acc[i];
            bool fromEscrow =
                a.accessor == address(escrow) || a.accessor == impl || a.accessor == ext;
            if (!fromEscrow || a.account == address(escrow)) continue;
            assertTrue(a.account != address(usdg), "a redemption touched the token");
            if (a.kind == VmSafe.AccountAccessKind.StaticCall) {
                statics++;
                assertTrue(
                    a.account == address(config) || a.account == address(stake) || a.account == ext
                        || a.account == impl || uint160(a.account) <= 0xff, // precompiles: ecrecover
                    "static call to an unexpected account"
                );
            } else if (a.kind == VmSafe.AccountAccessKind.Call) {
                revert("a redemption made a state-changing call");
            }
        }
        assertGt(statics, 0, "no static call recorded: the pin is not measuring anything");
    }

    /// The fullest sets a batch can make: 64 payers, 64 delegates and 64 providers, all distinct
    /// (192 entries in the 256-word active set, 64 in the 128-word stake set), then a collect of
    /// all 64 with 64 distinct providers (64 entries in the 128-word provider map). Every probe
    /// ends, the books are exact and each provider gets its own share.
    function test_fullestSetsRedeemAndCollect() public {
        uint256 n = 64;
        Voucher[] memory vs = new Voucher[](n);
        bytes[] memory sigs = new bytes[](n);
        address[] memory payers = new address[](n);
        uint64[] memory seqs = new uint64[](n);
        address[] memory provs = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            uint256 bk = 0xA0000 + i;
            uint256 dk = 0xB0000 + i;
            address b = vm.addr(bk);
            provs[i] = address(uint160(0xC0000 + i));
            _setBonded(provs[i], MINIMUM_STAKE);
            _arm(escrow, b, 2e6);
            vm.prank(b);
            escrow.authorizeDelegate(vm.addr(dk), 1e6, 2e6, uint64(block.timestamp + 30 days));
            vs[i] = _v(b, provs[i], 1e6, 1);
            sigs[i] = VoucherSigner.signVoucher(dk, ds, vs[i]);
            (payers[i], seqs[i]) = (b, 1);
        }
        uint128 te = escrow.totalEscrowed();
        vm.prank(redeemer);
        escrow.redeemVoucherBatch(vs, sigs);
        assertEq(escrow.totalEscrowed(), te - n * 1e6);
        assertEq(escrow.totalHeld(), n * 1e6);

        vm.warp(block.timestamp + Constants.DEFAULT_COLLECT_HOLD_SECONDS);
        uint256 t0 = usdg.balanceOf(treasury);
        vm.prank(redeemer);
        escrow.collectHeldBatch(payers, seqs);
        (uint64 fee, uint64 pa) = Fee.splitFee(1e6, TAKE_RATE_BPS);
        for (uint256 i = 0; i < n; i++) {
            assertEq(usdg.balanceOf(provs[i]), pa, "provider share");
        }
        assertEq(usdg.balanceOf(treasury) - t0, n * uint256(fee), "fees");
        assertEq(escrow.totalHeld(), 0);
        _books(escrow, address(usdg));
    }

    bytes32 internal constant IMPL_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
}
