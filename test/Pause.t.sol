// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.24;

import {Fixture} from "./helpers/Fixture.sol";
import {VoucherSigner} from "./helpers/VoucherSigner.sol";
import {MockPermit2} from "./helpers/MockPermit2.sol";
import {X402Escrow} from "../src/X402Escrow.sol";
import {X402Stake} from "../src/X402Stake.sol";
import {X402Config as X402Config_} from "../src/X402Config.sol";
import {X402EscrowV2} from "./helpers/X402EscrowV2.sol";
import {Voucher, SlashAttestation, ResponseClass} from "../src/Types.sol";
import {Constants} from "../src/Constants.sol";
import "../src/Errors.sol";

/// **The pause matrix, asserted — both halves of it.**
///
/// The `yes` rows are routine. **The `never` rows are the ones that matter:** an admin key that
/// could freeze an owner's exit is exactly what the pause rule was written to prevent,
/// and each of these tests is what stops a future edit adding a `whenNotPaused` where none
/// belongs. `set_paused.rs:14-21` draws the same line: pause stops money coming IN and stops the
/// platform collecting; it never stops an owner taking their own money OUT.
///
/// | Function | Pause closes it? |
/// |---|---|
/// | `X402Escrow.deposit` / `depositFor` / `depositWithPermit2` | **yes** |
/// | `X402Escrow.redeemVoucher` / `redeemVoucherBatch` | **yes** |
/// | `X402Stake.proposeSlash` / `executeSlash` | **yes** |
/// | `X402Escrow.withdraw` | **never** |
/// | `X402Escrow.requestWithdraw` / `requestWithdrawBySig` | **never** |
/// | `X402Escrow.setLimits` / `setLimitsBySig` | **never** |
/// | `X402Stake.depositStake` / `depositStakeFor` | **never** |
/// | `X402Stake.requestUnstake` / `withdrawStake` | **never** |
/// | `X402Stake.cancelSlash` / `expireSlash` | **never** |
/// | `upgradeToAndCall` on any of the three proxies | **never** |
///
/// Two of those rows are worth their reasons in full.
///
/// **`depositStake` is never paused**, matching `deposit_stake.rs`, which has no pause check.
/// Pausing a provider's own top-up would strand exactly the provider trying to cure an
/// under-stake, and a deposit can only ever increase what the provider owns.
///
/// **`upgradeToAndCall` is never paused.** Pause is the first half of an emergency and the
/// upgrade is usually the second; a pause that blocked the fix would be a foot-gun.
/// `_authorizeUpgrade` checks the admin and nothing else (D-1).
contract PauseTest is Fixture {
    uint256 internal verifierKeyPk = 0x7E5717;
    address internal verifierAddr;
    address internal beneficiary = address(0xA6E7);
    uint64 internal constant BOND = 1_000_000_000;

    function setUp() public virtual override {
        super.setUp();
        verifierAddr = vm.addr(verifierKeyPk);

        _fund(buyer, 100_000_000);
        vm.startPrank(buyer);
        usdg.approve(address(escrow), 100_000_000);
        escrow.deposit(50_000_000);
        escrow.setLimits(type(uint64).max, type(uint64).max);
        vm.stopPrank();
    }

    function _pause() internal {
        vm.prank(admin);
        config.setPaused(true);
        assertTrue(config.paused(), "the fixture must actually be paused");
    }

    function _voucher(uint64 seq, uint64 amount) internal view returns (Voucher memory v) {
        v = Voucher({
            payer: buyer,
            provider: provider,
            amount: amount,
            resourceHash: keccak256("r"),
            requestHash: keccak256(abi.encode(seq)),
            seq: seq,
            issuedAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp) + 60
        });
    }

    // === the rows that CLOSE =================================================================

    function test_pauseClosesEveryDepositDoorOnTheEscrow() public {
        MockPermit2 permit2 = new MockPermit2();
        X402Escrow p2Escrow = _deployEscrow(address(permit2));
        _fund(buyer, 10_000_000);
        vm.prank(buyer);
        usdg.approve(address(permit2), 10_000_000);

        _pause();

        vm.prank(buyer);
        vm.expectRevert(ProgramPaused.selector);
        escrow.deposit(1_000_000);

        vm.prank(buyer);
        vm.expectRevert(ProgramPaused.selector);
        escrow.depositFor(buyer, 1_000_000);

        vm.expectRevert(ProgramPaused.selector);
        p2Escrow.depositWithPermit2(buyer, 1_000_000, 0, block.timestamp + 60, hex"00");
    }

    function test_pauseClosesBothRedemptionDoors() public {
        Voucher memory v = _voucher(1, 1_000);
        bytes memory sig = VoucherSigner.signVoucher(buyerKey, escrow.DOMAIN_SEPARATOR(), v);
        Voucher[] memory vs = new Voucher[](1);
        bytes[] memory sigs = new bytes[](1);
        vs[0] = v;
        sigs[0] = sig;

        _pause();

        vm.prank(redeemer);
        vm.expectRevert(ProgramPaused.selector);
        escrow.redeemVoucher(v, sig);

        vm.prank(redeemer);
        vm.expectRevert(ProgramPaused.selector);
        escrow.redeemVoucherBatch(vs, sigs);
    }

    function test_pauseClosesBothSlashDoors() public {
        _stakeAndEnrol();
        SlashAttestation memory a = _att(bytes32("p1"));
        bytes memory sig = VoucherSigner.signAttestation(verifierKeyPk, stake.DOMAIN_SEPARATOR(), a);
        stake.proposeSlash(a, sig);

        SlashAttestation memory b = _att(bytes32("p2"));
        bytes memory bsig =
            VoucherSigner.signAttestation(verifierKeyPk, stake.DOMAIN_SEPARATOR(), b);

        _pause();

        vm.expectRevert(ProgramPaused.selector);
        stake.proposeSlash(b, bsig);

        vm.warp(block.timestamp + Constants.SLASH_DELAY_SECONDS);
        vm.expectRevert(ProgramPaused.selector);
        stake.executeSlash(bytes32("p1"));
    }

    // === the rows that NEVER close ===========================================================

    /// **The extortion row.** A buyer who has asked for their money back gets it while the
    /// program is paused. If this test ever needs changing, the change is wrong.
    function test_pauseNeverClosesTheBuyersExit() public {
        vm.prank(buyer);
        escrow.requestWithdraw(5_000_000);
        uint64 availableAt = escrow.escrowOf(buyer).withdrawAvailableAt;

        _pause();

        vm.warp(availableAt);
        vm.prank(buyer);
        escrow.withdraw();
        assertEq(usdg.balanceOf(buyer), 50_000_000 + 5_000_000, "paid while paused");
    }

    /// Starting the exit clock is also never closed — otherwise pause would merely postpone the
    /// exit by however long the pause lasted, which is the same extortion with an extra step.
    function test_pauseNeverClosesTheRequestThatStartsTheExitClock() public {
        _pause();

        vm.prank(buyer);
        escrow.requestWithdraw(1_000_000);
        assertEq(escrow.escrowOf(buyer).withdrawRequested, 1_000_000);

        // …including the relayed form, which is the door a buyer with no gas has.
        uint64 deadline = uint64(block.timestamp) + 600;
        bytes memory sig = VoucherSigner.signRequestWithdraw(
            buyerKey, escrow.DOMAIN_SEPARATOR(), buyer, 2_000_000, 0, deadline
        );
        escrow.requestWithdrawBySig(buyer, 2_000_000, 0, deadline, sig);
        assertEq(escrow.escrowOf(buyer).withdrawRequested, 2_000_000);
    }

    /// A buyer LOWERING their own ceiling while paused must not be blocked: it is the one control
    /// a buyer has over an escrow they suspect, and `set_paused.rs:14-21` puts it on the same side
    /// of the line as the exit.
    function test_pauseNeverClosesTheBuyersOwnLimits() public {
        _pause();

        vm.prank(buyer);
        escrow.setLimits(1, 2);
        assertEq(escrow.escrowOf(buyer).maxVoucherAmount, 1);

        uint64 deadline = uint64(block.timestamp) + 600;
        bytes memory sig = VoucherSigner.signSetLimits(
            buyerKey, escrow.DOMAIN_SEPARATOR(), buyer, 3, 4, 0, deadline
        );
        escrow.setLimitsBySig(buyer, 3, 4, 0, deadline, sig);
        assertEq(escrow.escrowOf(buyer).maxPerWindow, 4);
    }

    /// Parity with `deposit_stake.rs`, which has no pause check: pausing a provider's own top-up
    /// would strand the provider trying to CURE an under-stake, and a deposit can only ever
    /// increase what the provider owns.
    function test_pauseNeverClosesAProvidersOwnStakeTopUp() public {
        _stakeAndEnrol();
        _pause();

        _fund(provider, 1_000_000);
        vm.startPrank(provider);
        usdg.approve(address(stake), 1_000_000);
        stake.depositStake(1_000_000);
        vm.stopPrank();

        _fund(address(this), 1_000_000);
        usdg.approve(address(stake), 1_000_000);
        stake.depositStakeFor(provider, 1_000_000);

        assertEq(stake.bondedOf(provider), BOND + 2_000_000);
    }

    /// The provider's exit, the mirror of the buyer's.
    function test_pauseNeverClosesTheProvidersExit() public {
        _stakeAndEnrol();
        _pause();

        vm.prank(provider);
        stake.requestUnstake(BOND);
        vm.warp(block.timestamp + config.params().unbondingPeriodSeconds);
        vm.prank(provider);
        stake.withdrawStake(BOND);
        assertEq(usdg.balanceOf(provider), BOND);
    }

    /// **Releasing a hold is never closed either**, and it is the subtlest row: a pause that
    /// closed `cancelSlash` and `expireSlash` while leaving `proposeSlash`'s reservation standing
    /// would leave a provider's collateral held by a judgement that can no longer be executed OR
    /// released — a hold with no exit, created by the same key that paused.
    function test_pauseNeverClosesTheTwoWaysAHoldIsReleased() public {
        _stakeAndEnrol();
        SlashAttestation memory a = _att(bytes32("c1"));
        stake.proposeSlash(
            a, VoucherSigner.signAttestation(verifierKeyPk, stake.DOMAIN_SEPARATOR(), a)
        );
        SlashAttestation memory b = _att(bytes32("c2"));
        stake.proposeSlash(
            b, VoucherSigner.signAttestation(verifierKeyPk, stake.DOMAIN_SEPARATOR(), b)
        );

        _pause();

        vm.prank(admin);
        stake.cancelSlash(bytes32("c1"));

        vm.warp(
            block.timestamp + Constants.SLASH_DELAY_SECONDS
                + Constants.SLASH_EXECUTION_GRACE_SECONDS
        );
        stake.expireSlash(bytes32("c2"));

        assertEq(stake.stakeOf(provider).pendingSlash, 0, "both holds released while paused");
    }

    /// **Pause is the first half of an emergency; the upgrade is usually the second.** A pause
    /// that blocked the fix would be a foot-gun, so all three proxies stay upgradeable while
    /// paused — `_authorizeUpgrade` checks the admin and nothing else (D-1).
    function test_pauseNeverClosesTheUpgradeDoorOnAnyOfTheThree() public {
        _pause();

        address escrowV2 = address(new X402EscrowV2());
        address stakeV2 = address(new X402Stake());

        vm.prank(admin);
        escrow.upgradeToAndCall(escrowV2, "");
        vm.prank(admin);
        stake.upgradeToAndCall(stakeV2, "");

        // Config last: upgrading it is what an operator would reach for to change `paused`
        // itself, so a pause that closed this door would be unrecoverable without a redeploy.
        address configV2 = address(new X402Config_());
        vm.prank(admin);
        config.upgradeToAndCall(configV2, "");

        assertTrue(config.paused(), "still paused, and all three moved");
        assertEq(X402EscrowV2(address(escrow)).version2(), "v2");
    }

    /// And `setPaused` itself is not self-locking: the admin can lift it. Trivially true, and
    /// asserted anyway, because "paused" that could not be unset is a different contract.
    function test_pauseCanAlwaysBeLifted() public {
        _pause();
        vm.prank(admin);
        config.setPaused(false);
        assertFalse(config.paused());

        vm.prank(buyer);
        escrow.deposit(1_000_000); // the door that was closed is open again
    }

    function _stakeAndEnrol() internal {
        stake = _deployStake(address(usdg));
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

    function _att(bytes32 requestId) internal view returns (SlashAttestation memory) {
        return SlashAttestation({
            requestId: requestId,
            provider: provider,
            beneficiary: beneficiary,
            status: uint8(ResponseClass.DataFail),
            penalty: 1_000_000,
            policy: keccak256("policy v1"),
            issuedAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp) + 3 * 86_400
        });
    }
}
