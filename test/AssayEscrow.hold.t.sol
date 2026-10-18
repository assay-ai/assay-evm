// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {Fixture} from "./helpers/Fixture.sol";
import {VoucherSigner} from "./helpers/VoucherSigner.sol";
import {AssayEscrow} from "../src/AssayEscrow.sol";
import {Voucher, ParamSet} from "../src/Types.sol";
import {Constants} from "../src/Constants.sol";
import {Fee} from "../src/libraries/Fee.sol";
import "../src/Errors.sol";

/// Redeem into hold (analysis §5): a redemption moves the amount from the buyer's balance into
/// `held[payer][seq]` and pays nobody; `collectHeld` pays the provider and the treasury by the
/// split frozen at redemption, `refundHeld` returns the amount to the buyer's balance. The
/// redeemer collects from `collectableAt` and refunds until `collectableAt + HELD_TIMEOUT`;
/// after that anybody may collect, in the provider's favour.
contract AssayEscrowHoldTest is Fixture {
    address internal stranger = address(0xDEAD);
    bytes32 internal ds;

    uint64 internal constant HOLD = Constants.DEFAULT_COLLECT_HOLD_SECONDS;
    uint64 internal constant TIMEOUT = Constants.HELD_TIMEOUT_SECONDS;

    event PaymentHeld(
        address indexed payer,
        uint64 indexed seq,
        address indexed provider,
        uint64 amount,
        uint64 collectableAt
    );
    event HeldCollected(
        address indexed payer,
        uint64 indexed seq,
        address indexed provider,
        uint64 providerAmount,
        uint64 fee
    );
    event HeldRefunded(address indexed payer, uint64 indexed seq, uint64 amount);
    event VoucherRedeemed(
        address indexed payer,
        address indexed provider,
        bytes32 requestHash,
        bytes32 resourceHash,
        uint64 amount,
        uint64 fee,
        uint64 seq,
        uint16 takeRateBps,
        uint64 spentInWindow
    );
    event CollectHoldSet(uint64 previous, uint64 next);

    function setUp() public virtual override {
        super.setUp();
        ds = escrow.DOMAIN_SEPARATOR();
        _fund(buyer, 10_000_000);
        vm.startPrank(buyer);
        usdg.approve(address(escrow), 10_000_000);
        escrow.deposit(10_000_000);
        escrow.setLimits(1_000_000, 5_000_000);
        vm.stopPrank();
    }

    // --- helpers -----------------------------------------------------------------------------

    function _v(uint64 amount, uint64 seq) internal view returns (Voucher memory) {
        return Voucher({
            payer: buyer,
            provider: provider,
            amount: amount,
            resourceHash: keccak256("resource"),
            requestHash: keccak256(abi.encode("hold", seq)),
            seq: seq,
            issuedAt: uint64(vm.getBlockTimestamp()),
            expiresAt: uint64(vm.getBlockTimestamp()) + 300
        });
    }

    function _redeem(uint64 amount, uint64 seq) internal returns (AssayEscrow.HeldPayment memory) {
        Voucher memory v = _v(amount, seq);
        bytes memory sig = VoucherSigner.signVoucher(buyerKey, ds, v);
        vm.prank(redeemer);
        escrow.redeemVoucher(v, sig);
        return escrow.held(buyer, seq);
    }

    function _collectAs(address who, uint64 seq) internal {
        vm.prank(who);
        escrow.collectHeld(buyer, seq);
    }

    function _refund(uint64 seq) internal {
        vm.prank(redeemer);
        escrow.refundHeld(buyer, seq);
    }

    function _expectCollect(address who, uint64 seq, bytes4 err) internal {
        vm.prank(who);
        vm.expectRevert(err);
        escrow.collectHeld(buyer, seq);
    }

    function _expectRefund(address who, uint64 seq, bytes4 err) internal {
        vm.prank(who);
        vm.expectRevert(err);
        escrow.refundHeld(buyer, seq);
    }

    function _status(uint64 seq) internal view returns (AssayEscrow.HeldStatus) {
        return escrow.held(buyer, seq).status;
    }

    function _setTakeRate(uint16 bps) internal {
        ParamSet memory p = config.params();
        p.takeRateBps = bps;
        vm.prank(admin);
        config.updateConfig(p);
    }

    function _one(address a) internal pure returns (address[] memory r) {
        r = new address[](1);
        r[0] = a;
    }

    // --- redeem writes a Held record ---------------------------------------------------------

    function test_redeemWritesAHeldRecordAndMovesNoToken() public {
        uint256 escrowTokensBefore = usdg.balanceOf(address(escrow));
        AssayEscrow.HeldPayment memory h = _redeem(250_000, 1);

        assertEq(h.provider, provider);
        assertEq(h.amount, 250_000);
        assertEq(h.takeRateBps, TAKE_RATE_BPS);
        assertEq(uint8(h.status), uint8(AssayEscrow.HeldStatus.Held));
        assertEq(h.collectableAt, uint64(vm.getBlockTimestamp()) + HOLD);

        assertEq(usdg.balanceOf(provider), 0, "the provider is not paid at redemption");
        assertEq(usdg.balanceOf(treasury), 0, "the treasury is not paid at redemption");
        assertEq(usdg.balanceOf(address(escrow)), escrowTokensBefore, "no token moved");

        assertEq(escrow.totalHeld(), 250_000);
        assertEq(escrow.totalEscrowed(), 9_750_000);
        assertEq(escrow.escrowOf(buyer).balance, 9_750_000);
        assertEq(escrow.escrowOf(buyer).totalRedeemed, 250_000);
        assertEq(escrow.escrowOf(buyer).spentInWindow, 250_000);
        assertEq(escrow.escrowOf(buyer).seqHigh, 1);
    }

    function test_anUnredeemedSeqReadsAsNoRecord() public view {
        AssayEscrow.HeldPayment memory h = escrow.held(buyer, 7);
        assertEq(uint8(h.status), uint8(AssayEscrow.HeldStatus.None));
        assertEq(h.amount, 0);
        assertEq(h.provider, address(0));
    }

    /// The redemption log is unchanged and the new one follows it: `PaymentHeld` first (it is
    /// written with the record), then `VoucherRedeemed` with the fee the collect will take.
    function test_redeemEmitsPaymentHeldAndVoucherRedeemed() public {
        Voucher memory v = _v(250_000, 1);
        bytes memory sig = VoucherSigner.signVoucher(buyerKey, ds, v);
        vm.expectEmit(true, true, true, true, address(escrow));
        emit PaymentHeld(buyer, 1, provider, 250_000, uint64(vm.getBlockTimestamp()) + HOLD);
        vm.expectEmit(true, true, true, true, address(escrow));
        emit VoucherRedeemed(
            buyer,
            provider,
            v.requestHash,
            v.resourceHash,
            250_000,
            25_000,
            1,
            TAKE_RATE_BPS,
            250_000
        );
        vm.prank(redeemer);
        escrow.redeemVoucher(v, sig);
    }

    // --- collect: who and when ---------------------------------------------------------------

    function test_collect_refusedBeforeCollectableAt() public {
        AssayEscrow.HeldPayment memory h = _redeem(250_000, 1);
        _expectCollect(redeemer, 1, HeldNotYetCollectable.selector);
        vm.warp(h.collectableAt - 1);
        _expectCollect(redeemer, 1, HeldNotYetCollectable.selector);
    }

    function test_collect_theRedeemerMayCollectAtCollectableAt() public {
        AssayEscrow.HeldPayment memory h = _redeem(250_000, 1);
        vm.warp(h.collectableAt);
        vm.expectEmit(true, true, true, true, address(escrow));
        emit HeldCollected(buyer, 1, provider, 225_000, 25_000);
        _collectAs(redeemer, 1);

        assertEq(usdg.balanceOf(provider), 225_000);
        assertEq(usdg.balanceOf(treasury), 25_000);
        assertEq(uint8(_status(1)), uint8(AssayEscrow.HeldStatus.Collected));
        assertEq(escrow.totalHeld(), 0);
        assertEq(escrow.totalEscrowed(), 9_750_000, "a collect leaves the balances alone");
        assertEq(usdg.balanceOf(address(escrow)), 9_750_000);
    }

    function test_collect_anybodyElseIsRefusedUntilTheTimeout() public {
        AssayEscrow.HeldPayment memory h = _redeem(250_000, 1);
        vm.warp(h.collectableAt);
        _expectCollect(stranger, 1, HeldNotYetCollectable.selector);
        _expectCollect(provider, 1, HeldNotYetCollectable.selector);
        _expectCollect(buyer, 1, HeldNotYetCollectable.selector);
        _expectCollect(admin, 1, HeldNotYetCollectable.selector);
        vm.warp(uint256(h.collectableAt) + TIMEOUT - 1);
        _expectCollect(stranger, 1, HeldNotYetCollectable.selector);
    }

    /// Operator silence favours the provider: after the timeout anybody collects, and the money
    /// still goes to the voucher's provider and the treasury, never to the caller.
    function test_collect_anybodyMayCollectAfterTheTimeout() public {
        AssayEscrow.HeldPayment memory h = _redeem(250_000, 1);
        vm.warp(uint256(h.collectableAt) + TIMEOUT);
        _collectAs(stranger, 1);
        assertEq(usdg.balanceOf(provider), 225_000);
        assertEq(usdg.balanceOf(treasury), 25_000);
        assertEq(usdg.balanceOf(stranger), 0);
        assertEq(uint8(_status(1)), uint8(AssayEscrow.HeldStatus.Collected));
    }

    // --- refund: who and when ----------------------------------------------------------------

    function test_refund_allowedFromRedemptionUntilJustBeforeTheTimeout() public {
        AssayEscrow.HeldPayment memory h = _redeem(250_000, 1);
        _redeem(100_000, 2);

        // seq 1 at once, seq 2 in the last second of the window
        vm.expectEmit(true, true, true, true, address(escrow));
        emit HeldRefunded(buyer, 1, 250_000);
        _refund(1);
        vm.warp(uint256(h.collectableAt) + TIMEOUT - 1);
        _refund(2);

        AssayEscrow.Escrow memory e = escrow.escrowOf(buyer);
        assertEq(e.balance, 10_000_000, "the whole amount is back in the balance");
        assertEq(e.totalRedeemed, 0, "the lifetime counter is lowered with it");
        assertEq(escrow.totalEscrowed(), 10_000_000);
        assertEq(escrow.totalHeld(), 0);
        assertEq(usdg.balanceOf(address(escrow)), 10_000_000, "a refund moves no token");
        assertEq(usdg.balanceOf(provider), 0);
        assertEq(uint8(_status(1)), uint8(AssayEscrow.HeldStatus.Refunded));
        assertEq(uint8(_status(2)), uint8(AssayEscrow.HeldStatus.Refunded));
        // the per-escrow identity survives the refund
        assertEq(e.totalFunded, uint256(e.balance) + e.totalRedeemed + e.totalWithdrawn);
    }

    function test_refund_refusedAtAndAfterTheTimeout() public {
        AssayEscrow.HeldPayment memory h = _redeem(250_000, 1);
        vm.warp(uint256(h.collectableAt) + TIMEOUT);
        _expectRefund(redeemer, 1, HeldRefundWindowClosed.selector);
        vm.warp(uint256(h.collectableAt) + TIMEOUT + 30 days);
        _expectRefund(redeemer, 1, HeldRefundWindowClosed.selector);
    }

    function test_refund_isRedeemerOnly() public {
        _redeem(250_000, 1);
        _expectRefund(stranger, 1, NotRedeemer.selector);
        _expectRefund(buyer, 1, NotRedeemer.selector);
        _expectRefund(provider, 1, NotRedeemer.selector);
        _expectRefund(admin, 1, NotRedeemer.selector);
        _expectRefund(owner, 1, NotRedeemer.selector);
    }

    /// Owner's decision: a refund does not hand back window capacity, for the escrow or for a
    /// delegate.
    function test_refund_leavesSpentInWindowUnchanged() public {
        _redeem(1_000_000, 1);
        _redeem(1_000_000, 2);
        _redeem(1_000_000, 3);
        _redeem(1_000_000, 4);
        _redeem(1_000_000, 5); // the 5_000_000 window is full
        uint64 spent = escrow.escrowOf(buyer).spentInWindow;
        uint64 startedAt = escrow.escrowOf(buyer).windowStartedAt;

        _refund(3);
        assertEq(escrow.escrowOf(buyer).spentInWindow, spent);
        assertEq(escrow.escrowOf(buyer).windowStartedAt, startedAt);

        Voucher memory v = _v(1, 6);
        bytes memory sig = VoucherSigner.signVoucher(buyerKey, ds, v);
        vm.prank(redeemer);
        vm.expectRevert(EscrowWindowLimitExceeded.selector);
        escrow.redeemVoucher(v, sig);
    }

    // --- one exit per record -----------------------------------------------------------------

    function test_aRecordLeavesHeldExactlyOnce() public {
        AssayEscrow.HeldPayment memory h = _redeem(250_000, 1);
        _redeem(100_000, 2);
        vm.warp(h.collectableAt);

        _collectAs(redeemer, 1);
        _expectCollect(redeemer, 1, HeldPaymentNotHeld.selector); // no double collect
        _expectRefund(redeemer, 1, HeldPaymentNotHeld.selector); // no refund after collect

        _refund(2);
        _expectRefund(redeemer, 2, HeldPaymentNotHeld.selector); // no double refund
        _expectCollect(redeemer, 2, HeldPaymentNotHeld.selector); // no collect after refund
        vm.warp(uint256(h.collectableAt) + TIMEOUT);
        _expectCollect(stranger, 2, HeldPaymentNotHeld.selector);

        assertEq(usdg.balanceOf(provider), 225_000, "paid once");
        assertEq(escrow.totalHeld(), 0);
    }

    function test_aSeqThatWasNeverRedeemedCannotBeCollectedOrRefunded() public {
        _expectCollect(redeemer, 1, HeldPaymentNotHeld.selector);
        _expectRefund(redeemer, 1, HeldPaymentNotHeld.selector);
        vm.warp(vm.getBlockTimestamp() + HOLD + TIMEOUT);
        _expectCollect(stranger, 1, HeldPaymentNotHeld.selector);
    }

    // --- pause and blocklist -----------------------------------------------------------------

    function test_thePauseFreezesCollectAndReleasesItIntact() public {
        AssayEscrow.HeldPayment memory h = _redeem(250_000, 1);
        vm.warp(uint256(h.collectableAt) + TIMEOUT);
        vm.prank(admin);
        config.setPaused(true);
        _expectCollect(redeemer, 1, ProgramPaused.selector);
        _expectCollect(stranger, 1, ProgramPaused.selector);

        vm.prank(admin);
        config.setPaused(false);
        _collectAs(stranger, 1);
        assertEq(usdg.balanceOf(provider), 225_000);
    }

    function test_theBlocklistFreezesCollectForThePayerAndForTheProvider() public {
        AssayEscrow.HeldPayment memory h = _redeem(250_000, 1);
        vm.warp(h.collectableAt);
        address[2] memory parties = [buyer, provider];
        for (uint256 i = 0; i < 2; i++) {
            vm.prank(admin);
            config.setBlocked(parties[i], true);
            _expectCollect(redeemer, 1, AddressBlocked.selector);
            vm.prank(admin);
            config.setBlocked(parties[i], false);
        }
        _collectAs(redeemer, 1);
        assertEq(usdg.balanceOf(provider), 225_000);
    }

    /// The refund is not pause-gated: it moves no token, only returns held money to a balance
    /// whose exits the pause still closes.
    function test_aRefundLandsWhilePaused() public {
        _redeem(250_000, 1);
        vm.prank(admin);
        config.setPaused(true);
        _refund(1);
        assertEq(escrow.escrowOf(buyer).balance, 10_000_000);
    }

    // --- withdraw cannot reach held money ----------------------------------------------------

    function test_withdrawCannotReachHeldMoney() public {
        AssayEscrow.HeldPayment memory h = _redeem(1_000_000, 1);
        vm.prank(buyer);
        escrow.requestWithdraw(10_000_000);
        vm.warp(vm.getBlockTimestamp() + Constants.WITHDRAW_DELAY_SECONDS);
        assertGe(vm.getBlockTimestamp(), h.collectableAt);
        vm.prank(buyer);
        escrow.withdraw();

        assertEq(usdg.balanceOf(buyer), 9_000_000, "the buyer takes the balance, not the hold");
        assertEq(escrow.escrowOf(buyer).balance, 0);
        assertEq(escrow.totalHeld(), 1_000_000);
        assertEq(usdg.balanceOf(address(escrow)), 1_000_000, "the held amount is still here");

        _collectAs(redeemer, 1);
        assertEq(usdg.balanceOf(provider), 900_000);
        assertEq(usdg.balanceOf(treasury), 100_000);
        assertEq(usdg.balanceOf(address(escrow)), 0);
    }

    /// A refund after the buyer emptied the escrow is withdrawable again.
    function test_aRefundAfterAWithdrawIsWithdrawable() public {
        _redeem(1_000_000, 1);
        vm.prank(buyer);
        escrow.requestWithdraw(10_000_000);
        vm.warp(vm.getBlockTimestamp() + Constants.WITHDRAW_DELAY_SECONDS);
        vm.prank(buyer);
        escrow.withdraw();
        _refund(1);
        vm.prank(buyer);
        escrow.requestWithdraw(1_000_000);
        vm.warp(vm.getBlockTimestamp() + Constants.WITHDRAW_DELAY_SECONDS);
        vm.prank(buyer);
        escrow.withdraw();
        assertEq(usdg.balanceOf(buyer), 10_000_000);
        assertEq(usdg.balanceOf(address(escrow)), 0);
    }

    // --- the collect hold (Config) -----------------------------------------------------------

    function test_setCollectHold_defaultBoundsAndAdminOnly() public {
        assertEq(config.collectHoldSeconds(), Constants.DEFAULT_COLLECT_HOLD_SECONDS);
        assertEq(Constants.DEFAULT_COLLECT_HOLD_SECONDS, 3_600);
        assertEq(Constants.MIN_COLLECT_HOLD_SECONDS, 60);
        assertEq(Constants.MAX_COLLECT_HOLD_SECONDS, 86_400);
        assertEq(Constants.HELD_TIMEOUT_SECONDS, 7 days);

        vm.startPrank(admin);
        vm.expectRevert(InvalidCollectHold.selector);
        config.setCollectHold(59);
        vm.expectRevert(InvalidCollectHold.selector);
        config.setCollectHold(86_401);
        vm.expectRevert(InvalidCollectHold.selector);
        config.setCollectHold(0);

        vm.expectEmit(true, true, true, true, address(config));
        emit CollectHoldSet(3_600, 60);
        config.setCollectHold(60);
        assertEq(config.collectHoldSeconds(), 60);
        vm.expectEmit(true, true, true, true, address(config));
        emit CollectHoldSet(60, 86_400);
        config.setCollectHold(86_400);
        assertEq(config.collectHoldSeconds(), 86_400);
        vm.stopPrank();

        address[4] memory notAdmin = [owner, redeemer, stranger, buyer];
        for (uint256 i = 0; i < notAdmin.length; i++) {
            vm.prank(notAdmin[i]);
            vm.expectRevert(NotAdmin.selector);
            config.setCollectHold(600);
        }
    }

    /// Each record keeps the hold and the take rate it was redeemed under.
    function test_theHoldAndTheTakeRateAreFrozenPerRecord() public {
        uint64 t0 = uint64(vm.getBlockTimestamp());
        _redeem(250_000, 1); // 3600 s, 10 %

        vm.prank(admin);
        config.setCollectHold(600);
        _setTakeRate(2_000);
        _redeem(250_000, 2); // 600 s, 20 %

        vm.prank(admin);
        config.setCollectHold(86_400);
        _setTakeRate(0);

        assertEq(escrow.held(buyer, 1).collectableAt, t0 + 3_600);
        assertEq(escrow.held(buyer, 1).takeRateBps, 1_000);
        assertEq(escrow.held(buyer, 2).collectableAt, t0 + 600);
        assertEq(escrow.held(buyer, 2).takeRateBps, 2_000);

        vm.warp(t0 + 600);
        _collectAs(redeemer, 2);
        _expectCollect(redeemer, 1, HeldNotYetCollectable.selector);
        vm.warp(t0 + 3_600);
        _collectAs(redeemer, 1);

        assertEq(usdg.balanceOf(provider), 200_000 + 225_000);
        assertEq(usdg.balanceOf(treasury), 50_000 + 25_000);
    }

    /// The treasury is not frozen: a collect pays Config's treasury at collect time.
    function test_aCollectPaysTheTreasuryInForceAtCollectTime() public {
        AssayEscrow.HeldPayment memory h = _redeem(250_000, 1);
        address newTreasury = address(0x7EA6);
        ParamSet memory p = config.params();
        p.treasury = newTreasury;
        vm.prank(admin);
        config.updateConfig(p);
        vm.warp(h.collectableAt);
        _collectAs(redeemer, 1);
        assertEq(usdg.balanceOf(newTreasury), 25_000);
        assertEq(usdg.balanceOf(treasury), 0);
    }

    // --- seq ordering ------------------------------------------------------------------------

    /// A held (say, disputed) seq n does not delay seq n+1: the next voucher redeems, and is
    /// collected, while n stays held and is refunded later.
    function test_aHeldSeqDoesNotBlockTheNextSeq() public {
        AssayEscrow.HeldPayment memory h1 = _redeem(250_000, 1);
        AssayEscrow.HeldPayment memory h2 = _redeem(100_000, 2);
        vm.warp(h2.collectableAt);
        assertGe(vm.getBlockTimestamp(), h1.collectableAt);
        _collectAs(redeemer, 2);
        assertEq(uint8(_status(1)), uint8(AssayEscrow.HeldStatus.Held));
        _redeem(50_000, 3);
        _refund(1);
        assertEq(usdg.balanceOf(provider), 90_000);
        assertEq(escrow.totalHeld(), 50_000);
        assertEq(escrow.escrowOf(buyer).seqHigh, 3);
    }

    // --- the fee split -----------------------------------------------------------------------

    /// The collect's split is exactly the one the redemption reported (`VoucherRedeemed.fee`) and
    /// `Fee.splitFee` computes, for any amount and any take rate in force at redemption.
    function testFuzz_theCollectSplitMatchesTheRedeemSplit(uint64 amount, uint16 bps) public {
        amount = uint64(bound(amount, 1, 1_000_000));
        bps = uint16(bound(bps, 0, Constants.MAX_TAKE_RATE_BPS));
        _setTakeRate(bps);
        (uint64 fee, uint64 net) = Fee.splitFee(amount, bps);

        Voucher memory v = _v(amount, 1);
        bytes memory sig = VoucherSigner.signVoucher(buyerKey, ds, v);
        vm.recordLogs();
        vm.prank(redeemer);
        escrow.redeemVoucher(v, sig);
        uint64 reportedFee = _voucherRedeemedFee(vm.getRecordedLogs());
        assertEq(reportedFee, fee, "VoucherRedeemed.fee");

        _setTakeRate(Constants.MAX_TAKE_RATE_BPS - bps); // a later change must not matter
        vm.warp(escrow.held(buyer, 1).collectableAt);
        vm.expectEmit(true, true, true, true, address(escrow));
        emit HeldCollected(buyer, 1, provider, net, fee);
        _collectAs(redeemer, 1);
        assertEq(usdg.balanceOf(provider), net);
        assertEq(usdg.balanceOf(treasury), fee);
        assertEq(uint256(net) + fee, amount);
    }

    function _voucherRedeemedFee(Vm.Log[] memory logs) internal view returns (uint64) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(escrow) && logs[i].topics[0] == VoucherRedeemed.selector)
            {
                (,, uint64 amount_, uint64 fee_,,,) = abi.decode(
                    logs[i].data, (bytes32, bytes32, uint64, uint64, uint64, uint16, uint64)
                );
                amount_;
                return fee_;
            }
        }
        revert("no VoucherRedeemed");
    }

    // --- solvency ----------------------------------------------------------------------------

    /// `balanceOf(escrow) >= totalEscrowed + totalHeld` over a fuzzed mix of redeems, collects,
    /// refunds and a withdraw (the stateful version is `invariant_theContractHoldsAtLeastWhatItOwes`).
    function testFuzz_solvencyHoldsAcrossRedeemCollectRefund(uint256 seed) public {
        uint64 n = uint64(bound(seed, 1, 12));
        for (uint64 s = 1; s <= n; s++) {
            _redeem(uint64(bound(uint256(keccak256(abi.encode(seed, s))), 1, 400_000)), s);
            _assertSolvent();
        }
        vm.warp(vm.getBlockTimestamp() + HOLD);
        for (uint64 s = 1; s <= n; s++) {
            uint256 r = uint256(keccak256(abi.encode(seed, s, "act"))) % 3;
            if (r == 0) _collectAs(redeemer, s);
            else if (r == 1) _refund(s);
            _assertSolvent();
        }
        vm.prank(buyer);
        escrow.requestWithdraw(type(uint64).max);
        vm.warp(vm.getBlockTimestamp() + Constants.WITHDRAW_DELAY_SECONDS);
        vm.prank(buyer);
        escrow.withdraw();
        _assertSolvent();
        vm.warp(vm.getBlockTimestamp() + TIMEOUT);
        for (uint64 s = 1; s <= n; s++) {
            if (_status(s) == AssayEscrow.HeldStatus.Held) _collectAs(stranger, s);
        }
        _assertSolvent();
        assertEq(escrow.totalHeld(), 0);
        assertEq(usdg.balanceOf(address(escrow)), 0, "every unit went somewhere");
    }

    function _assertSolvent() internal view {
        assertGe(
            usdg.balanceOf(address(escrow)),
            uint256(escrow.totalEscrowed()) + escrow.totalHeld(),
            "balanceOf >= totalEscrowed + totalHeld"
        );
    }

    // --- batches -----------------------------------------------------------------------------

    function _pair(uint64 a, uint64 b)
        internal
        view
        returns (address[] memory payers, uint64[] memory seqs)
    {
        payers = new address[](2);
        payers[0] = buyer;
        payers[1] = buyer;
        seqs = new uint64[](2);
        seqs[0] = a;
        seqs[1] = b;
    }

    function test_collectHeldBatch_collectsEveryItem() public {
        AssayEscrow.HeldPayment memory h = _redeem(250_000, 1);
        _redeem(100_000, 2);
        vm.warp(h.collectableAt);
        (address[] memory payers, uint64[] memory seqs) = _pair(1, 2);
        vm.prank(redeemer);
        escrow.collectHeldBatch(payers, seqs);
        assertEq(usdg.balanceOf(provider), 315_000);
        assertEq(usdg.balanceOf(treasury), 35_000);
        assertEq(escrow.totalHeld(), 0);
    }

    /// Atomic, like `redeemVoucherBatch`: one bad item reverts every item.
    function test_collectHeldBatch_isAtomic() public {
        AssayEscrow.HeldPayment memory h = _redeem(250_000, 1);
        _redeem(100_000, 2);
        vm.warp(h.collectableAt);
        _refund(2);
        (address[] memory payers, uint64[] memory seqs) = _pair(1, 2);
        vm.prank(redeemer);
        vm.expectRevert(HeldPaymentNotHeld.selector);
        escrow.collectHeldBatch(payers, seqs);
        // a duplicate is refused by the second iteration's status check
        (payers, seqs) = _pair(1, 1);
        vm.prank(redeemer);
        vm.expectRevert(HeldPaymentNotHeld.selector);
        escrow.collectHeldBatch(payers, seqs);
        assertEq(uint8(_status(1)), uint8(AssayEscrow.HeldStatus.Held));
        assertEq(usdg.balanceOf(provider), 0);
    }

    function test_collectHeldBatch_permissionlessOnlyAfterTheTimeout() public {
        AssayEscrow.HeldPayment memory h = _redeem(250_000, 1);
        _redeem(100_000, 2);
        (address[] memory payers, uint64[] memory seqs) = _pair(1, 2);
        vm.warp(h.collectableAt);
        vm.prank(stranger);
        vm.expectRevert(HeldNotYetCollectable.selector);
        escrow.collectHeldBatch(payers, seqs);
        vm.warp(uint256(h.collectableAt) + TIMEOUT);
        vm.prank(stranger);
        escrow.collectHeldBatch(payers, seqs);
        assertEq(usdg.balanceOf(provider), 315_000);
    }

    function test_refundHeldBatch_refundsEveryItemAndIsRedeemerOnly() public {
        _redeem(250_000, 1);
        _redeem(100_000, 2);
        (address[] memory payers, uint64[] memory seqs) = _pair(1, 2);
        vm.prank(stranger);
        vm.expectRevert(NotRedeemer.selector);
        escrow.refundHeldBatch(payers, seqs);
        vm.prank(redeemer);
        escrow.refundHeldBatch(payers, seqs);
        assertEq(escrow.escrowOf(buyer).balance, 10_000_000);
        assertEq(escrow.totalHeld(), 0);
        vm.prank(redeemer);
        vm.expectRevert(HeldPaymentNotHeld.selector);
        escrow.refundHeldBatch(payers, seqs);
    }

    function test_theHeldBatchesCheckTheirShape() public {
        address[] memory none = new address[](0);
        uint64[] memory noSeqs = new uint64[](0);
        address[] memory big = new address[](Constants.MAX_REDEEM_BATCH + 1);
        uint64[] memory bigSeqs = new uint64[](Constants.MAX_REDEEM_BATCH + 1);
        uint64[] memory two = new uint64[](2);

        vm.startPrank(redeemer);
        vm.expectRevert(EmptyBatch.selector);
        escrow.collectHeldBatch(none, noSeqs);
        vm.expectRevert(EmptyBatch.selector);
        escrow.refundHeldBatch(none, noSeqs);
        vm.expectRevert(BatchTooLarge.selector);
        escrow.collectHeldBatch(big, bigSeqs);
        vm.expectRevert(BatchTooLarge.selector);
        escrow.refundHeldBatch(big, bigSeqs);
        vm.expectRevert(BatchLengthMismatch.selector);
        escrow.collectHeldBatch(_one(buyer), two);
        vm.expectRevert(BatchLengthMismatch.selector);
        escrow.refundHeldBatch(_one(buyer), two);
        vm.stopPrank();
    }
}
