// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.38;

import {Vm} from "forge-std/Vm.sol";
import {AssayEscrowChannelTest} from "./AssayEscrow.channel.t.sol";
import {ChannelDoor} from "../src/libraries/ChannelDoor.sol";
import {AssayEscrow} from "../src/AssayEscrow.sol";
import {ChannelVoucher} from "../src/Types.sol";
import {SetHash} from "./helpers/SetHash.sol";

/// `settleChannels` forwards its own calldata to the library (D-30): non-canonical but valid
/// encodings settle like canonical ones, an offset into the head is refused, and the lookup table
/// stays exact when every provider of a full batch lands in one slot.
contract AssayEscrowChannelForwardTest is AssayEscrowChannelTest {
    function _strip(bytes memory enc) internal pure returns (bytes memory out) {
        // abi.encode(x) of one dynamic value = [0x20][tail]; return the tail.
        out = new bytes(enc.length - 32);
        for (uint256 i = 0; i < out.length; i++) {
            out[i] = enc[i + 32];
        }
    }

    function _two() internal view returns (ChannelVoucher[] memory vs, bytes memory sigs) {
        vs = new ChannelVoucher[](2);
        vs[0] = _cv(CH, 300_000, 3);
        vs[1] = _cv(keccak256("lane-2"), 200_000, 2);
        sigs = abi.encodePacked(_sign(delegateKey, vs[0]), _sign(buyerKey, vs[1]));
    }

    /// A non-canonical but valid encoding (tail reordered, a junk word first) must settle
    /// exactly like the canonical one.
    function test_E1_nonCanonicalTailSettlesLikeCanonical() public {
        (ChannelVoucher[] memory vs, bytes memory sigs) = _two();
        uint64[] memory from = new uint64[](2);
        uint64[] memory ch = new uint64[](2);
        ch[0] = 300_000;
        ch[1] = 150_000;

        uint256 snap = vm.snapshotState();
        vm.prank(redeemer);
        escrow.settleChannels(vs, sigs, from, ch);
        (uint256 w0,,, uint128 held0) = escrow.channelBooks(_key(delegate), address(0));
        uint128 te0 = escrow.totalEscrowed();
        vm.revertToState(snap);

        bytes memory eV = _strip(abi.encode(vs));
        bytes memory eS = _strip(abi.encode(sigs));
        bytes memory eF = _strip(abi.encode(from));
        bytes memory eC = _strip(abi.encode(ch));
        uint256 oC = 0x80 + 32;
        uint256 oF = oC + eC.length;
        uint256 oS = oF + eF.length;
        uint256 oV = oS + eS.length;
        bytes memory data = abi.encodePacked(
            AssayEscrow.settleChannels.selector,
            abi.encode(oV, oS, oF, oC),
            bytes32(uint256(0xdead)),
            eC,
            eF,
            eS,
            eV
        );
        vm.prank(redeemer);
        (bool ok,) = address(escrow).call(data);
        assertTrue(ok, "non-canonical encoding refused");
        (uint256 w1,,, uint128 held1) = escrow.channelBooks(_key(delegate), address(0));
        assertEq(w1, w0, "slot differs");
        assertEq(held1, held0, "held differs");
        assertEq(escrow.totalEscrowed(), te0, "totalEscrowed differs");
    }

    /// Two dynamic args sharing one tail region (fromSettled and charges alias) are valid ABI.
    function test_E1_aliasedArraysDecodeTheSame() public {
        // `fromSettled` and `charges` both point at one `[0]` array: from 0, charge 0, a pure
        // waiver of the voucher's whole value.
        ChannelVoucher memory v = _cv(CH, 0x40, 1);
        bytes memory sigs = _sign(delegateKey, v);
        ChannelVoucher[] memory vs = _one(v);
        bytes memory eV = _strip(abi.encode(vs));
        bytes memory eS = _strip(abi.encode(sigs));
        bytes memory eZ = _strip(abi.encode(_u(0)));
        uint256 oZ = 0x80;
        uint256 oS = oZ + eZ.length;
        uint256 oV = oS + eS.length;
        bytes memory data = abi.encodePacked(
            AssayEscrow.settleChannels.selector, abi.encode(oV, oS, oZ, oZ), eZ, eS, eV
        );
        vm.prank(redeemer);
        (bool ok,) = address(escrow).call(data);
        assertTrue(ok);
        assertEq(_slot(delegate).settled, 0x40);
        assertEq(_slot(delegate).h1, 0);
    }

    /// An offset into the 4-word head reverts empty and moves nothing. (Solidity's own decoder
    /// already refuses this one; `AssayEscrowChannelReplayTest` sends one it accepts.)
    function test_E1_headPointingOffsetReverts() public {
        ChannelVoucher memory v = _cv(CH, 100_000, 1);
        bytes memory good = abi.encodeCall(
            AssayEscrow.settleChannels, (_one(v), _sign(delegateKey, v), _u(0), _u(100_000))
        );
        // charges offset (head word 3) := 0x20 -> points at the sigs offset word.
        assembly {
            mstore(add(good, add(0x20, add(4, 0x60))), 0x20)
        }
        vm.prank(redeemer);
        (bool ok,) = address(escrow).call(good);
        assertFalse(ok);
        assertEq(_slot(delegate).settled, 0);
    }

    /// 64 items whose providers all probe the same E4 table bucket: every answer is still the
    /// exact one (blocked / unstaked / staked) and the batch terminates.
    function test_E4_fullyCollidingProvidersStayExact() public {
        address[64] memory P = [
            address(0x100060),
            address(0x1000a6),
            address(0x100379),
            address(0x1003bf),
            address(0x1006d8),
            address(0x10071e),
            address(0x100a37),
            address(0x100d50),
            address(0x100d96),
            address(0x1010af),
            address(0x1010f5),
            address(0x10140e),
            address(0x101727),
            address(0x10176d),
            address(0x101a86),
            address(0x101d9f),
            address(0x101de5),
            address(0x1020fe),
            address(0x102144),
            address(0x10245d),
            address(0x102776),
            address(0x1027bc),
            address(0x102ad5),
            address(0x102dee),
            address(0x102e34),
            address(0x10314d),
            address(0x103193),
            address(0x1034ac),
            address(0x1037c5),
            address(0x10380b),
            address(0x103b24),
            address(0x103e3d),
            address(0x103e83),
            address(0x10419c),
            address(0x1041e2),
            address(0x1044fb),
            address(0x104814),
            address(0x10485a),
            address(0x104b73),
            address(0x104bb9),
            address(0x104e8c),
            address(0x104ed2),
            address(0x1051eb),
            address(0x105231),
            address(0x10554a),
            address(0x105863),
            address(0x1058a9),
            address(0x105bc2),
            address(0x105c08),
            address(0x105f21),
            address(0x10623a),
            address(0x106280),
            address(0x106599),
            address(0x1068b2),
            address(0x1068f8),
            address(0x106c11),
            address(0x106c57),
            address(0x106f70),
            address(0x107289),
            address(0x1072cf),
            address(0x1075e8),
            address(0x107901),
            address(0x107947),
            address(0x107c60)
        ];
        // The 64 providers share one stake slot of the 512-word table of a 64-item batch.
        for (uint256 i = 1; i < 64; i++) {
            assertEq(SetHash.doorSlot(P[i], 2, 512), SetHash.doorSlot(P[0], 2, 512), "no collision");
        }
        ChannelVoucher[] memory vs = new ChannelVoucher[](64);
        bytes memory sigs;
        uint64[] memory from = new uint64[](64);
        uint64[] memory ch = new uint64[](64);
        for (uint256 i = 0; i < 64; i++) {
            vs[i] = _cv(CH, 10_000, 1);
            vs[i].provider = P[i];
            sigs = abi.encodePacked(sigs, _sign(buyerKey, vs[i]));
            ch[i] = 10_000;
            if (i % 3 == 0) {
                vm.prank(admin);
                config.setBlocked(P[i], true);
            }
            if (i % 4 == 1 && i % 3 != 0) _setBonded(P[i], MINIMUM_STAKE);
        }
        vm.recordLogs();
        uint256 g = gasleft();
        vm.prank(redeemer);
        escrow.settleChannels(vs, sigs, from, ch);
        g -= gasleft();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 settled;
        uint256 blockedSkips;
        uint256 stakeSkips;
        for (uint256 k = 0; k < logs.length; k++) {
            if (logs[k].topics[0] == ChannelDoor.ChannelSettleSkipped.selector) {
                uint256 i = uint256(logs[k].topics[1]);
                (,, uint8 why) = abi.decode(logs[k].data, (bytes32, uint64, uint8));
                if (i % 3 == 0) {
                    assertEq(why, uint8(ChannelDoor.SettleSkip.Blocked), "blocked item");
                    blockedSkips++;
                } else {
                    assertTrue(i % 4 != 1, "staked item skipped");
                    assertEq(why, uint8(ChannelDoor.SettleSkip.Stake), "unstaked item");
                    stakeSkips++;
                }
            } else if (logs[k].topics[0] == ChannelDoor.ChannelSettled.selector) {
                settled++;
            }
        }
        // i%3==0 -> 22 blocked; of the rest, i%4==1 staked.
        uint256 expSettled;
        for (uint256 i = 0; i < 64; i++) {
            if (i % 3 != 0 && i % 4 == 1) expSettled++;
        }
        assertEq(blockedSkips, 22);
        assertEq(settled, expSettled);
        assertEq(stakeSkips, 64 - 22 - expSettled);
        emit log_named_uint("colliding batch gas", g);
    }
}
