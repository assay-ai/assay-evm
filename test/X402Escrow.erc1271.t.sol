// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.24;

import {X402EscrowDelegateTest} from "./X402Escrow.delegate.t.sol";
import {GasBurnWallet, HostileWallet, ReturnBombWallet} from "./helpers/HostileWallets.sol";
import {X402Escrow} from "../src/X402Escrow.sol";
import {Voucher} from "../src/Types.sol";
import {Constants} from "../src/Constants.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../src/Errors.sol";

/// Regression tests from the delegation review (S2-1 and S2-3), and the bounds that fix S2-3.
contract X402EscrowErc1271Test is X402EscrowDelegateTest {
    event DelegateUpdated(
        address indexed payer,
        address indexed delegate,
        uint64 maxVoucherAmount,
        uint64 maxPerWindow,
        uint64 validUntil
    );

    /// The backend's redemption gas budget: `EVM_REDEEM_BATCH_BASE_GAS + n * PER_VOUCHER`.
    function _gasFor(uint256 n) internal pure returns (uint256) {
        return 200_000 + 120_000 * n;
    }

    function _armWallet(HostileWallet w) internal {
        _fund(address(w), 5_000_000);
        w.approveToken(IERC20(address(usdg)), address(escrow), 5_000_000);
        w.call(address(escrow), abi.encodeCall(X402Escrow.deposit, (5_000_000)));
        w.call(
            address(escrow),
            abi.encodeCall(X402Escrow.setLimits, (ESCROW_PER_CALL, ESCROW_PER_WINDOW))
        );
    }

    function _batchOf(address wallet)
        internal
        view
        returns (Voucher[] memory vs, bytes[] memory sigs)
    {
        vs = new Voucher[](2);
        sigs = new bytes[](2);
        vs[0] = _v(buyer, 250_000, 1);
        sigs[0] = _signed(buyerKey, vs[0]);
        vs[1] = _v(wallet, 250_000, 1);
        sigs[1] = hex"01"; // anything: the wallet judges
    }

    /// Runs the batch as the redeemer with the backend's budget; returns the revert data.
    function _runBatch(Voucher[] memory vs, bytes[] memory sigs)
        internal
        returns (bool ok, bytes memory ret, uint256 used)
    {
        vm.prank(redeemer);
        uint256 before = gasleft();
        (ok, ret) = address(escrow).call{gas: _gasFor(vs.length)}(
            abi.encodeCall(X402Escrow.redeemVoucherBatch, (vs, sigs))
        );
        used = before - gasleft();
    }

    // --- S2-1: the chain checks validUntil at the REDEMPTION block ------------------------------

    /// The property the backend's margin rests on (review S2-1): a delegate voucher whose expiry
    /// is at `validUntil` is refused when redeemed inside the grace, after `validUntil`. The
    /// off-chain fix (`validUntil >= expiresAt + REDEEM_GRACE_SECONDS`, in `VoucherService`) is
    /// tested in the backend; this pins the chain half it is derived from.
    function test_review_aDelegateVoucherRedeemedInsideTheGraceAfterValidUntilIsRefused() public {
        Voucher memory v = _v(buyer, 250_000, 1);
        vm.prank(buyer);
        escrow.authorizeDelegate(delegate, D_PER_CALL, D_PER_WINDOW, v.expiresAt);
        bytes memory sig = _signed(DELEGATE_KEY, v);
        vm.warp(v.expiresAt + 60);
        _expect(v, sig, DelegateIsExpired.selector);
    }

    function test_review_aDelegationThatOutlivesTheGraceIsHonouredAtItsLastInstant() public {
        Voucher memory v = _v(buyer, 250_000, 1);
        vm.prank(buyer);
        escrow.authorizeDelegate(
            delegate, D_PER_CALL, D_PER_WINDOW, v.expiresAt + Constants.REDEEM_GRACE_SECONDS
        );
        bytes memory sig = _signed(DELEGATE_KEY, v);
        vm.warp(v.expiresAt + Constants.REDEEM_GRACE_SECONDS);
        _redeem(v, sig);
    }

    // --- S2-3: one EIP-1271 wallet must not be able to burn a batch ------------------------------

    /// REGRESSION (review S2-3). Uncapped, a wallet that burns gas received 63/64 of the batch's
    /// gas and ran the whole batch out of it — the honest payer's voucher died with it. Capped, the
    /// wallet burns at most `ERC1271_GAS_LIMIT`; it still answers the magic value, so its own
    /// voucher settles, and the batch settles inside the backend's gas budget.
    function test_review_aGasBurningWalletCannotStarveTheBatch() public {
        GasBurnWallet w = new GasBurnWallet();
        _armWallet(w);
        w.setHostile(true);
        (Voucher[] memory vs, bytes[] memory sigs) = _batchOf(address(w));
        (bool ok,, uint256 used) = _runBatch(vs, sigs);
        assertTrue(ok, "the batch settled");
        assertLt(used, _gasFor(2));
        assertEq(escrow.escrowOf(buyer).seqHigh, 1, "the honest payer was paid");
    }

    /// The single redemption the backend falls back to is bounded the same way.
    function test_review_aGasBurningWalletCostsAtMostItsCapAlone() public {
        GasBurnWallet w = new GasBurnWallet();
        _armWallet(w);
        w.setHostile(true);
        Voucher memory v = _v(address(w), 250_000, 1);
        vm.prank(redeemer);
        uint256 before = gasleft();
        (bool ok,) = address(escrow).call{gas: _gasFor(1)}(
            abi.encodeCall(X402Escrow.redeemVoucher, (v, hex"01"))
        );
        uint256 used = before - gasleft();
        assertTrue(ok);
        assertLt(used, Constants.ERC1271_GAS_LIMIT + 120_000);
    }

    /// A wallet that burns its whole cap and then FAILS is refused by name, never out of gas.
    function test_erc1271_aWalletThatRunsOutOfItsCapIsRefusedByName() public {
        GasBurnWallet w = new GasBurnWallet();
        _armWallet(w);
        w.setHostile(true);
        w.setFail(true);
        (Voucher[] memory vs, bytes[] memory sigs) = _batchOf(address(w));
        (bool ok, bytes memory ret, uint256 used) = _runBatch(vs, sigs);
        assertFalse(ok);
        assertEq(bytes4(ret), SignerIsNotPayer.selector, "refused by name, not out of gas");
        assertLt(used, _gasFor(2));
    }

    /// REGRESSION (review S2-3, the return-data half). `SignatureChecker` copied all of it, so a
    /// wallet returning as much as its gas could pay for made the escrow pay about as much again to
    /// copy it, and the batch ran out of gas. Capped, and with one word copied, the wallet's answer
    /// — still the magic value — settles inside the backend's budget with the honest payer's.
    function test_review_aReturnBombWalletCannotStarveTheBatch() public {
        ReturnBombWallet w = new ReturnBombWallet();
        _armWallet(w);
        w.setHostile(true);
        (Voucher[] memory vs, bytes[] memory sigs) = _batchOf(address(w));
        (bool ok,, uint256 used) = _runBatch(vs, sigs);
        assertTrue(ok, "the batch settled");
        assertLt(used, _gasFor(2));
        assertEq(escrow.escrowOf(buyer).seqHigh, 1, "the honest payer was paid");
        assertEq(escrow.escrowOf(address(w)).seqHigh, 1);
    }

    /// A wallet answering the magic word followed by MORE data is still a valid answer, and only
    /// one word of it is ever copied (it fits the cap because its own memory cost is small).
    function test_erc1271_aMagicWordWithTrailingDataIsValid() public {
        TrailingDataWallet w = new TrailingDataWallet();
        _armWallet(w);
        Voucher memory v = _v(address(w), 250_000, 1);
        _redeem(v, hex"01");
        assertEq(escrow.escrowOf(address(w)).seqHigh, 1);
    }

    /// The cap must never become a false refusal: with too little gas to give the wallet its full
    /// cap, the redemption reverts `WalletCheckUnderfunded` rather than refusing the voucher.
    function test_erc1271_tooLittleGasForTheCapRevertsRatherThanRefuses() public {
        GasBurnWallet w = new GasBurnWallet(); // honest
        _armWallet(w);
        Voucher memory v = _v(address(w), 250_000, 1);
        vm.prank(redeemer);
        (bool ok, bytes memory ret) = address(escrow).call{gas: 120_000}(
            abi.encodeCall(X402Escrow.redeemVoucher, (v, hex"01"))
        );
        assertFalse(ok);
        assertEq(bytes4(ret), WalletCheckUnderfunded.selector);
        assertEq(escrow.escrowOf(address(w)).seqHigh, 0);
    }

    // --- S3-19: an update is not a new grant ------------------------------------------------------

    function test_events_anUpdateEmitsDelegateUpdatedNotDelegateAuthorized() public {
        _authorize(buyer, delegate);
        uint64 until = _until() + 1;
        vm.expectEmit(true, true, false, true, address(escrow));
        emit DelegateUpdated(buyer, delegate, D_PER_CALL, D_PER_WINDOW, until);
        vm.prank(buyer);
        escrow.authorizeDelegate(delegate, D_PER_CALL, D_PER_WINDOW, until);
    }
}

contract TrailingDataWallet is HostileWallet {
    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        assembly ("memory-safe") {
            mstore(0, 0x1626ba7e00000000000000000000000000000000000000000000000000000000)
            mstore(0x20, 0xdead)
            return(0, 0x40)
        }
    }
}
