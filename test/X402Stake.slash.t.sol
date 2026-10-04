// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.24;

import {Fixture} from "./helpers/Fixture.sol";
import {VoucherSigner} from "./helpers/VoucherSigner.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ReentrantStakeUSDG, StakeObserverUSDG} from "./helpers/MockUSDG.sol";
import {X402Stake} from "../src/X402Stake.sol";
import {SlashAttestation, ResponseClass, SlashStatus, ParamSet} from "../src/Types.sol";
import {Constants} from "../src/Constants.sol";
import "../src/Errors.sol";

contract X402StakeSlashTest is Fixture {
    uint256 internal verifierKeyPk = 0x7E5717;
    address internal verifierAddr;
    address internal beneficiary = address(0xA6E7);
    uint64 internal constant BOND = 1_000_000_000; // 1,000 USDG

    function setUp() public virtual override {
        super.setUp();
        // This suite's own stake contract, for the reason `X402StakeTest.setUp` gives: the
        // fixture's is pre-funded to MINIMUM_STAKE for the escrow tests, and `capAllowance` is a
        // fraction of the provider's WHOLE stake, so that 100 USDG would move every figure here.
        stake = _deployStake(address(usdg));
        verifierAddr = vm.addr(verifierKeyPk);

        vm.prank(admin);
        config.registerVerifier(
            verifierAddr, bytes32("verifier-evm-2026-09"), uint64(block.timestamp) + 180 * 86_400
        );

        _fund(provider, BOND);
        vm.startPrank(provider);
        usdg.approve(address(stake), BOND);
        stake.depositStake(BOND);
        vm.stopPrank();
    }

    function _att(bytes32 requestId, uint64 penalty)
        internal
        view
        returns (SlashAttestation memory)
    {
        return SlashAttestation({
            requestId: requestId,
            provider: provider,
            beneficiary: beneficiary,
            status: uint8(ResponseClass.DataFail),
            penalty: penalty,
            policy: keccak256("policy v1"),
            issuedAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp) + 3 * 86_400
        });
    }

    function _sign(SlashAttestation memory a, uint256 pk) internal view returns (bytes memory) {
        return VoucherSigner.signAttestation(pk, stake.DOMAIN_SEPARATOR(), a);
    }

    function _stakeFor(address who, uint64 amount) internal {
        _fund(address(this), amount);
        usdg.approve(address(stake), amount);
        stake.depositStakeFor(who, amount);
    }

    function _propose(bytes32 id, uint64 penalty) internal returns (SlashAttestation memory a) {
        a = _att(id, penalty);
        stake.proposeSlash(a, _sign(a, verifierKeyPk));
    }

    /// **The signature is built BEFORE `vm.expectRevert` is armed, and that is not style.**
    /// `_sign` reads `stake.DOMAIN_SEPARATOR()`, which is an external call; an armed
    /// `expectRevert` binds to the NEXT call, so writing
    /// `vm.expectRevert(E); stake.proposeSlash(a, _sign(a, pk))` arms the cheat code against the
    /// domain read — which succeeds — and every such test fails with "next call did not revert
    /// as expected" no matter what `proposeSlash` does. Measured: that spelling failed 11
    /// of this file's 17 tests against a correct implementation.
    function _expect(SlashAttestation memory a, uint256 pk, bytes4 err) internal {
        bytes memory sig = _sign(a, pk);
        vm.expectRevert(err);
        stake.proposeSlash(a, sig);
    }

    function test_happyPath_aProposalReservesCollateralAndWaits() public {
        _propose(bytes32("r1"), 1_000_000);

        assertEq(uint256(stake.slashRecordOf(bytes32("r1")).status), uint256(SlashStatus.Pending));
        assertEq(stake.slashRecordOf(bytes32("r1")).reserved, 1_000_000);
        assertEq(stake.slashRecordOf(bytes32("r1")).verifier, verifierAddr);
        assertEq(stake.slashRecordOf(bytes32("r1")).provider, provider);
        assertEq(stake.slashRecordOf(bytes32("r1")).beneficiary, beneficiary);
        assertEq(stake.slashRecordOf(bytes32("r1")).penalty, 1_000_000);
        assertEq(stake.slashRecordOf(bytes32("r1")).policy, keccak256("policy v1"));
        assertEq(stake.slashRecordOf(bytes32("r1")).proposedAt, uint64(block.timestamp));
        assertEq(
            stake.slashRecordOf(bytes32("r1")).executableAt,
            uint64(block.timestamp) + Constants.SLASH_DELAY_SECONDS
        );
        assertEq(stake.stakeOf(provider).pendingSlash, 1_000_000);
        // Nothing moved.
        assertEq(usdg.balanceOf(beneficiary), 0);
        assertEq(stake.stakeOf(provider).bonded, BOND);
        assertEq(stake.totalSlashed(), 0);
        assertEq(usdg.balanceOf(address(stake)), BOND);
    }

    /// Permissionless to SUBMIT: the authority is the signature, not the sender. Four unrelated
    /// senders, four request ids, one key.
    function test_happyPath_anybodyMaySubmitAVerifiersJudgement() public {
        address[4] memory senders = [address(0xF00D), buyer, provider, redeemer];
        bytes32[4] memory ids = [bytes32("s1"), bytes32("s2"), bytes32("s3"), bytes32("s4")];
        for (uint256 i = 0; i < senders.length; i++) {
            SlashAttestation memory a = _att(ids[i], 1_000);
            vm.prank(senders[i]);
            stake.proposeSlash(a, _sign(a, verifierKeyPk));
            assertEq(stake.slashRecordOf(ids[i]).reserved, 1_000);
        }
        assertEq(stake.stakeOf(provider).pendingSlash, 4_000);
    }

    function test_wrongSigner_anUnregisteredKeyCannotPropose() public {
        SlashAttestation memory a = _att(bytes32("r1"), 1_000_000);
        _expect(a, 0xBADBAD, VerifierNotRegistered.selector);
    }

    function test_wrongSigner_aRevokedKeyCannotPropose() public {
        vm.prank(admin);
        config.revokeVerifier(verifierAddr);
        SlashAttestation memory a = _att(bytes32("r1"), 1_000_000);
        _expect(a, verifierKeyPk, VerifierRevoked.selector);
    }

    /// An attestation signed against X402Escrow's domain is not signed for this contract. Two
    /// independent guards keep the two doors apart — the typehash and the `verifyingContract` —
    /// and this is the one that pins the domain half.
    function test_wrongSigner_anAttestationSignedForTheEscrowIsRefusedHere() public {
        SlashAttestation memory a = _att(bytes32("r1"), 1_000_000);
        bytes memory wrongDomain =
            VoucherSigner.signAttestation(verifierKeyPk, escrow.DOMAIN_SEPARATOR(), a);
        vm.expectRevert(VerifierNotRegistered.selector);
        stake.proposeSlash(a, wrongDomain);
    }

    /// THE REPLAY LOCK. One request id, one proposal, forever.
    function test_wrongState_theSameRequestIdCanNeverBeProposedTwice() public {
        _propose(bytes32("r1"), 1_000_000);
        SlashAttestation memory a = _att(bytes32("r1"), 1_000_000);
        _expect(a, verifierKeyPk, SlashAlreadyExists.selector);
        assertEq(stake.stakeOf(provider).pendingSlash, 1_000_000, "reserved once, not twice");
    }

    function test_wrongState_onlyDataFailSlashes() public {
        uint8[3] memory harmless = [
            uint8(ResponseClass.Pass),
            uint8(ResponseClass.SystemError),
            uint8(ResponseClass.RequestError)
        ];
        for (uint256 i = 0; i < harmless.length; i++) {
            SlashAttestation memory a = _att(bytes32("r1"), 1_000_000);
            a.status = harmless[i];
            _expect(a, verifierKeyPk, StatusDoesNotSlash.selector);
        }
        // And a byte outside the enum entirely, which `uint8` is what admits diagnosing.
        SlashAttestation memory bad = _att(bytes32("r1"), 1_000_000);
        bad.status = 99;
        _expect(bad, verifierKeyPk, StatusDoesNotSlash.selector);
    }

    function test_wrongState_aPenaltyAboveTheConfiguredMaximumIsRefused() public {
        SlashAttestation memory a = _att(bytes32("r1"), 1_000_001); // params.penaltyAmount 1_000_000
        _expect(a, verifierKeyPk, PenaltyExceedsMaximum.selector);

        // A ceiling, not an equality: exactly the maximum is admitted.
        SlashAttestation memory ok = _att(bytes32("r2"), 1_000_000);
        stake.proposeSlash(ok, _sign(ok, verifierKeyPk));
        assertEq(stake.slashRecordOf(bytes32("r2")).penalty, 1_000_000);
    }

    function test_wrongState_aZeroPenaltyAndAZeroBeneficiaryAreRefused() public {
        SlashAttestation memory a = _att(bytes32("r1"), 0);
        _expect(a, verifierKeyPk, ZeroAmount.selector);

        SlashAttestation memory b = _att(bytes32("r1"), 1_000_000);
        b.beneficiary = address(0);
        _expect(b, verifierKeyPk, MissingBeneficiary.selector);
    }

    /// Boundary: the attestation window at -1 / exact / +1 on both ends.
    function test_boundary_theAttestationWindow() public {
        SlashAttestation memory a = _att(bytes32("r1"), 1_000_000);
        a.expiresAt = a.issuedAt;
        _expect(a, verifierKeyPk, InvalidAttestationWindow.selector);

        a = _att(bytes32("r1"), 1_000_000);
        a.expiresAt = a.issuedAt + Constants.MAX_ATTESTATION_LIFETIME_SECONDS + 1;
        _expect(a, verifierKeyPk, InvalidAttestationWindow.selector);

        a = _att(bytes32("r1"), 1_000_000);
        a.expiresAt = a.issuedAt + Constants.MAX_ATTESTATION_LIFETIME_SECONDS; // admitted exactly
        stake.proposeSlash(a, _sign(a, verifierKeyPk));

        a = _att(bytes32("r2"), 1_000_000);
        a.issuedAt = uint64(block.timestamp) + 1; // dated in the future
        a.expiresAt = a.issuedAt + 3600;
        _expect(a, verifierKeyPk, AttestationNotYetValid.selector);

        // AT its expiry instant an attestation is still valid — `now <= expires_at`
        // (`attestation.rs:175`), so the shared instant belongs to the attestation.
        SlashAttestation memory atExpiry = _att(bytes32("r4"), 1_000_000);
        bytes memory sigAtExpiry = _sign(atExpiry, verifierKeyPk);
        vm.warp(uint256(atExpiry.expiresAt));
        stake.proposeSlash(atExpiry, sigAtExpiry);
        assertEq(stake.slashRecordOf(bytes32("r4")).reserved, 1_000_000);

        a = _att(bytes32("r3"), 1_000_000);
        vm.warp(uint256(a.expiresAt) + 1);
        _expect(a, verifierKeyPk, AttestationExpired.selector);
    }

    /// The cap allowance is a fraction of the provider's OWN stake — 1,000 bps of 1,000 USDG
    /// = 100 USDG — and it is FROZEN onto the record at proposal, so a parameter change in
    /// the 72 hours cannot move it. `penaltyAmount` (1 USDG) is what bounds the reservation
    /// here; the allowance is asserted as arithmetic, not exercised as a clamp.
    function test_theCapAllowanceIsFrozenFromTheProvidersOwnStake() public {
        _propose(bytes32("r1"), 1_000_000);
        assertEq(stake.slashRecordOf(bytes32("r1")).capAllowance, 100_000_000); // 10% of 1,000
        assertEq(stake.slashRecordOf(bytes32("r1")).reserved, 1_000_000); // min(penalty, cap, free)

        // Frozen: halving the parameter after the fact leaves the record alone.
        ParamSet memory p = config.params();
        p.slashCapBps = 500;
        vm.prank(admin);
        config.updateConfig(p, address(0));
        assertEq(stake.slashRecordOf(bytes32("r1")).capAllowance, 100_000_000);
        // and the NEXT proposal reads the new one.
        _propose(bytes32("r2"), 1_000_000);
        assertEq(stake.slashRecordOf(bytes32("r2")).capAllowance, 50_000_000);
    }

    /// `reserved = min(penalty, capAllowance, atRisk - pendingSlash)`, and this is the SECOND
    /// term binding: a thin provider whose whole daily ceiling is below the penalty the verifier
    /// signed. The judgement stays what it was; only what it may ever be paid is cut.
    function test_theCapAllowanceClampsAReservationThePenaltyWouldHaveAllowed() public {
        address thin = address(0x7418);
        _stakeFor(thin, 5_000_000); // slashCapBps 1_000 → capAllowance 500_000

        SlashAttestation memory a = _att(bytes32("k1"), 1_000_000);
        a.provider = thin;
        stake.proposeSlash(a, _sign(a, verifierKeyPk));

        assertEq(stake.slashRecordOf(bytes32("k1")).capAllowance, 500_000);
        assertEq(stake.slashRecordOf(bytes32("k1")).reserved, 500_000, "cut to the ceiling");
        assertEq(stake.slashRecordOf(bytes32("k1")).penalty, 1_000_000, "the judgement is intact");
        assertEq(stake.stakeOf(thin).pendingSlash, 500_000);
    }

    /// `reserved = min(penalty, capAllowance, atRisk - pendingSlash)`, and this is the third
    /// term binding: three judgements against a provider whose free balance runs out under the
    /// last one. Reservations stack up to the whole stake and no further — `propose_slash.rs`'s
    /// "a leaked key can freeze a provider's exit … it cannot take it".
    ///
    /// The cap is raised to its MAXIMUM first, because at the fixture's 1,000 bps the ceiling is
    /// exactly a tenth of `atRisk` and the free term can then only ever EQUAL it, never fall
    /// below it — an arrangement in which this clamp is unreachable and the test would prove
    /// nothing.
    function test_theFreeBalanceClampsAReservationTheCapWouldHaveAllowed() public {
        ParamSet memory p = config.params();
        p.slashCapBps = Constants.MAX_SLASH_CAP_BPS; // 5,000 — half of atRisk
        vm.prank(admin);
        config.updateConfig(p, address(0));

        address thin = address(0x7417);
        _stakeFor(thin, 2_500_000);

        bytes32[3] memory ids = [bytes32("f1"), bytes32("f2"), bytes32("f3")];
        for (uint256 i = 0; i < 3; i++) {
            SlashAttestation memory a = _att(ids[i], 1_000_000);
            a.provider = thin;
            stake.proposeSlash(a, _sign(a, verifierKeyPk));
        }

        assertEq(stake.slashRecordOf(bytes32("f1")).reserved, 1_000_000);
        assertEq(stake.slashRecordOf(bytes32("f2")).reserved, 1_000_000);
        assertEq(stake.slashRecordOf(bytes32("f3")).reserved, 500_000, "clamped to what was free");
        assertEq(stake.slashRecordOf(bytes32("f3")).penalty, 1_000_000, "the judgement is intact");
        assertEq(stake.stakeOf(thin).pendingSlash, 2_500_000);

        // And nothing more can be reserved: free is now zero.
        SlashAttestation memory over = _att(bytes32("f4"), 1_000_000);
        over.provider = thin;
        _expect(over, verifierKeyPk, NothingToSlash.selector);
    }

    /// A provider with nothing at risk cannot be judged.
    function test_wrongState_nothingToSlash() public {
        address bare = address(0xBA2E);
        SlashAttestation memory a = _att(bytes32("r1"), 1_000_000);
        a.provider = bare;
        _expect(a, verifierKeyPk, NothingToSlash.selector);
    }

    /// A stake so small that 10% of it floors to zero: there is a ceiling, and it is nothing.
    function test_wrongState_aCapAllowanceThatRoundsToZeroIsRefused() public {
        address dust = address(0xD057);
        _stakeFor(dust, 9); // 10% of 9 floors to 0

        SlashAttestation memory a = _att(bytes32("r1"), 1_000_000);
        a.provider = dust;
        _expect(a, verifierKeyPk, SlashCapExceeded.selector);
    }

    function test_wrongState_proposeIsClosedWhilePaused() public {
        vm.prank(admin);
        config.setPaused(true);
        SlashAttestation memory a = _att(bytes32("r1"), 1_000_000);
        _expect(a, verifierKeyPk, ProgramPaused.selector);
    }

    /// FLIP ONE SIGNED FIELD.
    ///
    /// **Every case allocates from `_att` rather than copying the signed struct.**
    /// `SlashAttestation memory t = signed;` ALIASES in Solidity — it copies a pointer, not a
    /// value — so the `t = signed; t.x = …` spelling mutates `signed` itself and every
    /// case after the first flips a field on top of the previous flip. That is the trap recorded
    /// against the voucher encoder test and the batch test; here it would have made this test
    /// assert something weaker than it claims, and the same signature is reused across all eight
    /// cases on purpose.
    ///
    /// A tampered field changes the digest, so `Sig.recover` returns a DIFFERENT address and the
    /// failure surfaces as `VerifierNotRegistered` rather than a signature error. That is the
    /// correct diagnosis and nobody should "fix" it.
    function test_flipOneSignedField_everyAttestationFieldIsBound() public {
        SlashAttestation memory signed = _att(bytes32("r1"), 1_000_000);
        bytes memory sig = _sign(signed, verifierKeyPk);

        SlashAttestation memory t = _att(bytes32("r1"), 999_999); // penalty
        _expectUnrecognised(t, sig);

        t = _att(bytes32("r1"), 1_000_000);
        t.provider = address(0xDEAD);
        _expectUnrecognised(t, sig);

        t = _att(bytes32("r1"), 1_000_000);
        t.beneficiary = address(0xDEAD);
        _expectUnrecognised(t, sig);

        t = _att(bytes32("r2"), 1_000_000); // requestId
        _expectUnrecognised(t, sig);

        t = _att(bytes32("r1"), 1_000_000);
        t.policy = keccak256("policy v2");
        _expectUnrecognised(t, sig);

        t = _att(bytes32("r1"), 1_000_000);
        t.issuedAt = t.issuedAt - 1;
        _expectUnrecognised(t, sig);

        t = _att(bytes32("r1"), 1_000_000);
        t.expiresAt = t.expiresAt - 1;
        _expectUnrecognised(t, sig);

        // `status` is the eighth field. Flipping it to another CLASS is refused by
        // `StatusDoesNotSlash` before recovery ever runs, so the binding has to be shown from
        // the other side: the same bytes with the status left alone are ACCEPTED.
        stake.proposeSlash(signed, sig);
        assertEq(stake.slashRecordOf(bytes32("r1")).reserved, 1_000_000);
    }

    function _expectUnrecognised(SlashAttestation memory t, bytes memory sig) internal {
        vm.expectRevert(VerifierNotRegistered.selector);
        stake.proposeSlash(t, sig);
    }

    /// One guard, many keys and many providers: a judgement is bound to the provider it names
    /// and to no other, across a sweep.
    function test_theReservationLandsOnTheNamedProviderAndNoOther() public {
        uint256[3] memory pks = [uint256(0xA1), uint256(0xA2), uint256(0xA3)];
        address[3] memory provs =
            [address(0xC0DE01), address(0xC0DE02), address(uint160(uint256(keccak256("p3"))))];

        for (uint256 i = 0; i < 3; i++) {
            vm.prank(admin);
            config.registerVerifier(
                vm.addr(pks[i]), bytes32("k"), uint64(block.timestamp) + 100 * 86_400
            );
            _stakeFor(provs[i], 10_000_000);
        }

        for (uint256 i = 0; i < 3; i++) {
            SlashAttestation memory a = _att(bytes32(uint256(0x5000 + i)), 100_000);
            a.provider = provs[i];
            stake.proposeSlash(a, _sign(a, pks[i]));
        }

        for (uint256 i = 0; i < 3; i++) {
            assertEq(stake.stakeOf(provs[i]).pendingSlash, 100_000);
            assertEq(stake.slashRecordOf(bytes32(uint256(0x5000 + i))).verifier, vm.addr(pks[i]));
            assertEq(stake.slashRecordOf(bytes32(uint256(0x5000 + i))).provider, provs[i]);
        }
        assertEq(stake.stakeOf(provider).pendingSlash, 0, "the fixture's provider is untouched");
    }

    // ---- phase two ---------------------------------------------------------------------------

    function _signFor(X402Stake st, SlashAttestation memory a, uint256 pk)
        internal
        view
        returns (bytes memory)
    {
        return VoucherSigner.signAttestation(pk, st.DOMAIN_SEPARATOR(), a);
    }

    function test_happyPath_aJudgementPaysAfterSeventyTwoHours() public {
        _propose(bytes32("r1"), 1_000_000);
        vm.warp(block.timestamp + Constants.SLASH_DELAY_SECONDS);

        vm.prank(address(0xF00D)); // permissionless
        stake.executeSlash(bytes32("r1"));

        // slashAgentBps 6000, slashPlatformBps 3000 → the provider KEEPS 10%. Pinned PER
        // RECIPIENT: `agent + platform == taken` is structurally true and would hold for any
        // split, including one that paid the platform everything.
        assertEq(usdg.balanceOf(beneficiary), 600_000);
        assertEq(usdg.balanceOf(treasury), 300_000);
        assertEq(stake.stakeOf(provider).bonded, BOND - 900_000);
        assertEq(stake.stakeOf(provider).totalSlashed, 900_000);
        assertEq(stake.stakeOf(provider).pendingSlash, 0);
        assertEq(stake.totalSlashed(), 900_000);
        assertEq(uint256(stake.slashRecordOf(bytes32("r1")).status), uint256(SlashStatus.Executed));
        assertEq(stake.slashRecordOf(bytes32("r1")).applied, 1_000_000);
        assertEq(stake.slashRecordOf(bytes32("r1")).executedAt, uint64(block.timestamp));
        // 100_000 of the judgement was never transferred to anybody.
        assertEq(usdg.balanceOf(address(stake)), BOND - 900_000);
    }

    /// The same judgement under a DIFFERENT split, so the two shares are read from the two
    /// parameters rather than from one of them or from a constant.
    function test_theSplitIsReadFromBothParametersSeparately() public {
        ParamSet memory p = config.params();
        p.slashAgentBps = 1_000; // 10%
        p.slashPlatformBps = 1_000; // 10% — the provider keeps 80%
        vm.prank(admin);
        config.updateConfig(p, address(0));

        _propose(bytes32("r1"), 1_000_000);
        vm.warp(block.timestamp + Constants.SLASH_DELAY_SECONDS);
        stake.executeSlash(bytes32("r1"));

        assertEq(usdg.balanceOf(beneficiary), 100_000, "the agent's share");
        assertEq(usdg.balanceOf(treasury), 100_000, "the platform's share");
        assertEq(stake.stakeOf(provider).bonded, BOND - 200_000, "and the provider kept 80%");
        assertEq(stake.slashRecordOf(bytes32("r1")).applied, 1_000_000, "of a WHOLE judgement");
    }

    /// The identity survives a slash.
    function test_theAccountingIdentitySurvivesASlash() public {
        _propose(bytes32("r1"), 1_000_000);
        vm.warp(block.timestamp + Constants.SLASH_DELAY_SECONDS);
        stake.executeSlash(bytes32("r1"));
        assertEq(
            stake.totalStaked(),
            stake.totalDeposited() - stake.totalWithdrawn() - stake.totalSlashed()
        );
    }

    /// Boundary B11/B12 — the two windows and every one of the four shared instants the D-13
    /// table names, each at one warp. Four records, because a record that leaves `Pending`
    /// cannot be asked the next question.
    function test_boundary_theExecutionWindowAndItsSharedInstantWithExpire() public {
        _propose(bytes32("r1"), 1_000_000);
        _propose(bytes32("r2"), 1_000_000);
        _propose(bytes32("r3"), 1_000_000);
        uint64 executableAt = stake.slashRecordOf(bytes32("r1")).executableAt;

        // executableAt - 1: neither door is open.
        vm.warp(uint256(executableAt) - 1);
        vm.expectRevert(SlashNotYetExecutable.selector);
        stake.executeSlash(bytes32("r1"));
        vm.expectRevert(SlashNotExpired.selector);
        stake.expireSlash(bytes32("r1"));

        // executableAt exactly: execute opens, expire is still shut.
        vm.warp(uint256(executableAt));
        vm.expectRevert(SlashNotExpired.selector);
        stake.expireSlash(bytes32("r1"));
        stake.executeSlash(bytes32("r2"));

        // executableAt + GRACE - 1: the last instant execute is open, and expire is still shut.
        vm.warp(uint256(executableAt) + Constants.SLASH_EXECUTION_GRACE_SECONDS - 1);
        vm.expectRevert(SlashNotExpired.selector);
        stake.expireSlash(bytes32("r1"));
        stake.executeSlash(bytes32("r3"));

        // THE SHARED INSTANT: execute closes at exactly the moment expire opens.
        vm.warp(uint256(executableAt) + Constants.SLASH_EXECUTION_GRACE_SECONDS);
        vm.expectRevert(SlashExecutionWindowClosed.selector);
        stake.executeSlash(bytes32("r1"));
        stake.expireSlash(bytes32("r1")); // exactly one of the two succeeds

        assertEq(uint256(stake.slashRecordOf(bytes32("r1")).status), uint256(SlashStatus.Cancelled));
        assertEq(stake.stakeOf(provider).pendingSlash, 0, "the reservation was released");
        assertEq(usdg.balanceOf(beneficiary), 1_200_000, "r2 and r3 paid; r1 paid nothing");
    }

    /// Boundary B13 — the verifier's expiry instant, and its complement in expireSlash.
    ///
    /// Needs a SHORT-lived key: `executeSlash` checks the execution window (B11/B12) BEFORE
    /// the key, so with the fixture's 180-day key the warp to its expiry would land 170 days
    /// past the 7-day grace and revert `SlashExecutionWindowClosed` — proving nothing about
    /// B13. So: a second key that expires 4 days out, inside the [3 d, 10 d) window of a
    /// judgement proposed now.
    function test_boundary_theVerifierExpiryInstantBelongsToExecute() public {
        uint256 shortPk = 0x5407;
        address shortKey = vm.addr(shortPk);
        uint64 keyExpiry = uint64(block.timestamp) + 4 * 86_400;
        vm.prank(admin);
        config.registerVerifier(shortKey, bytes32("verifier-evm-short"), keyExpiry);

        // r1: proposed now → executable at +3 d, grace until +10 d. Key expires at +4 d.
        SlashAttestation memory a1 = _att(bytes32("r1"), 1_000_000);
        stake.proposeSlash(a1, _sign(a1, shortPk));

        // r2: proposed at +1 d so that its executableAt == keyExpiry exactly.
        vm.warp(block.timestamp + 1 days);
        SlashAttestation memory a2 = _att(bytes32("r2"), 1_000_000);
        stake.proposeSlash(a2, _sign(a2, shortPk));
        assertEq(stake.slashRecordOf(bytes32("r2")).executableAt, keyExpiry);

        // AT the expiry instant: the key can still sign, so expire refuses and execute pays.
        vm.warp(keyExpiry);
        vm.expectRevert(SlashNotExpired.selector);
        stake.expireSlash(bytes32("r1"));
        stake.executeSlash(bytes32("r1")); // the shared instant belongs to execute
        assertEq(usdg.balanceOf(beneficiary), 600_000);

        // ONE SECOND LATER: r2 is executable (its clock ran out at keyExpiry) but the key is
        // dead, so execute reverts on the KEY — not on the window — and expire releases.
        vm.warp(uint256(keyExpiry) + 1);
        vm.expectRevert(VerifierKeyExpired.selector);
        stake.executeSlash(bytes32("r2"));
        stake.expireSlash(bytes32("r2"));
        assertEq(uint256(stake.slashRecordOf(bytes32("r2")).status), uint256(SlashStatus.Cancelled));
        assertEq(stake.stakeOf(provider).pendingSlash, 0);
    }

    /// THE POINT OF THE TWO-PHASE DESIGN: revocation in the window voids what is in flight.
    function test_revokingTheKeyInTheWindowVoidsTheJudgementAndReleasesTheCollateral() public {
        _propose(bytes32("r1"), 1_000_000);
        assertEq(stake.stakeOf(provider).pendingSlash, 1_000_000);

        vm.prank(admin);
        config.revokeVerifier(verifierAddr);

        vm.warp(block.timestamp + Constants.SLASH_DELAY_SECONDS);
        vm.expectRevert(VerifierRevoked.selector);
        stake.executeSlash(bytes32("r1"));

        vm.prank(address(0xCAFE)); // permissionless cleanup — a stranger, not the admin
        stake.expireSlash(bytes32("r1"));
        assertEq(stake.stakeOf(provider).pendingSlash, 0);
        assertEq(stake.stakeOf(provider).bonded, BOND, "nothing was taken");
        assertEq(usdg.balanceOf(beneficiary), 0);
        assertEq(uint256(stake.slashRecordOf(bytes32("r1")).status), uint256(SlashStatus.Cancelled));
    }

    /// And the same fact reaches EVERY judgement that key signed, not only the one being looked
    /// at — which is what makes revocation a cleanup rather than a stop.
    function test_revocationReachesEveryJudgementThatKeySigned() public {
        _propose(bytes32("r1"), 1_000_000);
        _propose(bytes32("r2"), 1_000_000);
        _propose(bytes32("r3"), 1_000_000);
        assertEq(stake.stakeOf(provider).pendingSlash, 3_000_000);

        vm.prank(admin);
        config.revokeVerifier(verifierAddr);
        vm.warp(block.timestamp + Constants.SLASH_DELAY_SECONDS);

        bytes32[3] memory ids = [bytes32("r1"), bytes32("r2"), bytes32("r3")];
        for (uint256 i = 0; i < 3; i++) {
            vm.expectRevert(VerifierRevoked.selector);
            stake.executeSlash(ids[i]);
            stake.expireSlash(ids[i]);
        }
        assertEq(stake.stakeOf(provider).pendingSlash, 0);
        assertEq(stake.stakeOf(provider).bonded, BOND);
    }

    function test_wrongSigner_onlyAdminCancels() public {
        _propose(bytes32("r1"), 1_000_000);
        vm.expectRevert(NotAdmin.selector);
        stake.cancelSlash(bytes32("r1"));

        // Not the verifier either — a leaked verifier key must not be able to void an honest
        // judgement, which is `cancel_slash.rs`'s whole argument for the admin.
        vm.prank(verifierAddr);
        vm.expectRevert(NotAdmin.selector);
        stake.cancelSlash(bytes32("r1"));

        vm.prank(admin);
        stake.cancelSlash(bytes32("r1"));
        assertEq(stake.stakeOf(provider).pendingSlash, 0);
        assertEq(uint256(stake.slashRecordOf(bytes32("r1")).status), uint256(SlashStatus.Cancelled));
    }

    /// Pending is left exactly once, from BOTH terminal states.
    function test_wrongState_aTerminalRecordCannotBeExecutedCancelledOrExpired() public {
        _propose(bytes32("r1"), 1_000_000);
        _propose(bytes32("r2"), 1_000_000);
        vm.warp(block.timestamp + Constants.SLASH_DELAY_SECONDS);
        stake.executeSlash(bytes32("r1"));
        vm.prank(admin);
        stake.cancelSlash(bytes32("r2"));

        bytes32[2] memory terminal = [bytes32("r1"), bytes32("r2")];
        for (uint256 i = 0; i < 2; i++) {
            vm.expectRevert(SlashNotPending.selector);
            stake.executeSlash(terminal[i]);
            vm.expectRevert(SlashNotPending.selector);
            stake.expireSlash(terminal[i]);
            vm.prank(admin);
            vm.expectRevert(SlashNotPending.selector);
            stake.cancelSlash(terminal[i]);
        }

        // Nothing was paid twice and nothing was released twice.
        assertEq(usdg.balanceOf(beneficiary), 600_000);
        assertEq(stake.stakeOf(provider).pendingSlash, 0);
        assertEq(stake.totalSlashed(), 900_000);
    }

    /// A request id that was never proposed reads back as `None`, and none of the three exits
    /// mistakes that for `Pending`.
    function test_wrongState_anUnknownRequestIdIsNotPending() public {
        vm.expectRevert(SlashNotPending.selector);
        stake.executeSlash(bytes32("never"));
        vm.expectRevert(SlashNotPending.selector);
        stake.expireSlash(bytes32("never"));
        vm.prank(admin);
        vm.expectRevert(SlashNotPending.selector);
        stake.cancelSlash(bytes32("never"));
    }

    function test_wrongState_executeIsClosedWhilePaused() public {
        _propose(bytes32("r1"), 1_000_000);
        vm.warp(block.timestamp + Constants.SLASH_DELAY_SECONDS);
        vm.prank(admin);
        config.setPaused(true);
        vm.expectRevert(ProgramPaused.selector);
        stake.executeSlash(bytes32("r1"));
    }

    /// Pause NEVER closes cancel or expire — a paused program must not be able to hold
    /// a provider's collateral hostage.
    function test_pauseDoesNotCloseCancelOrExpire() public {
        _propose(bytes32("r1"), 1_000_000);
        _propose(bytes32("r2"), 1_000_000);
        vm.prank(admin);
        config.setPaused(true);

        vm.prank(admin);
        stake.cancelSlash(bytes32("r1"));

        vm.warp(
            block.timestamp + Constants.SLASH_DELAY_SECONDS
                + Constants.SLASH_EXECUTION_GRACE_SECONDS
        );
        vm.prank(address(0xBEEF));
        stake.expireSlash(bytes32("r2"));

        assertEq(stake.stakeOf(provider).pendingSlash, 0);
    }

    /// A Pending reservation shields exactly its own remainder from an exit, and releasing it
    /// gives the remainder back.
    function test_pendingSlashShieldsCollateralFromWithdrawStake() public {
        vm.startPrank(provider);
        stake.requestUnstake(BOND);
        vm.stopPrank();

        _propose(bytes32("r1"), 1_000_000);
        vm.warp(block.timestamp + config.params().unbondingPeriodSeconds);

        vm.prank(provider);
        vm.expectRevert(InsufficientUnbondingStake.selector);
        stake.withdrawStake(BOND);

        vm.prank(provider);
        stake.withdrawStake(BOND - 1_000_000); // everything except the reservation

        // Released, and the shield goes with it.
        vm.prank(admin);
        stake.cancelSlash(bytes32("r1"));
        vm.prank(provider);
        stake.withdrawStake(1_000_000);
        assertEq(usdg.balanceOf(provider), BOND);
        assertEq(stake.totalStaked(), 0);
    }

    /// The verifier's daily cap is metered at EXECUTION against the LIVE cap, and it clamps
    /// `applied` rather than refusing outright. Proposal reserves nothing against it, so a
    /// leaked key cannot burn a day's capacity on judgements it never intends to execute.
    ///
    /// The fixture's cap (500 USDG) is far above two 1-USDG judgements, so the cap is lowered
    /// with `updateConfig`, which binds immediately (D-6).
    function test_theVerifierDailyCapClampsAtExecution() public {
        _propose(bytes32("r1"), 1_000_000);
        _propose(bytes32("r2"), 1_000_000);

        ParamSet memory p = config.params();
        p.verifierDailyCap = 1_500_000; // room for one and a half judgements
        vm.prank(admin);
        config.updateConfig(p, address(0));

        vm.warp(block.timestamp + Constants.SLASH_DELAY_SECONDS);

        stake.executeSlash(bytes32("r1")); // applied 1_000_000; the key's window now holds it
        stake.executeSlash(bytes32("r2")); // keyRemaining 500_000 → applied clamps to 500_000

        assertEq(stake.slashRecordOf(bytes32("r1")).applied, 1_000_000);
        assertEq(stake.slashRecordOf(bytes32("r2")).applied, 500_000);
        assertEq(usdg.balanceOf(beneficiary), 600_000 + 300_000);
        assertEq(usdg.balanceOf(treasury), 300_000 + 150_000);
        // r2's unapplied remainder was RELEASED, not kept pending — Pending is left once.
        assertEq(stake.stakeOf(provider).pendingSlash, 0);
    }

    /// And when the key's window is empty the judgement is refused outright, with the key's own
    /// diagnosis rather than the provider's.
    function test_wrongState_anExhaustedVerifierWindowRefusesTheNextJudgement() public {
        _propose(bytes32("r1"), 1_000_000);
        _propose(bytes32("r2"), 1_000_000);

        ParamSet memory p = config.params();
        p.verifierDailyCap = 1_000_000; // room for exactly one
        vm.prank(admin);
        config.updateConfig(p, address(0));

        vm.warp(block.timestamp + Constants.SLASH_DELAY_SECONDS);
        stake.executeSlash(bytes32("r1"));
        vm.expectRevert(VerifierDailyCapExceeded.selector);
        stake.executeSlash(bytes32("r2"));

        // The record survives as Pending, its reservation intact, to be retried as the window
        // drains — which is the reason the guard reverts rather than applying zero.
        assertEq(uint256(stake.slashRecordOf(bytes32("r2")).status), uint256(SlashStatus.Pending));
        assertEq(stake.stakeOf(provider).pendingSlash, 1_000_000);

        // Half a day later the drain has returned half the capacity and it goes through.
        vm.warp(block.timestamp + 43_200);
        stake.executeSlash(bytes32("r2"));
        assertEq(uint256(stake.slashRecordOf(bytes32("r2")).status), uint256(SlashStatus.Executed));
    }

    /// One key, THREE judgements inside one window, each well under the cap. The cap is the
    /// key's TOTAL reach per `SLASH_WINDOW_SECONDS`, so the third must be clamped to whatever
    /// the first two left of it — the sum is the cap, not a multiple of it.
    ///
    /// **Three, not two, and that is the whole point of this test.** The two tests above each
    /// execute exactly two records, and with two executions `vw.slashedInWindow = keyCarried +
    /// applied` and a meter that merely REMEMBERS THE LAST execution
    /// (`vw.slashedInWindow = applied`) are indistinguishable: the second execution reads a
    /// meter the first wrote, either way. The divergence first appears on the third. An
    /// review proved the accumulating `+` could be deleted with all 378 tests still
    /// green, and `Config.verifierDailyCap` is the only bound on a leaked verifier key short of
    /// `revokeVerifier` — `slashCapBps` bounds the loss to one provider, this bounds the reach
    /// of one key across every provider. So it gets held by a test that can see it.
    function test_oneKeysDailyCapBindsAcrossThreeJudgements() public {
        ParamSet memory p = config.params();
        p.verifierDailyCap = 1_000_000;
        vm.prank(admin);
        config.updateConfig(p, address(0));

        // The provider is bonded 1,000 USDG, so `capAllowance` is 100 USDG and never binds
        // here: the key's cap is the only ceiling in play.
        _propose(bytes32("r1"), 400_000);
        _propose(bytes32("r2"), 400_000);
        _propose(bytes32("r3"), 400_000);

        vm.warp(block.timestamp + Constants.SLASH_DELAY_SECONDS);
        stake.executeSlash(bytes32("r1"));
        stake.executeSlash(bytes32("r2"));
        stake.executeSlash(bytes32("r3"));

        uint64 a1 = stake.slashRecordOf(bytes32("r1")).applied;
        uint64 a2 = stake.slashRecordOf(bytes32("r2")).applied;
        uint64 a3 = stake.slashRecordOf(bytes32("r3")).applied;
        assertEq(a1, 400_000, "r1");
        assertEq(a2, 400_000, "r2");
        assertEq(a3, 200_000, "r3 must be clamped by what r1+r2 already spent of the key's cap");
        assertEq(uint256(a1) + a2 + a3, 1_000_000, "the key's 24h reach is the cap, not a multiple");
    }

    /// The PROVIDER's own rolling window, against the allowance frozen on each record: it
    /// clamps the second judgement and refuses the third.
    function test_theProvidersRollingWindowClampsAndThenRefuses() public {
        address capped = address(0xCA9);
        _stakeFor(capped, 15_000_000); // slashCapBps 1_000 → capAllowance 1_500_000

        bytes32[3] memory ids = [bytes32("c1"), bytes32("c2"), bytes32("c3")];
        for (uint256 i = 0; i < 3; i++) {
            SlashAttestation memory a = _att(ids[i], 1_000_000);
            a.provider = capped;
            stake.proposeSlash(a, _sign(a, verifierKeyPk));
            assertEq(stake.slashRecordOf(ids[i]).capAllowance, 1_500_000);
        }

        vm.warp(block.timestamp + Constants.SLASH_DELAY_SECONDS);
        stake.executeSlash(bytes32("c1"));
        stake.executeSlash(bytes32("c2"));
        vm.expectRevert(SlashCapExceeded.selector);
        stake.executeSlash(bytes32("c3"));

        assertEq(stake.slashRecordOf(bytes32("c1")).applied, 1_000_000);
        assertEq(stake.slashRecordOf(bytes32("c2")).applied, 500_000, "clamped by the window");
        assertEq(uint256(stake.slashRecordOf(bytes32("c3")).status), uint256(SlashStatus.Pending));
        assertEq(stake.stakeOf(capped).slashedInWindow, 1_500_000);
    }

    // --- neither window anchor moves backwards ------------------------------------------------

    /// `executeSlash` writes both meters' anchors with `nowTs > anchor ? nowTs : anchor`, and the
    /// comment above them says "a clock that stepped back must not hand capacity to whoever
    /// noticed". This is the provider half. Same shape as
    /// `X402Escrow.redeem.t.sol::test_theWindowAnchorNeverMovesBackwards`, which holds the third
    /// anchor of the three in this codebase; a review found that these two were the
    /// pair nothing held, and that replacing both with an unconditional `= nowTs` was invisible
    /// to the whole suite.
    function test_theProvidersSlashWindowAnchorNeverMovesBackwards() public {
        _propose(bytes32("r1"), 1_000_000);
        _propose(bytes32("r2"), 1_000_000);

        uint64 tLow = uint64(block.timestamp) + Constants.SLASH_DELAY_SECONDS;
        uint64 tHigh = tLow + 10_000;

        vm.warp(tHigh);
        stake.executeSlash(bytes32("r1"));
        assertEq(stake.stakeOf(provider).slashWindowStartedAt, tHigh);
        assertEq(stake.stakeOf(provider).slashedInWindow, 1_000_000);

        // The clock steps back ten thousand seconds. The second judgement still executes — the
        // wait was already served — but it must not re-anchor the meter to the earlier instant.
        vm.warp(tLow);
        stake.executeSlash(bytes32("r2"));

        assertEq(stake.stakeOf(provider).slashWindowStartedAt, tHigh, "the anchor never moves back");
        assertEq(stake.stakeOf(provider).slashedInWindow, 2_000_000, "nor is capacity handed back");
    }

    /// The verifier key's half of the same guard. `VerifierWindow` is internal with no getter —
    /// deliberately, since [`stakeOf`]'s reasoning about flattened tuples applies and the
    /// external surface is pinned — so the anchor is observed through what it does rather than
    /// read: a THIRD execution back at the high instant, where the amount of capacity the meter
    /// has drained is exactly the distance from the anchor.
    ///
    /// With the anchor held at `tHigh`, no time has passed at the third execution and none of the
    /// 800 000 already metered has drained, so 200 000 of the key's 1 000 000 cap is left. Had
    /// the second execution re-anchored to `tLow`, the meter would read 10 000 seconds of drain
    /// that never happened and hand back roughly 92 000 base units of capacity that a stepped-back
    /// clock had created out of nothing.
    function test_theVerifierKeysWindowAnchorNeverMovesBackwards() public {
        ParamSet memory p = config.params();
        p.verifierDailyCap = 1_000_000;
        vm.prank(admin);
        config.updateConfig(p, address(0));

        // The provider is bonded 1,000 USDG, so its own `capAllowance` is 100 USDG and never
        // binds: the key's cap is the only ceiling, and the key's anchor the only one observed.
        _propose(bytes32("r1"), 400_000);
        _propose(bytes32("r2"), 400_000);
        _propose(bytes32("r3"), 400_000);

        uint64 tLow = uint64(block.timestamp) + Constants.SLASH_DELAY_SECONDS;
        uint64 tHigh = tLow + 10_000;

        vm.warp(tHigh);
        stake.executeSlash(bytes32("r1")); // key meter 400 000, anchored at tHigh

        vm.warp(tLow); // the clock steps back
        stake.executeSlash(bytes32("r2")); // key meter 800 000, still anchored at tHigh

        vm.warp(tHigh);
        stake.executeSlash(bytes32("r3"));

        assertEq(
            stake.slashRecordOf(bytes32("r3")).applied,
            200_000,
            "a stepped-back clock must not drain the key's meter"
        );
    }

    /// A judgement too small to divide leaves the record PENDING. Every write the handler made
    /// is rolled back by the revert, which is what makes "retry as the window rolls" true.
    function test_wrongState_aPenaltyTooSmallToSplitLeavesTheRecordPending() public {
        address tiny = address(0x7141);
        _stakeFor(tiny, 1_000); // capAllowance 100

        SlashAttestation memory a = _att(bytes32("t1"), 1); // 6000 bps of 1 floors to zero
        a.provider = tiny;
        stake.proposeSlash(a, _sign(a, verifierKeyPk));
        assertEq(stake.slashRecordOf(bytes32("t1")).reserved, 1);

        vm.warp(block.timestamp + Constants.SLASH_DELAY_SECONDS);
        vm.expectRevert(PenaltyTooSmallToSplit.selector);
        stake.executeSlash(bytes32("t1"));

        assertEq(uint256(stake.slashRecordOf(bytes32("t1")).status), uint256(SlashStatus.Pending));
        assertEq(stake.stakeOf(tiny).pendingSlash, 1, "the reservation is still standing");
        assertEq(stake.stakeOf(tiny).bonded, 1_000, "and nothing was taken");
    }

    /// Unbonding pays first: a provider on their way out pays from the stake they were leaving
    /// with (`execute_slash.rs:264`).
    function test_theSlashIsTakenFromUnbondingFirst() public {
        vm.prank(provider);
        stake.requestUnstake(400_000);

        _propose(bytes32("r1"), 1_000_000); // taken will be 900_000 > the 400_000 unbonding
        vm.warp(block.timestamp + Constants.SLASH_DELAY_SECONDS);
        stake.executeSlash(bytes32("r1"));

        assertEq(stake.stakeOf(provider).unbonding, 0, "the unbonding bucket was emptied first");
        assertEq(stake.stakeOf(provider).unbondingStartedAt, 0, "and its clock cleared with it");
        assertEq(stake.stakeOf(provider).bonded, BOND - 900_000);
    }

    /// Every effect is written before either transfer. The asset re-enters a VIEW from inside
    /// the FIRST payout and records what it sees.
    function test_everyEffectIsWrittenBeforeTheSlashTransfers() public {
        StakeObserverUSDG asset = new StakeObserverUSDG();
        X402Stake st = _deployStake(address(asset));

        asset.mint(address(this), BOND);
        asset.approve(address(st), BOND);
        st.depositStakeFor(provider, BOND);

        SlashAttestation memory a = _att(bytes32("o1"), 1_000_000);
        st.proposeSlash(a, _signFor(st, a, verifierKeyPk));
        vm.warp(block.timestamp + Constants.SLASH_DELAY_SECONDS);

        asset.arm(address(st), provider);
        st.executeSlash(bytes32("o1"));

        assertTrue(asset.observed(), "the asset never got to look");
        assertEq(asset.seenTotalSlashed(), 900_000, "totalSlashed not yet raised at payout time");
        assertEq(asset.seenBonded(), BOND - 900_000, "the bond not yet debited");
        assertEq(asset.seenTotalStaked(), BOND - 900_000, "totalStaked not yet debited");
    }

    /// The payout door re-entered with the SAME judgement. **Read the observed error in the
    /// mutation log before crediting the modifier**: the effects are already written when the
    /// asset calls back, so the nested execution is refused by `status != Pending` even without
    /// it. The modifier is the belt; row X12 — the transfers moved above the effects — is the
    /// brace, and it is the row that would fire if a future edit reordered them.
    function test_wrongState_aReentrantAssetCannotRecurseIntoExecuteSlash() public {
        ReentrantStakeUSDG asset = new ReentrantStakeUSDG();
        X402Stake st = _deployStake(address(asset));

        asset.mint(address(this), BOND);
        asset.approve(address(st), BOND);
        st.depositStakeFor(provider, BOND);

        SlashAttestation memory a = _att(bytes32("x1"), 1_000_000);
        st.proposeSlash(a, _signFor(st, a, verifierKeyPk));
        vm.warp(block.timestamp + Constants.SLASH_DELAY_SECONDS);

        asset.arm(
            address(st), abi.encodeCall(X402Stake.executeSlash, (bytes32("x1"))), 0, false, true
        );
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        st.executeSlash(bytes32("x1"));

        assertEq(uint256(st.slashRecordOf(bytes32("x1")).status), uint256(SlashStatus.Pending));
        assertEq(asset.balanceOf(beneficiary), 0, "and nothing was paid, once or twice");
    }

    /// A hold anybody can end is a hold nobody can extend: four unrelated senders, four reaps.
    function test_expireIsPermissionlessAcrossASweepOfCallers() public {
        bytes32[4] memory ids = [bytes32("e1"), bytes32("e2"), bytes32("e3"), bytes32("e4")];
        address[4] memory callers = [address(0x1), buyer, provider, treasury];
        for (uint256 i = 0; i < 4; i++) {
            _propose(ids[i], 1_000_000);
        }
        vm.warp(
            block.timestamp + Constants.SLASH_DELAY_SECONDS
                + Constants.SLASH_EXECUTION_GRACE_SECONDS
        );
        for (uint256 i = 0; i < 4; i++) {
            vm.prank(callers[i]);
            stake.expireSlash(ids[i]);
        }
        assertEq(stake.stakeOf(provider).pendingSlash, 0);
        assertEq(stake.stakeOf(provider).bonded, BOND);
    }
}
