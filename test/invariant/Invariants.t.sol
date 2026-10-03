// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {EscrowHandler} from "./EscrowHandler.sol";
import {StakeHandler} from "./StakeHandler.sol";

/// D-14's four accounting identities, asserted over a stateful random walk rather than over a
/// scripted sequence somebody thought of.
///
/// **`fail_on_revert = false`** is set in `foundry.toml`, which is correct for a handler whose
/// job is to explore refusals as well as successes — and which is also how an invariant suite
/// silently becomes worthless. If every call in a run reverted, all six invariants below would
/// be green over an untouched state. `test_theHandlerActuallyReachedEveryAction` is the guard,
/// and it is a plain unit test rather than an invariant so it reports the counts.
contract InvariantsTest is Test {
    EscrowHandler internal escrowHandler;
    StakeHandler internal stakeHandler;

    function setUp() public {
        escrowHandler = new EscrowHandler();
        stakeHandler = new StakeHandler();

        // Only the actions are fuzzed. Without the selector lists, `targetContract` would also
        // offer forge-std's own inherited externals — the handler inherits `Test` for `bound`
        // and `vm` — and a run would spend its calls on those instead.
        bytes4[] memory e = new bytes4[](8);
        e[0] = EscrowHandler.deposit.selector;
        e[1] = EscrowHandler.depositFor.selector;
        e[2] = EscrowHandler.setLimits.selector;
        e[3] = EscrowHandler.redeem.selector;
        e[4] = EscrowHandler.requestWithdraw.selector;
        e[5] = EscrowHandler.withdraw.selector;
        e[6] = EscrowHandler.warp.selector;
        e[7] = EscrowHandler.donate.selector;
        targetSelector(FuzzSelector({addr: address(escrowHandler), selectors: e}));

        bytes4[] memory s = new bytes4[](8);
        s[0] = StakeHandler.depositStake.selector;
        s[1] = StakeHandler.requestUnstake.selector;
        s[2] = StakeHandler.withdrawStake.selector;
        s[3] = StakeHandler.proposeSlash.selector;
        s[4] = StakeHandler.executeSlash.selector;
        s[5] = StakeHandler.cancelSlash.selector;
        s[6] = StakeHandler.expireSlash.selector;
        s[7] = StakeHandler.warp.selector;
        targetSelector(FuzzSelector({addr: address(stakeHandler), selectors: s}));

        targetContract(address(escrowHandler));
        targetContract(address(stakeHandler));
    }

    // === the escrow ==========================================================================

    /// D-14: the pooled vault is solvent by INTERNAL accounting, never by `balanceOf`.
    function invariant_escrowBalancesSumToTotalEscrowed() public view {
        assertEq(escrowHandler.sumOfBalances(), escrowHandler.escrow().totalEscrowed());
    }

    /// The contract can only ever hold MORE than it owes — donations are possible, a shortfall is
    /// not. Asserted as an inequality precisely because `balanceOf` is not the source of truth:
    /// mainnet USDG is presumed to be an upgradeable issuer proxy with a blocklist, so a
    /// `balanceOf`-based solvency check would refuse EVERY withdrawal rather than the one actually
    /// blocked.
    function invariant_theContractHoldsAtLeastWhatItOwes() public view {
        assertGe(
            escrowHandler.usdg().balanceOf(address(escrowHandler.escrow())),
            escrowHandler.escrow().totalEscrowed()
        );
    }

    /// D-9: `seq` is a high-water mark and never goes backwards. There is no path that lowers it
    /// — `closeEscrow` does not exist here for exactly this reason — and this is what would
    /// notice if one were added.
    function invariant_seqHighIsMonotonic() public view {
        assertTrue(escrowHandler.seqHighNeverWentBackwards());
    }

    // === the stake vault =====================================================================

    function invariant_stakeAccountingIdentity() public view {
        assertEq(
            stakeHandler.stake().totalStaked(),
            stakeHandler.stake().totalDeposited() - stakeHandler.stake().totalWithdrawn()
                - stakeHandler.stake().totalSlashed()
        );
    }

    /// The vault's own `pendingSlash` bookkeeping against the handler's independent record of
    /// every proposal it believes is still `Pending`. A release that forgot to lower
    /// `pendingSlash`, or lowered it twice, shows up here and in no unit test.
    function invariant_pendingSlashEqualsTheSumOfPendingReservations() public view {
        assertEq(stakeHandler.sumOfPendingSlash(), stakeHandler.sumOfPendingReservations());
    }

    /// A hold can never exceed the collateral it is held against, per provider.
    function invariant_atRiskCoversPendingSlash() public view {
        assertTrue(stakeHandler.everyProviderCoversItsPendingSlash());
    }

    /// The stake vault holds at least what the providers are owed, by the same argument as the
    /// escrow's — and it is a different sum, so it is a different assertion.
    function invariant_theStakeVaultHoldsAtLeastWhatItOwes() public view {
        assertGe(
            stakeHandler.usdg().balanceOf(address(stakeHandler.stake())),
            stakeHandler.stake().totalStaked()
        );
    }

    // === the guard on the guards =============================================================

    /// **The degenerate this suite would otherwise be, and the two halves it takes to refuse it.**
    ///
    /// With `fail_on_revert = false`, an invariant campaign in which every single call reverted is
    /// reported as green: the identities all hold over an untouched state, trivially. Something
    /// has to assert that the walk went somewhere.
    ///
    /// **Half one, `afterInvariant`, is a floor and not a checklist.** It runs once at the end of
    /// each of the 256 runs, and a run is 64 calls spread over 16 selectors, so "every action
    /// landed" is not attainable per run and asserting it would be a flaky test rather than a
    /// strong one. Measured on one run: `deposit 3, depositFor 3, setLimits 6, redeem 1,
    /// requestWithdraw 6, withdraw 0, warp 4, donate 2, depositStake 7, requestUnstake 5,
    /// withdrawStake 0, proposeSlash 2, executeSlash 0, cancelSlash 0, expireSlash 0, warp 1`.
    /// The floor below is what such a run clears comfortably and an all-reverts run cannot.
    ///
    /// **Half two, `test_theHandlerCanReachEveryAction`, is the checklist**, driven
    /// deterministically so the preconditions the fuzzer only sometimes assembles — a matured
    /// withdrawal, a proposal past its 72-hour delay, a proposal past its seven-day grace — are
    /// assembled every time. It ends by asserting all seven identities over the state it built.
    ///
    /// Neither half alone is enough: the floor cannot prove the slash lifecycle is reachable at
    /// all, and the checklist proves nothing about the random walk.
    function afterInvariant() public view {
        uint256 total = _escrowLanded() + _stakeLanded();
        assertGe(total, 8, "the run landed almost nothing: the identities held over an empty state");
        assertGt(_escrowLanded(), 0, "no escrow call landed in this run");
        assertGt(_stakeLanded(), 0, "no stake call landed in this run");
    }

    /// Every action, in an order that satisfies its preconditions, then every identity over the
    /// state that produced. This is the test that would fail against a handler which could not
    /// reach a state where an identity could break.
    function test_theHandlerCanReachEveryAction() public {
        EscrowHandler h = escrowHandler;

        h.deposit(0, 500_000_000);
        h.depositFor(1, 2, 300_000_000);
        h.setLimits(0, 100_000_000, 400_000_000);
        h.redeem(0, 1, 50_000_000);
        h.donate(1_000);
        h.requestWithdraw(0, 10_000_000);
        h.warp(3_599); // the withdraw delay is 3,600s, so two warps are needed
        h.warp(3_599);
        h.withdraw(0);

        StakeHandler k = stakeHandler;
        k.depositStake(0, 500_000_000);
        k.requestUnstake(0, 100_000_000);
        k.proposeSlash(0, 1_000_000); // -> executed
        k.proposeSlash(1, 1_000_000); // -> cancelled
        k.proposeSlash(2, 1_000_000); // -> expired
        k.cancelSlash(1);
        k.warp(3 * 86_400); // past SLASH_DELAY_SECONDS
        k.executeSlash(0);
        k.warp(4 * 86_400);
        k.warp(4 * 86_400); // past executableAt + SLASH_EXECUTION_GRACE_SECONDS
        k.expireSlash(2);
        k.warp(4 * 86_400); // the unbonding period is 14 days and the warps above reach 11
        k.withdrawStake(0, 100_000_000);

        string[8] memory escrowOps = [
            "deposit",
            "depositFor",
            "setLimits",
            "redeem",
            "requestWithdraw",
            "withdraw",
            "warp",
            "donate"
        ];
        for (uint256 i = 0; i < escrowOps.length; i++) {
            assertGt(
                h.landed(_k(escrowOps[i])),
                0,
                string.concat("escrow action unreachable: ", escrowOps[i])
            );
        }

        string[8] memory stakeOps = [
            "depositStake",
            "requestUnstake",
            "withdrawStake",
            "proposeSlash",
            "executeSlash",
            "cancelSlash",
            "expireSlash",
            "warp"
        ];
        for (uint256 i = 0; i < stakeOps.length; i++) {
            assertGt(
                k.landed(_k(stakeOps[i])),
                0,
                string.concat("stake action unreachable: ", stakeOps[i])
            );
        }

        // Every identity, over the state those 21 calls built — a state in which money has been
        // redeemed, withdrawn, donated, staked, unbonded, slashed, cancelled and reaped.
        invariant_escrowBalancesSumToTotalEscrowed();
        invariant_theContractHoldsAtLeastWhatItOwes();
        invariant_seqHighIsMonotonic();
        invariant_stakeAccountingIdentity();
        invariant_pendingSlashEqualsTheSumOfPendingReservations();
        invariant_atRiskCoversPendingSlash();
        invariant_theStakeVaultHoldsAtLeastWhatItOwes();

        // …and the state is not the empty one: the assertions above would all hold over an
        // untouched handler, so say out loud that it is not untouched.
        assertGt(stakeHandler.stake().totalSlashed(), 0, "nothing was ever actually slashed");
        assertGt(escrowHandler.escrow().totalEscrowed(), 0, "no money is in the escrow");
    }

    function _escrowLanded() internal view returns (uint256 n) {
        string[8] memory ops = [
            "deposit",
            "depositFor",
            "setLimits",
            "redeem",
            "requestWithdraw",
            "withdraw",
            "warp",
            "donate"
        ];
        for (uint256 i = 0; i < ops.length; i++) {
            n += escrowHandler.landed(_k(ops[i]));
        }
    }

    function _stakeLanded() internal view returns (uint256 n) {
        string[8] memory ops = [
            "depositStake",
            "requestUnstake",
            "withdrawStake",
            "proposeSlash",
            "executeSlash",
            "cancelSlash",
            "expireSlash",
            "warp"
        ];
        for (uint256 i = 0; i < ops.length; i++) {
            n += stakeHandler.landed(_k(ops[i]));
        }
    }

    function _k(string memory s) internal pure returns (bytes32 out) {
        bytes memory b = bytes(s);
        assembly ("memory-safe") {
            out := mload(add(b, 0x20))
        }
    }
}
