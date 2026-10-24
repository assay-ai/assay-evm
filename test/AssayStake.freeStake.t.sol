// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.38;

import {Fixture} from "./helpers/Fixture.sol";
import {VoucherSigner} from "./helpers/VoucherSigner.sol";
import {SlashAttestation, ResponseClass, SlashStatus, Voucher} from "../src/Types.sol";
import "../src/Errors.sol";

/// D-26, review 2026-10-24 F-M1 and F-L1. Both are about stake that standing slash records have
/// already reserved (`pendingSlash`).
///
/// F-M1: a provider could fill its own `pendingSlash` with records it disputes itself (calls
/// bought by sybil buyers and deliberately failed), so that every honest proposal against it
/// reverted `NothingToSlash`, while `bonded` stayed above the minimum and the escrow kept paying
/// it. The redeem gate now reads `freeBondedOf = bonded - pendingSlash`: a provider whose free
/// stake is under the minimum is not paid.
///
/// F-L1: a reservation was cut to whatever `free` stake was left, so a judgement could be spent
/// for a few base units. Now a judgement `free` cannot cover in full is refused and stays
/// unconsumed. The cut to `capAllowance` is the ceiling itself and stays.
///
/// Deployed-like parameters: penalty 1 USDG, cap 10 %, split 60/30, minimum stake 100 USDG.
contract AssayStakeFreeStakeTest is Fixture {
    uint256 internal vPk = 0x7E5717;
    uint64 internal constant PEN = 1_000_000;
    address internal sybilAgent = address(0x5B11);
    address internal victim = address(0x71C7);
    bytes32 internal ds;

    function setUp() public override {
        super.setUp();
        vm.prank(admin);
        config.registerVerifier(vm.addr(vPk), "v", uint64(vm.getBlockTimestamp()) + 300 days);
        ds = escrow.DOMAIN_SEPARATOR();
        _fund(buyer, 10_000_000);
        vm.startPrank(buyer);
        usdg.approve(address(escrow), 10_000_000);
        escrow.deposit(10_000_000);
        escrow.setLimits(1_000_000, 5_000_000);
        vm.stopPrank();
    }

    function _att(bytes32 id, address prov, address ben)
        internal
        view
        returns (SlashAttestation memory a)
    {
        a = SlashAttestation({
            requestId: id,
            provider: prov,
            beneficiary: ben,
            status: uint8(ResponseClass.DataFail),
            penalty: PEN,
            policy: keccak256("p"),
            issuedAt: uint64(vm.getBlockTimestamp()),
            expiresAt: uint64(vm.getBlockTimestamp()) + 600
        });
    }

    function _sign(SlashAttestation memory a) internal view returns (bytes memory) {
        return VoucherSigner.signAttestation(vPk, stake.DOMAIN_SEPARATOR(), a);
    }

    function _propose(bytes32 id, address prov, address ben) internal {
        SlashAttestation memory a = _att(id, prov, ben);
        stake.proposeSlash(a, _sign(a));
    }

    function _v(uint64 seq) internal view returns (Voucher memory) {
        return Voucher({
            payer: buyer,
            provider: provider,
            amount: 100_000,
            resourceHash: keccak256("resource"),
            requestHash: keccak256(abi.encode("request", seq)),
            seq: seq,
            issuedAt: uint64(vm.getBlockTimestamp()),
            expiresAt: uint64(vm.getBlockTimestamp()) + 300
        });
    }

    function _redeem(uint64 seq) internal {
        Voucher memory v = _v(seq);
        bytes memory sig = VoucherSigner.signVoucher(buyerKey, ds, v);
        vm.prank(redeemer);
        escrow.redeemVoucher(v, sig);
    }

    function _expectRedeemRefused(uint64 seq) internal {
        Voucher memory v = _v(seq);
        bytes memory sig = VoucherSigner.signVoucher(buyerKey, ds, v);
        vm.prank(redeemer);
        vm.expectRevert(ProviderBelowMinimumStake.selector);
        escrow.redeemVoucher(v, sig);
    }

    /// Twenty self-records a day, each disputed by the provider itself (the backend's
    /// per-provider budget signs 10 % of atRisk a day).
    function _selfDisputeDay(uint256 day) internal {
        for (uint256 i = 0; i < 20; i++) {
            bytes32 id = keccak256(abi.encode("self", day, i));
            _propose(id, provider, sybilAgent);
            vm.prank(provider);
            stake.disputeSlash(id);
        }
    }

    function test_freeBondedOfIsBondedMinusPendingSlash() public {
        assertEq(stake.freeBondedOf(provider), MINIMUM_STAKE, "nothing reserved");
        _propose("r1", provider, victim);
        assertEq(stake.freeBondedOf(provider), MINIMUM_STAKE - PEN);
        assertEq(stake.bondedOf(provider), MINIMUM_STAKE, "bondedOf is unchanged");
        assertEq(escrow.STAKE().freeBondedOf(provider), MINIMUM_STAKE - PEN, "the escrow's edge");
    }

    /// When the reservation exceeds `bonded` (it is measured against `bonded + unbonding`), the
    /// view floors at zero rather than reverting.
    function test_freeBondedOfFloorsAtZero() public {
        _propose("r1", provider, victim); // reserves 1 USDG of 100
        vm.prank(provider);
        stake.requestUnstake(MINIMUM_STAKE); // bonded 0, unbonding 100, pendingSlash 1
        assertEq(stake.bondedOf(provider), 0);
        assertEq(stake.freeBondedOf(provider), 0);
    }

    /// The reviewer's F-M1 PoC, turned around: the freeze still blocks honest proposals while it
    /// lasts, but it now costs the provider its income from the day its free stake falls under
    /// the minimum, which removes the motive.
    function test_F_M1_aProviderWhoseStakeIsReservedBelowTheMinimumIsNotPaid() public {
        _setBonded(provider, 200_000_000); // cap allowance 20 USDG a day
        uint64 seq = 1;
        _redeem(seq++);

        for (uint256 day = 0; day < 5; day++) {
            _selfDisputeDay(day);
            vm.warp(vm.getBlockTimestamp() + 1 days);
        }
        // 100 USDG reserved, 100 free: the floor is inclusive, still paid.
        assertEq(stake.freeBondedOf(provider), MINIMUM_STAKE);
        _redeem(seq++);

        _selfDisputeDay(5);
        // 120 reserved, 80 free: refused, although `bonded` is still twice the minimum.
        assertEq(stake.bondedOf(provider), 200_000_000, "bonded alone would clear the gate");
        assertEq(stake.freeBondedOf(provider), 80_000_000);
        _expectRedeemRefused(seq);

        for (uint256 day = 6; day < 10; day++) {
            vm.warp(vm.getBlockTimestamp() + 1 days);
            _selfDisputeDay(day);
        }
        assertEq(stake.stakeOf(provider).pendingSlash, 200_000_000, "whole stake reserved");
        SlashAttestation memory h = _att("honest", provider, victim);
        bytes memory hs = _sign(h);
        vm.expectRevert(NothingToSlash.selector);
        stake.proposeSlash(h, hs);
        _expectRedeemRefused(seq);

        // The records expire after the dispute timeout; only then is the provider paid again.
        vm.warp(vm.getBlockTimestamp() + 31 days);
        for (uint256 day = 0; day < 10; day++) {
            for (uint256 i = 0; i < 20; i++) {
                stake.expireSlash(keccak256(abi.encode("self", day, i)));
            }
        }
        assertEq(stake.freeBondedOf(provider), 200_000_000);
        _redeem(seq);
    }

    /// F-L1, adapted: free stake short of what the judgement may take refuses it, the
    /// attestation is not consumed, and the SAME attestation lands in full once free stake is
    /// back.
    function test_F_L1_aShortFreeBalanceRefusesTheJudgementAndBurnsNothing() public {
        address p = address(0xBAD3);
        _fund(p, 200_000_000);
        vm.startPrank(p);
        usdg.approve(address(stake), 200_000_000);
        stake.depositStake(200_000_000);
        stake.requestUnstake(200_000_000);
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + config.params().unbondingPeriodSeconds + 1);

        _propose("standing", p, victim); // 1 USDG reserved
        // Withdraw down to pendingSlash + 4: atRisk 1_000_004, cap allowance 100_000, free 4.
        uint64 out = stake.withdrawableOf(p) - 4;
        vm.prank(p);
        stake.withdrawStake(out);

        SlashAttestation memory a = _att("leaked", p, victim);
        bytes memory sig = _sign(a);
        vm.expectRevert(NothingToSlash.selector);
        stake.proposeSlash(a, sig);
        assertEq(uint8(stake.slashRecordOf("leaked").status), uint8(SlashStatus.None), "no record");
        assertEq(stake.stakeOf(p).pendingSlash, PEN, "nothing reserved");

        // The standing record released: the leaked attestation now reserves its whole ceiling.
        vm.prank(admin);
        stake.cancelSlash("standing");
        stake.proposeSlash(a, sig);
        assertEq(stake.slashRecordOf("leaked").reserved, 100_000, "min(penalty, cap allowance)");
    }

    /// The residual D-26 keeps: the cut to `capAllowance` is the ceiling, not a shortfall, so a
    /// provider that has withdrawn to `atRisk = 40` still has a judgement reserved at 4 units.
    /// It earns nothing while doing so (`bonded` is 0, so the redeem gate refuses it).
    function test_F_L1_theCapAllowanceCutStays() public {
        address p = address(0xBAD4);
        _fund(p, 200_000_000);
        vm.startPrank(p);
        usdg.approve(address(stake), 200_000_000);
        stake.depositStake(200_000_000);
        stake.requestUnstake(200_000_000);
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + config.params().unbondingPeriodSeconds + 1);
        vm.prank(p);
        stake.withdrawStake(200_000_000 - 40);

        _propose("leaked", p, victim);
        assertEq(stake.slashRecordOf("leaked").reserved, 4);
        assertEq(stake.freeBondedOf(p), 0, "and it is not paid");
    }
}
