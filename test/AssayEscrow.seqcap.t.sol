// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.24;

import {Fixture} from "./helpers/Fixture.sol";
import {VoucherSigner} from "./helpers/VoucherSigner.sol";
import {Voucher} from "../src/Types.sol";
import {Constants} from "../src/Constants.sol";
import "../src/Errors.sol";

/// D-17: the seq jump cap. A redeemed voucher above the mark needs `seq <= seqHigh + MAX_SEQ_GAP`,
/// a CONSTANT (1,000,000), on the single and batch paths and for every signer kind. Without it
/// one voucher at `2^64 - 1` leaves the backend's allocator nothing to issue above `seqHigh`.
contract AssayEscrowSeqCapTest is Fixture {
    uint256 internal constant DELEGATE_KEY = 0xDE1E6A7E;
    uint64 internal constant GAP = 1_000_000;
    bytes32 internal ds;
    address internal delegate;

    function setUp() public override {
        super.setUp();
        ds = escrow.DOMAIN_SEPARATOR();
        delegate = vm.addr(DELEGATE_KEY);
        _fund(buyer, 100_000_000);
        vm.startPrank(buyer);
        usdg.approve(address(escrow), type(uint256).max);
        escrow.deposit(100_000_000);
        escrow.setLimits(10_000_000, 50_000_000);
        escrow.authorizeDelegate(delegate, 1_000_000, 10_000_000, uint64(block.timestamp + 30 days));
        vm.stopPrank();
    }

    function _v(uint64 seq) internal view returns (Voucher memory) {
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

    function _redeem(uint64 seq, uint256 key) internal {
        Voucher memory v = _v(seq);
        vm.prank(redeemer);
        escrow.redeemVoucher(v, VoucherSigner.signVoucher(key, ds, v));
    }

    function _refused(uint64 seq, uint256 key) internal {
        Voucher memory v = _v(seq);
        bytes memory sig = VoucherSigner.signVoucher(key, ds, v);
        vm.prank(redeemer);
        vm.expectRevert(VoucherSeqGapTooLarge.selector);
        escrow.redeemVoucher(v, sig);
    }

    function test_theCapIsAConstantOfOneMillion() public pure {
        assertEq(Constants.MAX_SEQ_GAP, GAP);
    }

    /// From a fresh escrow (`seqHigh == 0`): `GAP` is admitted, `GAP + 1` is not.
    function test_boundary_aFreshEscrowAdmitsExactlyTheGap() public {
        _refused(GAP + 1, buyerKey);
        assertEq(escrow.escrowOf(buyer).seqHigh, 0, "a refusal consumes nothing");
        _redeem(GAP, buyerKey);
        assertEq(escrow.escrowOf(buyer).seqHigh, GAP);
    }

    /// From a moved high-water mark: `seqHigh + GAP` is admitted, `+ 1` is not, and the cap
    /// slides with the mark.
    function test_boundary_theCapIsRelativeToTheCurrentHighWaterMark() public {
        _redeem(500, buyerKey);
        _refused(500 + GAP + 1, buyerKey);
        _redeem(500 + GAP, buyerKey);
        _refused(500 + 2 * GAP + 1, buyerKey);
        _redeem(500 + 2 * GAP, buyerKey);
    }

    /// The brick this exists to stop: `seq = 2^64 - 1` is refused, for the payer's own key and
    /// for a delegate's.
    function test_theTopOfTheTypeIsRefusedForEverySignerKind() public {
        _refused(type(uint64).max, buyerKey);
        _refused(type(uint64).max, DELEGATE_KEY);
        _refused(GAP + 1, DELEGATE_KEY);
        _redeem(GAP, DELEGATE_KEY);
        assertEq(escrow.escrowOf(buyer).seqHigh, GAP);
    }

    /// The batch path applies the same per-escrow rule item by item, and one over-gap item
    /// reverts the whole (atomic) batch.
    function test_theBatchPathRefusesAnOverGapItem() public {
        Voucher[] memory vs = new Voucher[](2);
        bytes[] memory sigs = new bytes[](2);
        vs[0] = _v(1);
        vs[1] = _v(1 + GAP + 1);
        sigs[0] = VoucherSigner.signVoucher(buyerKey, ds, vs[0]);
        sigs[1] = VoucherSigner.signVoucher(DELEGATE_KEY, ds, vs[1]);
        vm.prank(redeemer);
        vm.expectRevert(VoucherSeqGapTooLarge.selector);
        escrow.redeemVoucherBatch(vs, sigs);
        assertEq(escrow.escrowOf(buyer).seqHigh, 0);

        vs[1] = _v(1 + GAP);
        sigs[1] = VoucherSigner.signVoucher(DELEGATE_KEY, ds, vs[1]);
        vm.prank(redeemer);
        escrow.redeemVoucherBatch(vs, sigs);
        assertEq(escrow.escrowOf(buyer).seqHigh, 1 + GAP);
    }

    /// Fuzzed over the mark and the jump: admitted iff `0 < seq - seqHigh <= GAP`.
    function testFuzz_admittedIffWithinTheGap(uint64 first, uint64 jump) public {
        first = uint64(bound(first, 1, GAP));
        _redeem(first, buyerKey);
        jump = uint64(bound(jump, 1, type(uint64).max - first));
        uint64 seq = first + jump;
        Voucher memory v = _v(seq);
        bytes memory sig = VoucherSigner.signVoucher(buyerKey, ds, v);
        vm.prank(redeemer);
        if (jump > GAP) {
            vm.expectRevert(VoucherSeqGapTooLarge.selector);
            escrow.redeemVoucher(v, sig);
            assertEq(escrow.escrowOf(buyer).seqHigh, first);
        } else {
            escrow.redeemVoucher(v, sig);
            assertEq(escrow.escrowOf(buyer).seqHigh, seq);
        }
    }

    /// The order: the cap is checked after the used-seq check (D-23), only above the mark (so
    /// the subtraction cannot wrap), and before the signature, like the rest of the seq rule.
    function test_theCapSitsBesideTheUsedSeqCheckInTheSource() public view {
        string memory src = vm.readFile(string.concat(vm.projectRoot(), "/src/AssayEscrow.sol"));
        bytes memory h = bytes(src);
        bytes memory n = bytes(
            "        if (heldPayments[v.payer][v.seq].status != HeldStatus.None) revert VoucherSeqUsed();\n        // D-17: the jump cap, now only on a seq above the high-water mark; the guard is what\n        // keeps the subtraction from wrapping.\n        if (v.seq > e.seqHigh && v.seq - e.seqHigh > Constants.MAX_SEQ_GAP) {\n            revert VoucherSeqGapTooLarge();\n        }\n"
        );
        uint256 found;
        for (uint256 i = 0; i + n.length <= h.length; i++) {
            uint256 j = 0;
            while (j < n.length && h[i + j] == n[j]) j++;
            if (j == n.length) found++;
        }
        assertEq(found, 1);
    }
}
