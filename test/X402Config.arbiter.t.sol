// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.24;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Fixture} from "./helpers/Fixture.sol";
import {ParamSet} from "../src/Types.sol";
import {Constants} from "../src/Constants.sol";
import "../src/Errors.sol";

/// The three additions of the dispute upgrade to X402Config: the arbiter, the blocklist and the
/// settable slash delay. Their consumers are tested in `X402Stake.dispute.t.sol`,
/// `Blocklist.t.sol` and `Pause.t.sol`.
contract X402ConfigArbiterTest is Fixture {
    address internal arbiter = address(0xA4B1);
    address internal someone = address(0x5E1F);

    event ArbiterSet(address indexed previousArbiter, address indexed newArbiter);
    event SlashDelaySet(uint64 previousDelay, uint64 newDelay);
    event BlockedSet(address indexed account, bool blocked, address indexed by);

    // === arbiter =============================================================================

    function test_happyPath_theAdminAppointsAndRemovesTheArbiter() public {
        assertEq(config.arbiter(), address(0), "no arbiter until appointed");

        vm.expectEmit(address(config));
        emit ArbiterSet(address(0), arbiter);
        vm.prank(admin);
        config.setArbiter(arbiter);
        assertEq(config.arbiter(), arbiter);

        vm.expectEmit(address(config));
        emit ArbiterSet(arbiter, address(0));
        vm.prank(admin);
        config.setArbiter(address(0));
        assertEq(config.arbiter(), address(0), "address(0) means no arbiter");
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
        vm.expectRevert(NotAdmin.selector);
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

    /// Lower bound: `MIN_SLASH_DELAY_SECONDS`. Upper bound: the live unbonding period (14 days
    /// in the fixture) minus `SLASH_PATH_MARGIN_SECONDS` (8 days), so 6 days here.
    function test_boundary_theSlashDelayBounds() public {
        uint64 min = Constants.MIN_SLASH_DELAY_SECONDS;
        uint64 max = config.params().unbondingPeriodSeconds - Constants.SLASH_PATH_MARGIN_SECONDS;
        assertEq(Constants.SLASH_PATH_MARGIN_SECONDS, 8 * 86_400);
        assertEq(max, 6 * 86_400);

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

    /// The other side of the same inequality: once the delay is long, the unbonding period
    /// cannot be lowered under `delay + margin`, so a provider still cannot outrun the path.
    function test_boundary_theUnbondingPeriodCoversTheLiveDelay() public {
        vm.prank(admin);
        config.setSlashDelay(5 * 86_400); // needs unbonding >= 13 days

        ParamSet memory p = config.params();
        p.unbondingPeriodSeconds = 13 * 86_400 - 1;
        vm.prank(admin);
        vm.expectRevert(UnbondingPeriodTooShort.selector);
        config.updateConfig(p, address(0));

        p.unbondingPeriodSeconds = 13 * 86_400;
        vm.prank(admin);
        config.updateConfig(p, address(0));
        assertEq(config.params().unbondingPeriodSeconds, 13 * 86_400);

        // At or below the default delay, the floor stays MIN_UNBONDING_PERIOD_SECONDS.
        vm.prank(admin);
        config.setSlashDelay(Constants.MIN_SLASH_DELAY_SECONDS);
        p.unbondingPeriodSeconds = Constants.MIN_UNBONDING_PERIOD_SECONDS - 1;
        vm.prank(admin);
        vm.expectRevert(UnbondingPeriodTooShort.selector);
        config.updateConfig(p, address(0));
        p.unbondingPeriodSeconds = Constants.MIN_UNBONDING_PERIOD_SECONDS;
        vm.prank(admin);
        config.updateConfig(p, address(0));
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
}
