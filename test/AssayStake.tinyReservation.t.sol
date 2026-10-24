// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.38;

import {Fixture} from "./helpers/Fixture.sol";
import {VoucherSigner} from "./helpers/VoucherSigner.sol";
import {SlashAttestation, ResponseClass, SlashStatus, ParamSet} from "../src/Types.sol";
import "../src/Errors.sol";

/// Review 2026-10-23 L-1. `proposeSlash` cuts a reservation to the provider's `free` stake. A
/// provider holding matured unbonding stake and a valid attestation (for example from public
/// calldata) could withdraw down to `pendingSlash + 1` and then land it: the record reserved one
/// base unit, could never split (`PenaltyTooSmallToSplit`), expired, and burnt the `requestId`.
/// Now a reservation the current split cannot divide is refused at proposal, nothing is written,
/// and the same attestation can be landed again once there is stake to reserve. Since D-26 a
/// short `free` no longer cuts a reservation at all (it refuses `NothingToSlash`), so the split
/// check is reached only by a penalty or a cap allowance too small to divide.
contract AssayStakeTinyReservationTest is Fixture {
    uint256 internal vPk = 0x7E5717;
    address internal p2 = address(0x9A11);

    function setUp() public override {
        super.setUp();
        stake = _deployStake(address(usdg));
        vm.prank(admin);
        config.registerVerifier(vm.addr(vPk), "v", uint64(vm.getBlockTimestamp()) + 300 days);
    }

    function _att(bytes32 id, uint64 penalty) internal view returns (SlashAttestation memory a) {
        a = SlashAttestation({
            requestId: id,
            provider: p2,
            beneficiary: address(0xB0B),
            status: uint8(ResponseClass.DataFail),
            penalty: penalty,
            policy: keccak256("p"),
            issuedAt: uint64(vm.getBlockTimestamp()),
            expiresAt: uint64(vm.getBlockTimestamp()) + 600
        });
    }

    function _sign(SlashAttestation memory a) internal view returns (bytes memory) {
        return VoucherSigner.signAttestation(vPk, stake.DOMAIN_SEPARATOR(), a);
    }

    function _bondAndUnbond(uint64 amt) internal {
        _fund(p2, amt);
        vm.startPrank(p2);
        usdg.approve(address(stake), amt);
        stake.depositStake(amt);
        stake.requestUnstake(amt); // a matured exit kept ready
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + 14 days + 1);
    }

    /// The reviewer's PoC, turned around. Since D-26 the refusal is `NothingToSlash`: free stake
    /// one unit short of the penalty refuses the whole judgement instead of cutting it.
    function test_L1_aReservationTooSmallToSplitIsRefusedAndBurnsNothing() public {
        _bondAndUnbond(200_000_000);
        SlashAttestation memory a1 = _att("first", 1_000_000);
        stake.proposeSlash(a1, _sign(a1)); // an honest record already pending

        SlashAttestation memory a2 = _att("second", 1_000_000);
        bytes memory sig2 = _sign(a2);

        uint64 out = stake.withdrawableOf(p2) - 1; // leave pendingSlash + 1
        vm.prank(p2);
        stake.withdrawStake(out);
        vm.expectRevert(NothingToSlash.selector);
        stake.proposeSlash(a2, sig2);
        assertEq(uint8(stake.slashRecordOf("second").status), uint8(SlashStatus.None), "no record");
        assertEq(stake.stakeOf(p2).pendingSlash, 1_000_000, "nothing reserved");

        // The requestId is not burnt: with stake to reserve, the same attestation lands.
        _fund(p2, 20_000_000);
        vm.startPrank(p2);
        usdg.approve(address(stake), 20_000_000);
        stake.depositStake(20_000_000);
        vm.stopPrank();
        stake.proposeSlash(a2, sig2);
        assertEq(stake.slashRecordOf("second").reserved, 1_000_000, "reserved in full");
    }

    /// The boundary at the deployed split (60 / 30): 4 base units give agent 2 and platform 1 and
    /// are admitted; 3 give agent 1 and platform 0 and are refused; 1 gives 0 and 0.
    function test_L1_theBoundaryIsANonZeroShareForEveryPaidParty() public {
        _bondAndUnbond(200_000_000);
        SlashAttestation memory r1 = _att("r1", 1);
        bytes memory s1 = _sign(r1);
        vm.expectRevert(PenaltyTooSmallToSplit.selector);
        stake.proposeSlash(r1, s1);
        SlashAttestation memory r3 = _att("r3", 3);
        bytes memory s3 = _sign(r3);
        vm.expectRevert(PenaltyTooSmallToSplit.selector);
        stake.proposeSlash(r3, s3);
        SlashAttestation memory r4 = _att("r4", 4);
        stake.proposeSlash(r4, _sign(r4));
        assertEq(stake.slashRecordOf("r4").reserved, 4);
    }

    /// With a zero platform share configured, only the agent share has to be non-zero.
    function test_L1_aZeroPlatformShareIsNotRequired() public {
        ParamSet memory p = config.params();
        p.slashPlatformBps = 0;
        vm.prank(admin);
        config.updateConfig(p);
        _bondAndUnbond(200_000_000);
        SlashAttestation memory a = _att("two", 2); // agent 6 000 bps of 2 = 1, platform 0
        stake.proposeSlash(a, _sign(a));
        assertEq(stake.slashRecordOf("two").reserved, 2);
    }
}
