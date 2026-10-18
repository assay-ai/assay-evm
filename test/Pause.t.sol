// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.24;

import {Fixture} from "./helpers/Fixture.sol";
import {VoucherSigner} from "./helpers/VoucherSigner.sol";
import {X402Escrow} from "../src/X402Escrow.sol";
import {X402Stake} from "../src/X402Stake.sol";
import {X402Config as X402Config_} from "../src/X402Config.sol";
import {X402EscrowV2} from "./helpers/X402EscrowV2.sol";
import {Voucher, SlashAttestation, ResponseClass} from "../src/Types.sol";
import {Constants} from "../src/Constants.sol";
import "../src/Errors.sol";

/// **The pause matrix, asserted — both halves of it.**
///
/// **The rule changed in the dispute upgrade, by the owner's explicit decision.** Until then the
/// owner exits (`withdraw`, `requestWithdraw`, `setLimits`, the stake top-up and exit) were
/// pinned here as **never** paused, after `set_paused.rs`. They are now closed by the
/// pause too. What stays open is what only reduces risk or releases a hold. The pause still
/// moves nobody's money — there is no seize and no sweep — so every closed exit reopens on
/// unpause with its balance untouched (`test_aPausedExitReopensWithTheBalanceUntouched`).
///
/// | Function | Pause closes it? |
/// |---|---|
/// | `X402Escrow.deposit` / `depositFor` | **yes** |
/// | `X402Escrow.redeemVoucher` / `redeemVoucherBatch` | **yes** |
/// | `X402Escrow.withdraw` / `requestWithdraw` / `requestWithdrawBySig` | **yes** (since the dispute upgrade) |
/// | `X402Escrow.setLimits` / `setLimitsBySig` | **yes** (since the dispute upgrade) |
/// | `X402Escrow.authorizeDelegate` / `authorizeDelegateBySig` | **yes** (since the dispute upgrade) |
/// | `X402Stake.depositStake` / `depositStakeFor` | **yes** (since the dispute upgrade) |
/// | `X402Stake.requestUnstake` / `withdrawStake` | **yes** (since the dispute upgrade) |
/// | `X402Stake.proposeSlash` / `executeSlash` | **yes** |
/// | `X402Escrow.revokeDelegate` / `revokeDelegateBySig` | **never** |
/// | `X402Stake.disputeSlash` / `upholdSlash` / `cancelSlash` / `expireSlash` | **never** |
/// | the config roles' own calls, and `upgradeToAndCall` on any of the three proxies | **never** |
///
/// **`upgradeToAndCall` is never paused.** Pause is the first half of an emergency and the
/// upgrade is usually the second; a pause that blocked the fix would be a foot-gun.
/// `_authorizeUpgrade` checks the owner and nothing else (D-1, D-17).
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
        _fund(buyer, 10_000_000);

        _pause();

        vm.prank(buyer);
        vm.expectRevert(ProgramPaused.selector);
        escrow.deposit(1_000_000);

        vm.prank(buyer);
        vm.expectRevert(ProgramPaused.selector);
        escrow.depositFor(buyer, 1_000_000);
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

    /// The exit and the buyer's own controls, closed since the dispute upgrade.
    function test_pauseClosesTheBuyersExitAndControls() public {
        vm.prank(buyer);
        escrow.requestWithdraw(5_000_000);
        uint64 availableAt = escrow.escrowOf(buyer).withdrawAvailableAt;
        uint64 n = escrow.escrowOf(buyer).authNonce;
        uint64 deadline = uint64(block.timestamp) + 600;
        bytes memory rwSig = VoucherSigner.signRequestWithdraw(
            buyerKey, escrow.DOMAIN_SEPARATOR(), buyer, 2_000_000, n, deadline
        );
        bytes memory slSig = VoucherSigner.signSetLimits(
            buyerKey, escrow.DOMAIN_SEPARATOR(), buyer, 3, 4, n, deadline
        );
        address delegate = address(0xDE1E);
        uint64 until = uint64(block.timestamp) + 86_400;
        bytes memory adSig = VoucherSigner.signAuthorizeDelegate(
            buyerKey, escrow.DOMAIN_SEPARATOR(), buyer, delegate, 1, 2, until, n, deadline
        );

        _pause();
        vm.warp(availableAt);

        vm.startPrank(buyer);
        vm.expectRevert(ProgramPaused.selector);
        escrow.withdraw();
        vm.expectRevert(ProgramPaused.selector);
        escrow.requestWithdraw(1_000_000);
        vm.expectRevert(ProgramPaused.selector);
        escrow.setLimits(1, 2);
        vm.expectRevert(ProgramPaused.selector);
        escrow.authorizeDelegate(delegate, 1, 2, until);
        vm.stopPrank();

        vm.expectRevert(ProgramPaused.selector);
        escrow.requestWithdrawBySig(buyer, 2_000_000, n, deadline, rwSig);
        vm.expectRevert(ProgramPaused.selector);
        escrow.setLimitsBySig(buyer, 3, 4, n, deadline, slSig);
        vm.expectRevert(ProgramPaused.selector);
        escrow.authorizeDelegateBySig(buyer, delegate, 1, 2, until, n, deadline, adSig);
    }

    /// Every stake door except the four slash-lifecycle releases, closed.
    function test_pauseClosesEveryStakeDoor() public {
        _stakeAndEnrol();
        vm.prank(provider);
        stake.requestUnstake(BOND / 2);
        _fund(provider, 1_000_000);
        vm.prank(provider);
        usdg.approve(address(stake), 1_000_000);

        _pause();
        vm.warp(block.timestamp + config.params().unbondingPeriodSeconds);

        vm.startPrank(provider);
        vm.expectRevert(ProgramPaused.selector);
        stake.depositStake(1_000_000);
        vm.expectRevert(ProgramPaused.selector);
        stake.depositStakeFor(provider, 1_000_000);
        vm.expectRevert(ProgramPaused.selector);
        stake.requestUnstake(1);
        vm.expectRevert(ProgramPaused.selector);
        stake.withdrawStake(1);
        vm.stopPrank();
    }

    /// **Pause never moves the money.** Both exits refused while paused land in full after the
    /// unpause, from the same balances.
    function test_aPausedExitReopensWithTheBalanceUntouched() public {
        _stakeAndEnrol();
        vm.prank(buyer);
        escrow.requestWithdraw(5_000_000);
        vm.prank(provider);
        stake.requestUnstake(BOND);

        _pause();
        vm.warp(block.timestamp + config.params().unbondingPeriodSeconds);
        vm.prank(buyer);
        vm.expectRevert(ProgramPaused.selector);
        escrow.withdraw();
        assertEq(escrow.escrowOf(buyer).balance, 50_000_000, "the escrow balance is untouched");
        assertEq(stake.stakeOf(provider).unbonding, BOND, "the stake is untouched");

        vm.prank(admin);
        config.setPaused(false);
        vm.prank(buyer);
        escrow.withdraw();
        vm.prank(provider);
        stake.withdrawStake(BOND);
        assertEq(usdg.balanceOf(buyer), 50_000_000 + 5_000_000);
        assertEq(usdg.balanceOf(provider), BOND);
    }

    // === the rows that NEVER close ===========================================================

    /// Revoking a delegate only removes authority, so the pause never closes it, in either form.
    function test_pauseNeverClosesTheDelegateRevocation() public {
        address d1 = address(0xDE11);
        address d2 = address(0xDE12);
        uint64 until = uint64(block.timestamp) + 86_400;
        vm.startPrank(buyer);
        escrow.authorizeDelegate(d1, 1, 2, until);
        escrow.authorizeDelegate(d2, 1, 2, until);
        vm.stopPrank();

        uint64 n = escrow.escrowOf(buyer).authNonce + 1; // the direct revoke below consumes one
        uint64 deadline = uint64(block.timestamp) + 600;
        bytes memory sig = VoucherSigner.signRevokeDelegate(
            buyerKey, escrow.DOMAIN_SEPARATOR(), buyer, d2, n, deadline
        );

        _pause();
        vm.prank(buyer);
        escrow.revokeDelegate(d1);
        escrow.revokeDelegateBySig(buyer, d2, n, deadline, sig);
        assertEq(escrow.delegatesOf(buyer).length, 0);
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
    /// paused — `_authorizeUpgrade` checks the owner and nothing else (D-1, D-17).
    function test_pauseNeverClosesTheUpgradeDoorOnAnyOfTheThree() public {
        _pause();

        address escrowV2 = address(new X402EscrowV2());
        address stakeV2 = address(new X402Stake());

        vm.prank(owner);
        escrow.upgradeToAndCall(escrowV2, "");
        vm.prank(owner);
        stake.upgradeToAndCall(stakeV2, "");

        // Config last: upgrading it is what an operator would reach for to change `paused`
        // itself, so a pause that closed this door would be unrecoverable without a redeploy.
        address configV2 = address(new X402Config_());
        vm.prank(owner);
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
