// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {SystemHandler} from "./SystemHandler.sol";
import {X402Config} from "../../../src/X402Config.sol";
import {X402Escrow} from "../../../src/X402Escrow.sol";
import {X402Stake} from "../../../src/X402Stake.sol";
import {SlashStatus} from "../../../src/Types.sol";
import {MockUSDG} from "../../helpers/MockUSDG.sol";

/// Audit D's stateful invariants over the whole system. See `SystemHandler` for the per-call
/// outcome properties (pause, blocklist, roles, liveness of dispute/revoke, transitions, caps);
/// each is a counter here that must stay zero.
///
/// Adopted from audit D (property-based audit of `a4f97ab`). Bounded for CI: 128 runs of depth
/// 100 per invariant (12,800 calls each). The audit's own final pass was 1,000 x 200:
/// `FOUNDRY_INVARIANT_RUNS=1000 FOUNDRY_INVARIANT_DEPTH=200 forge test --mc SystemInvariantsTest`.
/// Depth 100 rather than the repo's 64, because pause now closes most doors and a 64-call run
/// that pauses early can land fewer calls than `afterInvariant`'s floor.
/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 100
contract SystemInvariantsTest is Test {
    SystemHandler internal h;
    X402Config internal config;
    X402Escrow internal escrow;
    X402Stake internal stake;
    MockUSDG internal usdg;

    function setUp() public {
        vm.warp(1_760_000_000);
        h = new SystemHandler();
        config = h.config();
        escrow = h.escrow();
        stake = h.stake();
        usdg = h.usdg();

        bytes4[] memory s = new bytes4[](30);
        uint256 n;
        s[n++] = SystemHandler.deposit.selector;
        s[n++] = SystemHandler.setLimits.selector;
        s[n++] = SystemHandler.setLimitsBySig.selector;
        s[n++] = SystemHandler.requestWithdraw.selector;
        s[n++] = SystemHandler.withdraw.selector;
        s[n++] = SystemHandler.authorizeDelegate.selector;
        s[n++] = SystemHandler.revokeDelegate.selector;
        s[n++] = SystemHandler.redeem.selector;
        s[n++] = SystemHandler.redeem.selector; // weighted
        s[n++] = SystemHandler.redeemBatch.selector;
        s[n++] = SystemHandler.depositStake.selector;
        s[n++] = SystemHandler.requestUnstake.selector;
        s[n++] = SystemHandler.withdrawStake.selector;
        s[n++] = SystemHandler.proposeSlash.selector;
        s[n++] = SystemHandler.proposeSlash.selector; // weighted
        s[n++] = SystemHandler.executeSlash.selector;
        s[n++] = SystemHandler.cancelSlash.selector;
        s[n++] = SystemHandler.cancelSlashBatch.selector;
        s[n++] = SystemHandler.expireSlash.selector;
        s[n++] = SystemHandler.disputeSlash.selector;
        s[n++] = SystemHandler.disputeSlashBatch.selector;
        s[n++] = SystemHandler.upholdSlash.selector;
        s[n++] = SystemHandler.upholdSlashBatch.selector;
        s[n++] = SystemHandler.setPaused.selector;
        s[n++] = SystemHandler.setBlocked.selector;
        s[n++] = SystemHandler.setSlashDelay.selector;
        s[n++] = SystemHandler.setArbiter.selector;
        s[n++] = SystemHandler.registerVerifier.selector;
        s[n++] = SystemHandler.revokeVerifier.selector;
        s[n++] = SystemHandler.warp.selector;
        bytes4[] memory more = new bytes4[](35);
        for (uint256 i = 0; i < 30; i++) {
            more[i] = s[i];
        }
        more[30] = SystemHandler.updateConfig.selector;
        more[31] = SystemHandler.setAdmin.selector;
        more[32] = SystemHandler.donate.selector;
        more[33] = SystemHandler.warp.selector; // weighted
        more[34] = SystemHandler.executeSlash.selector; // weighted
        targetSelector(FuzzSelector({addr: address(h), selectors: more}));
        targetContract(address(h));
    }

    // === per-call outcome properties (counters in the handler) ================================

    function _zero(bytes32 key) internal view {
        assertEq(h.violations(key), 0, h.firstViolation());
    }

    function invariant_pauseStopsEveryUserDoorAndSlashExecution() public view {
        _zero("pause");
    }

    function invariant_blockedSubjectsCanDoNothingButRevokeOrDispute() public view {
        _zero("block");
        _zero("blockedBalance");
    }

    function invariant_rolesAreExact() public view {
        _zero("role");
    }

    function invariant_statusMachine() public view {
        _zero("transition");
        _zero("frozenField");
        _zero("disputedTwice");
        _zero("disputedExecuted");
        _zero("upholdLate");
        _zero("executableAtEarlier");
        _zero("replay");
        _zero("delay");
    }

    function invariant_escrowHighWaterMarksAndDelegateList() public view {
        _zero("monotonic");
        _zero("delegateList");
    }

    function invariant_capsHold() public view {
        _zero("caps");
        _zero("delegate");
        _zero("reservation");
    }

    function invariant_payoutsAreExact() public view {
        _zero("payout");
        _zero("escrowExit");
        _zero("stakeExit");
        _zero("expire");
    }

    function invariant_providerCanAlwaysDisputeAndPayerCanAlwaysRevoke() public view {
        _zero("disputeLiveness");
        _zero("revokeLiveness");
    }

    // === live role facts ======================================================================

    /// The arbiter is a separate person: never the admin.
    function invariant_arbiterIsNeverTheAdmin() public view {
        address arb = config.arbiter();
        if (arb != address(0)) assertTrue(arb != config.admin(), "arbiter == admin");
    }

    /// The arbiter is never a live verifier (it may not propose slashes).
    function invariant_arbiterIsNeverALiveVerifier() public view {
        address arb = config.arbiter();
        if (arb != address(0)) assertFalse(config.canSign(arb), "arbiter can sign attestations");
    }

    // === conservation =========================================================================

    function invariant_escrowConservation() public view {
        uint256 sum;
        for (uint256 i = 0; i < 3; i++) {
            X402Escrow.Escrow memory e = escrow.escrowOf(h.buyers(i));
            sum += e.balance;
            assertEq(
                e.totalFunded,
                uint256(e.balance) + e.totalRedeemed + e.totalWithdrawn,
                "per-buyer funded != balance + redeemed + withdrawn"
            );
        }
        assertEq(sum, escrow.totalEscrowed(), "sum of balances != totalEscrowed");
        assertEq(
            usdg.balanceOf(address(escrow)),
            uint256(escrow.totalEscrowed()) + h.donatedEscrow(),
            "escrow token balance != totalEscrowed + donations"
        );
    }

    function invariant_stakeConservation() public view {
        uint256 atRisk;
        uint256 dep;
        uint256 wd;
        uint256 sl;
        for (uint256 i = 0; i < 3; i++) {
            X402Stake.ProviderStake memory s = stake.stakeOf(h.providers(i));
            atRisk += uint256(s.bonded) + s.unbonding;
            dep += s.totalDeposited;
            wd += s.totalWithdrawn;
            sl += s.totalSlashed;
            assertEq(
                uint256(s.bonded) + s.unbonding,
                uint256(s.totalDeposited) - s.totalWithdrawn - s.totalSlashed,
                "per-provider identity"
            );
        }
        assertEq(atRisk, stake.totalStaked(), "sum at-risk != totalStaked");
        assertEq(dep, stake.totalDeposited(), "sum deposited");
        assertEq(wd, stake.totalWithdrawn(), "sum withdrawn");
        assertEq(sl, stake.totalSlashed(), "sum slashed");
        assertEq(
            stake.totalStaked(),
            uint256(stake.totalDeposited()) - stake.totalWithdrawn() - stake.totalSlashed(),
            "global identity"
        );
        assertEq(
            usdg.balanceOf(address(stake)),
            uint256(stake.totalStaked()) + h.donatedStake(),
            "stake token balance != totalStaked + donations"
        );
    }

    /// No token is created or destroyed and none leaves the known world.
    function invariant_globalTokenConservation() public view {
        address[] memory hs = h.holders();
        uint256 sum;
        for (uint256 i = 0; i < hs.length; i++) {
            sum += usdg.balanceOf(hs[i]);
        }
        assertEq(sum, usdg.totalSupply(), "tokens left the known holder set");
    }

    // === reservations =========================================================================

    function invariant_pendingSlashIsTheSumOfOpenReservations() public view {
        uint256 n = h.idsLength();
        for (uint256 p = 0; p < 3; p++) {
            address prov = h.providers(p);
            uint256 sum;
            for (uint256 k = 0; k < n; k++) {
                X402Stake.SlashRecord memory r = stake.slashRecordOf(h.ids(k));
                if (r.provider != prov) continue;
                assertLe(r.reserved, r.capAllowance, "reserved > capAllowance");
                assertLe(r.reserved, r.penalty, "reserved > penalty");
                if (r.status == SlashStatus.Pending || r.status == SlashStatus.Disputed) {
                    sum += r.reserved;
                }
            }
            X402Stake.ProviderStake memory s = stake.stakeOf(prov);
            assertEq(s.pendingSlash, sum, "pendingSlash != sum of open reservations");
            assertLe(s.pendingSlash, uint256(s.bonded) + s.unbonding, "pendingSlash > at-risk");
        }
    }

    // === liveness probes (state discarded) ====================================================

    /// Once unpaused and unblocked, every buyer gets its whole balance back.
    function invariant_buyerCanAlwaysExit() public {
        uint256 snapId = vm.snapshotState();
        address admin = config.admin();
        vm.startPrank(admin);
        config.setPaused(false);
        for (uint256 i = 0; i < 3; i++) {
            config.setBlocked(h.buyers(i), false);
        }
        vm.stopPrank();
        for (uint256 i = 0; i < 3; i++) {
            address b = h.buyers(i);
            uint128 bal = escrow.escrowOf(b).balance;
            if (bal == 0) continue;
            vm.prank(b);
            escrow.requestWithdraw(uint64(bal));
        }
        vm.warp(block.timestamp + 3_600);
        for (uint256 i = 0; i < 3; i++) {
            address b = h.buyers(i);
            uint128 bal = escrow.escrowOf(b).balance;
            if (bal == 0) continue;
            uint256 before = usdg.balanceOf(b);
            vm.prank(b);
            escrow.withdraw();
            assertEq(usdg.balanceOf(b) - before, bal, "buyer could not take its whole balance");
            assertEq(escrow.escrowOf(b).balance, 0);
        }
        vm.revertToState(snapId);
    }

    /// Once unpaused and unblocked, every provider gets its whole unslashed stake back: every
    /// open record can be expired eventually, and nothing else holds the stake.
    function invariant_providerCanAlwaysExit() public {
        uint256 snapId = vm.snapshotState();
        address admin = config.admin();
        vm.startPrank(admin);
        config.setPaused(false);
        for (uint256 i = 0; i < 3; i++) {
            config.setBlocked(h.providers(i), false);
        }
        vm.stopPrank();
        vm.warp(block.timestamp + 61 days);
        uint256 n = h.idsLength();
        for (uint256 k = 0; k < n; k++) {
            bytes32 id = h.ids(k);
            SlashStatus st = stake.slashRecordOf(id).status;
            if (st == SlashStatus.Pending || st == SlashStatus.Disputed) stake.expireSlash(id);
        }
        uint64 period = config.params().unbondingPeriodSeconds;
        for (uint256 i = 0; i < 3; i++) {
            address p = h.providers(i);
            X402Stake.ProviderStake memory s = stake.stakeOf(p);
            assertEq(s.pendingSlash, 0, "a reservation survived every expiry");
            if (s.bonded > 0) {
                vm.prank(p);
                stake.requestUnstake(uint64(s.bonded));
            }
        }
        vm.warp(block.timestamp + period);
        for (uint256 i = 0; i < 3; i++) {
            address p = h.providers(i);
            X402Stake.ProviderStake memory s = stake.stakeOf(p);
            if (s.unbonding == 0) continue;
            uint256 before = usdg.balanceOf(p);
            vm.prank(p);
            stake.withdrawStake(s.unbonding);
            assertEq(usdg.balanceOf(p) - before, s.unbonding, "provider could not exit");
        }
        vm.revertToState(snapId);
    }

    /// The walk has to go somewhere: a floor on landed calls, and a coverage dump per run.
    function afterInvariant() public {
        uint256 n = h.actionCount();
        uint256 landed;
        string memory line;
        for (uint256 i = 0; i < n; i++) {
            bytes32 a = h.actionNames(i);
            landed += h.ok(a);
            line = string.concat(
                line, _s(a), "=", vm.toString(h.ok(a)), "/", vm.toString(h.tried(a)), " "
            );
        }
        // The floor binds full-length runs only (depth 100). Forge's shrinker keeps a candidate
        // that still fails `afterInvariant`, so an unconditional floor shrinks any real
        // violation to a two-call sequence reported as "landed almost nothing", and replays
        // that instead of the true cause. A shrunk or replayed sequence is shorter than 50.
        // No proportional floor here: with pause and the blocklist closing most doors, a full
        // run lands about 5 to 10% of its calls (measured), so "landed * 10 >= steps" would
        // fail real runs.
        uint256 st = h.steps();
        if (st >= 50) assertGe(landed, 3, "the run landed almost nothing");
        string memory path = vm.envOr("AUDIT_D_COVERAGE", string(""));
        if (bytes(path).length != 0) vm.writeLine(path, line);
    }

    function _s(bytes32 b) internal pure returns (string memory) {
        uint256 n;
        while (n < 32 && b[n] != 0) n++;
        bytes memory out = new bytes(n);
        for (uint256 i = 0; i < n; i++) {
            out[i] = b[i];
        }
        return string(out);
    }
}
