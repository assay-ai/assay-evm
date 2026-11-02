// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.38;

import {Test, console2} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AssayEscrow} from "../../src/AssayEscrow.sol";
import {IAssayEscrow} from "../../src/interfaces/IAssayEscrow.sol";
import {AssayConfig} from "../../src/AssayConfig.sol";
import {ChannelDoor} from "../../src/libraries/ChannelDoor.sol";
import {Voucher, ChannelVoucher, ChannelRef, VOUCHER_TYPEHASH} from "../../src/Types.sol";
import {VoucherSigner} from "../helpers/VoucherSigner.sol";

interface IUUPSLike {
    function upgradeToAndCall(address impl, bytes calldata data) external payable;
}

/// Mainnet 4663 fork (real proxies, real USDG, real providers' stake and balances, real
/// treasury). Skips unless `MAINNET_RPC` is set. Nothing is sent to the chain.
///
/// 1. The in-place upgrade v2 (`8620693`, live) -> v3 keeps every byte of state the proxy has.
/// 2. Gas, before and after, in the production shape: 7 payers round-robin, 2 providers 1:3,
///    delegate-signed, $0.10 per call. Tx gas = 21,000 + calldata + measured execution (this
///    method matched mainnet receipts within about 1% on 2026-10-30).
abstract contract MainnetBase is Test {
    address constant ESCROW = 0xe54E0142b1D0d34226498D563A16074C81Bc9A5e;
    address constant CONFIG = 0xD4025A66F7F76Ffa2f553141E86Fc47b84c15fd4;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant OWNER = 0x32bBeB9208BfBe84D318626027EFcC066090A842;
    address constant REDEEMER = 0x2341284933bb2d8Ee2Bf693a2A0813dE42AeF310;
    address constant PROV_A = 0x631233A2D9Dc5386b4f52f318FE02f32a7bDb579;
    address constant PROV_B = 0x76217586A3874748b603dFe3c53D6c7D107A2A60;
    bytes32 constant CHANNEL_TYPEHASH = keccak256(
        "ChannelVoucher(address payer,address provider,bytes32 channelId,uint64 cumulative,"
        "uint32 calls,uint64 issuedAt,uint64 expiresAt)"
    );
    uint256 constant PAYERS = 7;
    uint64 constant PRICE = 100_000;

    IAssayEscrow internal esc = IAssayEscrow(ESCROW);
    uint64[PAYERS] internal nextSeq;
    bool internal live;

    function _payerKey(uint256 i) internal pure returns (uint256) {
        return 0xA11CE000 + i;
    }

    function _delegateKey(uint256 i) internal pure returns (uint256) {
        return 0xDE1E6000 + i;
    }

    function _now() internal view returns (uint64) {
        return uint64(vm.getBlockTimestamp());
    }

    function _fork() internal returns (bool) {
        string memory rpc = vm.envOr("MAINNET_RPC", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return false;
        }
        vm.createSelectFork(rpc);
        assertEq(block.chainid, 4663);
        return true;
    }

    function _upgrade() internal {
        AssayEscrow impl = new AssayEscrow();
        vm.prank(OWNER);
        IUUPSLike(ESCROW).upgradeToAndCall(address(impl), "");
    }

    function _onboard() internal {
        for (uint256 i = 0; i < PAYERS; ++i) {
            address payer = vm.addr(_payerKey(i));
            deal(USDG, payer, 1_000e6, true);
            vm.startPrank(payer);
            IERC20(USDG).approve(ESCROW, type(uint256).max);
            esc.deposit(500e6);
            esc.setLimits(10e6, 400e6);
            esc.authorizeDelegate(
                vm.addr(_delegateKey(i)), 10e6, 400e6, uint64(block.timestamp + 30 days)
            );
            vm.stopPrank();
            nextSeq[i] = esc.escrowOf(payer).seqHigh + 1;
        }
    }

    function _cd(bytes memory d) internal pure returns (uint256 c) {
        for (uint256 i = 0; i < d.length; ++i) {
            c += d[i] == 0 ? 4 : 16;
        }
    }

    function _send(address from, bytes memory data) internal returns (uint256 txGas) {
        vm.prank(from);
        uint256 g = gasleft();
        (bool ok, bytes memory ret) = ESCROW.call(data);
        g -= gasleft();
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
        txGas = 21_000 + _cd(data) + g;
    }

    // ------------------------------------------------------------------ per-call door

    function _perCallBatch(uint256 n) internal returns (bytes memory data, Voucher[] memory vs) {
        vs = new Voucher[](n);
        bytes[] memory sigs = new bytes[](n);
        bytes32 ds = esc.DOMAIN_SEPARATOR();
        for (uint256 k = 0; k < n; ++k) {
            uint256 i = k % PAYERS;
            vs[k] = Voucher({
                payer: vm.addr(_payerKey(i)),
                provider: k % 4 == 0 ? PROV_A : PROV_B,
                amount: PRICE,
                resourceHash: keccak256(abi.encode("r", k)),
                requestHash: keccak256(abi.encode("q", k, _now(), n)),
                seq: nextSeq[i]++,
                issuedAt: _now(),
                expiresAt: _now() + 240
            });
            sigs[k] = VoucherSigner.signVoucher(_delegateKey(i), ds, vs[k]);
        }
        data = abi.encodeCall(IAssayEscrow.redeemVoucherBatch, (vs, sigs));
    }

    function _collectHeldData(Voucher[] memory vs) internal pure returns (bytes memory) {
        address[] memory p = new address[](vs.length);
        uint64[] memory q = new uint64[](vs.length);
        for (uint256 i = 0; i < vs.length; ++i) {
            p[i] = vs[i].payer;
            q[i] = vs[i].seq;
        }
        return abi.encodeCall(AssayEscrow.collectHeldBatch, (p, q));
    }

    // ------------------------------------------------------------------ channel door

    /// Channel c: payer c % 7, provider A for one in four, its own lane (distinct keys).
    function _channel(uint256 c) internal pure returns (uint256 i, address prov, bytes32 lane) {
        i = c % PAYERS;
        prov = c % 4 == 0 ? PROV_A : PROV_B;
        lane = keccak256(abi.encode("lane", c));
    }

    mapping(uint256 => uint64) internal cumOf;
    mapping(uint256 => uint32) internal callsOf;
    mapping(uint256 => uint64) internal settledOf;

    function _settleData(uint256 first, uint256 k, uint32 callsEach)
        internal
        returns (bytes memory data)
    {
        ChannelVoucher[] memory vs = new ChannelVoucher[](k);
        bytes memory sigs;
        uint64[] memory from = new uint64[](k);
        uint64[] memory ch = new uint64[](k);
        bytes32 ds = esc.DOMAIN_SEPARATOR();
        for (uint256 j = 0; j < k; ++j) {
            uint256 c = first + j;
            (uint256 i, address prov, bytes32 lane) = _channel(c);
            from[j] = settledOf[c];
            cumOf[c] += PRICE * callsEach;
            callsOf[c] += callsEach;
            vs[j] = ChannelVoucher(
                vm.addr(_payerKey(i)), prov, lane, cumOf[c], callsOf[c], _now(), _now() + 240
            );
            ch[j] = cumOf[c] - from[j];
            settledOf[c] = cumOf[c];
            bytes32 sh = keccak256(
                abi.encode(
                    CHANNEL_TYPEHASH,
                    vs[j].payer,
                    vs[j].provider,
                    vs[j].channelId,
                    vs[j].cumulative,
                    vs[j].calls,
                    vs[j].issuedAt,
                    vs[j].expiresAt
                )
            );
            (uint8 vv, bytes32 r, bytes32 s) =
                vm.sign(_delegateKey(i), keccak256(abi.encodePacked("\x19\x01", ds, sh)));
            sigs = abi.encodePacked(sigs, r, s, vv);
        }
        data = abi.encodeCall(AssayEscrow.settleChannels, (vs, sigs, from, ch));
    }

    function _collectChannelsData(uint256 first, uint256 k) internal view returns (bytes memory) {
        ChannelRef[] memory refs = new ChannelRef[](k);
        for (uint256 j = 0; j < k; ++j) {
            (uint256 i, address prov, bytes32 lane) = _channel(first + j);
            refs[j] = ChannelRef(vm.addr(_payerKey(i)), vm.addr(_delegateKey(i)), prov, lane);
        }
        return abi.encodeCall(AssayEscrow.collectChannels, (refs, new uint64[](k)));
    }
}

/// The upgrade keeps state, then both doors work on real USDG.
contract ChannelMainnetUpgradeTest is MainnetBase {
    function setUp() public {
        live = _fork();
    }

    function test_upgradeKeepsStateThenBothDoorsWork() public {
        AssayConfig cfg = AssayConfig(CONFIG);
        uint128 escrowed = esc.totalEscrowed();
        uint128 held = esc.totalHeld();
        uint256 balance = IERC20(USDG).balanceOf(ESCROW);
        bytes32 s2 = vm.load(ESCROW, bytes32(uint256(2)));
        bytes32 ds = esc.DOMAIN_SEPARATOR();
        address cfgBefore = address(esc.CONFIG());

        _upgrade();

        assertEq(esc.totalEscrowed(), escrowed);
        assertEq(esc.totalHeld(), held);
        assertEq(IERC20(USDG).balanceOf(ESCROW), balance);
        assertEq(vm.load(ESCROW, bytes32(uint256(2))), s2);
        assertEq(esc.DOMAIN_SEPARATOR(), ds, "outstanding signatures stay valid");
        assertEq(address(esc.CONFIG()), cfgBefore);
        (uint256 st, uint128 un, uint128 tu, uint128 ch) = esc.channelBooks(bytes32(0), address(0));
        assertEq(st + un + tu + ch, 0, "fresh channel storage");

        _onboard();
        // per-call door still works after the upgrade
        (bytes memory pdata, Voucher[] memory pv) = _perCallBatch(7);
        _send(REDEEMER, pdata);
        vm.warp(_now() + 2 hours);
        _send(REDEEMER, _collectHeldData(pv));

        // channel door: settle, then collect at maturity with real transfers
        vm.recordLogs();
        _send(REDEEMER, _settleData(0, 14, 10));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 j = 0; j < logs.length; ++j) {
            if (logs[j].topics[0] == ChannelDoor.ChannelSettleSkipped.selector) {
                (,, uint8 reason) = abi.decode(logs[j].data, (bytes32, uint64, uint8));
                console2.log("skipped index / reason", uint256(logs[j].topics[1]), reason);
            }
        }
        (,,, uint128 chHeld) = esc.channelBooks(bytes32(0), address(0));
        assertEq(chHeld, 14 * 10 * PRICE);
        vm.warp(_now() + 2 hours);
        uint256 pa = IERC20(USDG).balanceOf(PROV_A);
        uint256 pb = IERC20(USDG).balanceOf(PROV_B);
        address treasury = cfg.params().treasury;
        uint256 tb = IERC20(USDG).balanceOf(treasury);
        _send(REDEEMER, _collectChannelsData(0, 14));
        uint256 gross = 14 * 10 * PRICE;
        uint256 fee = gross / 10;
        assertEq(
            IERC20(USDG).balanceOf(PROV_A) - pa + IERC20(USDG).balanceOf(PROV_B) - pb, gross - fee
        );
        assertEq(IERC20(USDG).balanceOf(treasury) - tb, fee);
        (,,, chHeld) = esc.channelBooks(bytes32(0), address(0));
        assertEq(chHeld, 0);
        assertGe(
            IERC20(USDG).balanceOf(ESCROW), uint256(esc.totalEscrowed()) + esc.totalHeld(), "I7"
        );
    }
}

/// Gas before (v2, live) and after (v3) on the same fork state. ONE measured transaction per
/// test function, every preparation in `setUp`: forge runs a test function as one transaction,
/// so a second measured call inside it would find the slots of the first one warm.
abstract contract GasBase is MainnetBase {
    uint256[4] internal SIZES = [uint256(1), 6, 20, 64];
    Voucher[][4] internal prepared;

    function upgraded() internal pure virtual returns (bool);

    function setUp() public virtual {
        live = _fork();
        if (!live) return;
        if (upgraded()) _upgrade();
        _onboard();
        // warm-up: payer, delegate and seq slots non-zero, as in steady state
        (bytes memory d,) = _perCallBatch(PAYERS);
        _send(REDEEMER, d);
        // held payments for the collect measurements
        for (uint256 s = 0; s < 4; ++s) {
            Voucher[] memory vs;
            (d, vs) = _perCallBatch(SIZES[s]);
            _send(REDEEMER, d);
            for (uint256 k = 0; k < vs.length; ++k) {
                prepared[s].push(vs[k]);
            }
        }
        vm.warp(_now() + 2 hours);
    }

    function _tag() internal pure returns (string memory) {
        return upgraded() ? "AFTER" : "BEFORE";
    }

    function _redeem(uint256 n) internal {
        (bytes memory d,) = _perCallBatch(n);
        uint256 g = _send(REDEEMER, d);
        console2.log(string.concat(_tag(), " per-call redeem: n, tx gas, per item"), n, g, g / n);
    }

    function _collectHeld(uint256 s) internal {
        uint256 g = _send(REDEEMER, _collectHeldData(prepared[s]));
        console2.log(
            string.concat(_tag(), " per-call collect: n, tx gas, per item"),
            SIZES[s],
            g,
            g / SIZES[s]
        );
    }

    function test_redeem_1() public {
        _redeem(1);
    }

    function test_redeem_6() public {
        _redeem(6);
    }

    function test_redeem_20() public {
        _redeem(20);
    }

    function test_redeem_64() public {
        _redeem(64);
    }

    function test_collectHeld_1() public {
        _collectHeld(0);
    }

    function test_collectHeld_6() public {
        _collectHeld(1);
    }

    function test_collectHeld_20() public {
        _collectHeld(2);
    }

    function test_collectHeld_64() public {
        _collectHeld(3);
    }
}

contract GasBeforeTest is GasBase {
    function upgraded() internal pure override returns (bool) {
        return false;
    }
}

contract GasAfterTest is GasBase {
    function upgraded() internal pure override returns (bool) {
        return true;
    }
}

/// The channel door: per k channels in one tx, a first settlement (new channels), a recurring
/// one (an hour later, second bucket), and the collect of a matured bucket.
contract GasChannelsTest is MainnetBase {
    uint256[6] internal KS = [uint256(1), 3, 7, 14, 28, 64];
    uint256[6] internal base;
    uint256 internal fresh; // channel index range never settled

    function setUp() public {
        live = _fork();
        if (!live) return;
        _upgrade();
        _onboard();
        (bytes memory d,) = _perCallBatch(PAYERS);
        _send(REDEEMER, d);
        uint256 c;
        for (uint256 s = 0; s < 6; ++s) {
            base[s] = c;
            _send(REDEEMER, _settleData(c, KS[s], 10));
            c += KS[s];
        }
        fresh = c;
        vm.warp(_now() + 2 hours); // first buckets matured; a new settle lands in the second
    }

    function _new(uint256 s) internal {
        uint256 g = _send(REDEEMER, _settleData(fresh, KS[s], 10));
        console2.log("AFTER channel settle NEW: k, tx gas, per channel", KS[s], g, g / KS[s]);
    }

    function _recurring(uint256 s) internal {
        (,,, uint128 h0) = esc.channelBooks(bytes32(0), address(0));
        uint256 g = _send(REDEEMER, _settleData(base[s], KS[s], 10));
        (,,, uint128 h1) = esc.channelBooks(bytes32(0), address(0));
        assertEq(h1 - h0, KS[s] * 10 * PRICE, "every channel settled (no skip)");
        console2.log("AFTER channel settle RECURRING: k, tx gas, per channel", KS[s], g, g / KS[s]);
    }

    function _collect(uint256 s) internal {
        (,,, uint128 h0) = esc.channelBooks(bytes32(0), address(0));
        uint256 g = _send(REDEEMER, _collectChannelsData(base[s], KS[s]));
        (,,, uint128 h1) = esc.channelBooks(bytes32(0), address(0));
        assertEq(h0 - h1, KS[s] * 10 * PRICE, "every bucket paid");
        console2.log("AFTER channel collect: k, tx gas, per channel", KS[s], g, g / KS[s]);
    }

    function test_new_1() public {
        _new(0);
    }

    function test_new_3() public {
        _new(1);
    }

    function test_new_7() public {
        _new(2);
    }

    function test_new_14() public {
        _new(3);
    }

    function test_new_28() public {
        _new(4);
    }

    function test_new_64() public {
        _new(5);
    }

    function test_recurring_1() public {
        _recurring(0);
    }

    function test_recurring_3() public {
        _recurring(1);
    }

    function test_recurring_7() public {
        _recurring(2);
    }

    function test_recurring_14() public {
        _recurring(3);
    }

    function test_recurring_28() public {
        _recurring(4);
    }

    function test_recurring_64() public {
        _recurring(5);
    }

    function test_collect_1() public {
        _collect(0);
    }

    function test_collect_3() public {
        _collect(1);
    }

    function test_collect_7() public {
        _collect(2);
    }

    function test_collect_14() public {
        _collect(3);
    }

    function test_collect_28() public {
        _collect(4);
    }

    function test_collect_64() public {
        _collect(5);
    }

    function test_refund_1() public {
        (uint256 i, address prov, bytes32 lane) = _channel(0);
        ChannelRef[] memory refs = new ChannelRef[](1);
        refs[0] = ChannelRef(vm.addr(_payerKey(i)), vm.addr(_delegateKey(i)), prov, lane);
        (uint256 w,,,) = esc.channelBooks(
            ChannelDoor.keyOf(refs[0].payer, refs[0].signer, prov, lane), address(0)
        );
        uint40[] memory ms = new uint40[](1);
        ms[0] = uint40((((w >> 128) & 0xFFFFFF) << 16) | ((w >> 152) & 0xFFFF));
        uint64[] memory a = new uint64[](1);
        a[0] = PRICE;
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = keccak256("fork-refund-1");
        uint256 g = _send(REDEEMER, abi.encodeCall(AssayEscrow.refundChannels, (refs, ms, a, ids)));
        console2.log("AFTER channel refund, one item: tx gas", g);
    }
}
