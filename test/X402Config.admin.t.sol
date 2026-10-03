// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

import {X402Config} from "../src/X402Config.sol";
import {ParamSet} from "../src/Types.sol";
import "../src/Errors.sol";

/// `initialize_config` and `set_paused`, ported.
///
/// Every assertion here pins a *value* rather than bounding one. The recurring defect in this
/// plan has been a test that relates two things which a degenerate implementation relates just as
/// well — so `_valid()` gives every field a distinct value, `test_happyPath_…` reads all ten back,
/// and `test_theStoredParamsAreThisInstancesOwn` deploys a second proxy with a second parameter
/// set so a hard-coded `params()` cannot satisfy both.
contract X402ConfigAdminTest is Test {
    /// ERC-1967 implementation slot — `bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1)`.
    bytes32 internal constant IMPL_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    X402Config internal config;
    X402Config internal configImpl;
    address internal admin = address(0xADAA);
    address internal next = address(0xBEEF);
    address internal treasury = address(0x7EA5);
    address internal redeemer = address(0x4EED);

    function _valid() internal view returns (ParamSet memory p) {
        p = ParamSet({
            treasury: treasury,
            redeemer: redeemer,
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

    /// Every X402Config in this suite is a PROXY (D-1). The implementation is deployed once;
    /// `initialize` runs through the proxy's constructor, so a revert inside `_validate`
    /// still surfaces here as a revert of the `new ERC1967Proxy(...)` expression.
    function _deploy(ParamSet memory p, address a) internal returns (X402Config) {
        return X402Config(
            address(
                new ERC1967Proxy(address(configImpl), abi.encodeCall(X402Config.initialize, (p, a)))
            )
        );
    }

    function setUp() public {
        configImpl = new X402Config();
        config = _deploy(_valid(), admin);
    }

    // ---------------------------------------------------------------------------------------
    // the happy path
    // ---------------------------------------------------------------------------------------

    /// Reads back **every** field. Checking two of ten would pass against an `initialize` that
    /// stored only those two, and against a `params()` that returned a literal.
    function test_happyPath_initializeStoresValidatedParams() public view {
        ParamSet memory p = config.params();
        assertEq(p.treasury, treasury, "treasury");
        assertEq(p.redeemer, redeemer, "redeemer");
        assertEq(p.unbondingPeriodSeconds, 14 * 86_400, "unbondingPeriodSeconds");
        assertEq(p.minimumStake, 100_000_000, "minimumStake");
        assertEq(p.penaltyAmount, 1_000_000, "penaltyAmount");
        assertEq(p.verifierDailyCap, 500_000_000, "verifierDailyCap");
        assertEq(p.takeRateBps, 1_000, "takeRateBps");
        assertEq(p.slashAgentBps, 6_000, "slashAgentBps");
        assertEq(p.slashPlatformBps, 3_000, "slashPlatformBps");
        assertEq(p.slashCapBps, 1_000, "slashCapBps");
        assertEq(config.admin(), admin, "admin");
        assertFalse(config.paused(), "a fresh config is not paused");
    }

    /// The stored set belongs to *this* proxy. A `params()` returning a constant, or an
    /// `initialize` that ignored its argument, satisfies the test above and dies here.
    function test_theStoredParamsAreThisInstancesOwn() public {
        ParamSet memory q = _valid();
        q.treasury = address(0xF00D);
        q.redeemer = address(0xCAFE);
        q.unbondingPeriodSeconds = 20 * 86_400;
        q.minimumStake = 7;
        q.penaltyAmount = 9;
        q.verifierDailyCap = 11;
        q.takeRateBps = 2_500;
        q.slashAgentBps = 4_000;
        q.slashPlatformBps = 1_000;
        q.slashCapBps = 4_999;

        X402Config other = _deploy(q, next);

        ParamSet memory a = config.params();
        ParamSet memory b = other.params();
        assertEq(abi.encode(b), abi.encode(q), "the second proxy stored its own set verbatim");
        assertEq(abi.encode(a), abi.encode(_valid()), "the first proxy still holds the first set");
        assertTrue(keccak256(abi.encode(a)) != keccak256(abi.encode(b)), "two proxies, two sets");
        assertEq(other.admin(), next, "the second proxy has its own admin");
        assertEq(config.admin(), admin, "the first proxy's admin is untouched");
    }

    /// `initializer` — `initialize_config` creates the singleton `["config"]` PDA, so Anchor's
    /// runtime refuses a second call. This is that refusal.
    function test_wrongState_initializeRunsExactlyOnce() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        config.initialize(_valid(), next);
        assertEq(config.admin(), admin, "the failed re-initialise moved nothing");
    }

    function test_initializeEmitsConfigInitialized() public {
        ParamSet memory p = _valid();
        vm.expectEmit(true, false, false, true);
        emit X402Config.ConfigInitialized(admin, p);
        _deploy(p, admin);
    }

    // ---------------------------------------------------------------------------------------
    // the bounds — state.rs::Config::validate + validate_split
    // ---------------------------------------------------------------------------------------

    function test_wrongState_everyBoundIsRefusedAtConstruction() public {
        ParamSet memory p = _valid();
        p.treasury = address(0);
        vm.expectRevert(MissingBeneficiary.selector);
        _deploy(p, admin);

        p = _valid();
        p.redeemer = address(0);
        vm.expectRevert(MissingRedeemer.selector);
        _deploy(p, admin);

        p = _valid();
        p.takeRateBps = 3_001; // MAX_TAKE_RATE_BPS + 1
        vm.expectRevert(InvalidTakeRateBps.selector);
        _deploy(p, admin);

        p = _valid();
        p.slashAgentBps = 0; // the agent must keep a share
        vm.expectRevert(InvalidSplitBps.selector);
        _deploy(p, admin);

        p = _valid();
        p.slashAgentBps = 6_000;
        p.slashPlatformBps = 4_001; // 6000 + 4001 > 10000
        vm.expectRevert(InvalidSplitBps.selector);
        _deploy(p, admin);

        p = _valid();
        p.slashCapBps = 0; // zero is shadow mode by the side door, not a cap
        vm.expectRevert(InvalidSlashCapBps.selector);
        _deploy(p, admin);

        p = _valid();
        p.slashCapBps = 5_001; // MAX_SLASH_CAP_BPS + 1
        vm.expectRevert(InvalidSlashCapBps.selector);
        _deploy(p, admin);

        p = _valid();
        p.unbondingPeriodSeconds = 11 * 86_400 - 1;
        vm.expectRevert(UnbondingPeriodTooShort.selector);
        _deploy(p, admin);

        p = _valid();
        p.unbondingPeriodSeconds = 30 * 86_400 + 1;
        vm.expectRevert(UnbondingPeriodTooLong.selector);
        _deploy(p, admin);

        p = _valid();
        p.minimumStake = 0;
        vm.expectRevert(InvalidMinimumStake.selector);
        _deploy(p, admin);

        p = _valid();
        p.verifierDailyCap = 0;
        vm.expectRevert(InvalidVerifierDailyCap.selector);
        _deploy(p, admin);
    }

    /// `state.rs:175` widens both shares to `u32` before adding them. The reason is not
    /// cosmetic: two `uint16` shares can sum past `type(uint16).max`, and in checked Solidity
    /// that is a bare `Panic(0x11)` raised *before* the comparison — the parameter set would be
    /// refused, but with an arithmetic panic instead of the name an operator can act on. This
    /// input is exactly that case: `60_000 + 10_000 = 70_000` fits `uint32` and does not fit
    /// `uint16`. Drop the widening and this test reports a panic instead of `InvalidSplitBps`.
    function test_wrongState_aSplitThatOverflowsUint16IsStillRefusedByName() public {
        ParamSet memory p = _valid();
        p.slashAgentBps = 60_000;
        p.slashPlatformBps = 10_000;
        vm.expectRevert(InvalidSplitBps.selector);
        _deploy(p, admin);
    }

    /// Boundary: each bound admits its own value and refuses one more.
    function test_boundary_theBoundsAdmitTheirOwnValue() public {
        ParamSet memory p = _valid();
        p.takeRateBps = 3_000;
        p.slashCapBps = 5_000;
        p.unbondingPeriodSeconds = 11 * 86_400;
        _deploy(p, admin); // must not revert

        p.unbondingPeriodSeconds = 30 * 86_400;
        _deploy(p, admin); // must not revert

        // the other floors: one base unit is enough, zero is not (proved above).
        p = _valid();
        p.takeRateBps = 0; // a zero take rate is legal — the platform simply takes nothing
        p.slashAgentBps = 1;
        p.slashPlatformBps = 0;
        p.slashCapBps = 1;
        p.minimumStake = 1;
        p.verifierDailyCap = 1;
        X402Config floor_ = _deploy(p, admin);
        assertEq(floor_.params().slashCapBps, 1, "a one-bps cap is a cap");
        assertEq(floor_.params().takeRateBps, 0, "a zero take rate is not refused");
    }

    /// `penalty_amount` is deliberately unbounded in `state.rs` — `0` **is** on-chain shadow
    /// mode, and there is no absurd upper value for a token amount. This test fails the moment
    /// anybody adds a bound to it in either direction.
    function test_boundary_penaltyAmountIsBoundedAtNeitherEnd() public {
        ParamSet memory p = _valid();
        p.penaltyAmount = 0;
        assertEq(_deploy(p, admin).params().penaltyAmount, 0, "zero penalty is shadow mode");

        p.penaltyAmount = type(uint64).max;
        assertEq(
            _deploy(p, admin).params().penaltyAmount, type(uint64).max, "no ceiling on the penalty"
        );
    }

    /// **The set-wise property.** `validate` runs once, over the whole `ParamSet`, exactly as
    /// `initialize_config.rs:92` runs `config.validate()` after every field has landed.
    ///
    /// Neither share has an individual bound; only their sum does, plus `agent > 0`. So a
    /// validator that judged each field on its own against some per-field ceiling would refuse
    /// the first set here, and one that judged only the fields it happened to see would admit
    /// the second. Both sets differ from `_valid()` in the *pair*, not in either member.
    function test_validation_judgesTheSplitAsAPairNotFieldByField() public {
        ParamSet memory p = _valid();
        p.slashAgentBps = 9_000;
        p.slashPlatformBps = 1_000; // sums to exactly 10_000 — the provider keeps nothing
        X402Config a = _deploy(p, admin);
        assertEq(a.params().slashAgentBps, 9_000, "a 90% agent share is legal in this pair");
        assertEq(a.params().slashPlatformBps, 1_000, "and so is the 10% beside it");

        // The same platform share, one bps more of an agent share, is illegal — and the only
        // thing that changed is the sum.
        p.slashAgentBps = 9_001;
        vm.expectRevert(InvalidSplitBps.selector);
        _deploy(p, admin);

        // And the same agent share with a smaller platform share is legal again.
        p.slashPlatformBps = 999;
        assertEq(_deploy(p, admin).params().slashAgentBps, 9_001, "9_001 is legal against 999");
    }

    /// `Config::slash_provider_bps()` — `state.rs:127-131`.
    ///
    /// **Pins the value, three times, at three different answers.** A test asserting only that
    /// the three shares sum to 10,000 is satisfied by any implementation that computes the
    /// remainder *somehow* — including one that reads the wrong field, since the identity is
    /// structural once the remainder is defined by subtraction. So each row states the number,
    /// and the rows are chosen so that no single wrong formula produces all three: dropping the
    /// platform term gives 4,000 / 1,000 / 9,999 and dropping the agent term gives 7,000 /
    /// 9,000 / 10,000, against the correct 1,000 / 0 / 9,999.
    function test_theProviderKeepsTheRemainderOfEveryPenalty() public {
        ParamSet memory p = _valid(); // 6_000 + 3_000
        assertEq(config.slashProviderBps(), 1_000, "the provider keeps 10% of _valid()");

        p.slashAgentBps = 9_000;
        p.slashPlatformBps = 1_000;
        assertEq(_deploy(p, admin).slashProviderBps(), 0, "a 90/10 split leaves the provider none");

        p.slashAgentBps = 1;
        p.slashPlatformBps = 0;
        assertEq(_deploy(p, admin).slashProviderBps(), 9_999, "and almost all of it at the floor");

        // The sum identity holds too — asserted after the values, never instead of them.
        ParamSet memory q = config.params();
        assertEq(
            uint256(q.slashAgentBps) + q.slashPlatformBps + config.slashProviderBps(),
            10_000,
            "the three shares are a partition of the penalty"
        );
    }

    /// **The order of the checks, which nothing else can see.** Every other refusal test violates
    /// exactly one bound, and a set with one violation names the same error under any ordering —
    /// measured: reversing all nine checks end to end leaves the whole suite green.
    ///
    /// The order is what decides which name a **doubly** invalid config gets, and that is an
    /// operational property, not a cosmetic one: an operator reading the Solana runbook and the
    /// EVM runbook must see the same name for the same bad parameter set. `state.rs:134-164` runs
    /// treasury, redeemer, then `validate_split` (`state.rs:168-191`: take rate, split, cap), then
    /// unbonding-low, unbonding-high, minimum stake, verifier daily cap.
    ///
    /// Each row below violates two bounds at once and asserts the name of the **earlier** one, so
    /// the rows chain across the whole sequence: swapping any adjacent pair breaks a row.
    function test_theCheckOrderMatchesAnchorWhenTwoBoundsAreViolatedAtOnce() public {
        ParamSet memory p = _valid();
        p.treasury = address(0);
        p.redeemer = address(0);
        vm.expectRevert(MissingBeneficiary.selector); // treasury before redeemer
        _deploy(p, admin);

        p = _valid();
        p.redeemer = address(0);
        p.takeRateBps = 3_001;
        vm.expectRevert(MissingRedeemer.selector); // redeemer before the take rate
        _deploy(p, admin);

        p = _valid();
        p.takeRateBps = 3_001;
        p.slashAgentBps = 0;
        vm.expectRevert(InvalidTakeRateBps.selector); // take rate before the split
        _deploy(p, admin);

        p = _valid();
        p.slashAgentBps = 0;
        p.slashCapBps = 0;
        vm.expectRevert(InvalidSplitBps.selector); // split before the cap
        _deploy(p, admin);

        p = _valid();
        p.slashCapBps = 0;
        p.unbondingPeriodSeconds = 1;
        vm.expectRevert(InvalidSlashCapBps.selector); // cap before the unbonding floor
        _deploy(p, admin);

        p = _valid();
        p.unbondingPeriodSeconds = 1;
        p.minimumStake = 0;
        vm.expectRevert(UnbondingPeriodTooShort.selector); // unbonding floor before minimum stake
        _deploy(p, admin);

        p = _valid();
        p.unbondingPeriodSeconds = 365 * 86_400;
        p.minimumStake = 0;
        vm.expectRevert(UnbondingPeriodTooLong.selector); // unbonding ceiling before minimum stake
        _deploy(p, admin);

        p = _valid();
        p.minimumStake = 0;
        p.verifierDailyCap = 0;
        vm.expectRevert(InvalidMinimumStake.selector); // minimum stake before the daily cap
        _deploy(p, admin);

        // and one non-adjacent pair, so the chain is anchored at both ends rather than only
        // between neighbours.
        p = _valid();
        p.treasury = address(0);
        p.verifierDailyCap = 0;
        vm.expectRevert(MissingBeneficiary.selector);
        _deploy(p, admin);
    }

    // ---------------------------------------------------------------------------------------
    // the admin
    // ---------------------------------------------------------------------------------------

    function test_wrongState_theZeroAdminIsRefusedAtConstruction() public {
        vm.expectRevert(InvalidAdmin.selector);
        _deploy(_valid(), address(0));
    }

    /// Who may pause. **What `setPaused` writes is `test_setPausedAssignsItsArgument…` below** —
    /// this test walks `false -> true -> false`, which is a sequence a *toggle* satisfies exactly
    /// as well as an assignment, so it must not be cited as covering the value.
    function test_wrongSigner_onlyAdminPauses() public {
        vm.prank(next);
        vm.expectRevert(NotAdmin.selector);
        config.setPaused(true);
        assertFalse(config.paused(), "the refused call changed nothing");

        vm.prank(admin);
        config.setPaused(true);
        assertTrue(config.paused(), "the admin's call took effect");

        vm.prank(admin);
        config.setPaused(false);
        assertFalse(config.paused(), "and it is reversible");
    }

    /// `set_paused.rs:41` is `config.paused = paused;` — an **idempotent assignment**, not a
    /// toggle. The difference is not academic: under a toggle, an operator who hits pause twice
    /// un-pauses the system, during the incident that made them hit it twice.
    ///
    /// So every leg here pins the post-state of a **single** call against its **argument**,
    /// including the two calls a sequence test can never contain — `setPaused(true)` on an
    /// already-paused config and `setPaused(false)` on an already-unpaused one. A toggle passes
    /// any alternating walk; it cannot pass a repeat.
    function test_setPausedAssignsItsArgumentAndIsIdempotent() public {
        assertFalse(config.paused(), "precondition: a fresh config is unpaused");

        // false onto false — the leg a `false -> true -> false` walk cannot contain.
        vm.prank(admin);
        config.setPaused(false);
        assertFalse(config.paused(), "setPaused(false) on an unpaused config leaves it unpaused");

        vm.prank(admin);
        config.setPaused(true);
        assertTrue(config.paused(), "setPaused(true) pauses");

        // true onto true — the operator hitting pause a second time.
        vm.prank(admin);
        config.setPaused(true);
        assertTrue(config.paused(), "setPaused(true) on a paused config leaves it PAUSED");

        vm.prank(admin);
        config.setPaused(false);
        assertFalse(config.paused(), "setPaused(false) unpauses");

        vm.prank(admin);
        config.setPaused(false);
        assertFalse(config.paused(), "setPaused(false) on an unpaused config leaves it unpaused");
    }

    function test_setPausedEmitsPauseToggled() public {
        vm.warp(1_760_000_000);
        vm.expectEmit(true, false, false, true, address(config));
        emit X402Config.PauseToggled(admin, true, 1_760_000_000);
        vm.prank(admin);
        config.setPaused(true);
    }

    // ---------------------------------------------------------------------------------------
    // the upgrade door (D-1)
    // ---------------------------------------------------------------------------------------

    /// The upgrade key **is** `Config.admin`. Tested here, beside the other admin guards, because
    /// the standing rule is that no guard ships without a test that fails when it is removed.
    function test_wrongSigner_onlyTheAdminUpgradesConfig() public {
        X402Config newImpl = new X402Config();

        vm.prank(next);
        vm.expectRevert(NotAdmin.selector);
        config.upgradeToAndCall(address(newImpl), "");
        assertEq(_implementationOf(address(config)), address(configImpl), "nothing moved");

        vm.prank(admin);
        config.upgradeToAndCall(address(newImpl), "");
        assertEq(_implementationOf(address(config)), address(newImpl), "the admin's upgrade took");

        // and the proxy's storage survived it — the `__gap` layout claim, exercised.
        assertEq(config.admin(), admin, "admin survived the upgrade");
        assertEq(abi.encode(config.params()), abi.encode(_valid()), "params survived the upgrade");
    }

    /// `_disableInitializers()` in the constructor. Without it anybody may initialise the
    /// implementation, become *its* admin, and call `upgradeToAndCall` on it directly.
    function test_wrongState_theImplementationCannotBeInitialised() public {
        vm.prank(next);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        configImpl.initialize(_valid(), next);
        assertEq(configImpl.admin(), address(0), "the implementation has no admin, ever");
    }

    function _implementationOf(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, IMPL_SLOT))));
    }
}
