// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.24;

import {Fixture} from "./helpers/Fixture.sol";
import {VoucherSigner} from "./helpers/VoucherSigner.sol";
import {X402Stake} from "../src/X402Stake.sol";
import {SlashAttestation, ResponseClass, SlashStatus, ParamSet} from "../src/Types.sol";
import {Constants} from "../src/Constants.sol";
import "../src/Errors.sol";

/// Regressions built from the three audits of `a4f97ab` (audit A adversarial, B business,
/// C economics). Each test is the auditor's proof turned around to assert the fixed behaviour.
contract X402StakeAuditTest is Fixture {
    uint256 internal vPk = 0xA0D17;
    address internal vAddr;
    address internal beneficiary = address(0xBE4E);
    address internal arb = address(0xA4B1);
    address internal provider2 = address(0x9310);
    uint64 internal constant BOND = 1_000_000_000; // 1,000 USDG

    function setUp() public override {
        super.setUp();
        stake = _deployStake(address(usdg));
        vAddr = vm.addr(vPk);
        vm.startPrank(admin);
        config.registerVerifier(vAddr, bytes32("v"), uint64(block.timestamp) + 180 days);
        config.setArbiter(arb);
        vm.stopPrank();
        _bond(provider, BOND);
    }

    function _bond(address p, uint64 amt) internal {
        _fund(p, amt);
        vm.startPrank(p);
        usdg.approve(address(stake), amt);
        stake.depositStake(amt);
        vm.stopPrank();
    }

    function _propose(bytes32 id, address p, uint64 penalty) internal {
        SlashAttestation memory a = SlashAttestation({
            requestId: id,
            provider: p,
            beneficiary: beneficiary,
            status: uint8(ResponseClass.DataFail),
            penalty: penalty,
            policy: keccak256("p"),
            issuedAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp) + 1 days
        });
        bytes memory sig = VoucherSigner.signAttestation(vPk, stake.DOMAIN_SEPARATOR(), a);
        stake.proposeSlash(a, sig);
    }

    function _params(uint64 penalty, uint16 capBps, uint64 dailyCap) internal {
        ParamSet memory p = config.params();
        p.penaltyAmount = penalty;
        p.slashCapBps = capBps;
        p.verifierDailyCap = dailyCap;
        vm.prank(admin);
        config.updateConfig(p, address(0));
    }

    // === fix 1: the cap write-off (A M-1, B B1, C C2) ========================================

    /// The auditor's M-1: the provider executed s2 one second after s1 filled its window and
    /// discharged a 100 USDG judgement for ~0.001 USDG. Now the dust execution is refused, the
    /// record stays Pending, and once the window has drained it pays in full.
    function test_audit_M1_aWindowCutPaymentIsRefusedUntilTheWindowDrains() public {
        _params(100_000_000, 1_000, 500_000_000);
        _propose("s1", provider, 100_000_000);
        _propose("s2", provider, 100_000_000);

        vm.warp(stake.slashRecordOf("s1").executableAt);
        stake.executeSlash("s1");

        vm.warp(block.timestamp + 1);
        vm.prank(provider);
        vm.expectRevert(SlashWindowNotDrained.selector);
        stake.executeSlash("s2");
        assertEq(uint256(stake.slashRecordOf("s2").status), uint256(SlashStatus.Pending));
        assertEq(stake.stakeOf(provider).pendingSlash, 100_000_000, "still reserved");

        vm.warp(block.timestamp + Constants.SLASH_WINDOW_SECONDS);
        stake.executeSlash("s2");
        assertEq(stake.slashRecordOf("s2").applied, 100_000_000, "paid in full");
    }

    /// M-1b: the same through the verifier key's shared window.
    function test_audit_M1b_theSharedKeyWindowCannotBeUsedToDischargeEither() public {
        _params(100_000_000, 5_000, 100_000_000);
        _bond(provider2, BOND);
        _propose("other", provider2, 100_000_000);
        _propose("mine", provider, 100_000_000);
        vm.warp(stake.slashRecordOf("mine").executableAt);
        stake.executeSlash("other"); // fills the key's day

        vm.warp(block.timestamp + 1);
        vm.prank(provider);
        vm.expectRevert(SlashWindowNotDrained.selector);
        stake.executeSlash("mine");

        vm.warp(block.timestamp + Constants.SLASH_WINDOW_SECONDS);
        stake.executeSlash("mine");
        assertEq(stake.slashRecordOf("mine").applied, 100_000_000, "paid in full");
    }

    /// The exception: in the last `SLASH_WINDOW_SECONDS` before `executableAt + grace` a
    /// window-cut payment is allowed, so the record is paid something before it expires. The
    /// boundary instant belongs to the partial payment.
    function test_audit_theLastDayOfTheGraceAllowsAPartialPayment() public {
        _params(100_000_000, 1_000, 500_000_000);
        _propose("s1", provider, 100_000_000);
        _propose("s2", provider, 100_000_000);
        uint256 lastDay = uint256(stake.slashRecordOf("s2").executableAt)
            + Constants.SLASH_EXECUTION_GRACE_SECONDS - Constants.SLASH_WINDOW_SECONDS;

        vm.warp(lastDay - 2);
        stake.executeSlash("s1"); // fills the window
        vm.warp(lastDay - 1);
        vm.expectRevert(SlashWindowNotDrained.selector);
        stake.executeSlash("s2");

        vm.warp(lastDay);
        stake.executeSlash("s2");
        X402Stake.SlashRecord memory r = stake.slashRecordOf("s2");
        assertEq(uint256(r.status), uint256(SlashStatus.Executed));
        assertLt(r.applied, 100_000_000, "a partial payment, as before");
        assertGt(r.applied, 0);
        assertEq(stake.stakeOf(provider).pendingSlash, 0);
    }

    // === fix 2: no arbiter means no free veto (A M-2, C C4) ===================================

    function test_audit_M2_theArbiterCanNeverBeUnset() public {
        vm.prank(admin);
        vm.expectRevert(InvalidArbiter.selector);
        config.setArbiter(address(0));
        assertEq(config.arbiter(), arb);
    }

    // === fix 3: one key in two roles (A L-3, B B12) ===========================================

    function test_audit_L3_theAdminCanNeverBecomeTheArbiter() public {
        vm.prank(owner);
        vm.expectRevert(InvalidAdmin.selector);
        config.setAdmin(arb);
        assertEq(config.admin(), admin);
    }

    function test_audit_B12_aVerifierIsNeverTheAdminOrTheArbiter() public {
        uint64 exp = uint64(block.timestamp) + 30 days;
        vm.startPrank(admin);
        vm.expectRevert(VerifierIsAdminOrArbiter.selector);
        config.registerVerifier(arb, bytes32("x"), exp);
        vm.expectRevert(VerifierIsAdminOrArbiter.selector);
        config.registerVerifier(admin, bytes32("x"), exp);
        vm.stopPrank();
        assertFalse(config.verifierKey(arb).registered);
    }

    // === fix 4: error names (B B10) ===========================================================

    function test_audit_B10_theTwoMisleadingErrorsHaveTheirOwnNames() public {
        _propose("e1", provider, 1_000_000);
        vm.prank(provider);
        stake.disputeSlash("e1");
        vm.prank(arb);
        stake.upholdSlash("e1");
        vm.prank(provider);
        vm.expectRevert(SlashAlreadyDisputed.selector);
        stake.disputeSlash("e1");

        vm.prank(arb);
        config.setBlocked(provider2, true);
        vm.prank(arb);
        vm.expectRevert(ArbiterCannotUnblock.selector);
        config.setBlocked(provider2, false);
    }

    // === fix 5: parameter cross-checks (C C7) =================================================

    function test_audit_C7_aMinimumStakeWhoseCapRoundsToZeroIsRefused() public {
        ParamSet memory p = config.params(); // slashCapBps 1 000
        p.minimumStake = 9; // 9 * 1000 / 10000 = 0
        vm.prank(admin);
        vm.expectRevert(InvalidMinimumStake.selector);
        config.updateConfig(p, address(0));
        p.minimumStake = 10; // = 1: slashable
        vm.prank(admin);
        config.updateConfig(p, address(0));
    }

    function test_audit_C7_aPenaltyAboveTheDailyCapIsRefused() public {
        ParamSet memory p = config.params();
        p.verifierDailyCap = p.penaltyAmount - 1;
        vm.prank(admin);
        vm.expectRevert(InvalidVerifierDailyCap.selector);
        config.updateConfig(p, address(0));
        p.verifierDailyCap = p.penaltyAmount; // equal is admitted
        vm.prank(admin);
        config.updateConfig(p, address(0));
    }
}
