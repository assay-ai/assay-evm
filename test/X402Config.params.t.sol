// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {X402Config} from "../src/X402Config.sol";
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
///      `ReferenceLacks` and `test_handingTheAdminRoleToItselfIsLegalAndANoOp` are the negative
///      space, on the parameters and on the admin respectively;
///   4. a guard tested on one of this door's two paths. `newAdmin` splits every call into an
///      ordinary parameter update (`address(0)`) and a handover, and `onlyAdmin` has to be pinned
///      on both — see `test_wrongSigner_onlyAdminUpdates`.
///
/// Every refusal here also re-asserts the full pre-state. **That is bookkeeping, not a contract
/// property**: a revert on the EVM rolls everything back whatever the implementation did first, so
/// those assertions cannot fail for any implementation that reverts at all (mutation log C47).
/// They are kept because they make a refusal row report *which* field moved if one ever does.
contract X402ConfigParamsTest is Test {
    X402Config internal config;
    X402Config internal configImpl;

    address internal admin = address(0xADAA);
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
            minimumStake: 7,
            penaltyAmount: 9,
            verifierDailyCap: 11,
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
            minimumStake: 1,
            penaltyAmount: type(uint64).max,
            verifierDailyCap: 2,
            takeRateBps: 0,
            slashAgentBps: 1,
            slashPlatformBps: 0,
            slashCapBps: 1
        });
    }

    function setUp() public {
        vm.warp(1_760_000_000);
        configImpl = new X402Config();
        // Behind a proxy, like every X402Config in this suite (D-1).
        config = X402Config(
            address(
                new ERC1967Proxy(
                    address(configImpl), abi.encodeCall(X402Config.initialize, (_valid(), admin))
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
        config.updateConfig(p, next);

        _assertParamsEq(config.params(), before, string.concat(tag, " moved a parameter"));
        assertEq(config.admin(), adminBefore, string.concat(tag, " moved the admin"));
    }

    // ---------------------------------------------------------------------------------------
    // the happy path
    // ---------------------------------------------------------------------------------------

    /// Every change applies in the slot it arrives — `update_config.rs:18-19`, verbatim.
    ///
    /// The nine untouched fields are read back too. Without them this test passes against an
    /// `updateConfig` that writes `takeRateBps` and zeroes everything beside it.
    function test_happyPath_aChangeBindsInTheSlotItArrives() public {
        ParamSet memory p = _valid();
        p.takeRateBps = 2_000;

        vm.prank(admin);
        config.updateConfig(p, address(0));

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
        config.updateConfig(_other(), address(0));
        _assertParamsEq(config.params(), _other(), "first update");

        vm.prank(admin);
        config.updateConfig(_third(), address(0));
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
        config.updateConfig(current, address(0));
        _assertParamsEq(config.params(), _valid(), "a re-send of the current set");
        assertEq(config.admin(), admin, "and it moves no admin");
    }

    // ---------------------------------------------------------------------------------------
    // who may call
    // ---------------------------------------------------------------------------------------

    /// **Both paths through this door, because they are two different calls.** `newAdmin` splits
    /// `updateConfig` in two: the ordinary parameter update sends `address(0)` and the handover
    /// sends an address, and a guard can cover one and miss the other.
    ///
    /// The first leg is the one that matters and the one an earlier version of this test did not
    /// have. A guard degraded to `newAdmin != address(0) && msg.sender != admin` lets **any**
    /// caller rewrite all ten parameters on every ordinary update, and a wrong-signer test that
    /// only ever hands over cannot see it (mutation log C43).
    function test_wrongSigner_onlyAdminUpdates() public {
        // the ordinary parameter update — no handover, so `newAdmin` is the sentinel.
        vm.prank(stranger);
        vm.expectRevert(NotAdmin.selector);
        config.updateConfig(_other(), address(0));

        _assertParamsEq(config.params(), _valid(), "a stranger moved no parameter");
        assertEq(config.admin(), admin, "and no admin");

        // the handover path.
        vm.prank(stranger);
        vm.expectRevert(NotAdmin.selector);
        config.updateConfig(_other(), next);

        _assertParamsEq(config.params(), _valid(), "the refused handover moved no parameter");
        assertEq(config.admin(), admin, "and no admin");
    }

    // ---------------------------------------------------------------------------------------
    // the set is validated as a whole — update_config.rs:79-82
    // ---------------------------------------------------------------------------------------

    /// Validated AFTER every field lands, not per field. From (6000, 3000) to (3000, 7000) is
    /// legal as a set; a field-at-a-time check that landed `platform` first would see
    /// 6000 + 7000 and refuse a move the bounds permit. And the illegal set is still refused.
    function test_wrongState_theSetIsValidatedAsAWhole() public {
        ParamSet memory swap = _valid();
        swap.slashAgentBps = 3_000;
        swap.slashPlatformBps = 7_000;
        vm.prank(admin);
        config.updateConfig(swap, address(0)); // must not revert
        assertEq(config.params().slashPlatformBps, 7_000, "the platform share moved up");
        assertEq(config.params().slashAgentBps, 3_000, "and the agent share moved down");

        ParamSet memory bad = _valid();
        bad.slashPlatformBps = 4_001; // 6000 + 4001 > 10000
        vm.prank(admin);
        vm.expectRevert(InvalidSplitBps.selector);
        config.updateConfig(bad, address(0));
    }

    /// **Every** bound `state.rs::Config::validate` states is reached through *this* door too, by
    /// name, and each refusal moves nothing. `test_wrongState_everyBoundIsRefusedAtConstruction`
    /// proves the same eleven rows through `initialize`; that a set reaching `_params` through
    /// `initialize` is bounded says nothing about a set reaching it through `updateConfig`, and
    /// C22's "the saturation in `slashProviderBps` is unreachable" rests on *both* doors.
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
        config.updateConfig(bad, next);

        assertEq(config.admin(), admin, "the admin handover rolled back with the set");
        assertEq(config.params().takeRateBps, 1_000, "and the take rate never landed");
        _assertParamsEq(config.params(), _valid(), "nor did any other field");
    }

    // ---------------------------------------------------------------------------------------
    // the admin handover — update_config.rs:84-87
    // ---------------------------------------------------------------------------------------

    /// One step. The old key is out the moment the call lands; the new key is in.
    function test_happyPath_adminHandoverIsOneStep() public {
        vm.prank(admin);
        config.updateConfig(_valid(), next);
        assertEq(config.admin(), next, "the handover landed in this same call");

        vm.prank(admin);
        vm.expectRevert(NotAdmin.selector);
        config.updateConfig(_valid(), address(0));

        vm.prank(next);
        config.updateConfig(_other(), address(0)); // the new admin administers
        _assertParamsEq(config.params(), _other(), "and the new admin's set landed");
    }

    /// The zero address is the one nobody can sign for, so it is the "leave it" sentinel and
    /// can never become the admin — the same refusal `update_config` makes on `Pubkey::default()`.
    ///
    /// The second half is what makes this more than a tautology: the sentinel is measured against
    /// an admin that has already **moved**. A test that only ever ran at the initial admin cannot
    /// tell "leave the current admin alone" from "restore the admin this contract started with".
    function test_wrongState_theZeroAddressNeverBecomesAdmin() public {
        vm.prank(admin);
        config.updateConfig(_valid(), address(0));
        assertEq(config.admin(), admin, "address(0) left the initial admin in place");

        vm.prank(admin);
        config.updateConfig(_valid(), next);
        assertEq(config.admin(), next, "precondition: the admin has moved");

        vm.prank(next);
        config.updateConfig(_other(), address(0));
        assertEq(config.admin(), next, "address(0) leaves the CURRENT admin, not the first one");
    }

    /// Handing the role to whoever already holds it is legal and is a no-op —
    /// `update_config.rs:84-86` refuses `Pubkey::default()` and **only** that, so
    /// `Some(current_admin)` is accepted and assigns the admin to itself.
    ///
    /// Without this leg a "must differ" rule on the admin (`if (newAdmin == admin) revert`)
    /// survives the whole suite, because no other test ever passes the current admin
    /// (mutation log C44). That is the half of this door a second call cannot undo: a parameter
    /// this door refuses can be re-sent, an admin it refuses to install cannot be installed by
    /// anybody but the incumbent.
    function test_handingTheAdminRoleToItselfIsLegalAndANoOp() public {
        vm.prank(admin);
        config.updateConfig(_other(), admin);
        assertEq(config.admin(), admin, "a self-handover leaves the admin where it was");
        _assertParamsEq(config.params(), _other(), "and the set beside it still landed");

        // and the incumbent still administers afterwards — the self-handover installed a live key,
        // not a dead one.
        vm.prank(admin);
        config.updateConfig(_third(), address(0));
        _assertParamsEq(config.params(), _third(), "the admin still administers after");

        // the same, once the role has moved, so this is not a statement about the initial admin.
        vm.prank(admin);
        config.updateConfig(_third(), next);
        vm.prank(next);
        config.updateConfig(_other(), next);
        assertEq(config.admin(), next, "a self-handover by the SECOND admin is a no-op too");
    }

    // ---------------------------------------------------------------------------------------
    // the negative space — what this door must NOT refuse
    // ---------------------------------------------------------------------------------------

    /// **`_validate` refuses exactly what `state.rs::Config::validate` refuses, and nothing more.**
    ///
    /// Every other refusal test asks "is this bad set refused?". None of them can see a bound the
    /// port **invented** — a precondition the reference does not have — because an invented
    /// precondition only ever refuses sets no test sends. Measured: `q.treasury == q.redeemer`
    /// refused survives the entire suite (mutation log C45), as does a
    /// `penaltyAmount <= minimumStake` rule (C46).
    ///
    /// Each row below is legal under `state.rs:134-191` — read it against that function, not
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

        // a penalty larger than the whole minimum stake. `state.rs:68-75` bounds `penalty_amount`
        // at neither end; what bounds the damage is `slashCapBps`, a fraction of the stake held.
        p = _valid();
        p.minimumStake = 1;
        p.penaltyAmount = type(uint64).max;
        _accepted(p, "the penalty may exceed the minimum stake");

        // a daily cap smaller than a single penalty — one judgement a day, which is a policy, not
        // an error.
        p = _valid();
        p.penaltyAmount = 1_000_000;
        p.verifierDailyCap = 1;
        _accepted(p, "the verifier daily cap may be smaller than one penalty");

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
        config.updateConfig(p, address(0));
        _assertParamsEq(config.params(), p, tag);
        assertEq(config.admin(), adminBefore, string.concat(tag, ": moved the admin"));
    }

    // ---------------------------------------------------------------------------------------
    // the event
    // ---------------------------------------------------------------------------------------

    /// `emit!(ConfigUpdated { admin: config.admin, … })` — `update_config.rs:89-102`. The event
    /// carries the **post**-state, so on a handover the indexed admin is the incoming key, not
    /// the outgoing one that signed. That is the whole difference between `admin` and
    /// `msg.sender` here, and it is only visible on a call that hands over.
    function test_updateEmitsConfigUpdatedCarryingThePostState() public {
        // no handover: the indexed admin is the unchanged one.
        vm.expectEmit(true, false, false, true, address(config));
        emit X402Config.ConfigUpdated(admin, _other());
        vm.prank(admin);
        config.updateConfig(_other(), address(0));

        // with a handover: the indexed admin is `next`, though `admin` signed.
        vm.expectEmit(true, false, false, true, address(config));
        emit X402Config.ConfigUpdated(next, _third());
        vm.prank(admin);
        config.updateConfig(_third(), next);
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
        config.updateConfig(_other(), address(0));
        assertTrue(config.paused(), "a paused config stays paused across an update");
        _assertParamsEq(config.params(), _other(), "and the update still landed while paused");

        vm.prank(admin);
        config.setPaused(false);
        vm.prank(admin);
        config.updateConfig(_third(), address(0));
        assertFalse(config.paused(), "an unpaused config stays unpaused across an update");
    }

    /// `slashProviderBps()` is derived from `_params`, so it must follow an update rather than
    /// hold the value it was initialised with. Three sets, three pinned answers — never the sum
    /// identity alone, which any subtraction satisfies (see C20/C21 in the mutation log).
    function test_theDerivedProviderShareFollowsAnUpdate() public {
        assertEq(config.slashProviderBps(), 1_000, "6000 + 3000 leaves the provider 10%");

        vm.prank(admin);
        config.updateConfig(_other(), address(0)); // 4000 + 1000
        assertEq(config.slashProviderBps(), 5_000, "4000 + 1000 leaves the provider 50%");

        vm.prank(admin);
        config.updateConfig(_third(), address(0)); // 1 + 0
        assertEq(config.slashProviderBps(), 9_999, "1 + 0 leaves the provider almost all of it");
    }
}
