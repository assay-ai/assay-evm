// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.38;

import {Fixture} from "./helpers/Fixture.sol";
import {VoucherSigner} from "./helpers/VoucherSigner.sol";
import {SlashAttestation, ResponseClass, SlashStatus} from "../src/Types.sol";
import "../src/Errors.sol";

/// Review 2026-10-23 M-1 / D-25. Under "all or wait" with a per-verifier-key daily window, one
/// party that self-slashes (attestations for calls it bought from its own provider, beneficiary
/// its own agent) could keep the key's window full and make every OTHER provider's slash signed
/// by that key wait until it expired. D-25 removed the key window. These tests replay the
/// reviewer's scenario at the deployed testnet parameters (penalty 1 USDG, verifierDailyCap
/// 500 USDG, cap 10 %, split 60/30) and assert the fixed behaviour, plus the residual that D-25
/// accepts: a provider can still crowd its OWN window.
contract AssayStakeCrowdingTest is Fixture {
    uint256 internal vPk = 0x7E5717;
    address internal honest = address(0x4045); // the provider that deserves the slash
    address internal victim = address(0x71C7); // the buyer it harmed
    address internal attacker = address(0xBAD1); // the attacker's provider
    address internal attackerAgent = address(0xBAD2); // the attacker's own buyer agent
    uint64 internal constant PEN = 1_000_000;

    function setUp() public override {
        super.setUp();
        stake = _deployStake(address(usdg));
        vm.prank(admin);
        config.registerVerifier(vm.addr(vPk), "v", uint64(vm.getBlockTimestamp()) + 300 days);
    }

    function _bond(address who, uint64 amt) internal {
        _fund(who, amt);
        vm.startPrank(who);
        usdg.approve(address(stake), amt);
        stake.depositStake(amt);
        vm.stopPrank();
    }

    function _propose(bytes32 id, address prov, address ben) internal {
        SlashAttestation memory a = SlashAttestation({
            requestId: id,
            provider: prov,
            beneficiary: ben,
            status: uint8(ResponseClass.DataFail),
            penalty: PEN,
            policy: keccak256("p"),
            issuedAt: uint64(vm.getBlockTimestamp()),
            expiresAt: uint64(vm.getBlockTimestamp()) + 86_400
        });
        stake.proposeSlash(a, VoucherSigner.signAttestation(vPk, stake.DOMAIN_SEPARATOR(), a));
    }

    /// Variant A. The attacker executes more of its own records than the key's nominal daily cap
    /// (520 USDG > 500 USDG) first; the honest provider's record, signed by the same key, still
    /// pays at once and in full.
    function test_M1_selfSlashesNoLongerCrowdOutAnotherProvidersSlash() public {
        assertEq(config.params().verifierDailyCap, 500_000_000, "deployed cap");
        _bond(honest, 100_000_000);
        _bond(attacker, 6_000_000_000); // capAllowance 600 USDG per record

        bytes32 victimId = keccak256("victim-1");
        _propose(victimId, honest, victim);
        uint256 n = 520;
        for (uint256 i = 0; i < n; i++) {
            _propose(keccak256(abi.encode("self", i)), attacker, attackerAgent);
        }

        vm.warp(stake.slashRecordOf(victimId).executableAt);
        for (uint256 i = 0; i < n; i++) {
            stake.executeSlash(keccak256(abi.encode("self", i)));
        }
        assertEq(stake.stakeOf(attacker).slashedInWindow, n * PEN, "beyond the old key cap");

        stake.executeSlash(victimId);
        assertEq(uint8(stake.slashRecordOf(victimId).status), uint8(SlashStatus.Executed));
        assertEq(stake.slashRecordOf(victimId).applied, PEN, "paid in full");
        assertEq(usdg.balanceOf(victim), 600_000, "the victim's 60 %");
    }

    /// Variant B, the residual D-25 accepts (the backend refuses self-dealing attestations). A
    /// provider that fills its own window with self-slashes still makes a victim's record
    /// against ITSELF wait; the per-provider window and "all or wait" are unchanged.
    function test_M1_residual_aProviderCanStillCrowdItsOwnWindow() public {
        _bond(attacker, 200_000_000); // capAllowance 20 USDG per record
        bytes32 victimId = keccak256("victim-of-attacker");
        _propose(victimId, attacker, victim);
        for (uint256 i = 0; i < 20; i++) {
            _propose(keccak256(abi.encode("self", i)), attacker, attackerAgent);
        }

        vm.warp(stake.slashRecordOf(victimId).executableAt);
        for (uint256 i = 0; i < 20; i++) {
            stake.executeSlash(keccak256(abi.encode("self", i)));
        }
        vm.expectRevert(SlashWindowNotDrained.selector);
        stake.executeSlash(victimId);
        assertEq(uint8(stake.slashRecordOf(victimId).status), uint8(SlashStatus.Pending));
    }
}
