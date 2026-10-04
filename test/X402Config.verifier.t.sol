// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {X402Config} from "../src/X402Config.sol";
import {ParamSet} from "../src/Types.sol";
import {Constants} from "../src/Constants.sol";
import "../src/Errors.sol";

/// `register_verifier` and `revoke_verifier`, ported, plus the `VerifierKey::assert_can_sign`
/// predicate both slash phases are gated on.
///
/// **What this suite is defending against.** The registry is small and its tests are easy to write
/// so that they answer a weaker question than their names claim. Three shapes were named in
/// advance and each has a test written specifically to kill it:
///
/// - a `canSign` test that never checks a key at the **exact** expiry instant — Anchor's
///   `state.rs:254` is `now <= self.expires_at`, so the shared instant belongs to the key, and a
///   `<` port would be invisible to any test that samples "well inside" and "well past". See
///   `test_boundary_aKeyIsUsableAtExactlyItsExpiry`.
/// - a revocation test that proves `canSign` is false **once** without proving it can never be
///   true again. `canSign(x) == false` right after a revoke is also true of an implementation that
///   merely cleared `registered`, which re-opens registration for the same address. See
///   `test_wrongState_revocationCanNeverBeUndone`, which sweeps the clock and then tries to
///   re-register.
/// - a registration test that would pass against a `registerVerifier` **ignoring** its `expiresAt`
///   and storing `now + MAX_VERIFIER_KEY_LIFETIME_SECONDS` instead. See
///   `test_registrationStoresTheExpiryItWasGivenAndNotADefault`, which registers two keys with
///   two different lifetimes and pins both values and both expiry instants.
contract X402ConfigVerifierTest is Test {
    X402Config internal config;
    X402Config internal configImpl;

    address internal admin = address(0xADAA);
    address internal verifier = address(0x7E51);
    address internal second = address(0x7E52);
    address internal stranger = address(0xBAD);
    address internal unknown = address(0xDEAD);

    bytes32 internal constant LABEL = bytes32("verifier-evm-2026-09");
    uint64 internal constant T = 1_760_000_000;

    function _valid() internal pure returns (ParamSet memory p) {
        p = ParamSet({
            treasury: address(0x7EA5),
            redeemer: address(0x4EED),
            unbondingPeriodSeconds: 14 * 86_400,
            minimumStake: 100_000_000,
            penaltyAmount: 1_000_000,
            verifierDailyCap: 500_000_000,
            takeRateBps: 1_000,
            slashAgentBps: 6_000,
            slashPlatformBps: 3_000,
            slashCapBps: 1_000
        });
    }

    /// Behind a proxy, like every X402Config in this suite (D-1). The registry's storage is the
    /// proxy's, so a test that read the implementation's would see an empty registry forever.
    function _deploy(address a) internal returns (X402Config) {
        return X402Config(
            address(
                new ERC1967Proxy(
                    address(configImpl), abi.encodeCall(X402Config.initialize, (_valid(), a))
                )
            )
        );
    }

    function setUp() public {
        vm.warp(T);
        configImpl = new X402Config();
        config = _deploy(admin);
    }

    function _register(address who, bytes32 label, uint64 lifetime) internal {
        vm.prank(admin);
        config.registerVerifier(who, label, uint64(block.timestamp) + lifetime);
    }

    function _register(uint64 lifetime) internal {
        _register(verifier, LABEL, lifetime);
    }

    /// **Every field, every time.** A review's degenerate registry passed 21 of 21 with
    /// five substitutions, and two of them — a hard-coded `registeredAt`, and a `revokeVerifier`
    /// that wiped `registeredAt` and `expiresAt` — were invisible for the same reason: the suite
    /// read the fields it had just set and no others. Nothing in this file asserts on a record
    /// piecemeal any more.
    function _assertRecord(
        address who,
        uint64 registeredAt,
        uint64 expiresAt,
        uint64 revokedAt,
        bool registered,
        bool revoked,
        string memory what
    ) internal view {
        X402Config.VerifierKey memory k = config.verifierKey(who);
        assertEq(k.registeredAt, registeredAt, string.concat(what, ": registeredAt"));
        assertEq(k.expiresAt, expiresAt, string.concat(what, ": expiresAt"));
        assertEq(k.revokedAt, revokedAt, string.concat(what, ": revokedAt"));
        assertEq(k.registered, registered, string.concat(what, ": registered"));
        assertEq(k.revoked, revoked, string.concat(what, ": revoked"));
        // `verifierExpiry` is the `IX402Config` half of the same field and the slash path reads it,
        // so it is asserted wherever the record is.
        assertEq(config.verifierExpiry(who), expiresAt, string.concat(what, ": verifierExpiry"));
    }

    /// The `verifiers` mapping's declared slot. `admin`/`paused` share slot 0, `ParamSet` takes
    /// 1-3, so the mapping is 4 and `__gap` starts at 5. `_writeEntry` fails loudly if that ever
    /// stops being true, which makes every test that uses it a layout regression test as well.
    uint256 internal constant VERIFIERS_SLOT = 4;

    /// Write a `VerifierKey` straight into storage, bypassing `registerVerifier`.
    ///
    /// This is the instrument for the states the contract's own API cannot reach but a **future
    /// writer of this struct, or a storage-layout change, would produce** — the exact risk the
    /// `registered` and `revoked` flags exist to survive. It replaces an earlier test that reached
    /// for `vm.warp(0)` to make the same point: this construction is reachable-shaped and asserts
    /// at an ordinary timestamp.
    ///
    /// All five fields pack into the entry's single slot: `registeredAt` at byte 0, `expiresAt` at
    /// 8, `revokedAt` at 16, `registered` at 24, `revoked` at 25.
    function _writeEntry(
        address who,
        uint64 registeredAt,
        uint64 expiresAt,
        uint64 revokedAt,
        bool registered,
        bool revoked
    ) internal {
        uint256 packed = uint256(registeredAt) | (uint256(expiresAt) << 64)
            | (uint256(revokedAt) << 128) | (uint256(registered ? 1 : 0) << 192)
            | (uint256(revoked ? 1 : 0) << 200);
        vm.store(address(config), keccak256(abi.encode(who, VERIFIERS_SLOT)), bytes32(packed));
        // The packing above is an assumption about the layout; this read is what checks it. If the
        // mapping moves off slot 4 or the struct is reordered, every test using `_writeEntry`
        // fails here rather than silently asserting against a slot nobody writes.
        _assertRecord(
            who, registeredAt, expiresAt, revokedAt, registered, revoked, "vm.store round trip"
        );
    }

    // ------------------------------------------------------------------------------------
    // the happy path
    // ------------------------------------------------------------------------------------

    /// Reads back **every** field of the stored key, not only the predicate. `canSign == true`
    /// alone is satisfied by `canSign ≡ true`, which `test_wrongState_anUnknownKeyCannotSign`
    /// kills; the struct read is what pins that registration wrote what it was given.
    function test_happyPath_aRegisteredKeyCanSign() public {
        _register(180 * 86_400);

        assertTrue(config.canSign(verifier), "a fresh registration may sign");
        config.assertCanSign(verifier); // must not revert

        _assertRecord(verifier, T, T + 180 * 86_400, 0, true, false, "a fresh registration");
    }

    /// **`registeredAt` comes from the clock, and only two registrations at two clocks say so.**
    /// Every other registration in this file whose stamp is asserted happens at `T`, so a
    /// hard-coded `uint64 constant _FAKE_REGISTERED_AT = 1_760_000_000` passes all of them — that
    /// is substitution D1 of the review's degenerate registry, and it walked through 21 of 21.
    /// Mutation V9 (`registeredAt → 0`) is the weak form; this is the one that closes it.
    function test_registrationStampsTheClockItRanAt() public {
        _register(verifier, LABEL, 1_000);
        _assertRecord(verifier, T, T + 1_000, 0, true, false, "registered at T");

        vm.warp(T + 777_777);
        _register(second, LABEL, 1_000);
        _assertRecord(
            second, T + 777_777, T + 777_777 + 1_000, 0, true, false, "registered much later"
        );

        // And the first key's stamp did not move when the second was written.
        _assertRecord(verifier, T, T + 1_000, 0, true, false, "the first stamp is untouched");
    }

    /// **The trap this test exists for.** A `registerVerifier` that ignores its `expiresAt` and
    /// stores `now + MAX_VERIFIER_KEY_LIFETIME_SECONDS` passes every predicate test in this file
    /// that samples only "now". Two keys, two different lifetimes, both values pinned and both
    /// expiry instants walked — a default-storing implementation gives the two keys the same
    /// expiry and dies on the first `assertEq`.
    function test_registrationStoresTheExpiryItWasGivenAndNotADefault() public {
        _register(verifier, LABEL, 1_000);
        _register(second, bytes32("second-key"), 2_000);

        assertEq(config.verifierExpiry(verifier), T + 1_000, "first key's own expiry");
        assertEq(config.verifierExpiry(second), T + 2_000, "second key's own expiry");
        assertEq(config.verifierKey(verifier).expiresAt, T + 1_000, "struct agrees, first");
        assertEq(config.verifierKey(second).expiresAt, T + 2_000, "struct agrees, second");
        assertTrue(
            config.verifierExpiry(verifier) != config.verifierExpiry(second),
            "two lifetimes, two expiries"
        );

        // And the difference is observable through the predicate, at the instant between them.
        vm.warp(T + 1_001);
        assertFalse(config.canSign(verifier), "the shorter key is done");
        assertTrue(config.canSign(second), "the longer key is not");
    }

    /// The registry belongs to *this* proxy. A registry that were somehow global — a library
    /// singleton, or a read that reached the implementation's storage — satisfies every test
    /// above and dies here.
    function test_theRegistryIsThisProxysOwn() public {
        _register(180 * 86_400);
        X402Config otherConfig = _deploy(admin);

        assertTrue(config.canSign(verifier), "registered on the first proxy");
        assertFalse(otherConfig.canSign(verifier), "and only on the first proxy");
        assertEq(otherConfig.verifierExpiry(verifier), 0, "the second proxy knows nothing of it");

        vm.prank(admin);
        otherConfig.registerVerifier(verifier, LABEL, uint64(block.timestamp) + 500);
        assertEq(otherConfig.verifierExpiry(verifier), T + 500, "its own entry, its own expiry");
        assertEq(config.verifierExpiry(verifier), T + 180 * 86_400, "the first is untouched");
    }

    /// One key's lifecycle says nothing about another's. Kills a registry that is really a single
    /// flag: register two, revoke one, and the other must be untouched in every field.
    function test_oneKeysLifecycleDoesNotTouchAnother() public {
        _register(verifier, LABEL, 1_000);
        _register(second, bytes32("second-key"), 1_000);

        vm.prank(admin);
        config.revokeVerifier(verifier);

        assertFalse(config.canSign(verifier), "the revoked key is stopped");
        assertTrue(config.canSign(second), "the other key is not");
        _assertRecord(second, T, T + 1_000, 0, true, false, "the other key's record is intact");
        config.assertCanSign(second); // must not revert
    }

    // ------------------------------------------------------------------------------------
    // authority
    // ------------------------------------------------------------------------------------

    /// `register_verifier.rs:28` / `revoke_verifier.rs:23` — `has_one = admin`. Both doors, and
    /// the register leg runs from an address that is not the admin *and* is not the zero address,
    /// so it cannot be satisfied by an unrelated zero check.
    function test_wrongSigner_onlyAdminRegistersAndRevokes() public {
        vm.prank(stranger);
        vm.expectRevert(NotAdmin.selector);
        config.registerVerifier(verifier, bytes32(0), uint64(block.timestamp) + 1_000);
        assertFalse(config.canSign(verifier), "the refused registration wrote nothing");

        // The default `msg.sender` of a forge test is the test contract, which is also not the
        // admin. Both spellings of "not the admin" are refused.
        vm.expectRevert(NotAdmin.selector);
        config.registerVerifier(verifier, bytes32(0), uint64(block.timestamp) + 1_000);

        _register(180 * 86_400);

        vm.prank(stranger);
        vm.expectRevert(NotAdmin.selector);
        config.revokeVerifier(verifier);
        assertEq(config.verifierKey(verifier).revokedAt, 0, "the refused revoke wrote nothing");
        assertTrue(config.canSign(verifier), "and the key still signs");

        vm.expectRevert(NotAdmin.selector);
        config.revokeVerifier(verifier);
    }

    // ------------------------------------------------------------------------------------
    // an address that was never registered
    // ------------------------------------------------------------------------------------

    function test_wrongState_anUnknownKeyCannotSign() public view {
        assertFalse(config.canSign(unknown), "an address nobody enrolled is not a verifier");
    }

    function test_wrongState_anUnknownKeyRevertsWithItsOwnDiagnosis() public {
        vm.expectRevert(VerifierNotRegistered.selector);
        config.assertCanSign(unknown);
    }

    /// **Both flags are load-bearing, and this is the only test that says so.**
    ///
    /// Over the contract's own API `registered` agrees with `expiresAt != 0` and `revoked` agrees
    /// with `revokedAt != 0` on every reachable state, so a registry that consulted the two
    /// *timestamps* instead of the two flags behaves identically — that is substitutions D2, D3
    /// and D5 of the review's degenerate registry, which passed 21 of 21. The states where they
    /// disagree are what a future writer of this struct, or a storage-layout change, produces, and
    /// `vm.store` constructs them at an ordinary timestamp.
    ///
    /// It doubles as a layout regression test: `_writeEntry` reads its own write back.
    function test_theTwoFlagsAreLoadBearingAtEveryDoor() public {
        // (a) NOT registered, but carrying a live expiry. Everything must refuse it, and
        //     registration must still be OPEN — this address has never been enrolled.
        _writeEntry(unknown, 0, T + 1_000, 0, false, false);
        assertFalse(config.canSign(unknown), "a live expiry is not an enrolment");
        vm.expectRevert(VerifierNotRegistered.selector);
        config.assertCanSign(unknown);
        vm.prank(admin);
        vm.expectRevert(VerifierNotRegistered.selector);
        config.revokeVerifier(unknown);
        vm.prank(admin);
        config.registerVerifier(unknown, LABEL, uint64(block.timestamp) + 500);
        _assertRecord(unknown, T, T + 500, 0, true, false, "an unenrolled slot is registerable");

        // (b) registered with a ZERO expiry. It cannot sign — but it is enrolled, so the
        //     diagnosis is the lapse and not the absence, registration is CLOSED, and revocation
        //     is open.
        _writeEntry(second, T, 0, 0, true, false);
        assertFalse(config.canSign(second), "a zero expiry is expired");
        vm.expectRevert(VerifierKeyExpired.selector);
        config.assertCanSign(second);
        vm.prank(admin);
        vm.expectRevert(VerifierAlreadyRegistered.selector);
        config.registerVerifier(second, LABEL, uint64(block.timestamp) + 500);
        vm.prank(admin);
        config.revokeVerifier(second);
        _assertRecord(second, T, 0, T, true, true, "an enrolled lapsed key is revokable");

        // (c) revoked with a ZERO stamp — what a revocation at genesis leaves behind, and what
        //     the first draft of this port could not tell from "never revoked".
        _writeEntry(stranger, T, T + 1_000, 0, true, true);
        assertFalse(config.canSign(stranger), "the flag stops the key, not the stamp");
        vm.expectRevert(VerifierRevoked.selector);
        config.assertCanSign(stranger);
        vm.prank(admin);
        vm.expectRevert(VerifierAlreadyRevoked.selector);
        config.revokeVerifier(stranger);
    }

    /// The closing half of the same divergence, through the real door. `revokedAt = 0` is a legal
    /// stamp, so under the first draft's `revokedAt != 0` sentinel a revocation at genesis was a
    /// silent no-op — measured live in review: `revokedAt` stayed `0`, `canSign`
    /// returned true, and a second revoke succeeded. This is that case, fixed.
    ///
    /// It is the one assertion in this file on an input a live chain cannot produce, and it is
    /// here as a **regression test on a measured defect**, not as a substitute for coverage — the
    /// test above carries the flags at ordinary timestamps.
    function test_revocationLandsEvenWhenTheStampItselfIsZero() public {
        _writeEntry(verifier, 0, 1_000, 0, true, false);
        vm.warp(0);
        assertTrue(config.canSign(verifier), "active before the revoke");

        vm.prank(admin);
        config.revokeVerifier(verifier);
        _assertRecord(verifier, 0, 1_000, 0, true, true, "revoked at the zero instant");
        assertFalse(config.canSign(verifier), "and it is stopped");
        vm.expectRevert(VerifierRevoked.selector);
        config.assertCanSign(verifier);
        vm.prank(admin);
        vm.expectRevert(VerifierAlreadyRevoked.selector);
        config.revokeVerifier(verifier);
    }

    function test_wrongState_anUnknownKeyHasNoExpiryAndNoStruct() public view {
        _assertRecord(unknown, 0, 0, 0, false, false, "an address nobody enrolled");
    }

    /// `revoke_verifier.rs` takes the PDA as an `Account`, so Anchor's runtime refuses a key that
    /// was never initialised. A Solidity mapping has no absence, so the refusal has to be written
    /// down — and it must be `VerifierNotRegistered`, not `VerifierAlreadyRevoked`, which is what
    /// a `revokedAt != 0` check reached first would say about a zeroed slot's `0`.
    function test_wrongState_revokingAnUnknownKeyIsRefused() public {
        vm.prank(admin);
        vm.expectRevert(VerifierNotRegistered.selector);
        config.revokeVerifier(unknown);
    }

    function test_wrongState_theZeroAddressIsNeverAVerifier() public {
        vm.prank(admin);
        vm.expectRevert(ZeroAddress.selector);
        config.registerVerifier(address(0), bytes32(0), uint64(block.timestamp) + 1_000);
        assertFalse(config.canSign(address(0)), "and stays unregistered");
    }

    // ------------------------------------------------------------------------------------
    // revocation is a one-way door
    // ------------------------------------------------------------------------------------

    /// Revocation is permanent. A reinstatable key makes revocation a pause, not a stop.
    ///
    /// **`canSign(v) == false` is not the property.** It is also true of an implementation that
    /// cleared `registered`, or that let the entry expire — and both of those admit a fresh
    /// registration for the same address, which is `revoke_verifier.rs:35-45` refusing to close
    /// the account. So this test sweeps the clock forward and back over the whole life of the key
    /// *and* then tries both doors again.
    function test_wrongState_revocationCanNeverBeUndone() public {
        _register(180 * 86_400);
        uint256 expiry = T + 180 * 86_400;

        vm.warp(T + 100);
        vm.prank(admin);
        config.revokeVerifier(verifier);
        // **The whole record, not only the stamp.** A `revokeVerifier` that also zeroed
        // `registeredAt` and `expiresAt` passed the first version of this test — and it makes
        // `verifierExpiry(revokedKey)` return 0, which is what `expireSlash` reads.
        _assertRecord(verifier, T, uint64(expiry), T + 100, true, true, "after the revoke");

        // Every instant of the key's registered life, before and after revocation, inside and
        // outside its expiry. None of them may answer true.
        uint256[6] memory instants = [T + 100, T + 101, T + 1_000, expiry - 1, expiry, expiry + 1];
        for (uint256 i = 0; i < instants.length; i++) {
            vm.warp(instants[i]);
            assertFalse(config.canSign(verifier), "a revoked key never signs again");
            vm.expectRevert(VerifierRevoked.selector);
            config.assertCanSign(verifier);
        }

        vm.warp(T + 200);
        vm.prank(admin);
        vm.expectRevert(VerifierAlreadyRevoked.selector);
        config.revokeVerifier(verifier);
        _assertRecord(verifier, T, uint64(expiry), T + 100, true, true, "after the refused revoke");

        vm.prank(admin);
        vm.expectRevert(VerifierAlreadyRegistered.selector);
        config.registerVerifier(verifier, bytes32(0), uint64(block.timestamp) + 1_000);
        assertFalse(config.canSign(verifier), "still stopped after the refused re-registration");
    }

    /// An address that is merely *expired* — never revoked — is equally one-shot. Registration
    /// keys on `registered`, not on "currently able to sign", so rotation is always a new address.
    function test_wrongState_anExpiredKeyCannotBeReRegisteredEither() public {
        _register(1_000);
        vm.warp(T + 5_000);

        vm.prank(admin);
        vm.expectRevert(VerifierAlreadyRegistered.selector);
        config.registerVerifier(verifier, LABEL, uint64(block.timestamp) + 1_000);
        assertFalse(config.canSign(verifier), "and it is still expired");
    }

    /// `revoke_verifier.rs:54-57` checks the **status** and says nothing about expiry, so an
    /// expired key may still be revoked — which matters: `revokedAt` is when the key stopped being
    /// trusted, and an investigator needs it stamped even on a key that had already lapsed.
    ///
    /// It also pins the **diagnosis order**. `state.rs:249-256` asks "revoked?" before "expired?",
    /// so a key that is both reverts `VerifierRevoked`. Reversing the two checks is invisible to
    /// any test that never constructs a key in both states at once.
    function test_anExpiredKeyMayStillBeRevokedAndRevokedWinsTheDiagnosis() public {
        _register(1_000);

        vm.warp(T + 5_000);
        vm.expectRevert(VerifierKeyExpired.selector);
        config.assertCanSign(verifier);

        vm.prank(admin);
        config.revokeVerifier(verifier);
        // The whole record again: a lapsed key's registration history is exactly what an
        // investigator has left, so a revoke that tidied the slot would erase it here.
        _assertRecord(verifier, T, T + 1_000, T + 5_000, true, true, "an expired key still stamps");

        // Both conditions hold now. Anchor checks status first.
        vm.expectRevert(VerifierRevoked.selector);
        config.assertCanSign(verifier);
        assertFalse(config.canSign(verifier), "and the predicate is false either way");
    }

    // ------------------------------------------------------------------------------------
    // boundaries
    // ------------------------------------------------------------------------------------

    /// Boundary B13 at -1 / exact / +1: a key is usable AT its expiry instant.
    /// `state.rs:254` — `now <= self.expires_at`. The middle assertion is the whole test; the
    /// other two would pass against `<` as well.
    function test_boundary_aKeyIsUsableAtExactlyItsExpiry() public {
        _register(1_000);
        uint256 expiry = T + 1_000;

        vm.warp(expiry - 1);
        assertTrue(config.canSign(verifier), "one second before");
        config.assertCanSign(verifier);

        vm.warp(expiry);
        assertTrue(config.canSign(verifier), "the shared instant belongs to the key");
        config.assertCanSign(verifier);

        vm.warp(expiry + 1);
        assertFalse(config.canSign(verifier), "one second after");
        vm.expectRevert(VerifierKeyExpired.selector);
        config.assertCanSign(verifier);
    }

    /// Boundary B16: registration refuses `now`, admits `now + 1`, admits
    /// `now + MAX_VERIFIER_KEY_LIFETIME_SECONDS`, refuses one second past it.
    /// `register_verifier.rs:52-55` — `expires_at > now && expires_at <= now + MAX`.
    ///
    /// Both ends are asserted at -1 / exact / +1, and each admitted call is followed by a
    /// `canSign` so that "admitted" means a key was actually written rather than a call that
    /// merely failed to revert.
    function test_boundary_registrationExpiryBounds() public {
        uint64 nowTs = uint64(block.timestamp);

        // The lower end. `expiresAt == now` is refused; `now + 1` is admitted.
        vm.prank(admin);
        vm.expectRevert(InvalidVerifierExpiry.selector);
        config.registerVerifier(verifier, bytes32(0), nowTs);
        assertFalse(config.canSign(verifier), "the refused call wrote nothing");

        // ...and anything below it, for the same reason.
        vm.prank(admin);
        vm.expectRevert(InvalidVerifierExpiry.selector);
        config.registerVerifier(verifier, bytes32(0), nowTs - 1);

        vm.prank(admin);
        config.registerVerifier(verifier, bytes32(0), nowTs + 1);
        assertTrue(config.canSign(verifier), "a one-second key is a key");
        assertEq(config.verifierExpiry(verifier), nowTs + 1, "and it expires next second");

        // The upper end, on a second address so the one-shot rule does not interfere.
        uint64 ceiling = nowTs + Constants.MAX_VERIFIER_KEY_LIFETIME_SECONDS;

        vm.prank(admin);
        vm.expectRevert(InvalidVerifierExpiry.selector);
        config.registerVerifier(second, bytes32(0), ceiling + 1);
        assertFalse(config.canSign(second), "the refused call wrote nothing");

        vm.prank(admin);
        config.registerVerifier(second, bytes32(0), ceiling);
        assertTrue(config.canSign(second), "the ceiling value itself is admitted");
        assertEq(config.verifierExpiry(second), ceiling, "stored at the ceiling, verbatim");

        // ...and one second inside the ceiling, on a third address.
        vm.prank(admin);
        config.registerVerifier(stranger, bytes32(0), ceiling - 1);
        assertEq(config.verifierExpiry(stranger), ceiling - 1, "one inside the ceiling");
    }

    /// `register_verifier.rs:53` adds the lifetime with `saturating_add`, so a clock close enough
    /// to the end of the type does not make registration *fail* — it makes the ceiling stop
    /// binding, because the type is already the tighter bound. Solidity's checked `+` would panic
    /// there instead, with `Panic(0x11)` in place of a diagnosis, so the sum is widened to
    /// `uint256`. This is the only input that distinguishes the two.
    function test_boundary_aCeilingThatWouldOverflowUint64Saturates() public {
        uint64 late = type(uint64).max - 100;
        vm.warp(late);

        vm.prank(admin);
        config.registerVerifier(verifier, LABEL, type(uint64).max);
        assertTrue(config.canSign(verifier), "admitted, exactly as saturating_add admits it");
        assertEq(config.verifierExpiry(verifier), type(uint64).max, "stored verbatim");

        // The lower bound still binds at the same clock.
        vm.prank(admin);
        vm.expectRevert(InvalidVerifierExpiry.selector);
        config.registerVerifier(second, LABEL, late);
    }

    // ------------------------------------------------------------------------------------
    // events
    // ------------------------------------------------------------------------------------

    /// `events.rs:90-96`, field names kept. Asserts the **full** data payload, so an
    /// implementation that emitted the label as `bytes32(0)` or the ceiling in place of the
    /// argument is caught here as well as in the storage tests.
    function test_registrationEmitsVerifierRegistered() public {
        vm.expectEmit(true, true, false, true, address(config));
        emit X402Config.VerifierRegistered(verifier, admin, LABEL, T, T + 1_000);
        _register(1_000);
    }

    /// **The log is the whole audit trail for `label`, and `vm.expectEmit` alone does not defend
    /// it.** `expectEmit` matches *a* log and says nothing about how many were emitted or about a
    /// clock other than the one the assertion happens to run at, so a registry whose log carried a
    /// hard-coded `registeredAt`, plus a spurious second `VerifierRegistered` for an address
    /// nobody asked about, passed the whole suite. This reads the raw logs instead: **exactly
    /// one**, at a clock that is not `T`, decoded field by field.
    function test_theRegistrationLogIsExactlyOneAndCarriesTheClockItRanAt() public {
        vm.warp(T + 777_777);
        uint64 nowTs = uint64(block.timestamp);

        vm.recordLogs();
        _register(verifier, LABEL, 1_000);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length, 1, "a registration emits exactly one event");
        assertEq(logs[0].emitter, address(config), "emitted by the proxy");
        assertEq(logs[0].topics.length, 3, "one signature topic and two indexed addresses");
        assertEq(
            logs[0].topics[0],
            keccak256("VerifierRegistered(address,address,bytes32,uint64,uint64)"),
            "signature"
        );
        assertEq(address(uint160(uint256(logs[0].topics[1]))), verifier, "verifier topic");
        assertEq(address(uint160(uint256(logs[0].topics[2]))), admin, "admin topic");

        (bytes32 label, uint64 registeredAt, uint64 expiresAt) =
            abi.decode(logs[0].data, (bytes32, uint64, uint64));
        assertEq(label, LABEL, "the operator's key id survives the call");
        assertEq(registeredAt, nowTs, "the log carries the clock, not a constant");
        assertEq(expiresAt, nowTs + 1_000, "and the expiry it was given");
    }

    /// The same, for the revocation log: exactly one, at a clock that is neither the registration
    /// clock nor `T`.
    function test_theRevocationLogIsExactlyOneAndCarriesTheClockItRanAt() public {
        _register(10_000);
        vm.warp(T + 4_321);

        vm.recordLogs();
        vm.prank(admin);
        config.revokeVerifier(verifier);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length, 1, "a revocation emits exactly one event");
        assertEq(logs[0].emitter, address(config), "emitted by the proxy");
        assertEq(logs[0].topics.length, 3, "one signature topic and two indexed addresses");
        assertEq(
            logs[0].topics[0],
            keccak256("VerifierRevokedEvent(address,address,uint64)"),
            "signature"
        );
        assertEq(address(uint160(uint256(logs[0].topics[1]))), verifier, "verifier topic");
        assertEq(address(uint160(uint256(logs[0].topics[2]))), admin, "admin topic");
        assertEq(abi.decode(logs[0].data, (uint64)), T + 4_321, "the instant it ran");
    }

    /// `events.rs:98-103`. Emitted at the instant of the call, not at registration.
    function test_revocationEmitsVerifierRevokedEvent() public {
        _register(1_000);
        vm.warp(T + 400);

        vm.expectEmit(true, true, false, true, address(config));
        emit X402Config.VerifierRevokedEvent(verifier, admin, T + 400);
        vm.prank(admin);
        config.revokeVerifier(verifier);
    }

    // ------------------------------------------------------------------------------------
    // negative space — what this door must NOT have grown
    // ------------------------------------------------------------------------------------

    /// **Neither door is gated on the pause, and revocation especially must not be.** Anchor's
    /// `register_verifier.rs` and `revoke_verifier.rs` read `Config` without consulting
    /// `config.paused` at all — `set_paused.rs:13-22` closes the doors that move money, and these
    /// move none. A pause gate on `revokeVerifier` would make the emergency stop for a stolen key
    /// unreachable in exactly the incident that stops the system: paused, with a compromised key
    /// still able to sign judgements.
    function test_theRegistryIsNotGatedOnThePause() public {
        vm.prank(admin);
        config.setPaused(true);
        assertTrue(config.paused(), "paused for the duration of this test");

        _register(1_000);
        assertTrue(config.canSign(verifier), "registration lands while paused");

        vm.prank(admin);
        config.revokeVerifier(verifier);
        assertFalse(config.canSign(verifier), "and so does revocation");
    }

    /// A pure **acceptance** test: every row below is legal under `register_verifier.rs:44-75`,
    /// so it fails if anybody adds a precondition the reference lacks. It survives every mutation
    /// that changes what is *refused* and must never be cited as bounds coverage.
    function test_registrationAddsNoPreconditionTheReferenceLacks() public {
        vm.startPrank(admin);
        // An empty label. `label` is opaque operator metadata; nothing reads it on chain.
        config.registerVerifier(verifier, bytes32(0), uint64(block.timestamp) + 1);
        // A label that is not ASCII, and a one-year lifetime at the same time.
        config.registerVerifier(
            second, bytes32(type(uint256).max), uint64(block.timestamp) + 365 * 86_400
        );
        // The admin may enrol itself; nothing forbids the two roles overlapping.
        config.registerVerifier(admin, LABEL, uint64(block.timestamp) + 1_000);
        // A duplicate label across two keys. Labels are not identifiers.
        config.registerVerifier(stranger, LABEL, uint64(block.timestamp) + 1_000);
        vm.stopPrank();

        assertTrue(config.canSign(verifier), "empty label");
        assertTrue(config.canSign(second), "max label, max lifetime");
        assertTrue(config.canSign(admin), "the admin as a verifier");
        assertTrue(config.canSign(stranger), "a duplicate label");
    }
}
