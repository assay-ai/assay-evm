// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.38;

// Ported from the independent security audit of 2026-11-01. Read-only mainnet fork: upgrade the
// live proxy (8620693) to this build in memory, and check the D-31 refund-id slot starts empty.
import {Test} from "forge-std/Test.sol";
import {AssayEscrow} from "../../src/AssayEscrow.sol";
import {AssayEscrowExtension} from "../../src/AssayEscrowExtension.sol";
import {IAssayEscrow} from "../../src/interfaces/IAssayEscrow.sol";
import {IAssayConfig} from "../../src/interfaces/IAssayConfig.sol";
import {IAssayStakeView} from "../../src/interfaces/IAssayStakeView.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Voucher} from "../../src/Types.sol";

contract UpgradeForkAuditTest is Test {
    address constant ESCROW = 0xe54E0142b1D0d34226498D563A16074C81Bc9A5e;
    address constant OWNER = 0x32bBeB9208BfBe84D318626027EFcC066090A842;
    address constant REDEEMER = 0x2341284933bb2d8Ee2Bf693a2A0813dE42AeF310;
    bytes32 constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 constant INIT_SLOT = 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;
    IAssayEscrow esc = IAssayEscrow(ESCROW);

    function test_upgradeOnLiveState() public {
        string memory rpc = vm.envOr("MAINNET_RPC", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);
        assertEq(block.chainid, 4663);
        bytes32[64] memory before;
        for (uint256 i = 0; i < 64; ++i) {
            before[i] = vm.load(ESCROW, bytes32(i));
        }
        for (uint256 i = 14; i < 64; ++i) {
            assertEq(before[i], 0, "gap slot not empty pre-upgrade");
        }
        bytes32 ds = esc.DOMAIN_SEPARATOR();
        uint128 te = esc.totalEscrowed();
        uint128 th = esc.totalHeld();
        address oldImpl = address(uint160(uint256(vm.load(ESCROW, IMPL_SLOT))));

        AssayEscrow impl = new AssayEscrow();
        assertEq(
            vm.load(address(impl), INIT_SLOT),
            bytes32(uint256(type(uint64).max)),
            "impl init not disabled"
        );

        vm.prank(REDEEMER);
        vm.expectRevert();
        esc.upgradeToAndCall(address(impl), "");
        vm.prank(OWNER);
        esc.upgradeToAndCall(address(impl), "");

        assertTrue(address(uint160(uint256(vm.load(ESCROW, IMPL_SLOT)))) != oldImpl);
        for (uint256 i = 0; i < 64; ++i) {
            if (i == 2) continue; // reentrancy status
            assertEq(vm.load(ESCROW, bytes32(i)), before[i], "slot changed by upgrade");
        }
        assertEq(vm.load(ESCROW, INIT_SLOT), bytes32(uint256(1)), "initializer version moved");
        assertEq(esc.DOMAIN_SEPARATOR(), ds);
        assertEq(esc.totalEscrowed(), te);
        assertEq(esc.totalHeld(), th);
        (uint256 st, uint128 u, uint128 tu, uint128 h) = esc.channelBooks(bytes32(0), address(0));
        assertEq(st + u + tu + h, 0);
        // D-31: `ChannelDoor.Store` is slots 14..17 (state, unpaid, totals, refunded); every
        // slot from 14 was empty before the upgrade and is still empty, so no refund id is
        // pre-marked as used.
        for (uint256 i = 14; i < 64; ++i) {
            assertEq(vm.load(ESCROW, bytes32(i)), 0, "new slot");
        }
        uint256 bal = IERC20(address(esc.ASSET())).balanceOf(ESCROW);
        assertGe(bal, uint256(te) + th, "live solvency");

        vm.expectRevert();
        esc.initialize(IAssayConfig(address(1)), IAssayStakeView(address(1)), IERC20(address(1)));
        address ext = esc.EXTENSION();
        Voucher memory v;
        vm.prank(REDEEMER);
        vm.expectRevert();
        AssayEscrowExtension(ext).redeemVoucher(v, new bytes(65));
        emit log_named_uint("live totalEscrowed", te);
        emit log_named_uint("live totalHeld", th);
        emit log_named_uint("live escrow token balance", bal);
    }
}
