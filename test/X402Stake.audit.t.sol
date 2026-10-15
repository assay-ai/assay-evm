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

    /// Also raises `minimumStake` to the smallest the provider-day rule admits (a provider at the
    /// minimum fits two penalties a day). `minimumStake` gates only escrow redemption, so the
    /// 1 000 USDG `BOND` here may sit below it: that is the reachable case (a provider slashed
    /// under the minimum) where one record can still fill a provider-day, which these tests need.
    function _params(uint64 penalty, uint16 capBps, uint64 dailyCap) internal {
        ParamSet memory p = config.params();
        p.penaltyAmount = penalty;
        p.slashCapBps = capBps;
        p.verifierDailyCap = dailyCap;
        uint256 floor_ = (2 * uint256(penalty) * 10_000 + capBps - 1) / capBps;
        if (p.minimumStake < floor_) p.minimumStake = uint64(floor_);
        vm.prank(admin);
        config.updateConfig(p, address(0));
    }

    // === fix 1: the cap write-off (A M-1, B B1, C C2) ========================================

    /// Review 2026-10-15 R-5: the stake proxy as beneficiary would strand the 60 % share.
    function test_review_theStakeProxyCannotBeTheBeneficiary() public {
        SlashAttestation memory a = SlashAttestation({
            requestId: "self",
            provider: provider,
            beneficiary: address(stake),
            status: uint8(ResponseClass.DataFail),
            penalty: 1_000_000,
            policy: keccak256("p"),
            issuedAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp) + 1 days
        });
        bytes memory sig = VoucherSigner.signAttestation(vPk, stake.DOMAIN_SEPARATOR(), a);
        vm.expectRevert(MissingBeneficiary.selector);
        stake.proposeSlash(a, sig);
    }

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
        _params(100_000_000, 5_000, 200_000_000); // the key-day holds two penalties (G-1)
        _bond(provider2, BOND);
        _propose("other", provider2, 100_000_000);
        _propose("other2", provider2, 100_000_000);
        _propose("mine", provider, 100_000_000);
        vm.warp(stake.slashRecordOf("mine").executableAt);
        stake.executeSlash("other");
        stake.executeSlash("other2"); // fills the key's day

        vm.warp(block.timestamp + 1);
        vm.prank(provider);
        vm.expectRevert(SlashWindowNotDrained.selector);
        stake.executeSlash("mine");

        vm.warp(block.timestamp + Constants.SLASH_WINDOW_SECONDS);
        stake.executeSlash("mine");
        assertEq(stake.slashRecordOf("mine").applied, 100_000_000, "paid in full");
    }

    /// All or wait (owner decision, audit F R4): there is no last-day exception. A judgement that
    /// never fits whole before its deadline is not paid in part — it expires in the provider's
    /// favour, and `applied == reserved` holds for every executed record.
    function test_audit_noPartialPaymentEvenInTheLastDay() public {
        _params(100_000_000, 1_000, 500_000_000);
        _propose("s1", provider, 100_000_000);
        _propose("s2", provider, 100_000_000);
        uint256 deadline = uint256(stake.slashRecordOf("s2").executableAt)
            + Constants.SLASH_EXECUTION_GRACE_SECONDS;

        vm.warp(deadline - 2);
        stake.executeSlash("s1"); // fills the provider's window
        vm.warp(deadline - 1);
        vm.expectRevert(SlashWindowNotDrained.selector);
        stake.executeSlash("s2");

        vm.warp(deadline);
        vm.expectRevert(SlashExecutionWindowClosed.selector);
        stake.executeSlash("s2");
        stake.expireSlash("s2");
        assertEq(uint256(stake.slashRecordOf("s2").status), uint256(SlashStatus.Cancelled));
        assertEq(stake.slashRecordOf("s2").applied, 0, "never paid in part");
        assertEq(stake.slashRecordOf("s1").applied, 100_000_000, "s1 paid whole");
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
        // `_assertRolesDistinct` (audit F R5) names the arbiter overlap `InvalidArbiter`.
        vm.prank(owner);
        vm.expectRevert(InvalidArbiter.selector);
        config.setAdmin(arb);
        assertEq(config.admin(), admin);
    }

    function test_audit_B12_aVerifierIsNeverTheAdminOrTheArbiter() public {
        uint64 exp = uint64(block.timestamp) + 30 days;
        vm.startPrank(admin);
        vm.expectRevert(InvalidArbiter.selector);
        config.registerVerifier(arb, bytes32("x"), exp);
        vm.expectRevert(InvalidAdmin.selector);
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

    /// Since review 2026-10-15 R-1 the C7 rule is subsumed by the provider-day rule
    /// (`minimumStake * slashCapBps / 10_000 >= 2 * penaltyAmount`): with any non-zero penalty a
    /// cap that rounds to 0 is refused, and so is one that holds a single penalty.
    function test_audit_C7_aMinimumStakeWhoseCapRoundsToZeroIsRefused() public {
        ParamSet memory p = config.params(); // slashCapBps 1 000
        p.penaltyAmount = 1;
        p.minimumStake = 9; // 9 * 1000 / 10000 = 0
        vm.prank(admin);
        vm.expectRevert(InvalidMinimumStake.selector);
        config.updateConfig(p, address(0));
        p.minimumStake = 19; // = 1: slashable, but one penalty fills the provider-day
        vm.prank(admin);
        vm.expectRevert(InvalidMinimumStake.selector);
        config.updateConfig(p, address(0));
        p.minimumStake = 20; // = 2: two penalties fit
        vm.prank(admin);
        config.updateConfig(p, address(0));
        assertEq(config.params().minimumStake, 20);
    }

    function test_audit_C7_aPenaltyAboveTheDailyCapIsRefused() public {
        ParamSet memory p = config.params();
        // Audit G G-1: the daily cap must hold TWO maximal penalties.
        p.verifierDailyCap = 2 * p.penaltyAmount - 1;
        vm.prank(admin);
        vm.expectRevert(InvalidVerifierDailyCap.selector);
        config.updateConfig(p, address(0));
        p.verifierDailyCap = p.penaltyAmount; // one penalty is no longer enough
        vm.prank(admin);
        vm.expectRevert(InvalidVerifierDailyCap.selector);
        config.updateConfig(p, address(0));
        p.verifierDailyCap = 2 * p.penaltyAmount; // exactly two is admitted
        vm.prank(admin);
        config.updateConfig(p, address(0));
    }

    // === audit F R3: the delay is not coupled to the unbonding period ============================

    /// The longest delay (22 d) over the shortest unbonding (11 d) — refused by the old coupling —
    /// cannot be outrun: once proposed, the reservation holds, so a fully matured exit takes only
    /// `BOND - reserved`, and the slash later executes in full.
    function test_longDelayShortUnbondingCannotBeOutrun() public {
        ParamSet memory p = config.params();
        p.unbondingPeriodSeconds = Constants.MIN_UNBONDING_PERIOD_SECONDS;
        vm.startPrank(admin);
        config.updateConfig(p, address(0));
        config.setSlashDelay(Constants.MAX_SLASH_DELAY_SECONDS);
        vm.stopPrank();

        _propose("long", provider, 1_000_000);
        uint64 reserved = stake.slashRecordOf("long").reserved;
        assertEq(reserved, 1_000_000);

        vm.prank(provider);
        stake.requestUnstake(BOND);
        vm.warp(block.timestamp + Constants.MIN_UNBONDING_PERIOD_SECONDS);
        assertEq(stake.withdrawableOf(provider), BOND - reserved, "only the free part can leave");
        vm.prank(provider);
        vm.expectRevert(InsufficientUnbondingStake.selector);
        stake.withdrawStake(BOND);
        vm.prank(provider);
        stake.withdrawStake(BOND - reserved);

        vm.warp(stake.slashRecordOf("long").executableAt);
        stake.executeSlash("long");
        assertEq(stake.slashRecordOf("long").applied, reserved, "paid in full");
        assertEq(usdg.balanceOf(beneficiary), 600_000);
    }
}
