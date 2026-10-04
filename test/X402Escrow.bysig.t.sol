// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.24;

import {Fixture} from "./helpers/Fixture.sol";
import {VoucherSigner} from "./helpers/VoucherSigner.sol";
import {X402Escrow} from "../src/X402Escrow.sol";
import {Constants} from "../src/Constants.sol";
import "../src/Errors.sol";

/// A settlement asset that answers `decimals()` and **reverts on everything else**.
///
/// It is the whole re-entrancy argument for the four limit/withdraw-request doors, stated as a test
/// rather than as a comment: `setLimits`, `setLimitsBySig`, `requestWithdraw` and
/// `requestWithdrawBySig` make no external call at all — no transfer, no `balanceOf`, no callback —
/// so there is nothing for a hostile token to re-enter from. `nonReentrant` on them is belt with no
/// brace behind it, and that is worth measuring rather than asserting, because the natural way to
/// break it is to add an innocent-looking read of the asset later.
///
/// Distinct from `MockUSDG`'s family of adversaries: those all move balances. This one refuses to
/// do anything, which is exactly what makes a call to it visible.
contract InertAsset {
    uint8 public constant decimals = 6;

    error TheEscrowTouchedTheAssetOnAPathThatHasNoInteraction();

    fallback() external {
        revert TheEscrowTouchedTheAssetOnAPathThatHasNoInteraction();
    }
}

/// The two relayed doors, and the two direct ones they share their effects with.
///
/// The relayer key can never move USDG. `setLimits` gets a relayed variant because a buyer
/// *lowering* a ceiling must not be blocked by not holding gas; `requestWithdraw` gets one
/// because starting a clock moves no money. `withdraw` does not get one, ever (see
/// `X402Escrow.withdraw.t.sol`).
contract X402EscrowBySigTest is Fixture {
    address internal relayer = address(0x2E14);

    event WithdrawRequested(address indexed buyer, uint64 amount, uint64 availableAt);
    event EscrowLimitsSet(address indexed buyer, uint64 maxVoucherAmount, uint64 maxPerWindow);

    function setUp() public virtual override {
        super.setUp();
        _fund(buyer, 10_000_000);
        vm.startPrank(buyer);
        usdg.approve(address(escrow), 10_000_000);
        escrow.deposit(10_000_000);
        vm.stopPrank();
    }

    // --- the nine specified cases -------------------------------------------------------------

    function test_happyPath_aRelayerCarriesTheBuyersLimits() public {
        uint64 deadline = uint64(block.timestamp) + 600;
        bytes memory sig = VoucherSigner.signSetLimits(
            buyerKey, escrow.DOMAIN_SEPARATOR(), buyer, 1_000_000, 5_000_000, 0, deadline
        );
        vm.prank(relayer);
        vm.expectEmit(true, false, false, true, address(escrow));
        emit EscrowLimitsSet(buyer, 1_000_000, 5_000_000);
        escrow.setLimitsBySig(buyer, 1_000_000, 5_000_000, 0, deadline, sig);

        assertEq(escrow.escrowOf(buyer).maxVoucherAmount, 1_000_000);
        assertEq(escrow.escrowOf(buyer).maxPerWindow, 5_000_000, "the second limit is signed too");
        assertEq(escrow.escrowOf(buyer).authNonce, 1);
        // The relayer is credited with nothing: it carried a message, it did not send one.
        assertEq(escrow.escrowOf(relayer).maxVoucherAmount, 0);
        assertEq(escrow.escrowOf(relayer).authNonce, 0);
    }

    function test_wrongSigner_anotherKeysAuthorisationIsRefused() public {
        uint64 deadline = uint64(block.timestamp) + 600;
        bytes memory sig = VoucherSigner.signSetLimits(
            0xBADBAD, escrow.DOMAIN_SEPARATOR(), buyer, 1_000_000, 5_000_000, 0, deadline
        );
        vm.prank(relayer);
        vm.expectRevert(SignerIsNotBuyer.selector);
        escrow.setLimitsBySig(buyer, 1_000_000, 5_000_000, 0, deadline, sig);
    }

    /// A leaked relayer key cannot replay: the nonce is inside the signed struct.
    function test_wrongState_theSameAuthorisationCannotBeReplayed() public {
        uint64 deadline = uint64(block.timestamp) + 600;
        bytes memory sig = VoucherSigner.signSetLimits(
            buyerKey, escrow.DOMAIN_SEPARATOR(), buyer, 1_000_000, 5_000_000, 0, deadline
        );
        vm.startPrank(relayer);
        escrow.setLimitsBySig(buyer, 1_000_000, 5_000_000, 0, deadline, sig);
        vm.expectRevert(BadNonce.selector);
        escrow.setLimitsBySig(buyer, 1_000_000, 5_000_000, 0, deadline, sig);
        vm.stopPrank();
    }

    /// Boundary B17 at -1 / exact / +1.
    function test_boundary_theDeadlineAdmitsItsOwnInstant() public {
        uint64 deadline = uint64(block.timestamp) + 600;
        bytes memory sig = VoucherSigner.signSetLimits(
            buyerKey, escrow.DOMAIN_SEPARATOR(), buyer, 1_000_000, 5_000_000, 0, deadline
        );

        // +1: one second past the deadline is refused.
        vm.warp(deadline + 1);
        vm.prank(relayer);
        vm.expectRevert(SignatureExpired.selector);
        escrow.setLimitsBySig(buyer, 1_000_000, 5_000_000, 0, deadline, sig);

        // exact: the deadline's own instant is admitted — `>` and not `>=`.
        vm.warp(deadline);
        vm.prank(relayer);
        escrow.setLimitsBySig(buyer, 1_000_000, 5_000_000, 0, deadline, sig);
        assertEq(escrow.escrowOf(buyer).maxVoucherAmount, 1_000_000);

        // -1: and so is the second before it. A fresh authorisation, because the one above spent
        // the nonce, and a later deadline because time only moves forward.
        uint64 later = deadline + 600;
        bytes memory sig2 = VoucherSigner.signSetLimits(
            buyerKey, escrow.DOMAIN_SEPARATOR(), buyer, 2_000_000, 5_000_000, 1, later
        );
        vm.warp(later - 1);
        vm.prank(relayer);
        escrow.setLimitsBySig(buyer, 2_000_000, 5_000_000, 1, later, sig2);
        assertEq(escrow.escrowOf(buyer).maxVoucherAmount, 2_000_000);
    }

    /// CROSS-KIND REPLAY. A SetLimits signature presented at RequestWithdraw's door.
    function test_wrongSigner_aSetLimitsSignatureIsNotARequestWithdraw() public {
        uint64 deadline = uint64(block.timestamp) + 600;
        bytes memory sig = VoucherSigner.signSetLimits(
            buyerKey, escrow.DOMAIN_SEPARATOR(), buyer, 5_000_000, 0, 0, deadline
        );
        vm.prank(relayer);
        vm.expectRevert(SignerIsNotBuyer.selector);
        escrow.requestWithdrawBySig(buyer, 5_000_000, 0, deadline, sig);
    }

    function test_happyPath_requestWithdrawStartsTheClock() public {
        vm.prank(buyer);
        vm.expectEmit(true, false, false, true, address(escrow));
        emit WithdrawRequested(
            buyer, 4_000_000, uint64(block.timestamp) + Constants.WITHDRAW_DELAY_SECONDS
        );
        escrow.requestWithdraw(4_000_000);
        assertEq(escrow.escrowOf(buyer).withdrawRequested, 4_000_000);
        assertEq(
            escrow.escrowOf(buyer).withdrawAvailableAt,
            uint64(block.timestamp) + Constants.WITHDRAW_DELAY_SECONDS
        );
        // Requesting is not spending: nothing about the money moved.
        assertEq(escrow.escrowOf(buyer).balance, 10_000_000);
        assertEq(escrow.escrowOf(buyer).totalFunded, 10_000_000);
        assertEq(escrow.totalEscrowed(), 10_000_000);
    }

    /// Requesting zero cancels a standing request and clears the clock.
    function test_happyPath_requestingZeroCancels() public {
        vm.startPrank(buyer);
        escrow.requestWithdraw(4_000_000);
        vm.expectEmit(true, false, false, true, address(escrow));
        emit WithdrawRequested(buyer, 0, 0);
        escrow.requestWithdraw(0);
        vm.stopPrank();
        assertEq(escrow.escrowOf(buyer).withdrawRequested, 0);
        assertEq(escrow.escrowOf(buyer).withdrawAvailableAt, 0);
    }

    /// Neither of these is pause-gated: an admin key must not be able to stop a buyer
    /// tightening a limit or starting a withdrawal clock.
    function test_pauseDoesNotCloseTheSafetyDirection() public {
        vm.prank(admin);
        config.setPaused(true);

        vm.startPrank(buyer);
        escrow.setLimits(1, 1);
        escrow.requestWithdraw(1_000);
        vm.stopPrank();

        // And neither are the RELAYED twins — a buyer without gas is exactly the buyer an
        // incident strands, so the pause must not close their door either.
        uint64 deadline = uint64(block.timestamp) + 600;
        bytes memory s1 = VoucherSigner.signSetLimits(
            buyerKey, escrow.DOMAIN_SEPARATOR(), buyer, 2, 2, 0, deadline
        );
        vm.prank(relayer);
        escrow.setLimitsBySig(buyer, 2, 2, 0, deadline, s1);

        bytes memory s2 = VoucherSigner.signRequestWithdraw(
            buyerKey, escrow.DOMAIN_SEPARATOR(), buyer, 2_000, 1, deadline
        );
        vm.prank(relayer);
        escrow.requestWithdrawBySig(buyer, 2_000, 1, deadline, s2);

        assertEq(escrow.escrowOf(buyer).maxVoucherAmount, 2);
        assertEq(escrow.escrowOf(buyer).withdrawRequested, 2_000);
        assertTrue(config.paused(), "the pause was live for every call above");
    }

    function test_wrongState_settingTheSameLimitsTwiceIsRefused() public {
        vm.startPrank(buyer);
        escrow.setLimits(1_000_000, 5_000_000);
        vm.expectRevert(EscrowLimitsUnchanged.selector);
        escrow.setLimits(1_000_000, 5_000_000);
        vm.stopPrank();
    }

    // --- the relayed withdrawal request, which the specified cases have no happy path for -------

    /// **The degenerate this kills** is a `requestWithdrawBySig` that credits `msg.sender`
    /// instead of the recovered signer. The specified cases never call the door successfully, so
    /// nothing in it would notice — and the relayer would be able to start its own exit clock
    /// with somebody else's authorisation.
    function test_happyPath_aRelayerCarriesTheBuyersWithdrawRequest() public {
        uint64 deadline = uint64(block.timestamp) + 600;
        uint64 availableAt = uint64(block.timestamp) + Constants.WITHDRAW_DELAY_SECONDS;
        bytes memory sig = VoucherSigner.signRequestWithdraw(
            buyerKey, escrow.DOMAIN_SEPARATOR(), buyer, 4_000_000, 0, deadline
        );
        vm.prank(relayer);
        vm.expectEmit(true, false, false, true, address(escrow));
        emit WithdrawRequested(buyer, 4_000_000, availableAt);
        escrow.requestWithdrawBySig(buyer, 4_000_000, 0, deadline, sig);

        assertEq(escrow.escrowOf(buyer).withdrawRequested, 4_000_000, "the SIGNER's clock");
        assertEq(escrow.escrowOf(buyer).withdrawAvailableAt, availableAt);
        assertEq(escrow.escrowOf(buyer).authNonce, 1);

        assertEq(escrow.escrowOf(relayer).withdrawRequested, 0, "not the CALLER's");
        assertEq(escrow.escrowOf(relayer).withdrawAvailableAt, 0);
        assertEq(escrow.escrowOf(relayer).authNonce, 0);
    }

    /// The cross-kind replay in the other direction, which the specified cases only test one way
    /// round.
    function test_wrongSigner_aRequestWithdrawSignatureIsNotASetLimits() public {
        uint64 deadline = uint64(block.timestamp) + 600;
        bytes memory sig = VoucherSigner.signRequestWithdraw(
            buyerKey, escrow.DOMAIN_SEPARATOR(), buyer, 1_000_000, 0, deadline
        );
        vm.prank(relayer);
        vm.expectRevert(SignerIsNotBuyer.selector);
        escrow.setLimitsBySig(buyer, 1_000_000, 0, 0, deadline, sig);
    }

    /// One counter, both doors: an authorisation for either kind at nonce `n` voids the other.
    function test_wrongState_oneNonceServesBothDoors() public {
        uint64 deadline = uint64(block.timestamp) + 600;
        bytes memory limitsSig = VoucherSigner.signSetLimits(
            buyerKey, escrow.DOMAIN_SEPARATOR(), buyer, 1_000_000, 5_000_000, 0, deadline
        );
        bytes memory withdrawSig = VoucherSigner.signRequestWithdraw(
            buyerKey, escrow.DOMAIN_SEPARATOR(), buyer, 4_000_000, 0, deadline
        );

        vm.startPrank(relayer);
        escrow.setLimitsBySig(buyer, 1_000_000, 5_000_000, 0, deadline, limitsSig);
        vm.expectRevert(BadNonce.selector);
        escrow.requestWithdrawBySig(buyer, 4_000_000, 0, deadline, withdrawSig);
        vm.stopPrank();

        assertEq(escrow.escrowOf(buyer).withdrawRequested, 0);
    }

    /// The nonce may not be jumped forward either: a relayer holding signatures for 0 and 1
    /// cannot land 1 first and keep 0 alive for later.
    function test_wrongState_aFutureNonceIsRefusedAsWellAsAStaleOne() public {
        uint64 deadline = uint64(block.timestamp) + 600;
        bytes memory sig = VoucherSigner.signSetLimits(
            buyerKey, escrow.DOMAIN_SEPARATOR(), buyer, 1_000_000, 5_000_000, 1, deadline
        );
        vm.prank(relayer);
        vm.expectRevert(BadNonce.selector);
        escrow.setLimitsBySig(buyer, 1_000_000, 5_000_000, 1, deadline, sig);
    }

    function test_wrongState_theZeroAddressIsRefusedAtBothDoors() public {
        uint64 deadline = uint64(block.timestamp) + 600;
        bytes memory sig = new bytes(65);
        vm.startPrank(relayer);
        vm.expectRevert(ZeroAddress.selector);
        escrow.setLimitsBySig(address(0), 1, 1, 0, deadline, sig);
        vm.expectRevert(ZeroAddress.selector);
        escrow.requestWithdrawBySig(address(0), 1, 0, deadline, sig);
        vm.stopPrank();
    }

    // --- every signed field is inside the preimage ---------------------------------------------
    //
    // **The degenerate these kill** is a `setLimitsBySig` that drops one of the four signed values
    // from the hash it checks — a relayer holding one signature could then substitute any value
    // for the dropped field, which for `maxPerWindow` means raising a ceiling the buyer lowered.
    // Nothing in the specified cases can see it: every fixture there presents the same values it
    // signed, so a hash that ignores a field agrees with a hash that does not.

    function test_wrongSigner_everySignedFieldOfSetLimitsIsBoundIntoTheSignature() public {
        uint64 deadline = uint64(block.timestamp) + 600;
        bytes32 dom = escrow.DOMAIN_SEPARATOR();
        bytes memory sig =
            VoucherSigner.signSetLimits(buyerKey, dom, buyer, 1_000_000, 5_000_000, 0, deadline);

        vm.startPrank(relayer);
        // maxVoucherAmount
        vm.expectRevert(SignerIsNotBuyer.selector);
        escrow.setLimitsBySig(buyer, 1_000_001, 5_000_000, 0, deadline, sig);
        // maxPerWindow — the ceiling a relayer would most want to raise
        vm.expectRevert(SignerIsNotBuyer.selector);
        escrow.setLimitsBySig(buyer, 1_000_000, type(uint64).max, 0, deadline, sig);
        // deadline
        vm.expectRevert(SignerIsNotBuyer.selector);
        escrow.setLimitsBySig(buyer, 1_000_000, 5_000_000, 0, deadline + 1, sig);
        // buyer — an authorisation aimed at somebody else's escrow
        vm.expectRevert(SignerIsNotBuyer.selector);
        escrow.setLimitsBySig(provider, 1_000_000, 5_000_000, 0, deadline, sig);
        vm.stopPrank();

        // nonce: presented at the value the state expects (0) but signed at 1, so `BadNonce`
        // cannot be what refuses it and the refusal is the preimage's.
        bytes memory sigN =
            VoucherSigner.signSetLimits(buyerKey, dom, buyer, 1_000_000, 5_000_000, 1, deadline);
        vm.prank(relayer);
        vm.expectRevert(SignerIsNotBuyer.selector);
        escrow.setLimitsBySig(buyer, 1_000_000, 5_000_000, 0, deadline, sigN);

        // and nothing above moved the escrow.
        assertEq(escrow.escrowOf(buyer).maxVoucherAmount, 0);
        assertEq(escrow.escrowOf(buyer).maxPerWindow, 0);
        assertEq(escrow.escrowOf(buyer).authNonce, 0);
    }

    function test_wrongSigner_everySignedFieldOfRequestWithdrawIsBoundIntoTheSignature() public {
        uint64 deadline = uint64(block.timestamp) + 600;
        bytes32 dom = escrow.DOMAIN_SEPARATOR();
        bytes memory sig =
            VoucherSigner.signRequestWithdraw(buyerKey, dom, buyer, 4_000_000, 0, deadline);

        vm.startPrank(relayer);
        vm.expectRevert(SignerIsNotBuyer.selector);
        escrow.requestWithdrawBySig(buyer, 4_000_001, 0, deadline, sig);
        vm.expectRevert(SignerIsNotBuyer.selector);
        escrow.requestWithdrawBySig(buyer, 4_000_000, 0, deadline + 1, sig);
        vm.expectRevert(SignerIsNotBuyer.selector);
        escrow.requestWithdrawBySig(provider, 4_000_000, 0, deadline, sig);
        vm.stopPrank();

        bytes memory sigN =
            VoucherSigner.signRequestWithdraw(buyerKey, dom, buyer, 4_000_000, 1, deadline);
        vm.prank(relayer);
        vm.expectRevert(SignerIsNotBuyer.selector);
        escrow.requestWithdrawBySig(buyer, 4_000_000, 0, deadline, sigN);

        assertEq(escrow.escrowOf(buyer).withdrawRequested, 0);
        assertEq(escrow.escrowOf(buyer).authNonce, 0);
    }

    // --- the guard across the ADDRESS SPACE ----------------------------------------------------
    //
    // `redeemVoucher`'s signature guard was once exercised at exactly ONE `(payer, provider)` pair,
    // and a bypass keyed on any other address passed all 193 tests while moving 900,000 out of a
    // funded buyer. A guard tested at a single point is a guard tested nowhere, so the two relayed
    // doors are exercised here at many points: a deterministic sweep of SMALL keys (the structured
    // edges a uniform fuzz never draws), and a fuzz over the whole key space beside it.

    /// A deterministic sweep. Small private keys are exactly what a `bound`-ed uniform fuzz does
    /// not sample — measured here: a uniform `bytes32` fuzz never drew `s == 2` — so the
    /// sweep and the fuzz below are not two spellings of one test.
    function test_theRelayedDoorsHoldAcrossASweepOfBuyers() public {
        uint256[8] memory keys = [uint256(1), 2, 3, 4, 7, 255, 65_537, VoucherSigner.N - 1];
        bytes32 dom = escrow.DOMAIN_SEPARATOR();
        uint64 deadline = uint64(block.timestamp) + 600;

        for (uint256 i = 0; i < keys.length; i++) {
            address b = vm.addr(keys[i]);
            address otherRelayer = address(uint160(0xBEEF0000 + i));
            uint64 mv = uint64(1_000 + i);
            uint64 mw = uint64(10_000 + i);

            // the wrong key first, so a door that admitted it would not be masked by the nonce
            // the right one is about to spend.
            bytes memory bad = VoucherSigner.signSetLimits(
                keys[(i + 1) % keys.length], dom, b, mv, mw, 0, deadline
            );
            vm.prank(otherRelayer);
            vm.expectRevert(SignerIsNotBuyer.selector);
            escrow.setLimitsBySig(b, mv, mw, 0, deadline, bad);

            bytes memory good = VoucherSigner.signSetLimits(keys[i], dom, b, mv, mw, 0, deadline);
            vm.prank(otherRelayer);
            escrow.setLimitsBySig(b, mv, mw, 0, deadline, good);
            assertEq(escrow.escrowOf(b).maxVoucherAmount, mv, "this buyer's own limit");
            assertEq(escrow.escrowOf(b).maxPerWindow, mw);
            assertEq(escrow.escrowOf(b).authNonce, 1);

            uint64 amt = uint64(500 + i);
            bytes memory badW = VoucherSigner.signRequestWithdraw(
                keys[(i + 1) % keys.length], dom, b, amt, 1, deadline
            );
            vm.prank(otherRelayer);
            vm.expectRevert(SignerIsNotBuyer.selector);
            escrow.requestWithdrawBySig(b, amt, 1, deadline, badW);

            bytes memory goodW =
                VoucherSigner.signRequestWithdraw(keys[i], dom, b, amt, 1, deadline);
            vm.prank(otherRelayer);
            escrow.requestWithdrawBySig(b, amt, 1, deadline, goodW);
            assertEq(escrow.escrowOf(b).withdrawRequested, amt);
            assertEq(escrow.escrowOf(b).authNonce, 2);
            assertEq(escrow.escrowOf(otherRelayer).authNonce, 0, "the carrier is never the party");
        }
    }

    /// And the same two doors over the whole key space.
    function testFuzz_onlyTheNamedBuyersOwnKeyAuthorisesEitherDoor(
        uint256 k1,
        uint256 k2,
        uint64 mv,
        uint64 mw,
        uint64 amount
    ) public {
        k1 = bound(k1, 1, VoucherSigner.N - 1);
        k2 = bound(k2, 1, VoucherSigner.N - 1);
        address b = vm.addr(k1);
        vm.assume(vm.addr(k2) != b);
        vm.assume(b != address(0));
        vm.assume(!(mv == 0 && mw == 0)); // a no-op write is refused by EscrowLimitsUnchanged

        bytes32 dom = escrow.DOMAIN_SEPARATOR();
        uint64 deadline = uint64(block.timestamp) + 600;

        bytes memory bad = VoucherSigner.signSetLimits(k2, dom, b, mv, mw, 0, deadline);
        vm.prank(relayer);
        vm.expectRevert(SignerIsNotBuyer.selector);
        escrow.setLimitsBySig(b, mv, mw, 0, deadline, bad);

        bytes memory good = VoucherSigner.signSetLimits(k1, dom, b, mv, mw, 0, deadline);
        vm.prank(relayer);
        escrow.setLimitsBySig(b, mv, mw, 0, deadline, good);
        assertEq(escrow.escrowOf(b).maxVoucherAmount, mv);
        assertEq(escrow.escrowOf(b).maxPerWindow, mw);

        bytes memory badW = VoucherSigner.signRequestWithdraw(k2, dom, b, amount, 1, deadline);
        vm.prank(relayer);
        vm.expectRevert(SignerIsNotBuyer.selector);
        escrow.requestWithdrawBySig(b, amount, 1, deadline, badW);

        bytes memory goodW = VoucherSigner.signRequestWithdraw(k1, dom, b, amount, 1, deadline);
        vm.prank(relayer);
        escrow.requestWithdrawBySig(b, amount, 1, deadline, goodW);
        assertEq(escrow.escrowOf(b).withdrawRequested, amount);
        assertEq(
            escrow.escrowOf(b).withdrawAvailableAt,
            amount == 0 ? 0 : uint64(block.timestamp) + Constants.WITHDRAW_DELAY_SECONDS
        );
    }

    // --- what stops re-entrancy on these paths -------------------------------------------------

    /// **Nothing has to.** None of the four doors makes an external call, so there is no point
    /// from which a hostile asset could re-enter; `nonReentrant` on them is belt with no brace.
    /// That is a property of the code as written and not of the token, so it is measured here
    /// against an asset that reverts on every call but `decimals()`.
    ///
    /// It is the limit/withdraw-request counterpart of
    /// `test_everyEffectIsWrittenBeforeTheFirstTransfer`: that test exists because `_redeem` HAS an
    /// interaction and the ordering around it is what matters; this one exists because these four
    /// do not, and the way that silently stops being true is somebody adding a read of the asset.
    function test_theFourDoorsMakeNoExternalCallAtAll() public {
        InertAsset inert = new InertAsset();
        X402Escrow e2 = _deployEscrow(address(inert), address(0));

        vm.prank(buyer);
        e2.setLimits(1_000_000, 5_000_000);

        bytes32 dom = e2.DOMAIN_SEPARATOR();
        uint64 deadline = uint64(block.timestamp) + 600;

        bytes memory s1 =
            VoucherSigner.signSetLimits(buyerKey, dom, buyer, 2_000_000, 5_000_000, 0, deadline);
        vm.prank(relayer);
        e2.setLimitsBySig(buyer, 2_000_000, 5_000_000, 0, deadline, s1);

        vm.prank(buyer);
        e2.requestWithdraw(1_000);

        bytes memory s2 =
            VoucherSigner.signRequestWithdraw(buyerKey, dom, buyer, 2_000, 1, deadline);
        vm.prank(relayer);
        e2.requestWithdrawBySig(buyer, 2_000, 1, deadline, s2);

        assertEq(e2.escrowOf(buyer).maxVoucherAmount, 2_000_000);
        assertEq(e2.escrowOf(buyer).withdrawRequested, 2_000);
    }

    // --- the debt these doors owe: the Rust const-assert has no Solidity equivalent ----------

    /// `constants.rs:285` is `const _: () = assert!(WITHDRAW_DELAY_SECONDS >
    /// MAX_VOUCHER_REDEEMABLE_LIFE_SECONDS)`, so on Solana lowering the delay fails the BUILD.
    /// Solidity has no constant assertion, so `initialize` re-states it as a runtime check that
    /// the optimiser folds to nothing — which means no input can reach it and no behavioural test
    /// can kill its deletion. This is the test that can.
    ///
    /// It asserts four things, and each of them is a different way the invariant dies:
    ///
    ///   1. the 2,220 is DERIVED from its three terms and never typed, so an edit to any term
    ///      moves it;
    ///   2. the inequality holds today, at the values `constants.rs` carries;
    ///   3. `initialize` really contains the check, spelled against the derived constant and not
    ///      against a re-spelled sum that would go on checking the old form after an edit;
    ///   4. the delay `requestWithdraw` actually schedules with is the same constant — otherwise
    ///      `initialize` would be guarding a number nothing uses.
    function test_theWithdrawDelayOutlivesEveryVoucherSignedBeforeTheRequest() public {
        uint64 derived = Constants.CLOCK_SKEW_TOLERANCE_SECONDS
            + Constants.VOUCHER_MAX_LIFETIME_SECONDS + Constants.REDEEM_GRACE_SECONDS;
        assertEq(Constants.MAX_VOUCHER_REDEEMABLE_LIFE_SECONDS, derived, "2,220 is derived");
        assertEq(derived, 2_220);
        assertGt(Constants.WITHDRAW_DELAY_SECONDS, derived, "3,600 > 2,220");

        string memory src = vm.readFile(string.concat(vm.projectRoot(), "/src/X402Escrow.sol"));
        assertEq(
            _count(
                src,
                "        if (Constants.WITHDRAW_DELAY_SECONDS <= Constants.MAX_VOUCHER_REDEEMABLE_LIFE_SECONDS) {\n            revert WithdrawDelayTooShort();\n        }\n"
            ),
            1,
            "initialize no longer carries the const-assert the Rust build carries"
        );
        assertEq(
            _count(src, "WithdrawDelayTooShort()"), 1, "raised somewhere other than initialize"
        );

        // 4: the scheduled maturity really is one WITHDRAW_DELAY_SECONDS away, so the constant
        // `initialize` guards is the constant the clock is set by.
        uint64 t0 = uint64(block.timestamp);
        vm.prank(buyer);
        escrow.requestWithdraw(1);
        uint64 maturesAt = escrow.escrowOf(buyer).withdrawAvailableAt;
        assertEq(maturesAt, t0 + Constants.WITHDRAW_DELAY_SECONDS);
        assertGt(
            maturesAt - t0,
            derived,
            "a voucher issued at the request instant is dead before the exit matures"
        );
    }

    function _count(string memory haystack, string memory needle)
        internal
        pure
        returns (uint256 n)
    {
        bytes memory h = bytes(haystack);
        bytes memory x = bytes(needle);
        if (x.length == 0 || x.length > h.length) return 0;
        for (uint256 i = 0; i + x.length <= h.length; i++) {
            uint256 j = 0;
            while (j < x.length && h[i + j] == x[j]) j++;
            if (j == x.length) n++;
        }
    }
}
