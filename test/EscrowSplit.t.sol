// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.38;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {Fixture} from "./helpers/Fixture.sol";
import {VoucherSigner} from "./helpers/VoucherSigner.sol";
import {RedeemReentrantUSDG} from "./helpers/MockUSDG.sol";
import {AssayEscrow} from "../src/AssayEscrow.sol";
import {AssayEscrowExtension} from "../src/AssayEscrowExtension.sol";
import {IAssayEscrow} from "../src/interfaces/IAssayEscrow.sol";
import {Voucher, ParamSet} from "../src/Types.sol";
import "../src/Errors.sol";

/// D-29: `AssayEscrow` is a core plus an extension reached by `fallback` DELEGATECALL in the
/// core's storage. These pin what that split must never change or open: one storage layout, one
/// ABI (the union is `IAssayEscrow`), one reentrancy guard, one EIP-712 domain, the binding of
/// each implementation to the extension its constructor created, and a fallback that behaves for
/// every malformed call exactly as the contract without a fallback did.
contract EscrowSplitTest is Fixture {
    string internal constant CORE = "/out/AssayEscrow.sol/AssayEscrow.json";
    string internal constant EXT = "/out/AssayEscrowExtension.sol/AssayEscrowExtension.json";
    string internal constant IFACE = "/out/IAssayEscrow.sol/IAssayEscrow.json";

    function _art(string memory p) internal view returns (string memory) {
        return vm.readFile(string.concat(vm.projectRoot(), p));
    }

    // --- storage ------------------------------------------------------------------------

    /// Every slot of the core is the extension's slot: same label, slot, offset and type. The
    /// type key carries the struct's AST id, which is one declaration for both, so equal keys
    /// mean the same struct and not just a struct of the same name.
    function test_theCoreAndTheExtensionShareOneStorageLayout() public view {
        string memory a = _art(CORE);
        string memory b = _art(EXT);
        uint256 n;
        for (uint256 i = 0;; i++) {
            string memory at = string.concat(".storageLayout.storage[", vm.toString(i), "]");
            bool inA = vm.keyExistsJson(a, at);
            assertEq(inA, vm.keyExistsJson(b, at), "the layouts have different lengths");
            if (!inA) break;
            for (uint256 k = 0; k < 4; k++) {
                string memory field = [".label", ".slot", ".offset", ".type"][k];
                assertEq(
                    vm.parseJsonString(a, string.concat(at, field)),
                    vm.parseJsonString(b, string.concat(at, field)),
                    string.concat("storage entry ", vm.toString(i), field, " differs")
                );
            }
            n++;
        }
        assertEq(n, 16, "the escrow layout has 16 entries (3 inherited, 13 own incl. the gap)");
    }

    // --- surface ------------------------------------------------------------------------

    function _keys(string memory p) internal view returns (string[] memory) {
        return vm.parseJsonKeys(_art(p), ".methodIdentifiers");
    }

    function _has(string[] memory xs, string memory x) internal pure returns (bool) {
        for (uint256 i = 0; i < xs.length; i++) {
            if (keccak256(bytes(xs[i])) == keccak256(bytes(x))) return true;
        }
        return false;
    }

    /// The core and the extension overlap only in the storage base's public getters, which the
    /// core answers (the extension's copies are unreachable through the proxy), and together they
    /// are exactly `IAssayEscrow`, the integrator ABI.
    function test_theSurfaceIsTheCorePlusTheExtensionAndEqualsTheInterface() public view {
        string[] memory core = _keys(CORE);
        string[] memory ext = _keys(EXT);
        string[] memory iface = _keys(IFACE);
        string[5] memory shared =
            ["ASSET()", "CONFIG()", "STAKE()", "totalEscrowed()", "totalHeld()"];

        uint256 overlap;
        for (uint256 i = 0; i < ext.length; i++) {
            if (_has(core, ext[i])) {
                overlap++;
                bool allowed;
                for (uint256 k = 0; k < shared.length; k++) {
                    if (keccak256(bytes(shared[k])) == keccak256(bytes(ext[i]))) allowed = true;
                }
                assertTrue(allowed, string.concat("the core shadows an extension door: ", ext[i]));
            }
            assertTrue(_has(iface, ext[i]), string.concat("not in IAssayEscrow: ", ext[i]));
        }
        assertEq(overlap, shared.length, "the shared getters are not all on both");
        for (uint256 i = 0; i < core.length; i++) {
            assertTrue(_has(iface, core[i]), string.concat("not in IAssayEscrow: ", core[i]));
        }
        assertEq(iface.length, core.length + ext.length - overlap, "IAssayEscrow has extras");
    }

    // --- binding ------------------------------------------------------------------------

    /// Each implementation is bound to the extension its own constructor created, the first
    /// contract it created (nonce 1), and the proxy reports the same one.
    function test_anImplementationIsBoundToTheExtensionItCreated() public {
        assertEq(escrowImpl.EXTENSION(), vm.computeCreateAddress(address(escrowImpl), 1));
        assertEq(escrow.EXTENSION(), escrowImpl.EXTENSION());
        assertGt(escrowImpl.EXTENSION().code.length, 0);
        AssayEscrow next = new AssayEscrow();
        assertTrue(next.EXTENSION() != escrowImpl.EXTENSION(), "one extension per implementation");
    }

    /// The extension cannot become the proxy's implementation: it is not UUPS.
    function test_theExtensionIsNotAnUpgradeTarget() public {
        address ext = escrowImpl.EXTENSION();
        vm.prank(owner);
        vm.expectRevert();
        escrow.upgradeToAndCall(ext, "");
    }

    // --- direct calls -------------------------------------------------------------------

    /// Called directly (not through the proxy) every extension door refuses, before it reads its
    /// own empty storage.
    function test_theExtensionRefusesEveryDirectCall() public {
        IAssayEscrow ext = IAssayEscrow(escrowImpl.EXTENSION());
        bytes4 err = UUPSUpgradeable.UUPSUnauthorizedCallContext.selector;
        Voucher memory v;
        vm.prank(redeemer);
        vm.expectRevert(err);
        ext.redeemVoucher(v, "");
        vm.expectRevert(err);
        ext.redeemVoucherBatch(new Voucher[](0), new bytes[](0));
        vm.expectRevert(err);
        ext.setLimitsBySig(buyer, 1, 1, 0, 0, "");
        vm.expectRevert(err);
        ext.requestWithdrawBySig(buyer, 1, 0, 0, "");
        vm.expectRevert(err);
        ext.authorizeDelegateBySig(buyer, address(1), 1, 1, 1, 0, 0, "");
        vm.expectRevert(err);
        ext.revokeDelegateBySig(buyer, address(1), 0, 0, "");
        vm.expectRevert(err);
        ext.effectiveCapsOf(buyer, address(0));
    }

    // --- fallback -----------------------------------------------------------------------

    /// What the contract without a fallback did: value, empty or short calldata and an unknown
    /// selector all revert, with empty revert data.
    function test_theFallbackRevertsEmptyForEveryCallTheContractNeverHad() public {
        bytes[4] memory calls = [bytes(""), hex"01", hex"aabbcc", hex"deadbeef00"];
        for (uint256 i = 0; i < calls.length; i++) {
            (bool ok, bytes memory ret) = address(escrow).call(calls[i]);
            assertFalse(ok, "accepted a call it does not have");
            assertEq(ret.length, 0, "with revert data");
        }
        vm.deal(address(this), 1 ether);
        (bool sent,) = address(escrow).call{value: 1}("");
        assertFalse(sent, "accepted ETH");
        (sent,) = address(escrow).call{value: 1}(
            abi.encodeCall(IAssayEscrow.effectiveCapsOf, (buyer, address(0)))
        );
        assertFalse(sent, "accepted ETH on an extension door");
    }

    /// An extension door's custom error and its return data come back through the fallback
    /// byte for byte.
    function test_theFallbackReturnsTheExtensionsRevertAndReturnDataVerbatim() public {
        Voucher memory v;
        vm.expectRevert(NotRedeemer.selector);
        escrow.redeemVoucher(v, "");

        vm.prank(buyer);
        escrow.setLimits(7, 9);
        (bool ok, bytes memory ret) = address(escrow).staticcall(
            abi.encodeCall(IAssayEscrow.effectiveCapsOf, (buyer, address(0)))
        );
        assertTrue(ok);
        assertEq(ret, abi.encode(uint64(7), uint64(9), uint64(0), uint64(0)));
    }

    // --- domain -------------------------------------------------------------------------

    /// The extension builds its digests against the core's `DOMAIN_SEPARATOR()`: a relayed
    /// decision signed against that separator lands.
    function test_theExtensionEnforcesTheCoresDomain() public {
        uint64 nonce = escrow.escrowOf(buyer).authNonce;
        uint64 deadline = uint64(block.timestamp + 600);
        bytes memory sig = VoucherSigner.signSetLimits(
            buyerKey, escrow.DOMAIN_SEPARATOR(), buyer, 3, 5, nonce, deadline
        );
        escrow.setLimitsBySig(buyer, 3, 5, nonce, deadline, sig);
        assertEq(escrow.escrowOf(buyer).maxVoucherAmount, 3);
        assertEq(escrow.escrowOf(buyer).maxPerWindow, 5);
    }

    /// The domain itself, spelled out: a change to the shared name or version moves both halves
    /// together, so only a literal catches it (every outstanding voucher would die).
    function test_theDomainIsAssaySettlementVersionTwo() public view {
        bytes32 want = keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256("Assay Settlement"),
                keccak256("2"),
                block.chainid,
                address(escrow)
            )
        );
        assertEq(escrow.DOMAIN_SEPARATOR(), want);
    }

    // --- reentrancy ---------------------------------------------------------------------

    /// One `_status` slot for both halves: a payout in the core cannot re-enter an extension
    /// door.
    /// Every state-changing extension door, re-entered from a core payout, hits the shared
    /// guard (arguments are irrelevant: the guard is the first thing that can refuse).
    function test_everyExtensionDoorIsGuarded() public {
        bytes[6] memory doors = [
            abi.encodeCall(IAssayEscrow.redeemVoucherBatch, (new Voucher[](0), new bytes[](0))),
            abi.encodeCall(IAssayEscrow.redeemVoucher, (_emptyVoucher(), bytes(""))),
            abi.encodeCall(IAssayEscrow.setLimitsBySig, (buyer, 1, 1, 0, 0, bytes(""))),
            abi.encodeCall(IAssayEscrow.requestWithdrawBySig, (buyer, 1, 0, 0, bytes(""))),
            abi.encodeCall(
                IAssayEscrow.authorizeDelegateBySig, (buyer, address(1), 1, 1, 1, 0, 0, bytes(""))
            ),
            abi.encodeCall(IAssayEscrow.revokeDelegateBySig, (buyer, address(1), 0, 0, bytes("")))
        ];
        for (uint256 i = 0; i < doors.length; i++) {
            _reenterFromCollect(doors[i]);
        }
    }

    function _emptyVoucher() internal pure returns (Voucher memory v) {}

    function test_aCorePayoutCannotReenterAnExtensionDoor() public {
        _reenterFromCollect(
            abi.encodeCall(IAssayEscrow.redeemVoucherBatch, (new Voucher[](0), new bytes[](0)))
        );
    }

    function _reenterFromCollect(bytes memory reenter) internal {
        RedeemReentrantUSDG evil = new RedeemReentrantUSDG();
        IAssayEscrow e2 = _deployEscrow(address(evil));
        evil.mint(buyer, 10_000_000);
        vm.startPrank(buyer);
        evil.approve(address(e2), 10_000_000);
        e2.deposit(10_000_000);
        e2.setLimits(1_000_000, 5_000_000);
        vm.stopPrank();

        ParamSet memory p = config.params();
        p.redeemer = address(evil);
        vm.prank(admin);
        config.updateConfig(p);

        Voucher memory v = Voucher({
            payer: buyer,
            provider: provider,
            amount: 250_000,
            resourceHash: keccak256("resource"),
            requestHash: keccak256("request"),
            seq: 1,
            issuedAt: uint64(vm.getBlockTimestamp()),
            expiresAt: uint64(vm.getBlockTimestamp()) + 300
        });
        bytes memory sig = VoucherSigner.signVoucher(buyerKey, e2.DOMAIN_SEPARATOR(), v);
        vm.prank(address(evil));
        e2.redeemVoucher(v, sig);
        vm.warp(e2.held(buyer, 1).collectableAt);

        evil.arm(address(e2), reenter);
        vm.expectCall(address(e2), reenter, 1);
        vm.prank(address(evil));
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        e2.collectHeld(buyer, 1);
        assertEq(e2.totalHeld(), 250_000, "unwound");
    }
}
