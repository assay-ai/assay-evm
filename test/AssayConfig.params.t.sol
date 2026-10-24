// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {AssayConfig} from "../src/AssayConfig.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ParamSet} from "../src/Types.sol";
import "../src/Errors.sol";

/// `update_config`, ported. One door, no timelock, no pending slot, no two-step handover.
///
/// **The trap this file is written against.** The recurring defect in this suite is a test that
/// *relates* where it should *pin*. Here that shape has two specific faces, and each has a test
/// built to kill it rather than a comment asking the reader to be careful:
///
///   1. a test that confirms one field **changed** without confirming the other nine did **not**
///      — killed by `test_updateWritesTheWholeSetItWasGivenTwiceOver`, which reads all ten fields
///      back after each of two updates carrying two fully disjoint value sets;
///   2. a happy path satisfied by an `updateConfig` that **ignores its argument** and writes a
///      literal — killed by the same test, because no literal satisfies two disjoint sets;
///   3. a suite made entirely of refusals, which cannot see a precondition the port **invented** —
///      an invented rule only ever refuses sets no test sends. `test_updateAddsNoPreconditionThe`
///      `ReferenceLacks` is the negative space;
///   4. a door with no caller check — killed by `test_wrongSigner_onlyAdminUpdates`.
///
/// Every refusal here also re-asserts the full pre-state. **That is bookkeeping, not a contract
/// property**: a revert on the EVM rolls everything back whatever the implementation did first, so
/// those assertions cannot fail for any implementation that reverts at all (mutation log C47).
/// They are kept because they make a refusal row report *which* field moved if one ever does.
contract AssayConfigParamsTest is Test {
    AssayConfig internal config;
    AssayConfig internal configImpl;

    address internal admin = address(0xADAA);
    address internal constant OWNER = address(0x0A1E);
    address internal next = address(0xBEEF);
    address internal stranger = address(0x57A2);

    /// The set every proxy here starts from.
    function _valid() internal pure returns (ParamSet memory p) {
        p = ParamSet({
            treasury: address(0x7EA5),
            redeemer: address(0x4EED),
            unbondingPeriodSeconds: 14 * 86_400,
            minimumStake: 100_000_000, // 100 USDG
            penaltyAmount: 1_000_000, //   1 USDG
            verifierDailyCap: 500_000_000,
            takeRateBps: 1_000,
            slashAgentBps: 6_000,
            slashPlatformBps: 3_000,
            slashCapBps: 1_000
        });
    }

    /// A legal set differing from `_valid()` in **all ten** fields.
    function _other() internal pure returns (ParamSet memory p) {
        p = ParamSet({
            treasury: address(0xF00D),
            redeemer: address(0xCAFE),
            unbondingPeriodSeconds: 20 * 86_400,
            minimumStake: 37, // 37 * 4 999 / 10 000 = 18 >= 2 * penaltyAmount (review R-1)
            penaltyAmount: 9,
            verifierDailyCap: 18, // >= 2 * penaltyAmount (audit G G-1)
            takeRateBps: 2_500,
            slashAgentBps: 4_000,
            slashPlatformBps: 1_000,
            slashCapBps: 4_999
        });
    }

    /// A legal set differing from **both** of the above in all ten fields, so that no stored
    /// literal — and no set the contract could have captured at initialisation — satisfies the
    /// two updates `test_updateWritesTheWholeSetItWasGivenTwiceOver` performs.
    function _third() internal pure returns (ParamSet memory p) {
        p = ParamSet({
            treasury: address(0xB0A7),
            redeemer: address(0xD0E5),
            unbondingPeriodSeconds: 30 * 86_400,
            // The smallest minimum a 1-bps cap admits for this penalty: two penalties fit one
            // provider-day (review R-1: 40 000 * 1 / 10 000 = 4 = 2 * 2), and two fit one
            // key-day (audit G G-1: verifierDailyCap = 2 * penaltyAmount).
            minimumStake: 40_000,
            penaltyAmount: 2,
            verifierDailyCap: 4,
            takeRateBps: 0,
            slashAgentBps: 1,
            slashPlatformBps: 0,
            slashCapBps: 1
        });
    }

    function setUp() public {
        vm.warp(1_760_000_000);
        configImpl = new AssayConfig();
        // Behind a proxy, like every AssayConfig in this suite (D-1).
        config = AssayConfig(
            address(
                new ERC1967Proxy(
                    address(configImpl),
                    abi.encodeCall(AssayConfig.initialize, (_valid(), admin, OWNER))
                )
            )
        );
    }

    // ---------------------------------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------------------------------

    /// All ten fields, individually named. `abi.encode` equality would catch the same defects but
    /// reports one opaque blob; a field-wise diff names the field that moved.
    function _assertParamsEq(ParamSet memory got, ParamSet memory want, string memory tag)
        internal
        pure
    {
        assertEq(got.treasury, want.treasury, string.concat(tag, ": treasury"));
        assertEq(got.redeemer, want.redeemer, string.concat(tag, ": redeemer"));
        assertEq(
            got.unbondingPeriodSeconds,
            want.unbondingPeriodSeconds,
            string.concat(tag, ": unbondingPeriodSeconds")
        );
        assertEq(got.minimumStake, want.minimumStake, string.concat(tag, ": minimumStake"));
        assertEq(got.penaltyAmount, want.penaltyAmount, string.concat(tag, ": penaltyAmount"));
        assertEq(
            got.verifierDailyCap, want.verifierDailyCap, string.concat(tag, ": verifierDailyCap")
        );
        assertEq(got.takeRateBps, want.takeRateBps, string.concat(tag, ": takeRateBps"));
        assertEq(got.slashAgentBps, want.slashAgentBps, string.concat(tag, ": slashAgentBps"));
        assertEq(
            got.slashPlatformBps, want.slashPlatformBps, string.concat(tag, ": slashPlatformBps")
        );
        assertEq(got.slashCapBps, want.slashCapBps, string.concat(tag, ": slashCapBps"));
    }

    /// One refused update: the named error, **and** a post-state identical to the pre-state, in
    /// both the parameters and the admin. Every bound row is therefore also an atomicity row.
    function _refused(ParamSet memory p, bytes4 selector, string memory tag) internal {
        ParamSet memory before = config.params();
        address adminBefore = config.admin();

        vm.prank(adminBefore);
        vm.expectRevert(selector);
        config.updateConfig(p);

        _assertParamsEq(config.params(), before, string.concat(tag, " moved a parameter"));
        assertEq(config.admin(), adminBefore, string.concat(tag, " moved the admin"));
    }

    // ---------------------------------------------------------------------------------------
    // the happy path
    // ---------------------------------------------------------------------------------------

    /// Every change applies in the slot it arrives — `update_config.rs`, verbatim.
    ///
    /// The nine untouched fields are read back too. Without them this test passes against an
    /// `updateConfig` that writes `takeRateBps` and zeroes everything beside it.
    function test_happyPath_aChangeBindsInTheSlotItArrives() public {
        ParamSet memory p = _valid();
        p.takeRateBps = 2_000;

        vm.prank(admin);
        config.updateConfig(p);

        assertEq(config.params().takeRateBps, 2_000, "the one field that changed");
        _assertParamsEq(config.params(), p, "the other nine are exactly as sent");
        assertEq(config.admin(), admin, "address(0) leaves the admin alone");
    }

    /// **The counterweight to every happy path in this file.** Two updates, two value sets that
    /// share no field with each other or with `_valid()`, ten fields read back after each.
    ///
    /// A literal writer satisfies at most one of the two. A partial writer — one that lands the
    /// split and the take rate and leaves the addresses, say — dies on the first. An
    /// `updateConfig` that ignores `p` entirely dies on the first assertion of the first update.
    function test_updateWritesTheWholeSetItWasGivenTwiceOver() public {
        vm.prank(admin);
        config.updateConfig(_other());
        _assertParamsEq(config.params(), _other(), "first update");

        vm.prank(admin);
        config.updateConfig(_third());
        _assertParamsEq(config.params(), _third(), "second update");

        // and the two sets really are disjoint, so the pair could not both be a literal.
        assertTrue(
            keccak256(abi.encode(_other())) != keccak256(abi.encode(_third())),
            "the two update sets differ"
        );
        assertTrue(
            keccak256(abi.encode(_valid())) != keccak256(abi.encode(_other())),
            "and neither is the initial set"
        );
    }

    /// The console's loop is read `params()`, patch one field, send the whole struct back. Handing
    /// the current set back unchanged is legal and is a no-op — there is no "must differ" rule on
    /// the **parameters**, unlike `EscrowLimitsUnchanged` on the escrow door.
    ///
    /// Only the parameters: the admin half of that same class is
    /// `test_handingTheAdminRoleToItselfIsLegalAndANoOp`, and this test says nothing about it.
    function test_handingTheCurrentSetBackUnchangedIsLegalAndChangesNothing() public {
        ParamSet memory current = config.params();
        vm.prank(admin);
        config.updateConfig(current);
        _assertParamsEq(config.params(), _valid(), "a re-send of the current set");
        assertEq(config.admin(), admin, "and it moves no admin");
    }

    // ---------------------------------------------------------------------------------------
    // who may call
    // ---------------------------------------------------------------------------------------

    /// A stranger may not rewrite the parameter set, and the refusal moves nothing.
    function test_wrongSigner_onlyAdminUpdates() public {
        vm.prank(stranger);
        vm.expectRevert(NotAdmin.selector);
        config.updateConfig(_other());

        _assertParamsEq(config.params(), _valid(), "a stranger moved no parameter");
        assertEq(config.admin(), admin, "and no admin");
    }

    // ---------------------------------------------------------------------------------------
    // the set is validated as a whole — update_config.rs
    // ---------------------------------------------------------------------------------------

    /// Validated AFTER every field lands, not per field. From (6000, 3000) to (3000, 7000) is
    /// legal as a set; a field-at-a-time check that landed `platform` first would see
    /// 6000 + 7000 and refuse a move the bounds permit. And the illegal set is still refused.
    function test_wrongState_theSetIsValidatedAsAWhole() public {
        ParamSet memory swap = _valid();
        swap.slashAgentBps = 3_000;
        swap.slashPlatformBps = 7_000;
        vm.prank(admin);
        config.updateConfig(swap); // must not revert
        assertEq(config.params().slashPlatformBps, 7_000, "the platform share moved up");
        assertEq(config.params().slashAgentBps, 3_000, "and the agent share moved down");

        ParamSet memory bad = _valid();
        bad.slashPlatformBps = 4_001; // 6000 + 4001 > 10000
        vm.prank(admin);
        vm.expectRevert(InvalidSplitBps.selector);
        config.updateConfig(bad);
    }

    /// **Every** bound `state.rs::Config::validate` states is reached through *this* door too, by
    /// name, and each refusal moves nothing. `test_wrongState_everyBoundIsRefusedAtConstruction`
    /// proves the same eleven rows through `initialize`; that a set reaching `_params` through
    /// `initialize` is bounded says nothing about a set reaching it through `updateConfig`.
    function test_wrongState_updateRefusesEveryBoundJustAsInitializeDoes() public {
        ParamSet memory p = _valid();
        p.treasury = address(0);
        _refused(p, MissingBeneficiary.selector, "zero treasury");

        p = _valid();
        p.redeemer = address(0);
        _refused(p, MissingRedeemer.selector, "zero redeemer");

        p = _valid();
        p.takeRateBps = 3_001; // MAX_TAKE_RATE_BPS + 1
        _refused(p, InvalidTakeRateBps.selector, "take rate over the ceiling");

        p = _valid();
        p.slashAgentBps = 0; // the agent must keep a share
        _refused(p, InvalidSplitBps.selector, "zero agent share");

        p = _valid();
        p.slashPlatformBps = 4_001; // 6000 + 4001 > 10000
        _refused(p, InvalidSplitBps.selector, "split over 10000");

        p = _valid();
        p.slashAgentBps = 60_000;
        p.slashPlatformBps = 10_000; // sums past uint16 — still refused BY NAME, not by panic
        _refused(p, InvalidSplitBps.selector, "split overflowing uint16");

        p = _valid();
        p.slashCapBps = 0;
        _refused(p, InvalidSlashCapBps.selector, "zero cap");

        p = _valid();
        p.slashCapBps = 5_001; // MAX_SLASH_CAP_BPS + 1
        _refused(p, InvalidSlashCapBps.selector, "cap over the ceiling");

        p = _valid();
        p.unbondingPeriodSeconds = 11 * 86_400 - 1;
        _refused(p, UnbondingPeriodTooShort.selector, "unbonding under the floor");

        p = _valid();
        p.unbondingPeriodSeconds = 30 * 86_400 + 1;
        _refused(p, UnbondingPeriodTooLong.selector, "unbonding over the ceiling");

        p = _valid();
        p.minimumStake = 0;
        _refused(p, InvalidMinimumStake.selector, "zero minimum stake");

        p = _valid();
        p.verifierDailyCap = 0;
        _refused(p, InvalidVerifierDailyCap.selector, "zero verifier daily cap");

        // The provider-day twin of G-1: a minimum-stake provider's cap must hold two penalties.
        p = _valid();
        p.penaltyAmount = uint64(uint256(p.minimumStake) * p.slashCapBps / 10_000 / 2 + 1);
        if (p.verifierDailyCap < 2 * p.penaltyAmount) p.verifierDailyCap = 2 * p.penaltyAmount;
        _refused(p, InvalidMinimumStake.selector, "minimum-stake cap under two penalties");
    }

    /// Exactly two penalties in a minimum-stake provider's day is allowed.
    function test_aMinimumStakeCapOfExactlyTwoPenaltiesIsAccepted() public {
        ParamSet memory p = _valid();
        p.penaltyAmount = uint64(uint256(p.minimumStake) * p.slashCapBps / 10_000 / 2);
        if (p.verifierDailyCap < 2 * p.penaltyAmount) p.verifierDailyCap = 2 * p.penaltyAmount;
        vm.prank(config.admin());
        config.updateConfig(p);
        assertEq(config.params().penaltyAmount, p.penaltyAmount);
    }

    /// An invalid set moves nothing — not the parameters and not the admin.
    ///
    /// **This does not prove "applied last", and it is not a stronger claim than C41's.** A revert
    /// on the EVM rolls back every write in the call, so this test passes against an
    /// `updateConfig` that writes the set and hands over *before* validating (mutation log C47),
    /// exactly as it passes against one that validates first. Atomicity here is a property of the
    /// machine, not of this contract. The test earns its place as a **regression guard on that
    /// machine property holding for this door** — the day someone reaches for a low-level call, a
    /// `try/catch` or an assembly `return` in here, it is what notices.
    function test_wrongState_anInvalidSetMovesNothing() public {
        ParamSet memory bad = _valid();
        bad.takeRateBps = 3_001;
        vm.prank(admin);
        vm.expectRevert(InvalidTakeRateBps.selector);
        config.updateConfig(bad);

        assertEq(config.admin(), admin, "the admin did not move");
        assertEq(config.params().takeRateBps, 1_000, "and the take rate never landed");
        _assertParamsEq(config.params(), _valid(), "nor did any other field");
    }

    // ---------------------------------------------------------------------------------------
    // the admin handover — moved to the OWNER (D-17)
    // ---------------------------------------------------------------------------------------

    /// The owner appoints the admin in one step; the old key is out at once, the new one in.
    function test_happyPath_theOwnerAppointsTheAdminInOneStep() public {
        vm.expectEmit(true, true, false, false, address(config));
        emit AssayConfig.AdminSet(admin, next);
        vm.prank(OWNER);
        config.setAdmin(next);
        assertEq(config.admin(), next, "the handover landed in this same call");

        vm.prank(admin);
        vm.expectRevert(NotAdmin.selector);
        config.updateConfig(_valid());

        vm.prank(next);
        config.updateConfig(_other()); // the new admin administers
        _assertParamsEq(config.params(), _other(), "and the new admin's set landed");
    }

    /// `setAdmin` is the owner's alone: neither the admin nor a stranger may appoint, and the
    /// zero address is never an admin.
    function test_wrongSigner_onlyTheOwnerAppointsTheAdmin() public {
        address[3] memory callers = [admin, stranger, next];
        for (uint256 i = 0; i < callers.length; i++) {
            vm.prank(callers[i]);
            vm.expectRevert(
                abi.encodeWithSelector(
                    OwnableUpgradeable.OwnableUnauthorizedAccount.selector, callers[i]
                )
            );
            config.setAdmin(next);
        }
        vm.prank(OWNER);
        vm.expectRevert(InvalidAdmin.selector);
        config.setAdmin(address(0));
        assertEq(config.admin(), admin, "nothing moved");
    }

    // ---------------------------------------------------------------------------------------
    // the negative space — what this door must NOT refuse
    // ---------------------------------------------------------------------------------------

    /// **`_validate` refuses exactly what `state.rs::Config::validate` refuses, and nothing more.**
    ///
    /// Every other refusal test asks "is this bad set refused?". None of them can see a bound the
    /// port **invented** — a precondition the reference does not have — because an invented
    /// precondition only ever refuses sets no test sends. Measured: `q.treasury == q.redeemer`
    /// refused survives the entire suite (mutation log C45), as did a
    /// `penaltyAmount <= minimumStake` rule (C46) — since review 2026-10-15 R-1 implied by the
    /// provider-day rule, and the one row below that the port refuses on purpose.
    ///
    /// Each row below is legal under `state.rs` — read it against that function, not
    /// against intuition — and each is a set some plausible extra rule would refuse. A set that
    /// *looks* wrong and is not is exactly the kind of thing an implementer adds a guard for.
    function test_updateAddsNoPreconditionTheReferenceLacks() public {
        ParamSet memory p = _valid();

        // one address wearing both hats. Nothing in `validate` says they differ.
        p.treasury = address(0xBEEF01);
        p.redeemer = address(0xBEEF01);
        _accepted(p, "treasury and redeemer may be the same address");

        // the admin's own address in both roles.
        p = _valid();
        p.treasury = admin;
        p.redeemer = admin;
        _accepted(p, "the admin may be the treasury and the redeemer");

        // the config contract itself. It never holds a token, so this is merely odd, not illegal.
        p = _valid();
        p.treasury = address(config);
        _accepted(p, "the config's own address is a legal treasury");

        // A penalty larger than the whole minimum stake WAS accepted here (`state.rs`
        // bounds `penalty_amount` at neither end). Since review 2026-10-15 R-1 it is a deliberate
        // refusal: a provider at the minimum must fit two penalties in its capped day, so
        // `penaltyAmount <= minimumStake * slashCapBps / 20_000 <= minimumStake / 4`.
        p = _valid();
        p.minimumStake = 10;
        p.penaltyAmount = type(uint64).max / 2;
        p.verifierDailyCap = type(uint64).max;
        _refused(p, InvalidMinimumStake.selector, "a penalty above the minimum stake");
        // The ceiling itself: a quarter of the minimum stake, at the 5 000-bps cap.
        p.slashCapBps = 5_000;
        p.minimumStake = 4_000_000;
        p.penaltyAmount = 1_000_000;
        _accepted(p, "the penalty may be a quarter of the minimum stake");

        // A daily cap smaller than a single penalty: refused from audit C7 until D-25, which
        // stopped reading the cap on chain. Accepted again (only zero is refused).
        p = _valid();
        p.verifierDailyCap = 1;
        _accepted(p, "a daily cap below one penalty (D-25: not read on chain)");

        // an unbonding period that is not a whole number of days.
        p = _valid();
        p.unbondingPeriodSeconds = 11 * 86_400 + 1;
        _accepted(p, "the unbonding period need not be a round day");

        // a zero take rate beside a zero platform share: the platform takes nothing, twice over.
        p = _valid();
        p.takeRateBps = 0;
        p.slashPlatformBps = 0;
        _accepted(p, "the platform may take nothing from either stream");
    }

    /// One accepted set: it lands whole, and the admin is untouched. The counterpart of
    /// [`_refused`], and the reason the negative-space rows are not merely "did not revert".
    function _accepted(ParamSet memory p, string memory tag) internal {
        address adminBefore = config.admin();
        vm.prank(adminBefore);
        config.updateConfig(p);
        _assertParamsEq(config.params(), p, tag);
        assertEq(config.admin(), adminBefore, string.concat(tag, ": moved the admin"));
    }

    // ---------------------------------------------------------------------------------------
    // the event
    // ---------------------------------------------------------------------------------------

    /// `emit!(ConfigUpdated { admin: config.admin, … })` — `update_config.rs`. The event
    /// carries the **post**-state, so on a handover the indexed admin is the incoming key, not
    /// the outgoing one that signed. That is the whole difference between `admin` and
    /// `msg.sender` here, and it is only visible on a call that hands over.
    function test_updateEmitsConfigUpdatedCarryingThePostState() public {
        // no handover: the indexed admin is the unchanged one.
        vm.expectEmit(true, false, false, true, address(config));
        emit AssayConfig.ConfigUpdated(admin, _other());
        vm.prank(admin);
        config.updateConfig(_other());

        // after the OWNER moved the admin, the indexed admin is the new one.
        vm.prank(OWNER);
        config.setAdmin(next);
        vm.expectEmit(true, false, false, true, address(config));
        emit AssayConfig.ConfigUpdated(next, _third());
        vm.prank(next);
        config.updateConfig(_third());
    }

    // ---------------------------------------------------------------------------------------
    // what this door does NOT touch
    // ---------------------------------------------------------------------------------------

    /// The pause is a separate door and is untouched by a parameter update — in **both**
    /// positions of the flag, so an `updateConfig` that wrote a constant `paused` would have to
    /// pick one and would fail on the other. `update_config` also carries no pause check of its
    /// own: the admin must be able to re-parameterise a paused system, which is usually the
    /// reason it is paused.
    function test_updateDoesNotTouchThePauseInEitherPosition() public {
        vm.prank(admin);
        config.setPaused(true);
        vm.prank(admin);
        config.updateConfig(_other());
        assertTrue(config.paused(), "a paused config stays paused across an update");
        _assertParamsEq(config.params(), _other(), "and the update still landed while paused");

        vm.prank(admin);
        config.setPaused(false);
        vm.prank(admin);
        config.updateConfig(_third());
        assertFalse(config.paused(), "an unpaused config stays unpaused across an update");
    }
}
