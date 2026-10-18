// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Fixture} from "../../helpers/Fixture.sol";
import {VoucherSigner} from "../../helpers/VoucherSigner.sol";
import {X402Stake} from "../../../src/X402Stake.sol";
import {X402Escrow} from "../../../src/X402Escrow.sol";
import {Fee} from "../../../src/libraries/Fee.sol";
import {Window} from "../../../src/libraries/Window.sol";
import {Constants} from "../../../src/Constants.sol";
import {
    SlashAttestation, ResponseClass, SlashStatus, ParamSet, Voucher
} from "../../../src/Types.sol";

/// Library wrappers so a revert inside the library is observable as a revert of a call.
contract LibProbe {
    function split(uint64 a, uint16 b) external pure returns (uint64, uint64) {
        return Fee.splitFee(a, b);
    }

    function bps(uint64 a, uint16 b) external pure returns (uint64) {
        return Fee.bpsOf(a, b);
    }

    function decay(uint64 c, uint64 s, uint64 n) external pure returns (uint64) {
        return Window.decay(c, s, n);
    }
}

/// Audit D, step 3: the arithmetic, fuzzed at its edges.
contract AuditDArithmeticTest is Test {
    LibProbe internal lib = new LibProbe();
    uint256 internal constant W = Constants.SLASH_WINDOW_SECONDS;

    // --- Fee ----------------------------------------------------------------------------------

    function testFuzz_splitFeeIsExactAndFloors(uint64 amount, uint16 take) public view {
        take = uint16(bound(take, 0, 10_000));
        (uint64 fee, uint64 net) = lib.split(amount, take);
        assertEq(uint256(fee) + net, amount, "fee + net != amount");
        assertEq(fee, (uint256(amount) * take) / 10_000, "fee is not the floor");
        if (take <= Constants.MAX_TAKE_RATE_BPS) assertLe(fee, (uint256(amount) * 3_000) / 10_000);
    }

    /// Outside the validated domain the library must REVERT, never wrap.
    function testFuzz_splitFeeAboveOneHundredPercentReverts(uint64 amount, uint16 take) public {
        take = uint16(bound(take, 10_001, type(uint16).max));
        amount = uint64(bound(amount, 10_000, type(uint64).max));
        vm.expectRevert();
        lib.split(amount, take);
    }

    function testFuzz_slashSplitNeverExceedsApplied(uint64 applied, uint16 agent, uint16 plat)
        public
        view
    {
        agent = uint16(bound(agent, 1, 10_000));
        plat = uint16(bound(plat, 0, 10_000 - agent));
        uint64 a = lib.bps(applied, agent);
        uint64 p = lib.bps(applied, plat);
        assertLe(uint256(a) + p, applied, "agent + platform > applied");
        // the provider keeps at least the provider share, floored the other way
        assertGe(uint256(applied) - a - p, (uint256(applied) * (10_000 - agent - plat)) / 10_000);
    }

    // --- Window.decay ---------------------------------------------------------------------------

    function testFuzz_decayBounds(uint64 c, uint64 s, uint64 n) public view {
        uint64 d = lib.decay(c, s, n);
        assertLe(d, c, "decay grew the counter");
        if (n <= s) assertEq(d, c, "a clock that did not advance returned capacity");
        if (n > s && uint256(n) - s >= W) assertEq(d, 0, "a full window did not drain");
        if (n > s && uint256(n) - s < W) {
            uint256 rem = W - (uint256(n) - s);
            // div_ceil: returned late, never early, and by less than one unit
            assertGe(uint256(d) * W, uint256(c) * rem, "capacity returned early");
            if (d > 0) assertLt((uint256(d) - 1) * W, uint256(c) * rem, "not the ceiling");
        }
    }

    function testFuzz_decayIsMonotoneInTime(uint64 c, uint64 s, uint64 n1, uint64 n2) public view {
        if (n1 > n2) (n1, n2) = (n2, n1);
        assertGe(lib.decay(c, s, n1), lib.decay(c, s, n2), "later is larger");
    }

    function test_decayAtTheExtremes() public view {
        uint64 M = type(uint64).max;
        assertEq(lib.decay(M, 0, M), 0);
        assertEq(lib.decay(M, M, 0), M);
        assertEq(lib.decay(M, M - 1, M), uint64((uint256(M) * (W - 1) + W - 1) / W));
        assertEq(lib.decay(M, 0, uint64(W - 1)), uint64((uint256(M) + W - 1) / W));
        assertEq(lib.decay(1, 0, uint64(W - 1)), 1);
        assertEq(lib.decay(1, 0, uint64(W)), 0);
    }
}

/// The slash at its arithmetic edges, on the real deployed contracts.
contract AuditDSlashEdgesTest is Fixture {
    uint256 internal constant VPK = 0x7E5717;
    address internal ben = address(0xA6E7);
    address internal p2 = address(0x9393);

    function setUp() public override {
        super.setUp();
        stake = _deployStake(address(usdg));
        vm.prank(admin);
        config.registerVerifier(vm.addr(VPK), bytes32("v"), uint64(block.timestamp) + 300 days);
    }

    function _params(uint64 penaltyMax, uint64 daily, uint16 cap, uint16 agent, uint16 plat)
        internal
    {
        ParamSet memory p = config.params();
        p.penaltyAmount = penaltyMax;
        p.verifierDailyCap = daily;
        p.slashCapBps = cap;
        p.slashAgentBps = agent;
        p.slashPlatformBps = plat;
        // The smallest minimum the provider-day rule admits (review R-1). `minimumStake` gates
        // only escrow redemption, so it does not constrain the bonds fuzzed below.
        uint256 floor_ = (2 * uint256(penaltyMax) * 10_000 + cap - 1) / cap;
        if (p.minimumStake < floor_) p.minimumStake = uint64(floor_);
        vm.prank(admin);
        config.updateConfig(p, address(0));
    }

    /// The penalty larger than the stake, at any size, with any legal cap and split: the
    /// reservation never exceeds the cap or the stake, the take never exceeds the stake, and
    /// value is conserved to the unit.
    function testFuzz_penaltyAboveTheStake(
        uint64 bond,
        uint64 unbond,
        uint64 penalty,
        uint16 cap,
        uint16 agent,
        uint16 plat,
        uint64 daily
    ) public {
        bond = uint64(bound(bond, 1, type(uint64).max / 2));
        unbond = uint64(bound(unbond, 0, bond));
        cap = uint16(bound(cap, 1, Constants.MAX_SLASH_CAP_BPS));
        agent = uint16(bound(agent, 1, 10_000));
        plat = uint16(bound(plat, 0, 10_000 - agent));
        daily = uint64(bound(daily, 2, type(uint64).max));
        // Since audit G G-1 the penalty ceiling is at most half the key's daily cap, and since
        // review R-1 at most half of a minimum-stake provider's capped day; the largest
        // `minimumStake` (uint64 max) bounds it at `max * cap / 10_000 / 2`. Still far above any
        // small `bond`, so the penalty-above-the-stake case stays in the domain.
        uint64 penaltyMax = daily / 2;
        uint256 stakeCeiling = uint256(type(uint64).max) * cap / 10_000 / 2;
        if (penaltyMax > stakeCeiling) penaltyMax = uint64(stakeCeiling);
        penalty = uint64(bound(penalty, 1, penaltyMax));
        _params(penaltyMax, daily, cap, agent, plat);

        _fund(p2, bond);
        vm.startPrank(p2);
        usdg.approve(address(stake), bond);
        stake.depositStake(bond);
        if (unbond > 0) stake.requestUnstake(unbond);
        vm.stopPrank();

        SlashAttestation memory a = SlashAttestation({
            requestId: "edge",
            provider: p2,
            beneficiary: ben,
            status: uint8(ResponseClass.DataFail),
            penalty: penalty,
            policy: bytes32(0),
            issuedAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp) + 1
        });
        bytes memory sig = VoucherSigner.signAttestation(VPK, stake.DOMAIN_SEPARATOR(), a);
        uint256 capAllowance = (uint256(bond) * cap) / 10_000;
        if (capAllowance == 0) {
            vm.expectRevert();
            stake.proposeSlash(a, sig);
            return;
        }
        stake.proposeSlash(a, sig);
        X402Stake.SlashRecord memory r = stake.slashRecordOf("edge");
        assertEq(r.capAllowance, capAllowance);
        assertLe(r.reserved, r.capAllowance);
        assertLe(r.reserved, bond);
        assertEq(r.reserved, penalty < capAllowance ? penalty : capAllowance);

        vm.warp(r.executableAt);
        uint256 vaultBefore = usdg.balanceOf(address(stake));
        uint64 taken = Fee.bpsOf(r.reserved < daily ? r.reserved : daily, agent)
            + Fee.bpsOf(r.reserved < daily ? r.reserved : daily, plat);
        if (taken == 0) {
            vm.expectRevert();
            stake.executeSlash("edge");
            return;
        }
        stake.executeSlash("edge");
        r = stake.slashRecordOf("edge");
        X402Stake.ProviderStake memory s = stake.stakeOf(p2);
        uint256 out = vaultBefore - usdg.balanceOf(address(stake));
        assertEq(out, taken, "vault outflow != agent + platform");
        assertEq(uint256(s.bonded) + s.unbonding, uint256(bond) - taken, "stake debit");
        assertEq(usdg.balanceOf(ben), Fee.bpsOf(r.applied, agent));
        assertEq(s.pendingSlash, 0);
        assertEq(
            stake.totalStaked(),
            stake.totalDeposited() - stake.totalWithdrawn() - stake.totalSlashed()
        );
        assertLe(r.applied, r.reserved);
        assertLe(s.slashedInWindow, r.capAllowance);
    }

    /// uint64 time edges: every guard compares in uint256, so no door panics near the end of
    /// the clock except `proposeSlash`, whose `now + delay` is the one checked add.
    function test_expireAndExecuteNearTheEndOfTime() public {
        _fund(p2, 1_000_000_000);
        vm.startPrank(p2);
        usdg.approve(address(stake), 1_000_000_000);
        stake.depositStake(1_000_000_000);
        vm.stopPrank();
        uint64 t = type(uint64).max - Constants.SLASH_DELAY_SECONDS - 10;
        vm.warp(t);
        vm.prank(admin);
        config.registerVerifier(vm.addr(0xBEEF), bytes32("late"), type(uint64).max);
        SlashAttestation memory a = SlashAttestation({
            requestId: "late",
            provider: p2,
            beneficiary: ben,
            status: uint8(ResponseClass.DataFail),
            penalty: 1_000_000,
            policy: bytes32(0),
            issuedAt: t,
            expiresAt: t + 1
        });
        stake.proposeSlash(a, VoucherSigner.signAttestation(0xBEEF, stake.DOMAIN_SEPARATOR(), a));
        // executableAt + grace overflows uint64: the uint256 compare must not panic
        vm.warp(type(uint64).max);
        stake.executeSlash("late");
        assertEq(uint8(stake.slashRecordOf("late").status), uint8(SlashStatus.Executed));
    }
}

/// The escrow at uint64 edges: a balance above 2^64 (uint128), a max-size voucher at the max
/// take rate, and a two-step exit of a balance that does not fit one request.
contract AuditDEscrowEdgesTest is Fixture {
    function test_escrowAtTheUint64Edges() public {
        ParamSet memory p = config.params();
        p.takeRateBps = Constants.MAX_TAKE_RATE_BPS;
        vm.prank(admin);
        config.updateConfig(p, address(0));
        uint64 M = type(uint64).max;
        for (uint256 i = 0; i < 2; i++) {
            _fund(buyer, M);
            vm.startPrank(buyer);
            usdg.approve(address(escrow), M);
            escrow.deposit(M);
            vm.stopPrank();
        }
        vm.prank(buyer);
        escrow.setLimits(M, M);
        Voucher memory v = Voucher({
            payer: buyer,
            provider: provider,
            amount: M,
            resourceHash: bytes32(0),
            requestHash: bytes32(0),
            seq: 1,
            issuedAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp) + 60
        });
        bytes memory sig = VoucherSigner.signVoucher(buyerKey, escrow.DOMAIN_SEPARATOR(), v);
        uint256 provBefore = usdg.balanceOf(provider);
        vm.prank(redeemer);
        escrow.redeemVoucher(v, sig);
        _collect(buyer, 1); // redeem into hold: the payout is the collect's
        (uint64 fee, uint64 net) = Fee.splitFee(M, Constants.MAX_TAKE_RATE_BPS);
        assertEq(usdg.balanceOf(provider) - provBefore, net);
        assertEq(usdg.balanceOf(treasury), fee);
        assertEq(escrow.escrowOf(buyer).balance, M);
        // the window is full: the next voucher of 1 must be refused
        v.amount = 1;
        v.seq = 2;
        sig = VoucherSigner.signVoucher(buyerKey, escrow.DOMAIN_SEPARATOR(), v);
        vm.prank(redeemer);
        vm.expectRevert();
        escrow.redeemVoucher(v, sig);
        // exit the remaining M
        vm.prank(buyer);
        escrow.requestWithdraw(M);
        vm.warp(block.timestamp + Constants.WITHDRAW_DELAY_SECONDS);
        uint256 before = usdg.balanceOf(buyer);
        vm.prank(buyer);
        escrow.withdraw();
        assertEq(usdg.balanceOf(buyer) - before, M);
        assertEq(escrow.totalEscrowed(), 0);
        assertEq(usdg.balanceOf(address(escrow)), 0);
    }
}
