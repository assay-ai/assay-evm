// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.24;

import {Fixture} from "./helpers/Fixture.sol";
import {VoucherSigner} from "./helpers/VoucherSigner.sol";
import {Voucher} from "../src/Types.sol";
import "../src/Errors.sol";

/// `AssayConfig.blocked`, at every door it closes and the two it deliberately leaves open
/// (`revokeDelegate` and `disputeSlash`, the latter in `AssayStake.dispute.t.sol`).
///
/// Not `test/fork/Blocklist.fork.t.sol`, which is about the USDG token's OWN blocklist.
contract AddressBlocklistTest is Fixture {
    address internal arbiter = address(0xA4B1);
    uint256 internal delegateKey = 0xDE1E6A7E;
    address internal delegate;
    address internal funder = address(0xF0DE);
    uint64 internal constant BOND = 1_000_000_000;

    function setUp() public virtual override {
        super.setUp();
        delegate = vm.addr(delegateKey);
        vm.prank(admin);
        config.setArbiter(arbiter);

        _fund(buyer, 100_000_000);
        vm.startPrank(buyer);
        usdg.approve(address(escrow), type(uint256).max);
        escrow.deposit(50_000_000);
        escrow.setLimits(10_000_000, 50_000_000);
        escrow.authorizeDelegate(delegate, 1_000_000, 2_000_000, uint64(block.timestamp) + 86_400);
        vm.stopPrank();
    }

    function _block(address who) internal {
        vm.prank(arbiter);
        config.setBlocked(who, true);
    }

    function _voucher(uint64 seq) internal view returns (Voucher memory) {
        return Voucher({
            payer: buyer,
            provider: provider,
            amount: 1_000,
            resourceHash: keccak256("r"),
            requestHash: keccak256(abi.encode(seq)),
            seq: seq,
            issuedAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp) + 60
        });
    }

    function _redeemExpect(Voucher memory v, uint256 pk, bytes4 err) internal {
        bytes memory sig = VoucherSigner.signVoucher(pk, escrow.DOMAIN_SEPARATOR(), v);
        Voucher[] memory vs = new Voucher[](1);
        bytes[] memory sigs = new bytes[](1);
        vs[0] = v;
        sigs[0] = sig;
        vm.prank(redeemer);
        vm.expectRevert(err);
        escrow.redeemVoucher(v, sig);
        vm.prank(redeemer);
        vm.expectRevert(err);
        escrow.redeemVoucherBatch(vs, sigs);
    }

    // === escrow ==============================================================================

    function test_aBlockedBuyerCannotBeFundedAndABlockedFunderCannotFund() public {
        _block(buyer);
        vm.prank(buyer);
        vm.expectRevert(AddressBlocked.selector);
        escrow.deposit(1_000_000);

        _fund(funder, 1_000_000);
        vm.startPrank(funder);
        usdg.approve(address(escrow), 1_000_000);
        vm.expectRevert(AddressBlocked.selector);
        escrow.depositFor(buyer, 1_000_000);
        vm.stopPrank();

        _block(funder);
        vm.prank(funder);
        vm.expectRevert(AddressBlocked.selector);
        escrow.depositFor(address(0xC1EA), 1_000_000);
    }

    function test_redemptionRefusesABlockedPayerPayeeOrDelegate() public {
        // Control: both signers redeem while nobody is blocked.
        Voucher memory ok = _voucher(1);
        bytes memory okSig = VoucherSigner.signVoucher(buyerKey, escrow.DOMAIN_SEPARATOR(), ok);
        vm.prank(redeemer);
        escrow.redeemVoucher(ok, okSig);

        _block(delegate);
        _redeemExpect(_voucher(2), delegateKey, AddressBlocked.selector);
        // The payer's own signature is unaffected by a blocked delegate.
        Voucher memory own = _voucher(2);
        bytes memory ownSig = VoucherSigner.signVoucher(buyerKey, escrow.DOMAIN_SEPARATOR(), own);
        vm.prank(redeemer);
        escrow.redeemVoucher(own, ownSig);

        _block(provider);
        _redeemExpect(_voucher(3), buyerKey, AddressBlocked.selector);

        vm.prank(admin);
        config.setBlocked(provider, false);
        _block(buyer);
        _redeemExpect(_voucher(3), buyerKey, AddressBlocked.selector);
        assertEq(escrow.escrowOf(buyer).seqHigh, 2, "nothing past the block landed");
    }

    function test_aBlockedBuyerCannotExitOrChangeItsControls() public {
        vm.prank(buyer);
        escrow.requestWithdraw(5_000_000);
        uint64 availableAt = escrow.escrowOf(buyer).withdrawAvailableAt;
        uint64 n = escrow.escrowOf(buyer).authNonce;
        uint64 deadline = uint64(block.timestamp) + 600;
        bytes32 sep = escrow.DOMAIN_SEPARATOR();
        bytes memory rwSig = VoucherSigner.signRequestWithdraw(buyerKey, sep, buyer, 1, n, deadline);
        bytes memory slSig = VoucherSigner.signSetLimits(buyerKey, sep, buyer, 3, 4, n, deadline);
        uint64 until = uint64(block.timestamp) + 86_400;
        bytes memory adSig = VoucherSigner.signAuthorizeDelegate(
            buyerKey, sep, buyer, address(0xDE22), 1, 2, until, n, deadline
        );

        _block(buyer);
        vm.warp(availableAt);

        vm.startPrank(buyer);
        vm.expectRevert(AddressBlocked.selector);
        escrow.withdraw();
        vm.expectRevert(AddressBlocked.selector);
        escrow.requestWithdraw(1);
        vm.expectRevert(AddressBlocked.selector);
        escrow.setLimits(1, 2);
        vm.expectRevert(AddressBlocked.selector);
        escrow.authorizeDelegate(address(0xDE22), 1, 2, until);
        vm.stopPrank();
        vm.expectRevert(AddressBlocked.selector);
        escrow.requestWithdrawBySig(buyer, 1, n, deadline, rwSig);
        vm.expectRevert(AddressBlocked.selector);
        escrow.setLimitsBySig(buyer, 3, 4, n, deadline, slSig);
        vm.expectRevert(AddressBlocked.selector);
        escrow.authorizeDelegateBySig(buyer, address(0xDE22), 1, 2, until, n, deadline, adSig);

        // Nothing moved, and the unblock reopens the exit with the same balance.
        assertEq(escrow.escrowOf(buyer).balance, 50_000_000);
        vm.prank(admin);
        config.setBlocked(buyer, false);
        vm.prank(buyer);
        escrow.withdraw();
        assertEq(usdg.balanceOf(buyer), 50_000_000 + 5_000_000);
    }

    function test_aBlockedAddressCannotBeMadeADelegate() public {
        address d = address(0xDE33);
        _block(d);
        vm.prank(buyer);
        vm.expectRevert(AddressBlocked.selector);
        escrow.authorizeDelegate(d, 1, 2, uint64(block.timestamp) + 86_400);
    }

    /// Revoking only removes authority, so a blocked payer may always do it, in either form.
    function test_aBlockedBuyerMayStillRevokeADelegate() public {
        address d2 = address(0xDE44);
        vm.prank(buyer);
        escrow.authorizeDelegate(d2, 1, 2, uint64(block.timestamp) + 86_400);
        uint64 n = escrow.escrowOf(buyer).authNonce + 1;
        uint64 deadline = uint64(block.timestamp) + 600;
        bytes memory sig = VoucherSigner.signRevokeDelegate(
            buyerKey, escrow.DOMAIN_SEPARATOR(), buyer, d2, n, deadline
        );

        _block(buyer);
        vm.prank(buyer);
        escrow.revokeDelegate(delegate);
        escrow.revokeDelegateBySig(buyer, d2, n, deadline, sig);
        assertEq(escrow.delegatesOf(buyer).length, 0);
    }

    // === stake ===============================================================================

    function test_aBlockedProviderCannotStakeOrExit() public {
        stake = _deployStake(address(usdg));
        _fund(provider, BOND + 1_000_000);
        vm.startPrank(provider);
        usdg.approve(address(stake), type(uint256).max);
        stake.depositStake(BOND);
        stake.requestUnstake(BOND / 2);
        vm.stopPrank();
        vm.warp(block.timestamp + config.params().unbondingPeriodSeconds);

        _block(provider);
        vm.startPrank(provider);
        vm.expectRevert(AddressBlocked.selector);
        stake.depositStake(1_000_000);
        vm.expectRevert(AddressBlocked.selector);
        stake.requestUnstake(1);
        vm.expectRevert(AddressBlocked.selector);
        stake.withdrawStake(1);
        vm.stopPrank();

        _fund(funder, 1_000_000);
        vm.startPrank(funder);
        usdg.approve(address(stake), 1_000_000);
        vm.expectRevert(AddressBlocked.selector);
        stake.depositStakeFor(provider, 1_000_000);
        vm.stopPrank();

        // A blocked funder cannot fund an unblocked provider either.
        _block(funder);
        vm.prank(funder);
        vm.expectRevert(AddressBlocked.selector);
        stake.depositStakeFor(address(0x9310), 1_000_000);

        // Nothing moved; the unblock reopens the exit.
        assertEq(stake.stakeOf(provider).unbonding, BOND / 2);
        vm.prank(admin);
        config.setBlocked(provider, false);
        vm.prank(provider);
        stake.withdrawStake(BOND / 2);
        assertEq(stake.stakeOf(provider).unbonding, 0);
    }

    /// F3 (documented scope): the blocklist binds the buyer, not the relayer that lands its
    /// signature.
    function test_review_F3_aBlockedRelayerStillRelaysForAnUnblockedBuyer() public {
        address relayer = address(0xBADBAD);
        vm.prank(admin);
        config.setBlocked(relayer, true);
        uint64 n = escrow.escrowOf(buyer).authNonce;
        uint64 deadline = uint64(block.timestamp) + 600;
        bytes memory rwSig = VoucherSigner.signRequestWithdraw(
            buyerKey, escrow.DOMAIN_SEPARATOR(), buyer, 1, n, deadline
        );
        vm.prank(relayer);
        escrow.requestWithdrawBySig(buyer, 1, n, deadline, rwSig);
        assertEq(escrow.escrowOf(buyer).withdrawRequested, 1);
    }
}
