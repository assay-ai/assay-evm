// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.24;

import {Fixture} from "../../helpers/Fixture.sol";
import {VoucherSigner} from "../../helpers/VoucherSigner.sol";
import {X402Stake} from "../../../src/X402Stake.sol";
import {SlashAttestation, ResponseClass, SlashStatus, ParamSet} from "../../../src/Types.sol";
import "../../../src/Errors.sol";

/// Audit D (property-based audit of `a4f97ab`): the minimal reproductions of the invariant
/// violations `SystemInvariantsTest` found, INVERTED into regressions after the fixes — each now
/// asserts the refusal. AD-3 is an accepted Info (owner decision: skipped) and still documents
/// the limitation as found.
contract AuditDFindingsTest is Fixture {
    uint256 internal constant VERIFIER_PK = 0x7E5717;
    uint256 internal constant ARB_PK = 0xA4B1A4B1;
    address internal arb;
    address internal beneficiary = address(0xA6E7);

    function setUp() public override {
        super.setUp();
        stake = _deployStake(address(usdg));
        arb = vm.addr(ARB_PK);
        vm.startPrank(admin);
        config.registerVerifier(
            vm.addr(VERIFIER_PK), bytes32("v"), uint64(block.timestamp) + 180 days
        );
        config.setArbiter(arb);
        vm.stopPrank();
        _fund(provider, 1_000_000_000);
        vm.startPrank(provider);
        usdg.approve(address(stake), 1_000_000_000);
        stake.depositStake(1_000_000_000);
        vm.stopPrank();
    }

    function _attestation(bytes32 id) internal view returns (SlashAttestation memory) {
        return SlashAttestation({
            requestId: id,
            provider: provider,
            beneficiary: beneficiary,
            status: uint8(ResponseClass.DataFail),
            penalty: 1_000_000,
            policy: keccak256("policy"),
            issuedAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp) + 1 days
        });
    }

    /// AD-1 (invariant_arbiterIsNeverALiveVerifier): `registerVerifier` now refuses the
    /// current arbiter, so the arbiter can never propose a slash alone.
    function test_regression_AD1_registerVerifierRefusesTheCurrentArbiter() public {
        vm.prank(admin);
        vm.expectRevert(VerifierIsAdminOrArbiter.selector);
        config.registerVerifier(arb, bytes32("oops"), uint64(block.timestamp) + 30 days);
        assertFalse(config.canSign(arb), "the arbiter is not a verifier");

        SlashAttestation memory a = _attestation("ad1");
        bytes memory sig = VoucherSigner.signAttestation(ARB_PK, stake.DOMAIN_SEPARATOR(), a);
        vm.expectRevert(VerifierNotRegistered.selector);
        stake.proposeSlash(a, sig);
    }

    /// AD-2 (invariant_arbiterIsNeverTheAdmin): `setAdmin` now refuses the current arbiter.
    function test_regression_AD2_setAdminRefusesTheCurrentArbiter() public {
        vm.prank(owner);
        vm.expectRevert(InvalidAdmin.selector);
        config.setAdmin(arb);
        assertTrue(config.admin() != config.arbiter());

        vm.startPrank(arb);
        config.setBlocked(buyer, true);
        vm.expectRevert(ArbiterCannotUnblock.selector);
        config.setBlocked(buyer, false);
        vm.stopPrank();
        assertTrue(config.blocked(buyer));
    }

    /// AD-1b: the redeemer (a server key) is never the arbiter, from either side.
    function test_regression_AD1b_theArbiterIsNeverTheRedeemer() public {
        ParamSet memory p = config.params();
        p.redeemer = arb;
        vm.prank(admin);
        vm.expectRevert(RedeemerIsArbiter.selector);
        config.updateConfig(p, address(0));

        address r = config.params().redeemer;
        vm.prank(admin);
        vm.expectRevert(InvalidArbiter.selector);
        config.setArbiter(r);
    }

    /// AD-3 (info, arithmetic, ACCEPTED — not fixed by owner decision): `proposeSlash` narrows `atRisk * slashCapBps / 10_000` with
    /// `Cast.toUint64`, so a provider whose at-risk stake exceeds `2^64 * 10_000 / slashCapBps`
    /// base units can no longer be slashed at all (MathOverflow). At the 50% cap that is 2^65
    /// units (~3.7e13 USDG) — unreachable with real supply, noted for completeness.
    function test_repro_AD3_aHugeStakeIsUnslashable() public {
        ParamSet memory p = config.params();
        p.slashCapBps = 5_000;
        vm.prank(admin);
        config.updateConfig(p, address(0));
        address whale = address(0x3A1E);
        for (uint256 i = 0; i < 3; i++) {
            _fund(address(this), type(uint64).max);
            usdg.approve(address(stake), type(uint64).max);
            stake.depositStakeFor(whale, type(uint64).max);
        }
        SlashAttestation memory a = _attestation("ad3");
        a.provider = whale;
        bytes memory sig = VoucherSigner.signAttestation(VERIFIER_PK, stake.DOMAIN_SEPARATOR(), a);
        vm.expectRevert(MathOverflow.selector);
        stake.proposeSlash(a, sig);
    }
}
