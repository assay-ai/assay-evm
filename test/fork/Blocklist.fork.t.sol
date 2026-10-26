// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.38;

import {Fixture} from "../helpers/Fixture.sol";
import {BlockingUSDG} from "../helpers/BlockingUSDG.sol";
import {VoucherSigner} from "../helpers/VoucherSigner.sol";
import {AssayEscrow} from "../../src/AssayEscrow.sol";
import {Voucher} from "../../src/Types.sol";

/// **What a payout transfer that reverts does to the escrow's accounting.**
///
/// # What this proves, and what it does NOT
///
/// It does **not** prove anything about an issuer blocklist. It was measured that the token
/// deployed at 46630 has **no blocklist under any of five spellings** (`docs/chain-facts.md`
/// §1a), so that interaction cannot be exercised on this chain at all, and the mainnet USDG
/// address does not exist yet (risk register §10). **The real-blocklist proof is OWED and
/// unobtainable.** Do not read a green run here as covering it.
///
/// What it proves is the property a blocklist actually exercises, which is provable today: when
/// the provider payout reverts, **the escrow's accounting is left exactly as it was** — balance,
/// `seqHigh`, `authNonce`, the escrow's token holding, the treasury's, and `totalEscrowed` — and
/// for a batch, one bad recipient takes the other 63 with it and debits none of their payers.
///
/// That property is asserted **nowhere else**. The suite's one blocklist test
/// (`AssayEscrow.redeem.t.sol::test_aBlocklistedTreasuryOwedNothingDoesNotHaltThePayout`) is about
/// a treasury owed *nothing* not halting a payout — the opposite case — and it is one of the five
/// that `mockTokenOnly` skips on the fork.
///
/// # Why it runs on the fork at all
///
/// The fixture's own `usdg` is the real 46630 token here, so the stake floor every redeem checks
/// (`STAKE.bondedOf(provider) >= minimumStake`) is satisfied through a real deposit of the real
/// token. The blocked leg is a second escrow in front of `BlockingUSDG`, which is how this suite
/// already reaches a hostile asset (`_deployEscrow(address asset_)`).
contract BlocklistAccountingForkTest is Fixture {
    BlockingUSDG internal token;
    AssayEscrow internal blocking;
    bytes32 internal ds;

    /// A provider that is NOT blocked, bonded on the shared stake contract.
    address internal okProvider = address(0xDEC0DE);

    uint64 internal constant DEPOSIT = 20_000_000;
    uint64 internal constant AMOUNT = 400_000;

    uint256 internal constant POOL = 64;
    uint256[POOL] internal payerKeys;
    address[POOL] internal payers;

    function setUp() public override {
        forkMode = true;
        super.setUp();
        // `Fixture.setUp` calls `vm.skip(true)` and RETURNS EARLY when `RH_TESTNET_RPC` is unset,
        // leaving every field at its default. Reading that state back is the check — an
        // independent re-read of the env var here could drift out of step with the fixture's.
        if (address(config) == address(0)) return;

        token = new BlockingUSDG(provider); // the PROVIDER is the blocked party
        blocking = _deployEscrow(address(token));
        ds = blocking.DOMAIN_SEPARATOR();

        _setBonded(okProvider, MINIMUM_STAKE);

        token.mint(buyer, 50_000_000);
        vm.startPrank(buyer);
        token.approve(address(blocking), type(uint256).max);
        blocking.deposit(DEPOSIT);
        blocking.setLimits(type(uint64).max, type(uint64).max);
        vm.stopPrank();

        for (uint256 i = 0; i < POOL; i++) {
            payerKeys[i] = 0xB10C0000 + i + 1;
            payers[i] = vm.addr(payerKeys[i]);
            token.mint(payers[i], 1_000_000);
            vm.startPrank(payers[i]);
            token.approve(address(blocking), type(uint256).max);
            blocking.deposit(1_000_000);
            blocking.setLimits(type(uint64).max, type(uint64).max);
            vm.stopPrank();
        }
    }

    // --- helpers, deliberately local -------------------------------------------------------
    //
    // Copied from the shapes in `AssayEscrow.redeem.t.sol` and `AssayEscrow.batch.t.sol` rather
    // than exported from them: a helper shared between an escrow-behaviour suite and an
    // accounting-consistency suite drifts toward whichever it was last edited for.

    function _snapshot(address who) internal view returns (uint64 bal, uint64 seq, uint64 nonce) {
        AssayEscrow.Escrow memory e = blocking.escrowOf(who);
        return (uint64(e.balance), e.seqHigh, e.authNonce);
    }

    function _seqOf(address who) internal view returns (uint64) {
        return blocking.escrowOf(who).seqHigh;
    }

    function _voucherFor(address payer_, address provider_, uint64 amount, uint64 seq)
        internal
        view
        returns (Voucher memory)
    {
        return Voucher({
            payer: payer_,
            provider: provider_,
            amount: amount,
            resourceHash: keccak256("resource"),
            requestHash: keccak256(abi.encode("request", payer_, seq)),
            seq: seq,
            issuedAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp) + 300
        });
    }

    /// 64 vouchers from 64 distinct payers to the NON-blocked provider. The caller swaps one.
    function _batchOfSixtyFour() internal view returns (Voucher[] memory vs, bytes[] memory sigs) {
        vs = new Voucher[](POOL);
        sigs = new bytes[](POOL);
        for (uint256 i = 0; i < POOL; i++) {
            vs[i] = _voucherFor(payers[i], okProvider, 1_000, 1);
            sigs[i] = VoucherSigner.signVoucher(payerKeys[i], ds, vs[i]);
        }
    }

    // --- the assertions ----------------------------------------------------------------------
    //
    // A redeem only moves the voucher into a hold; the token leaves the escrow at collection.
    // A blocked provider therefore surfaces at `collectHeld`, and the held record can still be
    // refunded to the payer.

    function _warpToCollectable() internal {
        vm.warp(block.timestamp + config.collectHoldSeconds());
    }

    /// A blocked provider: the redeem lands in the hold, the collection reverts with every
    /// balance unchanged, and the redeemer can return the hold to the payer.
    function test_aBlockedProviderRevertsTheCollectAndLeavesTheAccountingUntouched() public {
        (uint64 balBefore,,) = _snapshot(buyer);
        uint256 escrowTokensBefore = token.balanceOf(address(blocking));
        uint256 treasuryBefore = token.balanceOf(treasury);
        uint128 totalBefore = blocking.totalEscrowed();

        Voucher memory v = _voucherFor(buyer, provider, AMOUNT, 1);
        bytes memory sig = VoucherSigner.signVoucher(buyerKey, ds, v);
        vm.prank(redeemer);
        blocking.redeemVoucher(v, sig);
        assertEq(blocking.totalHeld(), AMOUNT, "the redeem did not hold the amount");

        _warpToCollectable();
        vm.prank(redeemer);
        vm.expectRevert(abi.encodeWithSelector(BlockingUSDG.TransferBlocked.selector, provider));
        blocking.collectHeld(buyer, 1);

        assertEq(token.balanceOf(address(blocking)), escrowTokensBefore, "token left the escrow");
        assertEq(token.balanceOf(treasury), treasuryBefore, "the fee was taken anyway");
        assertEq(blocking.totalHeld(), AMOUNT, "the hold moved on a reverted collect");

        vm.prank(redeemer);
        blocking.refundHeld(buyer, 1);
        (uint64 balAfter,,) = _snapshot(buyer);
        assertEq(balAfter, balBefore, "the refund did not restore the balance");
        assertEq(blocking.totalEscrowed(), totalBefore, "totalEscrowed not restored");
        assertEq(blocking.totalHeld(), 0, "the hold was not released");
    }

    /// Positive control: the same voucher to a provider that is not blocked is collected and
    /// pays the provider and the treasury.
    function test_theSameVoucherToANonBlockedProviderIsCollected() public {
        (uint64 balBefore,,) = _snapshot(buyer);
        uint256 escrowTokensBefore = token.balanceOf(address(blocking));
        uint256 treasuryBefore = token.balanceOf(treasury);
        uint128 totalBefore = blocking.totalEscrowed();

        Voucher memory v = _voucherFor(buyer, okProvider, AMOUNT, 1);
        bytes memory sig = VoucherSigner.signVoucher(buyerKey, ds, v);
        vm.prank(redeemer);
        blocking.redeemVoucher(v, sig);

        (uint64 balAfter, uint64 seqAfter,) = _snapshot(buyer);
        assertEq(balAfter, balBefore - AMOUNT, "escrow balance did not move");
        assertEq(seqAfter, 1, "seqHigh did not advance");
        assertEq(blocking.totalEscrowed(), totalBefore - AMOUNT, "totalEscrowed did not move");

        _warpToCollectable();
        vm.prank(redeemer);
        blocking.collectHeld(buyer, 1);

        uint64 fee = (AMOUNT * TAKE_RATE_BPS) / 10_000;
        assertEq(token.balanceOf(okProvider), AMOUNT - fee, "the provider was not paid");
        assertEq(token.balanceOf(treasury), treasuryBefore + fee, "the fee was not taken");
        assertEq(
            token.balanceOf(address(blocking)), escrowTokensBefore - AMOUNT, "escrow still holds it"
        );
        assertEq(blocking.totalHeld(), 0, "the hold was not released");
    }

    /// `collectHeldBatch` is all-or-nothing: one blocked provider at position 17 reverts the
    /// collection of all 64, and nobody is paid.
    function test_oneBlockedProviderRevertsTheWholeCollectBatchOfSixtyFour() public {
        (Voucher[] memory vs, bytes[] memory sigs) = _batchOfSixtyFour();
        vs[17].provider = provider; // the blocked address
        sigs[17] = VoucherSigner.signVoucher(payerKeys[17], ds, vs[17]);

        vm.prank(redeemer);
        blocking.redeemVoucherBatch(vs, sigs);
        uint256 escrowTokensBefore = token.balanceOf(address(blocking));
        uint256 heldBefore = blocking.totalHeld();

        _warpToCollectable();
        (address[] memory ps, uint64[] memory seqs) = _collectArgs();
        vm.prank(redeemer);
        vm.expectRevert(abi.encodeWithSelector(BlockingUSDG.TransferBlocked.selector, provider));
        blocking.collectHeldBatch(ps, seqs);

        assertEq(token.balanceOf(address(blocking)), escrowTokensBefore, "token left the escrow");
        assertEq(blocking.totalHeld(), heldBefore, "the hold moved on a reverted batch");
        assertEq(token.balanceOf(okProvider), 0, "a provider was paid out of a reverted batch");
    }

    /// Positive control for the batch: the same 64 vouchers with nobody blocked are all collected.
    function test_theSameBatchWithNobodyBlockedCollectsAllSixtyFour() public {
        (Voucher[] memory vs, bytes[] memory sigs) = _batchOfSixtyFour();

        vm.prank(redeemer);
        blocking.redeemVoucherBatch(vs, sigs);
        for (uint256 i = 0; i < vs.length; i++) {
            assertEq(_seqOf(vs[i].payer), 1, "a payer's seqHigh did not advance");
        }

        _warpToCollectable();
        (address[] memory ps, uint64[] memory seqs) = _collectArgs();
        vm.prank(redeemer);
        blocking.collectHeldBatch(ps, seqs);

        // The uint64 cast matters: TAKE_RATE_BPS is a uint16 and 1,000 * bps overflows it.
        uint64 fee = (uint64(1_000) * TAKE_RATE_BPS) / 10_000;
        assertEq(token.balanceOf(okProvider), uint256(1_000 - fee) * POOL, "not all 64 paid");
        assertEq(blocking.totalHeld(), 0, "the hold was not released");
    }

    function _collectArgs() internal view returns (address[] memory ps, uint64[] memory seqs) {
        ps = new address[](POOL);
        seqs = new uint64[](POOL);
        for (uint256 i = 0; i < POOL; i++) {
            ps[i] = payers[i];
            seqs[i] = 1;
        }
    }
}
