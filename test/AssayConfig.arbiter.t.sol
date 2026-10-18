// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.24;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Fixture} from "./helpers/Fixture.sol";
import {ParamSet} from "../src/Types.sol";
import {Constants} from "../src/Constants.sol";
import "../src/Errors.sol";

/// The three additions of the dispute upgrade to AssayConfig: the arbiter, the blocklist and the
/// settable slash delay. Their consumers are tested in `AssayStake.dispute.t.sol`,
/// `Blocklist.t.sol` and `Pause.t.sol`.
contract AssayConfigArbiterTest is Fixture {
    address internal arbiter = address(0xA4B1);
    address internal someone = address(0x5E1F);

    event ArbiterSet(address indexed previousArbiter, address indexed newArbiter);
    event SlashDelaySet(uint64 previousDelay, uint64 newDelay);
    event BlockedSet(address indexed account, bool blocked, address indexed by);

    // === arbiter =============================================================================

    function test_happyPath_theAdminAppointsAndReplacesTheArbiter() public {
        assertEq(config.arbiter(), address(0), "no arbiter until appointed");

        vm.expectEmit(address(config));
        emit ArbiterSet(address(0), arbiter);
        vm.prank(admin);
        config.setArbiter(arbiter);
        assertEq(config.arbiter(), arbiter);

        vm.expectEmit(address(config));
        emit ArbiterSet(arbiter, someone);
        vm.prank(admin);
        config.setArbiter(someone);
        assertEq(config.arbiter(), someone, "replaced");

        // Never removed (audit A M-2): address(0) is refused.
        vm.prank(admin);
        vm.expectRevert(InvalidArbiter.selector);
        config.setArbiter(address(0));
    }

    function test_wrongSigner_onlyTheAdminSetsTheArbiter() public {
        vm.prank(admin);
        config.setArbiter(arbiter);
        address[4] memory others = [owner, arbiter, redeemer, someone];
        for (uint256 i = 0; i < others.length; i++) {
            vm.prank(others[i]);
            vm.expectRevert(NotAdmin.selector);
            config.setArbiter(others[i]);
        }
        assertEq(config.arbiter(), arbiter);
    }

    // === blocklist ===========================================================================

    function test_happyPath_theAdminBlocksAndUnblocks() public {
        vm.expectEmit(address(config));
        emit BlockedSet(someone, true, admin);
        vm.prank(admin);
        config.setBlocked(someone, true);
        assertTrue(config.blocked(someone));

        vm.expectEmit(address(config));
        emit BlockedSet(someone, false, admin);
        vm.prank(admin);
        config.setBlocked(someone, false);
        assertFalse(config.blocked(someone));
    }

    function test_theArbiterMayBlockButNeverUnblock() public {
        vm.prank(admin);
        config.setArbiter(arbiter);

        vm.expectEmit(address(config));
        emit BlockedSet(someone, true, arbiter);
        vm.prank(arbiter);
        config.setBlocked(someone, true);
        assertTrue(config.blocked(someone));

        vm.prank(arbiter);
        vm.expectRevert(ArbiterCannotUnblock.selector);
        config.setBlocked(someone, false);
        assertTrue(config.blocked(someone), "still blocked");
    }

    function test_wrongSigner_nobodyElseTouchesTheBlocklist() public {
        address[3] memory others = [owner, redeemer, someone];
        for (uint256 i = 0; i < others.length; i++) {
            vm.prank(others[i]);
            vm.expectRevert(NotAdmin.selector);
            config.setBlocked(buyer, true);
        }
        assertFalse(config.blocked(buyer));
    }

    function test_wrongArgs_theZeroAddressIsNeverBlocked() public {
        vm.prank(admin);
        vm.expectRevert(ZeroAddress.selector);
        config.setBlocked(address(0), true);
    }

    function test_assertActiveChecksThePauseThenEverySlot() public {
        config.assertActive(buyer, provider, address(0));

        vm.prank(admin);
        config.setBlocked(provider, true);
        vm.expectRevert(AddressBlocked.selector);
        config.assertActive(provider, address(0), address(0));
        vm.expectRevert(AddressBlocked.selector);
        config.assertActive(buyer, provider, address(0));
        vm.expectRevert(AddressBlocked.selector);
        config.assertActive(buyer, address(0), provider);

        vm.prank(admin);
        config.setPaused(true);
        vm.expectRevert(ProgramPaused.selector);
        config.assertActive(provider, address(0), address(0));
        vm.expectRevert(ProgramPaused.selector);
        config.assertActive(address(0), address(0), address(0));
    }

    // === slash delay =========================================================================

    function test_theSlashDelayDefaultsToSeventyTwoHours() public view {
        assertEq(config.slashDelaySeconds(), Constants.SLASH_DELAY_SECONDS);
        assertEq(Constants.SLASH_DELAY_SECONDS, 72 * 3600);
    }

    function test_happyPath_theAdminSetsTheSlashDelay() public {
        vm.expectEmit(address(config));
        emit SlashDelaySet(Constants.SLASH_DELAY_SECONDS, 3600);
        vm.prank(admin);
        config.setSlashDelay(3600);
        assertEq(config.slashDelaySeconds(), 3600);
    }

    function test_wrongSigner_onlyTheAdminSetsTheSlashDelay() public {
        vm.prank(admin);
        config.setArbiter(arbiter);
        address[4] memory others = [owner, arbiter, redeemer, someone];
        for (uint256 i = 0; i < others.length; i++) {
            vm.prank(others[i]);
            vm.expectRevert(NotAdmin.selector);
            config.setSlashDelay(3600);
        }
    }

    /// Fixed bounds since audit F R3: `[MIN_SLASH_DELAY_SECONDS, MAX_SLASH_DELAY_SECONDS]`,
    /// 10 minutes to 22 days, whatever the unbonding period.
    function test_boundary_theSlashDelayBounds() public {
        uint64 min = Constants.MIN_SLASH_DELAY_SECONDS;
        uint64 max = Constants.MAX_SLASH_DELAY_SECONDS;
        assertEq(min, 600);
        assertEq(max, 22 * 86_400);
        assertLt(config.params().unbondingPeriodSeconds, max, "the fixture's 14 d is below it");

        vm.startPrank(admin);
        vm.expectRevert(InvalidSlashDelay.selector);
        config.setSlashDelay(0);
        vm.expectRevert(InvalidSlashDelay.selector);
        config.setSlashDelay(min - 1);
        config.setSlashDelay(min);
        assertEq(config.slashDelaySeconds(), min);
        config.setSlashDelay(max);
        assertEq(config.slashDelaySeconds(), max);
        vm.expectRevert(InvalidSlashDelay.selector);
        config.setSlashDelay(max + 1);
        vm.expectRevert(InvalidSlashDelay.selector);
        config.setSlashDelay(type(uint64).max);
        vm.stopPrank();
    }

    /// The coupling is gone in both directions: with the delay at its maximum, the unbonding
    /// period may still go down to `MIN_UNBONDING_PERIOD_SECONDS`, and not below.
    function test_boundary_theUnbondingFloorIsIndependentOfTheDelay() public {
        vm.prank(admin);
        config.setSlashDelay(Constants.MAX_SLASH_DELAY_SECONDS);

        ParamSet memory p = config.params();
        p.unbondingPeriodSeconds = Constants.MIN_UNBONDING_PERIOD_SECONDS - 1;
        vm.prank(admin);
        vm.expectRevert(UnbondingPeriodTooShort.selector);
        config.updateConfig(p);
        p.unbondingPeriodSeconds = Constants.MIN_UNBONDING_PERIOD_SECONDS;
        vm.prank(admin);
        config.updateConfig(p);
        assertEq(config.params().unbondingPeriodSeconds, Constants.MIN_UNBONDING_PERIOD_SECONDS);
    }

    /// None of the three new setters is the owner's: `onlyOwner` still gates only the upgrade
    /// and the admin appointment.
    function test_theOwnerHoldsNoneOfTheNewDoors() public {
        vm.startPrank(owner);
        vm.expectRevert(NotAdmin.selector);
        config.setArbiter(arbiter);
        vm.expectRevert(NotAdmin.selector);
        config.setSlashDelay(3600);
        vm.expectRevert(NotAdmin.selector);
        config.setBlocked(someone, true);
        vm.stopPrank();
        // and the owner's own door is unchanged
        vm.prank(arbiter);
        vm.expectRevert(
            abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, arbiter)
        );
        config.setAdmin(arbiter);
    }

    /// I4: the arbiter is a separate person — never the admin, never a live verifier. A revoked
    /// verifier address is no longer a verifier and may be appointed.
    function test_wrongArgs_setArbiterRefusesTheAdminAndALiveVerifier() public {
        address v = address(0x7E57);
        vm.startPrank(admin);
        config.registerVerifier(v, bytes32("v"), uint64(block.timestamp) + 30 days);
        vm.expectRevert(InvalidArbiter.selector);
        config.setArbiter(admin);
        vm.expectRevert(InvalidArbiter.selector);
        config.setArbiter(v);

        // Expired but not revoked is still a registered, non-revoked verifier: refused.
        vm.warp(block.timestamp + 31 days);
        vm.expectRevert(InvalidArbiter.selector);
        config.setArbiter(v);

        config.revokeVerifier(v);
        config.setArbiter(v);
        vm.stopPrank();
        assertEq(config.arbiter(), v);
    }
}
