// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.24;

import {Fixture} from "./helpers/Fixture.sol";
import {X402Stake} from "../src/X402Stake.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {StakeObserverUSDG, ReentrantStakeUSDG} from "./helpers/MockUSDG.sol";
import "../src/Errors.sol";

contract X402StakeTest is Fixture {
    uint64 internal constant DEPOSIT = 1_000_000_000; // 1,000 USDG

    function setUp() public virtual override {
        super.setUp();
        // A stake contract of this suite's own: the fixture's is pre-funded to MINIMUM_STAKE for
        // every escrow test, and `totalStaked`/`totalDeposited` are contract-wide, so asserting
        // `totalStaked() == DEPOSIT` against the shared one would be asserting about the fixture.
        stake = _deployStake(address(usdg));

        _fund(provider, DEPOSIT);
        vm.prank(provider);
        usdg.approve(address(stake), DEPOSIT);
    }

    function test_happyPath_depositBondsAndCountsOnce() public {
        vm.prank(provider);
        stake.depositStake(DEPOSIT);

        assertEq(stake.stakeOf(provider).bonded, DEPOSIT);
        assertEq(stake.stakeOf(provider).totalDeposited, DEPOSIT);
        assertEq(stake.totalStaked(), DEPOSIT);
        assertEq(stake.totalDeposited(), DEPOSIT);
        assertEq(stake.bondedOf(provider), DEPOSIT);
    }

    function test_happyPath_anybodyMayFundAProvidersStake() public {
        _fund(buyer, DEPOSIT);
        vm.startPrank(buyer);
        usdg.approve(address(stake), DEPOSIT);
        stake.depositStakeFor(provider, DEPOSIT);
        vm.stopPrank();
        assertEq(stake.bondedOf(provider), DEPOSIT);
    }

    function test_wrongState_zeroIsRefused() public {
        vm.prank(provider);
        vm.expectRevert(ZeroAmount.selector);
        stake.depositStake(0);
    }

    function test_wrongState_theZeroProviderIsRefused() public {
        vm.prank(provider);
        vm.expectRevert(ZeroAddress.selector);
        stake.depositStakeFor(address(0), 1_000);
    }

    function test_happyPath_unstakeMovesBondedIntoUnbonding() public {
        vm.startPrank(provider);
        stake.depositStake(DEPOSIT);
        stake.requestUnstake(400_000_000);
        vm.stopPrank();

        assertEq(stake.stakeOf(provider).bonded, 600_000_000);
        assertEq(stake.stakeOf(provider).unbonding, 400_000_000);
        assertEq(stake.stakeOf(provider).unbondingStartedAt, uint64(block.timestamp));
        assertEq(stake.totalStaked(), DEPOSIT, "unbonding is still staked");
    }

    function test_wrongState_cannotUnstakeMoreThanIsBonded() public {
        vm.startPrank(provider);
        stake.depositStake(DEPOSIT);
        vm.expectRevert(InsufficientBondedStake.selector);
        stake.requestUnstake(DEPOSIT + 1);
        vm.stopPrank();
    }

    function test_wrongState_unstakingZeroIsRefused() public {
        vm.startPrank(provider);
        stake.depositStake(DEPOSIT);
        vm.expectRevert(ZeroAmount.selector);
        stake.requestUnstake(0);
        vm.expectRevert(ZeroAmount.selector);
        stake.withdrawStake(0);
        vm.stopPrank();
    }

    /// Boundary B14 at -1 / exact.
    function test_boundary_withdrawIsRefusedOneSecondEarlyAndAdmittedOnTheInstant() public {
        vm.startPrank(provider);
        stake.depositStake(DEPOSIT);
        stake.requestUnstake(400_000_000);
        uint256 t0 = block.timestamp;
        uint64 period = config.params().unbondingPeriodSeconds;

        vm.warp(t0 + period - 1);
        vm.expectRevert(UnbondingPeriodNotElapsed.selector);
        stake.withdrawStake(400_000_000);

        vm.warp(t0 + period);
        stake.withdrawStake(400_000_000);
        vm.stopPrank();

        assertEq(usdg.balanceOf(provider), 400_000_000);
        assertEq(stake.stakeOf(provider).unbonding, 0);
        assertEq(stake.stakeOf(provider).unbondingStartedAt, 0);
        assertEq(stake.totalStaked(), 600_000_000);
        assertEq(stake.totalWithdrawn(), 400_000_000);
    }

    /// The second request restarts ONE clock for the whole balance
    /// (`request_unstake.rs:51-55`), so the first amount waits again. It can only ever delay a
    /// withdrawal, never let an amount out early.
    function test_boundary_aSecondUnstakeRestartsTheClockForTheWholeBalance() public {
        uint64 period = config.params().unbondingPeriodSeconds;
        vm.startPrank(provider);
        stake.depositStake(DEPOSIT);
        stake.requestUnstake(100_000_000);

        vm.warp(block.timestamp + period - 10);
        stake.requestUnstake(100_000_000); // ten seconds short of maturity, and the clock resets

        vm.warp(block.timestamp + period - 1);
        vm.expectRevert(UnbondingPeriodNotElapsed.selector);
        stake.withdrawStake(100_000_000);

        vm.warp(block.timestamp + 1);
        stake.withdrawStake(200_000_000);
        vm.stopPrank();
        assertEq(usdg.balanceOf(provider), 200_000_000);
    }

    /// Only the provider takes their own collateral. No destination parameter, for the same
    /// reason `withdraw()` has none.
    ///
    /// `vm.prank(caller, origin)` sets tx.origin to the PROVIDER while msg.sender is the
    /// stranger. That is deliberate: with a plain `vm.prank` a `stakes[tx.origin]` mutation
    /// would read the default sender's empty account and revert for the wrong reason, so the
    /// test would pass under the mutation and prove nothing (`test/MUTATION-LOG.md` row K5).
    function test_wrongSigner_nobodyElseTakesAProvidersCollateral() public {
        vm.startPrank(provider);
        stake.depositStake(DEPOSIT);
        stake.requestUnstake(400_000_000);
        vm.stopPrank();
        vm.warp(block.timestamp + config.params().unbondingPeriodSeconds);

        vm.prank(address(0xDEAD), provider);
        vm.expectRevert(InsufficientUnbondingStake.selector);
        stake.withdrawStake(400_000_000);
        assertEq(usdg.balanceOf(address(0xDEAD)), 0);
        assertEq(stake.stakeOf(provider).unbonding, 400_000_000, "nothing left the provider");
    }

    /// The three checks are ordered as `withdraw_stake.rs:86-100` orders them, and the order is
    /// what this pins: an amount beyond `unbonding` is diagnosed as such even when the clock has
    /// ALSO not run out. Delete the first check and `withdrawableOf`'s min subsumes it at every
    /// matured instant — but before maturity the diagnosis flips to the clock, which tells the
    /// provider to wait for money that will not be there when they come back.
    function test_wrongState_anAmountBeyondUnbondingIsDiagnosedBeforeTheClock() public {
        vm.startPrank(provider);
        stake.depositStake(DEPOSIT);
        stake.requestUnstake(400_000_000);
        vm.expectRevert(InsufficientUnbondingStake.selector);
        stake.withdrawStake(400_000_001);
        vm.stopPrank();
    }

    /// A guard tested at one address pair is a guard tested nowhere. Five providers, five
    /// funders, no two the same, each fully round-tripped.
    function test_theWholeCycleHoldsAcrossASweepOfAddresses() public {
        uint64 amount = 7_000_000;
        uint64 period = config.params().unbondingPeriodSeconds;

        address[5] memory provs = [
            address(0xB1E),
            address(0x1111),
            provider,
            address(uint160(uint256(keccak256("prov-4")))),
            treasury
        ];
        address[5] memory funders = [
            buyer,
            admin,
            redeemer,
            address(uint160(uint256(keccak256("funder-5")))),
            address(this)
        ];

        for (uint256 i = 0; i < provs.length; i++) {
            address p = provs[i];
            address f = funders[i];
            _fund(f, amount);
            vm.startPrank(f);
            usdg.approve(address(stake), amount);
            stake.depositStakeFor(p, amount);
            vm.stopPrank();
            assertEq(stake.bondedOf(p), amount, "each provider is credited exactly once");
        }
        assertEq(stake.totalStaked(), amount * 5);

        for (uint256 i = 0; i < provs.length; i++) {
            address p = provs[i];
            uint256 held = usdg.balanceOf(p);
            vm.prank(p);
            stake.requestUnstake(amount);
            vm.warp(block.timestamp + period);
            vm.prank(p);
            stake.withdrawStake(amount);
            assertEq(usdg.balanceOf(p) - held, amount, "and paid exactly once, to itself");
        }
        assertEq(stake.totalStaked(), 0);
        assertEq(
            stake.totalStaked(),
            stake.totalDeposited() - stake.totalWithdrawn() - stake.totalSlashed()
        );
    }

    /// The accounting identity, asserted directly.
    function test_theAccountingIdentityHolds() public {
        vm.startPrank(provider);
        stake.depositStake(DEPOSIT);
        stake.requestUnstake(400_000_000);
        vm.warp(block.timestamp + config.params().unbondingPeriodSeconds);
        stake.withdrawStake(400_000_000);
        vm.stopPrank();

        assertEq(
            stake.totalStaked(),
            stake.totalDeposited() - stake.totalWithdrawn() - stake.totalSlashed()
        );
    }

    /// Pause never closes an owner's exit, and never closes collateral coming in.
    function test_pauseClosesNothingOnThisContract() public {
        vm.prank(admin);
        config.setPaused(true);

        vm.startPrank(provider);
        stake.depositStake(DEPOSIT);
        stake.requestUnstake(1_000);
        vm.warp(block.timestamp + config.params().unbondingPeriodSeconds);
        stake.withdrawStake(1_000);
        vm.stopPrank();
    }

    /// The pull is MEASURED, never trusted: a fee-on-transfer asset credits less than the
    /// argument says, and the whole accounting rests on `balance == the sum of the ledger`.
    /// `mockTokenOnly`: needs `MockUSDG.setTransferFeeBps`. A fee-on-transfer USDG is a
    /// hypothetical this delta assertion defends against; no deployed USDG has it, and the 46630
    /// token cannot be made to.
    function test_wrongState_aFeeOnTransferAssetIsRefusedAtTheDoor() public mockTokenOnly {
        usdg.setTransferFeeBps(1); // 0.01% — the smallest lie the mock can tell
        vm.prank(provider);
        vm.expectRevert(TransferAmountMismatch.selector);
        stake.depositStake(DEPOSIT);
        assertEq(stake.bondedOf(provider), 0, "and nothing was credited");
    }

    /// The exit is an ordinary ERC-20 call, so the asset can call back. Every effect must
    /// already be written when it does.
    function test_everyEffectIsWrittenBeforeTheWithdrawalTransfer() public {
        StakeObserverUSDG asset = new StakeObserverUSDG();
        X402Stake s = _deployStake(address(asset));

        asset.mint(provider, DEPOSIT);
        vm.startPrank(provider);
        asset.approve(address(s), DEPOSIT);
        s.depositStake(DEPOSIT);
        s.requestUnstake(400_000_000);
        vm.stopPrank();
        vm.warp(block.timestamp + config.params().unbondingPeriodSeconds);

        asset.arm(address(s), provider);
        vm.prank(provider);
        s.withdrawStake(400_000_000);

        assertTrue(asset.observed(), "the asset never got to look");
        assertEq(asset.seenTotalStaked(), 600_000_000, "totalStaked not yet debited at payout");
        assertEq(asset.seenTotalWithdrawn(), 400_000_000, "totalWithdrawn not yet raised");
        assertEq(asset.seenWithdrawable(), 0, "the unbonding balance was still claimable");
        assertEq(asset.seenBonded(), 600_000_000);
    }

    /// A withdrawal never touches the bonded balance, at any split.
    function testFuzz_withdrawTakesOnlyFromUnbonding(uint64 deposit_, uint64 unstake_) public {
        deposit_ = uint64(bound(deposit_, 2, 1_000_000_000_000));
        unstake_ = uint64(bound(unstake_, 1, deposit_));

        _fund(provider, deposit_);
        vm.startPrank(provider);
        usdg.approve(address(stake), deposit_);
        stake.depositStake(deposit_);
        stake.requestUnstake(unstake_);
        vm.warp(block.timestamp + config.params().unbondingPeriodSeconds);
        stake.withdrawStake(unstake_);
        vm.stopPrank();

        assertEq(stake.stakeOf(provider).bonded, deposit_ - unstake_);
        assertEq(stake.stakeOf(provider).unbonding, 0);
        assertEq(
            stake.totalStaked(),
            stake.totalDeposited() - stake.totalWithdrawn() - stake.totalSlashed()
        );
    }

    /// `nonReentrant` on the funding door. **Read the observed error in the mutation log before
    /// crediting the modifier**: the money is held by the measured DELTA even without it — the
    /// token funds its own nested deposit, the nested call succeeds, and the outer balance delta
    /// then sees `amount + reenterAmount` and refuses `TransferAmountMismatch`. Rows E4 and E23
    /// found the same thing on the escrow's two funding doors. This test pins the name.
    function test_wrongState_aReentrantAssetCannotRecurseIntoDepositStakeFor() public {
        ReentrantStakeUSDG asset = new ReentrantStakeUSDG();
        X402Stake s = _deployStake(address(asset));
        asset.arm(
            address(s),
            abi.encodeCall(X402Stake.depositStakeFor, (provider, 1_000)),
            1_000,
            true,
            false
        );

        asset.mint(provider, DEPOSIT);
        vm.startPrank(provider);
        asset.approve(address(s), DEPOSIT);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        s.depositStake(DEPOSIT);
        vm.stopPrank();

        assertEq(s.bondedOf(provider), 0, "and nothing was credited either way");
    }

    /// `nonReentrant` on the exit. Same reading: what actually stops the double payment here is
    /// that every effect is already written when the asset calls back — row K10 is the proof of
    /// that, and this row only pins the name the modifier gives the refusal.
    function test_wrongState_aReentrantAssetCannotRecurseIntoWithdrawStake() public {
        ReentrantStakeUSDG asset = new ReentrantStakeUSDG();
        X402Stake s = _deployStake(address(asset));

        asset.mint(provider, DEPOSIT);
        vm.startPrank(provider);
        asset.approve(address(s), DEPOSIT);
        s.depositStake(DEPOSIT);
        s.requestUnstake(400_000_000);
        vm.stopPrank();
        vm.warp(block.timestamp + config.params().unbondingPeriodSeconds);

        asset.arm(
            address(s), abi.encodeCall(X402Stake.withdrawStake, (400_000_000)), 0, false, true
        );
        vm.prank(provider);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        s.withdrawStake(400_000_000);

        assertEq(s.stakeOf(provider).unbonding, 400_000_000, "the exit was rolled back whole");
        assertEq(asset.balanceOf(provider), 0);
    }
}
