// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AssayConfig} from "../../src/AssayConfig.sol";
import {AssayEscrow} from "../../src/AssayEscrow.sol";
import {AssayEscrowStorage} from "../../src/AssayEscrowStorage.sol";
import {IAssayEscrow} from "../../src/interfaces/IAssayEscrow.sol";
import {AssayStake} from "../../src/AssayStake.sol";
import {IAssayConfig} from "../../src/interfaces/IAssayConfig.sol";
import {IAssayStakeView} from "../../src/interfaces/IAssayStakeView.sol";
import {ChannelDoor} from "../../src/libraries/ChannelDoor.sol";
import {Voucher, ParamSet, ChannelVoucher, ChannelRef} from "../../src/Types.sol";
import {MockUSDG} from "../helpers/MockUSDG.sol";
import {VoucherSigner} from "../helpers/VoucherSigner.sol";

/// Drives both doors of one escrow at random: channel settle (honest and stale bases, partial
/// charges, either signer), collect (redeemer with `keepHeld`, stranger), refund (any bucket,
/// any amount), a provider frozen by the token and `claimUnpaid`, per-call redeem / collect /
/// refund, deposit, withdraw, cap changes and time. A ghost ledger per channel records what the
/// chain must agree with.
contract ChannelHandler is Test {
    bytes32 internal constant CHANNEL_TYPEHASH = keccak256(
        "ChannelVoucher(address payer,address provider,bytes32 channelId,uint64 cumulative,"
        "uint32 calls,uint64 issuedAt,uint64 expiresAt)"
    );

    MockUSDG public usdg;
    AssayConfig public config;
    IAssayEscrow public escrow;
    AssayStake public stake;

    address internal constant ADMIN = address(0xADAA);
    address public constant TREASURY = address(0x7EA5);
    address internal constant REDEEMER = address(0x4EED);
    address[2] public providers = [address(0x9309), address(0x930A)];
    uint64 internal constant MINIMUM_STAKE = 100_000_000;

    uint256[3] internal payerKeys = [uint256(0xA1), 0xA2, 0xA3];
    uint256[3] internal delegateKeys = [uint256(0xD1), 0xD2, 0xD3];
    address[3] public payers;

    /// A channel: (payer index, signer is delegate?, provider index, lane). 3*2*2*2 = 24.
    struct Ghost {
        uint64 signed; // highest cumulative "signed" by the client so far
        uint32 calls;
        uint64 charged;
        uint64 waived;
        uint64 collected;
        uint64 refunded;
    }

    mapping(uint256 => Ghost) public ghost;
    uint256 public constant CHANNELS = 24;

    // per-call door bookkeeping
    uint64[3] internal nextSeq;
    uint256[] internal heldPayer;
    uint64[] internal heldSeq;

    uint256 public settles;
    uint256 public settleAttempts;
    /// Settlements that folded into an occupied bucket and moved its maturity (H1 fix), and
    /// whether any settlement ever moved a holding bucket's maturity EARLIER (it must not).
    uint256 public folds;
    bool public maturityMovedEarlier;
    uint256 public collects;
    /// Refunds that moved money out of the bucket they did not name. Must stay zero.
    uint256 public wrongBucketRefunds;
    uint256 public rateChanges;

    constructor() {
        usdg = new MockUSDG();
        ParamSet memory p = ParamSet({
            treasury: TREASURY,
            redeemer: REDEEMER,
            unbondingPeriodSeconds: 14 * 86_400,
            minimumStake: MINIMUM_STAKE,
            penaltyAmount: 1_000_000,
            verifierDailyCap: 500_000_000,
            takeRateBps: 1_000,
            slashAgentBps: 6_000,
            slashPlatformBps: 3_000,
            slashCapBps: 1_000
        });
        config = AssayConfig(
            address(
                new ERC1967Proxy(
                    address(new AssayConfig()),
                    abi.encodeCall(AssayConfig.initialize, (p, ADMIN, address(0x0A1E)))
                )
            )
        );
        stake = AssayStake(
            address(
                new ERC1967Proxy(
                    address(new AssayStake()),
                    abi.encodeCall(
                        AssayStake.initialize,
                        (IAssayConfig(address(config)), IERC20(address(usdg)))
                    )
                )
            )
        );
        escrow = IAssayEscrow(
            address(
                new ERC1967Proxy(
                    address(new AssayEscrow()),
                    abi.encodeCall(
                        AssayEscrow.initialize,
                        (
                            IAssayConfig(address(config)),
                            IAssayStakeView(address(stake)),
                            IERC20(address(usdg))
                        )
                    )
                )
            )
        );
        usdg.mint(address(this), 10 * MINIMUM_STAKE);
        usdg.approve(address(stake), 10 * MINIMUM_STAKE);
        stake.depositStakeFor(providers[0], 5 * MINIMUM_STAKE);
        stake.depositStakeFor(providers[1], 5 * MINIMUM_STAKE);
        for (uint256 i = 0; i < 3; ++i) {
            payers[i] = vm.addr(payerKeys[i]);
            usdg.mint(payers[i], 1_000e6);
            vm.startPrank(payers[i]);
            usdg.approve(address(escrow), type(uint256).max);
            escrow.deposit(200e6);
            escrow.setLimits(2e6, 150e6);
            escrow.authorizeDelegate(
                vm.addr(delegateKeys[i]), 2e6, 100e6, uint64(block.timestamp + 365 days)
            );
            vm.stopPrank();
            nextSeq[i] = 1;
        }
    }

    function _decode(uint256 c)
        internal
        view
        returns (address payer, uint256 signerKey, address signer, address provider, bytes32 lane)
    {
        uint256 pi = c % 3;
        bool byDelegate = (c / 3) % 2 == 1;
        payer = payers[pi];
        signerKey = byDelegate ? delegateKeys[pi] : payerKeys[pi];
        signer = vm.addr(signerKey);
        provider = providers[(c / 6) % 2];
        lane = keccak256(abi.encode("lane", (c / 12) % 2));
    }

    function slotOf(uint256 c) public view returns (ChannelDoor.Slot memory) {
        (address payer,, address signer, address provider, bytes32 lane) = _decode(c);
        (uint256 w,,,) =
            escrow.channelBooks(keccak256(abi.encode(payer, signer, provider, lane)), address(0));
        return ChannelDoor.unpack(w);
    }

    function _ref(uint256 c) internal view returns (ChannelRef memory) {
        (address payer,, address signer, address provider, bytes32 lane) = _decode(c);
        return ChannelRef(payer, signer, provider, lane);
    }

    // ------------------------------------------------------------------ channel actions

    /// The client signs `price` more for `n` calls; the redeemer settles with a charge of at most
    /// the delta, against the true base or (sometimes) a stale one.
    function settle(uint256 cSeed, uint64 price, uint8 n, uint64 chargeCut, bool stale) external {
        uint256 c = cSeed % CHANNELS;
        (address payer, uint256 signerKey,, address provider, bytes32 lane) = _decode(c);
        Ghost storage g = ghost[c];
        n = uint8(bound(n, 1, 5));
        price = uint64(bound(price, 1, 3e6));
        uint64 cum = g.signed + price;
        uint32 calls = g.calls + n;
        ChannelDoor.Slot memory sl = slotOf(c);
        uint64 from = uint64(sl.settled);
        // a stale base, one settle in four: must skip, never charge
        if (stale && chargeCut % 4 == 0 && from > 0) from = from - 1;
        uint64 delta = cum - uint64(sl.settled);
        uint64 charge = delta - uint64(bound(chargeCut, 0, delta));
        ChannelVoucher memory v = ChannelVoucher(
            payer,
            provider,
            lane,
            cum,
            calls,
            uint64(block.timestamp),
            uint64(block.timestamp + 240)
        );
        bytes32 sh = keccak256(
            abi.encode(
                CHANNEL_TYPEHASH,
                v.payer,
                v.provider,
                v.channelId,
                v.cumulative,
                v.calls,
                v.issuedAt,
                v.expiresAt
            )
        );
        (uint8 vv, bytes32 r, bytes32 s) = vm.sign(
            signerKey, keccak256(abi.encodePacked("\x19\x01", escrow.DOMAIN_SEPARATOR(), sh))
        );
        ChannelVoucher[] memory vs = new ChannelVoucher[](1);
        vs[0] = v;
        uint64[] memory f = new uint64[](1);
        f[0] = from;
        uint64[] memory ch = new uint64[](1);
        ch[0] = charge > cum - from ? cum - from : charge;
        if (cum <= from) return;
        // the client signed it either way
        g.signed = cum;
        g.calls = calls;
        ++settleAttempts;
        vm.prank(REDEEMER);
        escrow.settleChannels(vs, abi.encodePacked(r, s, vv), f, ch);
        ChannelDoor.Slot memory after_ = slotOf(c);
        if (after_.settled != sl.settled) {
            // it landed: bookkeeping follows the chain's own delta
            uint64 held = uint64(after_.h1 + after_.h2) - uint64(sl.h1 + sl.h2);
            g.charged += held;
            g.waived += uint64(after_.settled - sl.settled) - held;
            ++settles;
            // a bucket that held money and still holds the same rate keeps or delays its maturity
            if (sl.h1 != 0 && after_.h1 != 0 && after_.r1 == sl.r1) {
                if (after_.m1 < sl.m1) maturityMovedEarlier = true;
                if (after_.m1 > sl.m1) ++folds;
            }
            if (sl.h2 != 0 && after_.h2 != 0 && after_.r2 == sl.r2) {
                if (after_.m2 < sl.m2) maturityMovedEarlier = true;
                if (after_.m2 > sl.m2) ++folds;
            }
        }
    }

    function collect(uint256 cSeed, bool asStranger, uint64 keep) external {
        uint256 c = cSeed % CHANNELS;
        ChannelDoor.Slot memory before = slotOf(c);
        ChannelRef[] memory refs = new ChannelRef[](1);
        refs[0] = _ref(c);
        uint64[] memory k = new uint64[](1);
        k[0] = asStranger ? 0 : uint64(bound(keep, 0, 2e6));
        if (asStranger) {
            escrow.collectChannels(refs, k);
        } else {
            vm.prank(REDEEMER);
            escrow.collectChannels(refs, k);
        }
        ChannelDoor.Slot memory after_ = slotOf(c);
        ghost[c].collected += uint64(before.h1 + before.h2 - after_.h1 - after_.h2);
        ++collects;
    }

    function refund(uint256 cSeed, bool second, uint64 amount) external {
        uint256 c = cSeed % CHANNELS;
        ChannelDoor.Slot memory before = slotOf(c);
        uint256 m = second ? before.m2 : before.m1;
        uint256 h = second ? before.h2 : before.h1;
        if (h == 0) return;
        ChannelRef[] memory refs = new ChannelRef[](1);
        refs[0] = _ref(c);
        uint40[] memory ms = new uint40[](1);
        ms[0] = uint40((m << 16) | (second ? before.r2 : before.r1));
        uint64[] memory a = new uint64[](1);
        a[0] = uint64(bound(amount, 0, h + 1));
        vm.prank(REDEEMER);
        escrow.refundChannels(refs, ms, a);
        ChannelDoor.Slot memory after_ = slotOf(c);
        ghost[c].refunded += uint64(before.h1 + before.h2 - after_.h1 - after_.h2);
        // Only the named bucket may move: the other one keeps its amount, hour and rate.
        if (
            second
                ? (after_.h1 != before.h1 || after_.m1 != before.m1 || after_.r1 != before.r1)
                : (after_.h2 != before.h2 || after_.m2 != before.m2 || after_.r2 != before.r2)
        ) ++wrongBucketRefunds;
    }

    /// The admin moves the take rate between 10% and 20%, so one hour can hold two buckets
    /// that differ only by rate (I11) and refunds must tell them apart by rate.
    function setTakeRate(bool high) external {
        ParamSet memory p = config.params();
        p.takeRateBps = high ? 2_000 : 1_000;
        vm.prank(ADMIN);
        try config.updateConfig(p) {
            ++rateChanges;
        } catch {}
    }

    function freezeProvider(uint256 pSeed, bool frozen) external {
        usdg.setBlocked(providers[pSeed % 2], frozen);
    }

    function claim(uint256 pSeed) external {
        address to = pSeed % 3 == 2 ? TREASURY : providers[pSeed % 2];
        if (usdg.blocked(to)) return;
        escrow.claimUnpaid(to);
    }

    // ------------------------------------------------------------------ the per-call door

    function redeem(uint256 pSeed, uint64 amount) external {
        uint256 pi = pSeed % 3;
        amount = uint64(bound(amount, 1, 2e6));
        Voucher memory pv = Voucher(
            payers[pi],
            providers[pSeed % 2],
            amount,
            bytes32(0),
            bytes32(uint256(nextSeq[pi])),
            nextSeq[pi],
            uint64(block.timestamp),
            uint64(block.timestamp + 240)
        );
        bytes memory sig =
            VoucherSigner.signVoucher(delegateKeys[pi], escrow.DOMAIN_SEPARATOR(), pv);
        vm.prank(REDEEMER);
        try escrow.redeemVoucher(pv, sig) {
            heldPayer.push(pi);
            heldSeq.push(nextSeq[pi]);
            ++nextSeq[pi];
        } catch {}
    }

    function collectHeld(uint256 pick) external {
        if (heldSeq.length == 0) return;
        uint256 k = pick % heldSeq.length;
        vm.prank(REDEEMER);
        try escrow.collectHeld(payers[heldPayer[k]], heldSeq[k]) {} catch {}
    }

    function refundHeld(uint256 pick) external {
        if (heldSeq.length == 0) return;
        uint256 k = pick % heldSeq.length;
        vm.prank(REDEEMER);
        try escrow.refundHeld(payers[heldPayer[k]], heldSeq[k]) {} catch {}
    }

    // ------------------------------------------------------------------ buyer and time

    function deposit(uint256 pSeed, uint64 amount) external {
        amount = uint64(bound(amount, 1, 50e6));
        vm.prank(payers[pSeed % 3]);
        escrow.deposit(amount);
    }

    function setLimits(uint256 pSeed, uint64 v, uint64 w) external {
        // Cap refusals are unit-tested; here caps stay workable so settlements keep landing.
        v = uint64(bound(v, 1e6, 3e6));
        w = uint64(bound(w, 50e6, 200e6));
        vm.prank(payers[pSeed % 3]);
        try escrow.setLimits(v, w) {} catch {}
    }

    function withdraw(uint256 pSeed, uint64 amount) external {
        address a = payers[pSeed % 3];
        vm.prank(a);
        escrow.requestWithdraw(uint64(bound(amount, 1, 20e6)));
        vm.warp(block.timestamp + 3 hours);
        vm.prank(a);
        try escrow.withdraw() {} catch {}
    }

    function warp(uint32 s) external {
        vm.warp(block.timestamp + bound(s, 1, 3 days));
    }

    // ------------------------------------------------------------------ reads

    function sumOfBuckets() external view returns (uint256 t) {
        for (uint256 c = 0; c < CHANNELS; ++c) {
            ChannelDoor.Slot memory s = slotOf(c);
            t += s.h1 + s.h2;
        }
    }

    function sumOfBalances() external view returns (uint256 t) {
        for (uint256 i = 0; i < 3; ++i) {
            t += escrow.escrowOf(payers[i]).balance;
        }
    }

    function sumOfPerCallHeld() external view returns (uint256 t) {
        for (uint256 k = 0; k < heldSeq.length; ++k) {
            AssayEscrowStorage.HeldPayment memory h = escrow.held(payers[heldPayer[k]], heldSeq[k]);
            if (h.status == AssayEscrowStorage.HeldStatus.Held) t += h.amount;
        }
    }

    function sumOfUnpaid() external view returns (uint256 t) {
        (, uint128 a,,) = escrow.channelBooks(bytes32(0), providers[0]);
        (, uint128 b,,) = escrow.channelBooks(bytes32(0), providers[1]);
        (, uint128 c,,) = escrow.channelBooks(bytes32(0), TREASURY);
        t = uint256(a) + b + c;
    }
}
