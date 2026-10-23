// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.24;

import {Fixture} from "./helpers/Fixture.sol";
import {VoucherSigner} from "./helpers/VoucherSigner.sol";
import {AssayStake} from "../src/AssayStake.sol";
import {
    SlashAttestation, ResponseClass, SlashStatus, CancelReason, ParamSet
} from "../src/Types.sol";
import {Constants} from "../src/Constants.sol";
import "../src/Errors.sol";

/// The dispute step and the arbiter role on AssayStake.
///
/// `Pending → Disputed` is the provider's (`disputeSlash`, inside the delay, never paused).
/// `Disputed → Pending` is the arbiter's (`upholdSlash`, executable from now, the ordinary
/// `executeSlash` re-checks still run). `Pending | Disputed → Cancelled` is the admin's or the
/// arbiter's (`cancelSlash`) or anybody's once a condition holds (`expireSlash`).
contract AssayStakeDisputeTest is Fixture {
    uint256 internal verifierKeyPk = 0x7E5717;
    address internal verifierAddr;
    address internal beneficiary = address(0xA6E7);
    address internal arbiter = address(0xA4B1);
    uint64 internal constant BOND = 1_000_000_000;
    bytes32 internal constant ID = bytes32("d1");

    event SlashDisputed(
        bytes32 indexed requestId, address indexed provider, uint64 disputedAt, uint64 executableAt
    );
    event SlashUpheld(
        bytes32 indexed requestId,
        address indexed provider,
        address indexed arbiter,
        uint64 executableAt
    );
    event SlashCancelled(
        bytes32 indexed requestId,
        address indexed provider,
        CancelReason reason,
        uint64 released,
        uint64 pendingSlash,
        uint64 cancelledAt
    );

    function setUp() public virtual override {
        super.setUp();
        stake = _deployStake(address(usdg));
        verifierAddr = vm.addr(verifierKeyPk);

        vm.startPrank(admin);
        config.registerVerifier(
            verifierAddr, bytes32("verifier-evm-2026-09"), uint64(block.timestamp) + 180 * 86_400
        );
        config.setArbiter(arbiter);
        vm.stopPrank();

        _fund(provider, BOND);
        vm.startPrank(provider);
        usdg.approve(address(stake), BOND);
        stake.depositStake(BOND);
        vm.stopPrank();
    }

    function _propose(bytes32 id) internal {
        SlashAttestation memory a = SlashAttestation({
            requestId: id,
            provider: provider,
            beneficiary: beneficiary,
            status: uint8(ResponseClass.DataFail),
            penalty: 1_000_000,
            policy: keccak256("policy v1"),
            issuedAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp) + 3 * 86_400
        });
        stake.proposeSlash(
            a, VoucherSigner.signAttestation(verifierKeyPk, stake.DOMAIN_SEPARATOR(), a)
        );
    }

    function _status(bytes32 id) internal view returns (SlashStatus) {
        return stake.slashRecordOf(id).status;
    }

    function _dispute(bytes32 id) internal {
        vm.prank(provider);
        stake.disputeSlash(id);
    }

    // === disputeSlash ========================================================================

    function test_happyPath_theProviderDisputesAndTheSlashFreezes() public {
        _propose(ID);
        uint64 executableAt = stake.slashRecordOf(ID).executableAt;

        vm.warp(block.timestamp + 1 hours);
        vm.expectEmit(address(stake));
        emit SlashDisputed(ID, provider, uint64(block.timestamp), executableAt);
        _dispute(ID);

        AssayStake.SlashRecord memory r = stake.slashRecordOf(ID);
        assertEq(uint256(r.status), uint256(SlashStatus.Disputed));
        assertEq(r.disputedAt, uint64(block.timestamp));
        assertEq(r.executableAt, executableAt, "the dispute does not move executableAt");
        assertEq(stake.stakeOf(provider).pendingSlash, 1_000_000, "the reservation stays");

        // Frozen: executeSlash refuses it at and after executableAt.
        vm.warp(executableAt);
        vm.expectRevert(SlashNotPending.selector);
        stake.executeSlash(ID);
        // And the reservation still shields the exit.
        assertEq(stake.withdrawableOf(provider), 0);
    }

    function test_wrongSigner_onlyTheSlashedProviderMayDispute() public {
        _propose(ID);
        address[4] memory others = [admin, arbiter, verifierAddr, beneficiary];
        for (uint256 i = 0; i < others.length; i++) {
            vm.prank(others[i]);
            vm.expectRevert(NotSlashedProvider.selector);
            stake.disputeSlash(ID);
        }
        assertEq(uint256(_status(ID)), uint256(SlashStatus.Pending));
    }

    function test_wrongState_disputeNeedsAPendingRecord() public {
        // No record at all.
        vm.prank(provider);
        vm.expectRevert(SlashNotPending.selector);
        stake.disputeSlash(ID);

        // Already disputed: one dispute per record.
        _propose(ID);
        _dispute(ID);
        vm.prank(provider);
        vm.expectRevert(SlashNotPending.selector);
        stake.disputeSlash(ID);

        // Cancelled.
        _propose(bytes32("d2"));
        vm.prank(admin);
        stake.cancelSlash(bytes32("d2"));
        vm.prank(provider);
        vm.expectRevert(SlashNotPending.selector);
        stake.disputeSlash(bytes32("d2"));

        // Executed.
        _propose(bytes32("d3"));
        vm.warp(block.timestamp + Constants.SLASH_DELAY_SECONDS);
        stake.executeSlash(bytes32("d3"));
        vm.prank(provider);
        vm.expectRevert(SlashNotPending.selector);
        stake.disputeSlash(bytes32("d3"));
    }

    /// The dispute window IS the delay: open at `executableAt - 1`, closed at `executableAt`.
    function test_boundary_disputeClosesAtExecutableAt() public {
        _propose(ID);
        _propose(bytes32("d2"));
        uint64 executableAt = stake.slashRecordOf(ID).executableAt;

        // The last instant of the window.
        vm.warp(uint256(executableAt) - 1);
        _dispute(bytes32("d2"));
        assertEq(uint256(_status(bytes32("d2"))), uint256(SlashStatus.Disputed));

        vm.warp(executableAt);
        vm.prank(provider);
        vm.expectRevert(DisputeWindowClosed.selector);
        stake.disputeSlash(ID);

        vm.warp(uint256(executableAt) + 1 days);
        vm.prank(provider);
        vm.expectRevert(DisputeWindowClosed.selector);
        stake.disputeSlash(ID);

        // No dispute: the slash proceeds as before.
        stake.executeSlash(ID);
        assertEq(uint256(_status(ID)), uint256(SlashStatus.Executed));
    }

    /// Pause never closes the dispute: it only protects the provider.
    function test_pauseNeverClosesTheDispute() public {
        _propose(ID);
        vm.prank(admin);
        config.setPaused(true);
        _dispute(ID);
        assertEq(uint256(_status(ID)), uint256(SlashStatus.Disputed));
    }

    /// Nor does the blocklist.
    function test_aBlockedProviderMayStillDispute() public {
        _propose(ID);
        vm.prank(arbiter);
        config.setBlocked(provider, true);
        _dispute(ID);
        assertEq(uint256(_status(ID)), uint256(SlashStatus.Disputed));
    }

    // === upholdSlash =========================================================================

    function test_happyPath_upholdThenExecutePaysUnderTheNormalRules() public {
        _propose(ID);
        _dispute(ID);
        vm.warp(block.timestamp + 5 days); // past the original executableAt

        vm.expectEmit(address(stake));
        emit SlashUpheld(ID, provider, arbiter, uint64(block.timestamp));
        vm.prank(arbiter);
        stake.upholdSlash(ID);

        AssayStake.SlashRecord memory r = stake.slashRecordOf(ID);
        assertEq(uint256(r.status), uint256(SlashStatus.Pending));
        assertEq(r.executableAt, uint64(block.timestamp), "executable from now");
        assertEq(r.reserved, 1_000_000, "the arbiter changes no amount");
        assertEq(r.beneficiary, beneficiary, "nor the beneficiary");

        // An upheld record cannot be disputed again (F2: explicitly, by `disputedAt != 0`).
        vm.prank(provider);
        vm.expectRevert(SlashAlreadyDisputed.selector);
        stake.disputeSlash(ID);

        stake.executeSlash(ID);
        assertEq(usdg.balanceOf(beneficiary), 600_000);
        assertEq(usdg.balanceOf(treasury), 300_000);
        assertEq(stake.stakeOf(provider).pendingSlash, 0);
        assertEq(uint256(_status(ID)), uint256(SlashStatus.Executed));
    }

    /// Upholding does not lift either cap or the verifier re-check.
    function test_upholdThenExecuteStillMetersTheProviderWindowAndTheKeyCheck() public {
        _propose(ID);
        _propose(bytes32("d2"));
        _dispute(ID);
        _dispute(bytes32("d2"));
        vm.startPrank(arbiter);
        stake.upholdSlash(ID);
        stake.upholdSlash(bytes32("d2"));
        vm.stopPrank();
        // F2: the ruling does not pull execution before the frozen executableAt.
        vm.warp(stake.slashRecordOf(ID).executableAt);

        // The upheld record executes through the ordinary door: whole, and metered against the
        // provider's rolling window like any other (the uphold lifted no cap).
        stake.executeSlash(ID);
        assertEq(stake.slashRecordOf(ID).applied, 1_000_000, "paid whole");
        assertEq(stake.stakeOf(provider).slashedInWindow, 1_000_000, "and metered");

        // And the key re-check: revoked after the ruling, the other can never pay.
        vm.prank(admin);
        config.revokeVerifier(verifierAddr);
        vm.expectRevert(VerifierRevoked.selector);
        stake.executeSlash(bytes32("d2"));
        stake.expireSlash(bytes32("d2"));
        assertEq(stake.stakeOf(provider).pendingSlash, 0);
    }

    function test_wrongSigner_onlyTheArbiterUpholds() public {
        _propose(ID);
        _dispute(ID);
        address[4] memory others = [admin, owner, provider, verifierAddr];
        for (uint256 i = 0; i < others.length; i++) {
            vm.prank(others[i]);
            vm.expectRevert(NotArbiter.selector);
            stake.upholdSlash(ID);
        }

        // A replaced arbiter loses the door at once (it can never be unset: audit A M-2).
        vm.prank(admin);
        config.setArbiter(address(0xA4B2));
        vm.prank(arbiter);
        vm.expectRevert(NotArbiter.selector);
        stake.upholdSlash(ID);
        assertEq(uint256(_status(ID)), uint256(SlashStatus.Disputed));
    }

    /// Audit F R5's argument, checked: the per-record `ArbiterIsVerifier` was removed because
    /// Config keeps the arbiter off every LIVE verifier, so the arbiter can equal a record's
    /// verifier only after that key was REVOKED — and such a record can never pay. The uphold
    /// lands, `executeSlash` refuses the revoked key, and anyone releases the reservation.
    function test_anArbiterThatWasTheRecordsRevokedVerifierCannotMakeItPay() public {
        _enrolArbKey();
        _proposeSignedBy(ID, ARB_PK);
        _dispute(ID);
        _revokeAndAppointArbKey();

        vm.prank(vm.addr(ARB_PK));
        stake.upholdSlash(ID);
        vm.warp(stake.slashRecordOf(ID).executableAt);
        vm.expectRevert(VerifierRevoked.selector);
        stake.executeSlash(ID);
        stake.expireSlash(ID);
        assertEq(uint256(_status(ID)), uint256(SlashStatus.Cancelled));
        assertEq(stake.stakeOf(provider).pendingSlash, 0);
        assertEq(usdg.balanceOf(beneficiary), 0, "nothing paid");
    }

    /// The live case is refused in Config, at both doors (audit F R5).
    function test_theArbiterIsNeverALiveVerifierFromEitherDoor() public {
        _enrolArbKey();
        vm.prank(admin);
        vm.expectRevert(InvalidArbiter.selector);
        config.setArbiter(vm.addr(ARB_PK));
        vm.prank(admin);
        vm.expectRevert(InvalidArbiter.selector);
        config.registerVerifier(arbiter, bytes32("x"), uint64(block.timestamp) + 1 days);
    }

    uint256 internal constant ARB_PK = 0xA4B1A4B1;

    function _enrolArbKey() internal {
        vm.prank(admin);
        config.registerVerifier(
            vm.addr(ARB_PK), bytes32("arb-as-verifier"), uint64(block.timestamp) + 90 days
        );
    }

    function _revokeAndAppointArbKey() internal {
        vm.startPrank(admin);
        config.revokeVerifier(vm.addr(ARB_PK));
        config.setArbiter(vm.addr(ARB_PK));
        vm.stopPrank();
    }

    function _proposeSignedBy(bytes32 id, uint256 pk) internal {
        SlashAttestation memory a = SlashAttestation({
            requestId: id,
            provider: provider,
            beneficiary: beneficiary,
            status: uint8(ResponseClass.DataFail),
            penalty: 1_000_000,
            policy: keccak256("policy v1"),
            issuedAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp) + 3 * 86_400
        });
        bytes memory sig = VoucherSigner.signAttestation(pk, stake.DOMAIN_SEPARATOR(), a);
        stake.proposeSlash(a, sig);
    }

    function test_wrongState_upholdNeedsADisputedRecord() public {
        vm.prank(arbiter);
        vm.expectRevert(SlashNotDisputed.selector);
        stake.upholdSlash(ID);

        _propose(ID);
        vm.prank(arbiter);
        vm.expectRevert(SlashNotDisputed.selector);
        stake.upholdSlash(ID);

        vm.prank(arbiter);
        stake.cancelSlash(ID);
        vm.prank(arbiter);
        vm.expectRevert(SlashNotDisputed.selector);
        stake.upholdSlash(ID);
    }

    /// Upheld and then not executed: the ordinary grace runs from the ruling, then expire.
    function test_upholdThenGraceElapsedThenExpire() public {
        _propose(ID);
        _dispute(ID);
        vm.warp(block.timestamp + 1 days);
        vm.prank(arbiter);
        stake.upholdSlash(ID);
        uint256 ruledAt = stake.slashRecordOf(ID).executableAt; // = the ruling instant

        vm.warp(ruledAt + Constants.SLASH_EXECUTION_GRACE_SECONDS - 1);
        vm.expectRevert(SlashNotExpired.selector);
        stake.expireSlash(ID);

        vm.warp(ruledAt + Constants.SLASH_EXECUTION_GRACE_SECONDS);
        vm.expectRevert(SlashExecutionWindowClosed.selector);
        stake.executeSlash(ID);
        vm.expectEmit(address(stake));
        emit SlashCancelled(
            ID, provider, CancelReason.Expired, 1_000_000, 0, uint64(block.timestamp)
        );
        stake.expireSlash(ID);
        assertEq(uint256(_status(ID)), uint256(SlashStatus.Cancelled));
    }

    /// Uphold is allowed while paused (it moves no money); execute stays paused.
    function test_upholdWhilePausedButExecuteStaysClosed() public {
        _propose(ID);
        _dispute(ID);
        vm.prank(admin);
        config.setPaused(true);
        vm.prank(arbiter);
        stake.upholdSlash(ID);
        vm.expectRevert(ProgramPaused.selector);
        stake.executeSlash(ID);
    }

    // === cancelSlash =========================================================================

    function test_happyPath_theArbiterCancelsPendingAndDisputed() public {
        _propose(ID);
        _propose(bytes32("d2"));
        _dispute(bytes32("d2"));

        vm.expectEmit(address(stake));
        emit SlashCancelled(
            ID, provider, CancelReason.Withdrawn, 1_000_000, 1_000_000, uint64(block.timestamp)
        );
        vm.prank(arbiter);
        stake.cancelSlash(ID);
        vm.prank(arbiter);
        stake.cancelSlash(bytes32("d2"));

        assertEq(uint256(_status(ID)), uint256(SlashStatus.Cancelled));
        assertEq(uint256(_status(bytes32("d2"))), uint256(SlashStatus.Cancelled));
        assertEq(stake.stakeOf(provider).pendingSlash, 0);
    }

    function test_happyPath_theAdminCancelsADisputedRecord() public {
        _propose(ID);
        _dispute(ID);
        vm.prank(admin);
        stake.cancelSlash(ID);
        assertEq(uint256(_status(ID)), uint256(SlashStatus.Cancelled));
        assertEq(stake.stakeOf(provider).pendingSlash, 0);
    }

    function test_wrongSigner_cancelIsAdminOrArbiterOnly() public {
        _propose(ID);
        address[4] memory others = [owner, provider, verifierAddr, redeemer];
        for (uint256 i = 0; i < others.length; i++) {
            vm.prank(others[i]);
            vm.expectRevert(NotAdmin.selector);
            stake.cancelSlash(ID);
        }
        // A former arbiter loses the door the moment it is replaced.
        vm.prank(admin);
        config.setArbiter(address(0xA4B2));
        vm.prank(arbiter);
        vm.expectRevert(NotAdmin.selector);
        stake.cancelSlash(ID);
    }

    function test_wrongState_cancelRefusesTerminalRecords() public {
        _propose(ID);
        vm.prank(arbiter);
        stake.cancelSlash(ID);
        vm.prank(arbiter);
        vm.expectRevert(SlashNotPending.selector);
        stake.cancelSlash(ID);
    }

    // === expireSlash on a Disputed record ======================================================

    function test_disputeThenThirtyDaysThenAnybodyExpires() public {
        _propose(ID);
        _dispute(ID);
        // Read back from the record, not from `block.timestamp`: under via-ir a local holding
        // `block.timestamp` can be re-read after a later `vm.warp`.
        uint256 disputedAt = stake.slashRecordOf(ID).disputedAt;

        // The ordinary grace does not release a disputed record…
        vm.warp(
            uint256(stake.slashRecordOf(ID).executableAt) + Constants.SLASH_EXECUTION_GRACE_SECONDS
        );
        vm.expectRevert(SlashNotExpired.selector);
        stake.expireSlash(ID);

        vm.warp(disputedAt + Constants.DISPUTE_TIMEOUT_SECONDS - 1);
        vm.expectRevert(SlashNotExpired.selector);
        stake.expireSlash(ID);

        // …the dispute timeout does, for anybody.
        vm.warp(disputedAt + Constants.DISPUTE_TIMEOUT_SECONDS);
        vm.expectEmit(address(stake));
        emit SlashCancelled(
            ID, provider, CancelReason.DisputeUnresolved, 1_000_000, 0, uint64(block.timestamp)
        );
        vm.prank(address(0xF00D));
        stake.expireSlash(ID);
        assertEq(uint256(_status(ID)), uint256(SlashStatus.Cancelled));
        assertEq(stake.stakeOf(provider).pendingSlash, 0);
    }

    /// The verifier-unavailable path releases a disputed record at once.
    function test_aRevokedKeyReleasesADisputedRecord() public {
        _propose(ID);
        _dispute(ID);
        vm.prank(admin);
        config.revokeVerifier(verifierAddr);
        vm.expectEmit(address(stake));
        emit SlashCancelled(
            ID, provider, CancelReason.VerifierUnavailable, 1_000_000, 0, uint64(block.timestamp)
        );
        stake.expireSlash(ID);
    }

    /// Expire stays open while paused for a disputed record too.
    function test_pauseNeverClosesTheDisputeTimeout() public {
        _propose(ID);
        _dispute(ID);
        vm.prank(admin);
        config.setPaused(true);
        vm.warp(block.timestamp + Constants.DISPUTE_TIMEOUT_SECONDS);
        stake.expireSlash(ID);
        assertEq(uint256(_status(ID)), uint256(SlashStatus.Cancelled));
    }

    // === the settable delay reaches the record ==================================================

    /// A new proposal freezes the LIVE delay; an existing one keeps its own.
    function test_theSlashDelayAppliesOnlyToNewProposals() public {
        _propose(ID);
        uint64 oldExecutableAt = stake.slashRecordOf(ID).executableAt;
        assertEq(oldExecutableAt, uint64(block.timestamp) + Constants.SLASH_DELAY_SECONDS);

        vm.prank(admin);
        config.setSlashDelay(Constants.MIN_SLASH_DELAY_SECONDS_TESTNET);

        assertEq(stake.slashRecordOf(ID).executableAt, oldExecutableAt, "frozen at proposal");
        _propose(bytes32("d2"));
        assertEq(
            stake.slashRecordOf(bytes32("d2")).executableAt,
            uint64(block.timestamp) + Constants.MIN_SLASH_DELAY_SECONDS_TESTNET
        );

        // The short delay is the short dispute window.
        vm.warp(block.timestamp + Constants.MIN_SLASH_DELAY_SECONDS_TESTNET);
        vm.prank(provider);
        vm.expectRevert(DisputeWindowClosed.selector);
        stake.disputeSlash(bytes32("d2"));
        stake.executeSlash(bytes32("d2"));
        vm.expectRevert(SlashNotYetExecutable.selector);
        stake.executeSlash(ID);
    }

    // === the batch forms =======================================================================

    function _ids(uint256 n, uint256 salt) internal returns (bytes32[] memory ids) {
        ids = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) {
            ids[i] = keccak256(abi.encode("batch", salt, i));
            _propose(ids[i]);
        }
    }

    function test_happyPath_theThreeBatches() public {
        bytes32[] memory a = _ids(3, 1);
        bytes32[] memory b = _ids(2, 2);

        uint64 a0ExecutableAt = stake.slashRecordOf(a[0]).executableAt;
        vm.expectEmit(address(stake));
        emit SlashDisputed(a[0], provider, uint64(block.timestamp), a0ExecutableAt);
        vm.prank(provider);
        stake.disputeSlashBatch(a);
        vm.prank(provider);
        stake.disputeSlashBatch(b);
        for (uint256 i = 0; i < 3; i++) {
            assertEq(uint256(_status(a[i])), uint256(SlashStatus.Disputed));
        }

        vm.prank(arbiter);
        stake.upholdSlashBatch(a);
        vm.prank(arbiter);
        stake.cancelSlashBatch(b);
        for (uint256 i = 0; i < 3; i++) {
            assertEq(uint256(_status(a[i])), uint256(SlashStatus.Pending));
            // F2: the frozen executableAt, not "now" — nothing was pulled forward.
            assertEq(
                stake.slashRecordOf(a[i]).executableAt,
                uint64(block.timestamp) + Constants.SLASH_DELAY_SECONDS
            );
        }
        assertEq(uint256(_status(b[0])), uint256(SlashStatus.Cancelled));
        assertEq(uint256(_status(b[1])), uint256(SlashStatus.Cancelled));
        assertEq(stake.stakeOf(provider).pendingSlash, 3_000_000, "only b released");

        // The admin's batch cancel, on the upheld (Pending) records.
        vm.prank(admin);
        stake.cancelSlashBatch(a);
        assertEq(stake.stakeOf(provider).pendingSlash, 0);
    }

    /// One bad id anywhere reverts the whole batch, and nothing before it lands.
    function test_oneBadIdRevertsTheWholeBatch() public {
        bytes32[] memory ids = _ids(3, 3);
        ids[2] = bytes32("never-proposed");

        vm.prank(provider);
        vm.expectRevert(SlashNotPending.selector);
        stake.disputeSlashBatch(ids);
        assertEq(uint256(_status(ids[0])), uint256(SlashStatus.Pending), "the first did not land");

        vm.prank(arbiter);
        vm.expectRevert(SlashNotPending.selector);
        stake.cancelSlashBatch(ids);
        assertEq(stake.stakeOf(provider).pendingSlash, 3_000_000, "nothing released");

        // Uphold: ids[0] disputed, ids[1] still Pending, so the second item refuses.
        vm.prank(provider);
        stake.disputeSlash(ids[0]);
        vm.prank(arbiter);
        vm.expectRevert(SlashNotDisputed.selector);
        stake.upholdSlashBatch(ids);
        assertEq(uint256(_status(ids[0])), uint256(SlashStatus.Disputed), "the first did not land");
    }

    /// A duplicate id is refused by the second iteration's own status check.
    function test_aDuplicateIdInOneBatchIsRefused() public {
        bytes32[] memory one = _ids(1, 4);
        bytes32[] memory dup = new bytes32[](2);
        dup[0] = one[0];
        dup[1] = one[0];

        vm.prank(provider);
        vm.expectRevert(SlashNotPending.selector);
        stake.disputeSlashBatch(dup);

        vm.prank(provider);
        stake.disputeSlash(one[0]);
        vm.prank(arbiter);
        vm.expectRevert(SlashNotDisputed.selector);
        stake.upholdSlashBatch(dup);

        vm.prank(arbiter);
        vm.expectRevert(SlashNotPending.selector);
        stake.cancelSlashBatch(dup);
        assertEq(stake.stakeOf(provider).pendingSlash, 1_000_000, "released once, not twice");
        assertEq(uint256(_status(one[0])), uint256(SlashStatus.Disputed));
    }

    function test_wrongArgs_anEmptyAndAnOversizeBatchAreRefused() public {
        bytes32[] memory empty = new bytes32[](0);
        bytes32[] memory big = new bytes32[](Constants.MAX_SLASH_BATCH + 1);

        vm.startPrank(provider);
        vm.expectRevert(EmptyBatch.selector);
        stake.disputeSlashBatch(empty);
        vm.expectRevert(BatchTooLarge.selector);
        stake.disputeSlashBatch(big);
        vm.stopPrank();

        vm.startPrank(arbiter);
        vm.expectRevert(EmptyBatch.selector);
        stake.upholdSlashBatch(empty);
        vm.expectRevert(BatchTooLarge.selector);
        stake.upholdSlashBatch(big);
        vm.expectRevert(EmptyBatch.selector);
        stake.cancelSlashBatch(empty);
        vm.expectRevert(BatchTooLarge.selector);
        stake.cancelSlashBatch(big);
        vm.stopPrank();
    }

    function test_wrongSigner_eachBatchKeepsItsSingleCallsCaller() public {
        bytes32[] memory ids = _ids(2, 5);

        vm.prank(arbiter);
        vm.expectRevert(NotSlashedProvider.selector);
        stake.disputeSlashBatch(ids);

        vm.prank(provider);
        stake.disputeSlashBatch(ids);

        address[3] memory notArbiter = [admin, provider, owner];
        for (uint256 i = 0; i < notArbiter.length; i++) {
            vm.prank(notArbiter[i]);
            vm.expectRevert(NotArbiter.selector);
            stake.upholdSlashBatch(ids);
        }
        vm.prank(admin);
        config.setArbiter(address(0xA4B2)); // replace the arbiter

        address[3] memory notCanceller = [provider, owner, arbiter]; // arbiter was replaced
        for (uint256 i = 0; i < notCanceller.length; i++) {
            vm.prank(notCanceller[i]);
            vm.expectRevert(NotAdmin.selector);
            stake.cancelSlashBatch(ids);
        }
    }

    /// Dispute and cancel batches stay open while paused; a blocked provider may still dispute.
    function test_theBatchesFollowTheSingleCallsPauseAndBlocklistRules() public {
        bytes32[] memory ids = _ids(2, 6);
        vm.startPrank(admin);
        config.setPaused(true);
        config.setBlocked(provider, true);
        vm.stopPrank();
        vm.prank(provider);
        stake.disputeSlashBatch(ids);
        vm.prank(arbiter);
        stake.upholdSlashBatch(ids);
        vm.prank(arbiter);
        stake.cancelSlashBatch(ids);
        assertEq(stake.stakeOf(provider).pendingSlash, 0);
    }

    /// The figure `docs/gas.md` quotes: each batch at `MAX_SLASH_BATCH`, one provider.
    function test_measure_slashBatchesAtSixtyFour() public {
        ParamSet memory p = config.params();
        p.penaltyAmount = 1_000; // 64 reservations must fit under the cap allowance
        vm.prank(admin);
        config.updateConfig(p);

        uint256 n = Constants.MAX_SLASH_BATCH;
        bytes32[] memory ids = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) {
            ids[i] = keccak256(abi.encode("measure", i));
            SlashAttestation memory a = SlashAttestation({
                requestId: ids[i],
                provider: provider,
                beneficiary: beneficiary,
                status: uint8(ResponseClass.DataFail),
                penalty: 1_000,
                policy: keccak256("policy v1"),
                issuedAt: uint64(block.timestamp),
                expiresAt: uint64(block.timestamp) + 3 * 86_400
            });
            bytes memory sig =
                VoucherSigner.signAttestation(verifierKeyPk, stake.DOMAIN_SEPARATOR(), a);
            stake.proposeSlash(a, sig);
        }

        vm.prank(provider);
        uint256 g = gasleft();
        stake.disputeSlashBatch(ids);
        emit log_named_uint("disputeSlashBatch(64)", g - gasleft());

        vm.prank(arbiter);
        g = gasleft();
        stake.upholdSlashBatch(ids);
        emit log_named_uint("upholdSlashBatch(64)", g - gasleft());

        vm.prank(arbiter);
        g = gasleft();
        stake.cancelSlashBatch(ids);
        emit log_named_uint("cancelSlashBatch(64)", g - gasleft());
        assertEq(stake.stakeOf(provider).pendingSlash, 0);
    }

    // === review regressions (docs/…/security-review-dispute-upgrade: F1-F4, I1) ==============

    /// F1: a stale dispute can only expire. The reviewer's proof upheld at +40 d and slashed.
    function test_review_F1_upholdAfterTheDisputeTimeoutIsRefused() public {
        _propose(ID);
        _dispute(ID);
        uint256 disputedAt = stake.slashRecordOf(ID).disputedAt;
        vm.warp(disputedAt + Constants.DISPUTE_TIMEOUT_SECONDS + 10 days);
        vm.prank(arbiter);
        vm.expectRevert(DisputeTimedOut.selector);
        stake.upholdSlash(ID);
        stake.expireSlash(ID);
        assertEq(uint256(_status(ID)), uint256(SlashStatus.Cancelled));
        assertEq(usdg.balanceOf(beneficiary), 0, "nothing was paid");
    }

    /// F1: the boundary. One second before the timeout only uphold works; at the instant only
    /// expire works. The reviewer's proof had both doors open at the instant.
    function test_review_F1_theTimeoutInstantBelongsToExpireAlone() public {
        _propose(ID);
        _propose(bytes32("d2"));
        _dispute(ID);
        _dispute(bytes32("d2"));
        uint256 disputedAt = stake.slashRecordOf(ID).disputedAt;

        vm.warp(disputedAt + Constants.DISPUTE_TIMEOUT_SECONDS - 1);
        vm.expectRevert(SlashNotExpired.selector);
        stake.expireSlash(bytes32("d2"));
        vm.prank(arbiter);
        stake.upholdSlash(bytes32("d2"));

        vm.warp(disputedAt + Constants.DISPUTE_TIMEOUT_SECONDS);
        vm.prank(arbiter);
        vm.expectRevert(DisputeTimedOut.selector);
        stake.upholdSlash(ID);
        stake.expireSlash(ID);
        assertEq(uint256(_status(ID)), uint256(SlashStatus.Cancelled));
    }

    /// F1 in the batch form: one timed-out id reverts the batch, and the good one before it is
    /// untouched.
    function test_review_F1_aTimedOutIdRevertsTheUpholdBatch() public {
        _propose(ID);
        _dispute(ID);
        vm.warp(stake.slashRecordOf(ID).disputedAt + Constants.DISPUTE_TIMEOUT_SECONDS);
        _propose(bytes32("fresh"));
        _dispute(bytes32("fresh"));

        bytes32[] memory ids = new bytes32[](2);
        ids[0] = bytes32("fresh");
        ids[1] = ID;
        vm.prank(arbiter);
        vm.expectRevert(DisputeTimedOut.selector);
        stake.upholdSlashBatch(ids);
        assertEq(uint256(_status(bytes32("fresh"))), uint256(SlashStatus.Disputed));
    }

    /// F2: an early dispute never pulls execution forward. The reviewer's proof executed
    /// 259 140 s before the frozen executableAt.
    function test_review_F2_upholdNeverPullsExecutionBeforeTheFrozenDelay() public {
        _propose(ID);
        uint64 frozen = stake.slashRecordOf(ID).executableAt;
        vm.warp(block.timestamp + 1 minutes);
        _dispute(ID);

        vm.expectEmit(address(stake));
        emit SlashUpheld(ID, provider, arbiter, frozen);
        vm.prank(arbiter);
        stake.upholdSlash(ID);
        assertEq(stake.slashRecordOf(ID).executableAt, frozen, "max(frozen, now) = frozen");

        vm.expectRevert(SlashNotYetExecutable.selector);
        stake.executeSlash(ID);
        // …and no second dispute, although the window is still open by the clock.
        vm.prank(provider);
        vm.expectRevert(SlashAlreadyDisputed.selector);
        stake.disputeSlash(ID);

        vm.warp(frozen);
        stake.executeSlash(ID);
        assertEq(uint256(_status(ID)), uint256(SlashStatus.Executed));
    }

    /// F2: an uphold after the frozen instant makes it executable from now, with the 7-day grace
    /// counted from that new executableAt.
    function test_review_F2_aLateUpholdCountsTheGraceFromTheRuling() public {
        _propose(ID);
        _dispute(ID);
        vm.warp(block.timestamp + 10 days);
        vm.prank(arbiter);
        stake.upholdSlash(ID);
        uint64 ruled = stake.slashRecordOf(ID).executableAt;
        assertEq(ruled, uint64(block.timestamp));
        vm.warp(uint256(ruled) + Constants.SLASH_EXECUTION_GRACE_SECONDS - 1);
        stake.executeSlash(ID);
        assertEq(uint256(_status(ID)), uint256(SlashStatus.Executed));
    }

    /// F3 (documented scope, no code change): the blocklist binds subjects only. A blocked
    /// submitter, keeper, beneficiary, verifier address and arbiter all still act; blocking the
    /// verifier does NOT stop its signatures — only `revokeVerifier` does.
    function test_review_F3_theBlocklistDoesNotBindOperatorsOrTheVerifier() public {
        address blockedCaller = address(0xBAD);
        vm.startPrank(admin);
        config.setBlocked(blockedCaller, true);
        config.setBlocked(beneficiary, true);
        config.setBlocked(verifierAddr, true);
        vm.stopPrank();
        SlashAttestation memory a = SlashAttestation({
            requestId: ID,
            provider: provider,
            beneficiary: beneficiary,
            status: uint8(ResponseClass.DataFail),
            penalty: 1_000_000,
            policy: keccak256("policy v1"),
            issuedAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp) + 3 * 86_400
        });
        bytes memory sig = VoucherSigner.signAttestation(verifierKeyPk, stake.DOMAIN_SEPARATOR(), a);
        vm.prank(blockedCaller);
        stake.proposeSlash(a, sig);
        vm.warp(stake.slashRecordOf(ID).executableAt);
        vm.prank(blockedCaller);
        stake.executeSlash(ID);
        assertEq(usdg.balanceOf(beneficiary), 600_000, "a blocked beneficiary is paid");

        _propose(bytes32("d2"));
        vm.prank(admin);
        config.setBlocked(arbiter, true);
        vm.prank(arbiter);
        stake.cancelSlash(bytes32("d2"));

        // The only stop for the verifier: revocation.
        vm.prank(admin);
        config.revokeVerifier(verifierAddr);
        SlashAttestation memory b = SlashAttestation({
            requestId: bytes32("d3"),
            provider: provider,
            beneficiary: beneficiary,
            status: uint8(ResponseClass.DataFail),
            penalty: 1_000_000,
            policy: keccak256("policy v1"),
            issuedAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp) + 3 * 86_400
        });
        bytes memory bsig =
            VoucherSigner.signAttestation(verifierKeyPk, stake.DOMAIN_SEPARATOR(), b);
        vm.expectRevert(VerifierRevoked.selector);
        stake.proposeSlash(b, bsig);
    }

    /// F4 (runbook rule, no code change): a key that expires while a record is Disputed voids
    /// a timely ruling. This is why retired keys must stay registered and unexpired for
    /// delay + 30 d + 7 d after their last proposal.
    function test_review_F4_keyExpiryDuringADisputeVoidsTheRuling() public {
        uint256 pk2 = 0xBEEF02;
        address v2 = vm.addr(pk2);
        vm.prank(admin);
        config.registerVerifier(v2, bytes32("short"), uint64(block.timestamp) + 20 days);
        _proposeSignedBy(ID, pk2);
        _dispute(ID);
        vm.warp(block.timestamp + 21 days);
        vm.prank(arbiter);
        stake.upholdSlash(ID);
        vm.expectRevert(VerifierKeyExpired.selector);
        stake.executeSlash(ID);
        stake.expireSlash(ID);
        assertEq(uint256(_status(ID)), uint256(SlashStatus.Cancelled));
    }

    /// I1: before the FIRST appointment (the state right after the upgrade; `setArbiter(0)` is
    /// refused since audit A M-2, so it cannot be re-entered) nobody can uphold and the dispute
    /// wins at the timeout — the reason the runbook appoints the arbiter in the upgrade session.
    /// The pre-appointment slot is reproduced with `vm.store` (Config slot 5: arbiter + delay).
    function test_review_I1_noArbiterMeansEveryDisputeWins() public {
        vm.store(address(config), bytes32(uint256(5)), bytes32(0));
        assertEq(config.arbiter(), address(0));
        _propose(ID);
        _dispute(ID);
        vm.prank(admin);
        vm.expectRevert(NotArbiter.selector);
        stake.upholdSlash(ID);
        vm.warp(block.timestamp + Constants.DISPUTE_TIMEOUT_SECONDS);
        stake.expireSlash(ID);
        assertEq(uint256(_status(ID)), uint256(SlashStatus.Cancelled));
    }

    /// The reviewer's single-entry proof, adjusted for F2 (execution waits for the frozen delay).
    function test_review_reservationSingleEntryAcrossDisputedExits() public {
        bytes32[4] memory ids = [bytes32("a"), bytes32("b"), bytes32("c"), bytes32("d")];
        for (uint256 i = 0; i < 4; i++) {
            _propose(ids[i]);
        }
        for (uint256 i = 0; i < 4; i++) {
            _dispute(ids[i]);
        }
        assertEq(stake.stakeOf(provider).pendingSlash, 4_000_000);
        vm.prank(arbiter);
        stake.cancelSlash(ids[0]);
        assertEq(stake.stakeOf(provider).pendingSlash, 3_000_000);
        vm.prank(arbiter);
        stake.upholdSlash(ids[1]);
        vm.warp(stake.slashRecordOf(ids[1]).executableAt);
        stake.executeSlash(ids[1]);
        assertEq(stake.stakeOf(provider).pendingSlash, 2_000_000);
        vm.prank(arbiter);
        stake.upholdSlash(ids[2]);
        vm.prank(admin);
        stake.cancelSlash(ids[2]);
        assertEq(stake.stakeOf(provider).pendingSlash, 1_000_000);
        vm.warp(stake.slashRecordOf(ids[3]).disputedAt + Constants.DISPUTE_TIMEOUT_SECONDS);
        stake.expireSlash(ids[3]);
        assertEq(stake.stakeOf(provider).pendingSlash, 0);
        for (uint256 i = 0; i < 4; i++) {
            vm.expectRevert(SlashNotPending.selector);
            stake.expireSlash(ids[i]);
            vm.prank(admin);
            vm.expectRevert(SlashNotPending.selector);
            stake.cancelSlash(ids[i]);
            vm.prank(provider);
            vm.expectRevert(SlashNotPending.selector);
            stake.disputeSlash(ids[i]);
        }
    }
}
