// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {ChannelHandler} from "./ChannelHandler.sol";
import {AssayEscrow} from "../../src/AssayEscrow.sol";
import {IAssayEscrow} from "../../src/interfaces/IAssayEscrow.sol";
import {ChannelDoor} from "../../src/libraries/ChannelDoor.sol";

/// Invariants of the channel door, driven together with the per-call door (spec §2).
contract ChannelInvariantsTest is Test {
    ChannelHandler internal h;

    function setUp() public {
        h = new ChannelHandler();
        bytes4[] memory s = new bytes4[](15);
        s[0] = ChannelHandler.settle.selector;
        s[1] = ChannelHandler.settle.selector; // settle weighted up
        s[2] = ChannelHandler.collect.selector;
        s[3] = ChannelHandler.refund.selector;
        s[4] = ChannelHandler.freezeProvider.selector;
        s[5] = ChannelHandler.claim.selector;
        s[6] = ChannelHandler.redeem.selector;
        s[7] = ChannelHandler.collectHeld.selector;
        s[8] = ChannelHandler.refundHeld.selector;
        s[9] = ChannelHandler.deposit.selector;
        s[10] = ChannelHandler.setLimits.selector;
        s[11] = ChannelHandler.withdraw.selector;
        s[12] = ChannelHandler.warp.selector;
        s[13] = ChannelHandler.collect.selector;
        s[14] = ChannelHandler.setTakeRate.selector;
        targetSelector(FuzzSelector({addr: address(h), selectors: s}));
        targetContract(address(h));
    }

    function _books() internal view returns (uint128 totalUnpaid, uint128 held) {
        (,, totalUnpaid, held) = h.escrow().channelBooks(bytes32(0), address(0));
    }

    /// I7: the escrow's USDG covers balances, per-call holds, channel holds and set-aside payouts.
    function invariant_I7_solvency() public view {
        (uint128 totalUnpaid, uint128 held) = _books();
        IAssayEscrow e = h.escrow();
        assertGe(
            h.usdg().balanceOf(address(e)),
            uint256(e.totalEscrowed()) + e.totalHeld() + held + totalUnpaid
        );
    }

    /// The channel total is exactly the sum of every bucket; set-aside money is exactly the sum
    /// of the per-recipient records.
    function invariant_channelTotalsAreTheSumsTheyName() public view {
        (uint128 totalUnpaid, uint128 held) = _books();
        assertEq(held, h.sumOfBuckets());
        assertEq(totalUnpaid, h.sumOfUnpaid());
    }

    /// D-14: balances sum to `totalEscrowed`; the per-call total is only per-call holds.
    function invariant_D14_totals() public view {
        assertEq(h.sumOfBalances(), h.escrow().totalEscrowed());
        assertEq(h.sumOfPerCallHeld(), h.escrow().totalHeld());
    }

    /// I12 per channel: settled = charged + waived, charged = collected + refunded + held, and
    /// nothing is ever settled beyond what the client signed (I2/I17).
    function invariant_I12_perChannelLedger() public view {
        for (uint256 c = 0; c < h.CHANNELS(); ++c) {
            (uint64 signed,, uint64 charged, uint64 waived, uint64 collected, uint64 refunded) =
                h.ghost(c);
            ChannelDoor.Slot memory s = h.slotOf(c);
            assertEq(s.settled, uint256(charged) + waived, "settled = charged + waived");
            assertEq(uint256(charged), uint256(collected) + refunded + s.h1 + s.h2, "charged split");
            assertLe(s.settled, signed, "never settled beyond the signed total");
        }
    }

    /// A refund reaches the bucket it names by hour and rate, and no other.
    function invariant_refundReachesOnlyTheNamedBucket() public view {
        assertEq(h.wrongBucketRefunds(), 0);
    }

    /// D-31: a refund id applied on a channel never moves money there again.
    function invariant_aRefundIdAppliesOncePerChannel() public view {
        assertEq(h.reusedIdRefunds(), 0);
    }

    /// I10/I11: an empty bucket carries no maturity or rate; a non-empty one has both buckets'
    /// maturities distinct or their rates distinct.
    function invariant_I11_bucketShape() public view {
        for (uint256 c = 0; c < h.CHANNELS(); ++c) {
            ChannelDoor.Slot memory s = h.slotOf(c);
            if (s.h1 == 0) assertEq(s.m1 + s.r1, 0);
            if (s.h2 == 0) assertEq(s.m2 + s.r2, 0);
            if (s.h1 != 0 && s.h2 != 0) assertTrue(s.m1 != s.m2 || s.r1 != s.r2);
        }
    }

    /// A run that tried to settle several times and never landed one proved nothing about the
    /// channel door. (A short run can draw fewer than three settle calls; that is chance, not a
    /// broken handler.)
    /// H1 fix: a settlement may fold into an occupied bucket and move its maturity later, never
    /// earlier, so no money is ever released before its own hold.
    function invariant_aFoldNeverMovesAMaturityEarlier() public view {
        assertFalse(h.maturityMovedEarlier(), "a holding bucket's maturity moved earlier");
    }

    function afterInvariant() external view {
        if (h.settleAttempts() >= 3) {
            assertGt(h.settles(), 0, "no settlement landed in this run");
        }
    }
}
