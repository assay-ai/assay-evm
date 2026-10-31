// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.38;

import {console2} from "forge-std/console2.sol";
import {Fixture} from "./helpers/Fixture.sol";
import {VoucherSigner} from "./helpers/VoucherSigner.sol";
import {Voucher} from "../src/Types.sol";
import {SetHash} from "./helpers/SetHash.sol";

/// Gas cost of grinding collisions into the redeem memo: 64 buyers whose addresses all share one
/// slot of the 256-word set (free to grind off chain) versus 64 ordinary buyers. The answer stays
/// exact either way; this bounds what an attacker who controls the batch's addresses can add.
contract AssayEscrowMemoGriefTest is Fixture {
    function _batch(bool collide) internal returns (uint256 g) {
        Voucher[] memory vs = new Voucher[](64);
        bytes[] memory sigs = new bytes[](64);
        bytes32 ds = escrow.DOMAIN_SEPARATOR();
        uint256 k = collide ? 0x1000 : 0x900000;
        for (uint256 i = 0; i < 64; i++) {
            if (collide) k = SetHash.grindKey(address(0x42), 256, k);
            address b = vm.addr(k);
            _fund(b, 1e6);
            vm.startPrank(b);
            usdg.approve(address(escrow), 1e6);
            escrow.deposit(1e6);
            escrow.setLimits(1e6, 1e6);
            vm.stopPrank();
            vs[i] = Voucher(
                b,
                provider,
                1_000,
                0,
                bytes32(i),
                1,
                uint64(block.timestamp),
                uint64(block.timestamp + 300)
            );
            sigs[i] = VoucherSigner.signVoucher(k, ds, vs[i]);
            k++;
        }
        vm.prank(redeemer);
        g = gasleft();
        escrow.redeemVoucherBatch(vs, sigs);
        g -= gasleft();
    }

    function test_collidingBuyersCostBoundedGas() public {
        uint256 snap = vm.snapshotState();
        uint256 a = _batch(false);
        vm.revertToState(snap);
        uint256 b = _batch(true);
        console2.log("random buyers gas", a);
        console2.log("colliding buyers gas", b);
        console2.log("extra %", b > a ? (b - a) * 100 / a : 0);
        assertLt(b, a * 115 / 100, "colliding buyers cost more than 15% extra");
    }
}
