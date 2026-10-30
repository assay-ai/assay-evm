// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.38;

import {Fixture} from "./helpers/Fixture.sol";
import {VoucherSigner} from "./helpers/VoucherSigner.sol";
import {AssayEscrow} from "../src/AssayEscrow.sol";
import {ChannelDoor} from "../src/libraries/ChannelDoor.sol";
import {Constants} from "../src/Constants.sol";
import {ChannelVoucher, ChannelRef, Voucher, ParamSet} from "../src/Types.sol";
import "../src/Errors.sol";

/// A token whose transfer burns every unit of gas it is given: a payout to anyone always fails
/// by running out of gas, which is the shape a caller would use to force a deferral.
contract GasBurnToken {
    uint8 public constant decimals = 6;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        allowance[f][msg.sender] -= a;
        balanceOf[f] -= a;
        balanceOf[t] += a;
        return true;
    }

    function transfer(address, uint256) external view returns (bool) {
        while (gasleft() > 0) {}
        return true;
    }
}

/// The channel door of `AssayEscrow` (spec P2 v3.1 §3): settle, collect, refund, unpaid.
contract AssayEscrowChannelTest is Fixture {
    // The EIP-712 type string written out a second time, independently of `src/Types.sol`.
    bytes32 internal constant CHANNEL_TYPEHASH = keccak256(
        "ChannelVoucher(address payer,address provider,bytes32 channelId,uint64 cumulative,"
        "uint32 calls,uint64 issuedAt,uint64 expiresAt)"
    );

    uint256 internal delegateKey = 0xDE1E6A7E;
    address internal delegate;
    bytes32 internal constant CH = keccak256("lane-1");

    uint64 internal constant V = 1_000_000; // per-call cap: 1 USDG
    uint64 internal constant W = 100_000_000; // escrow window: 100 USDG
    uint64 internal constant DW = 50_000_000; // delegate window: 50 USDG

    function setUp() public override {
        super.setUp();
        delegate = vm.addr(delegateKey);
        _fund(buyer, 1_000e6);
        vm.startPrank(buyer);
        usdg.approve(address(escrow), type(uint256).max);
        escrow.deposit(500e6);
        escrow.setLimits(V, W);
        escrow.authorizeDelegate(delegate, V, DW, uint64(block.timestamp + 30 days));
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------- helpers

    struct S {
        uint256 settled;
        uint256 calls;
        uint256 h1;
        uint256 m1;
        uint256 r1;
        uint256 h2;
        uint256 m2;
        uint256 r2;
    }

    function _now() internal view returns (uint64) {
        return uint64(vm.getBlockTimestamp());
    }

    function _cv(bytes32 ch, uint64 cum, uint32 calls)
        internal
        view
        returns (ChannelVoucher memory)
    {
        return ChannelVoucher({
            payer: buyer,
            provider: provider,
            channelId: ch,
            cumulative: cum,
            calls: calls,
            issuedAt: _now(),
            expiresAt: _now() + 240
        });
    }

    function _sign(uint256 pk, ChannelVoucher memory v) internal view returns (bytes memory) {
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
        (uint8 vv, bytes32 r, bytes32 s) =
            vm.sign(pk, keccak256(abi.encodePacked("\x19\x01", escrow.DOMAIN_SEPARATOR(), sh)));
        return abi.encodePacked(r, s, vv);
    }

    function _one(ChannelVoucher memory v) internal pure returns (ChannelVoucher[] memory vs) {
        vs = new ChannelVoucher[](1);
        vs[0] = v;
    }

    function _u(uint64 a) internal pure returns (uint64[] memory x) {
        x = new uint64[](1);
        x[0] = a;
    }

    function _settle(ChannelVoucher memory v, bytes memory sig, uint64 from, uint64 charge)
        internal
    {
        vm.prank(redeemer);
        escrow.settleChannels(_one(v), sig, _u(from), _u(charge));
    }

    /// Delegate-signed settle of `cum` with `calls`, charging all of `cum - from`.
    function _settleD(uint64 from, uint64 cum, uint32 calls) internal {
        ChannelVoucher memory v = _cv(CH, cum, calls);
        _settle(v, _sign(delegateKey, v), from, cum - from);
    }

    function _key(address signer) internal view returns (bytes32) {
        return keccak256(abi.encode(buyer, signer, provider, CH));
    }

    /// Independent decoder of the packed slot (spec §3.1).
    function _slot(address signer) internal view returns (S memory s) {
        (uint256 w,,,) = escrow.channelBooks(_key(signer), address(0));
        s.settled = w & ((1 << 56) - 1);
        s.calls = (w >> 56) & ((1 << 24) - 1);
        s.h1 = (w >> 80) & ((1 << 48) - 1);
        s.m1 = (w >> 128) & ((1 << 24) - 1);
        s.r1 = (w >> 152) & 0xFFFF;
        s.h2 = (w >> 168) & ((1 << 48) - 1);
        s.m2 = (w >> 216) & ((1 << 24) - 1);
        s.r2 = (w >> 240) & 0xFFFF;
    }

    function _held() internal view returns (uint128 h) {
        (,,, h) = escrow.channelBooks(bytes32(0), address(0));
    }

    function _unpaid(address to) internal view returns (uint128 a, uint128 t) {
        (, a, t,) = escrow.channelBooks(bytes32(0), to);
    }

    function _ref(address signer) internal view returns (ChannelRef[] memory r) {
        r = new ChannelRef[](1);
        r[0] = ChannelRef(buyer, signer, provider, CH);
    }

    function _maturity() internal view returns (uint64) {
        return uint64((uint256(_now()) + config.collectHoldSeconds() + 3599) / 3600);
    }

    function _expectSkip(uint256 i, bytes32 key, uint64 cum, ChannelDoor.SettleSkip why) internal {
        vm.expectEmit(true, true, false, true, address(escrow));
        emit ChannelDoor.ChannelSettleSkipped(i, buyer, key, cum, uint8(why));
    }

    /// Escrow USDG covers every liability (I7) and the per-payer identity holds (D-14).
    function _assertBooks() internal view {
        (,, uint128 totalUnpaid, uint128 held) = escrow.channelBooks(bytes32(0), address(0));
        assertGe(
            usdg.balanceOf(address(escrow)),
            uint256(escrow.totalEscrowed()) + escrow.totalHeld() + held + totalUnpaid,
            "I7"
        );
        AssayEscrow.Escrow memory e = escrow.escrowOf(buyer);
        assertEq(e.totalFunded, e.balance + e.totalRedeemed + e.totalWithdrawn, "D-14");
    }

    // ---------------------------------------------------------------------- settle: happy

    function test_settle_delegateSigned_movesTheChargeIntoABucket() public {
        AssayEscrow.Escrow memory before = escrow.escrowOf(buyer);
        uint128 escrowedBefore = escrow.totalEscrowed();
        uint64 m = _maturity();

        vm.expectEmit(true, true, true, true, address(escrow));
        emit ChannelDoor.ChannelSettled(
            _key(delegate),
            buyer,
            delegate,
            provider,
            CH,
            300_000,
            3,
            300_000,
            0,
            uint24(m),
            TAKE_RATE_BPS
        );
        _settleD(0, 300_000, 3);

        S memory s = _slot(delegate);
        assertEq(s.settled, 300_000);
        assertEq(s.calls, 3);
        assertEq(s.h1, 300_000);
        assertEq(s.m1, m);
        assertEq(s.r1, TAKE_RATE_BPS);
        assertEq(s.h2, 0);
        AssayEscrow.Escrow memory e = escrow.escrowOf(buyer);
        assertEq(e.balance, before.balance - 300_000);
        assertEq(e.totalRedeemed, before.totalRedeemed + 300_000);
        assertEq(e.spentInWindow, 300_000);
        assertEq(escrow.delegationOf(buyer, delegate).spentInWindow, 300_000);
        assertEq(escrow.totalEscrowed(), escrowedBefore - 300_000);
        assertEq(escrow.totalHeld(), 0, "per-call totalHeld untouched");
        assertEq(_held(), 300_000);
        _assertBooks();
    }

    function test_settle_payerSigned_usesThePayerAsKeySigner() public {
        ChannelVoucher memory v = _cv(CH, 200_000, 2);
        _settle(v, _sign(buyerKey, v), 0, 200_000);
        assertEq(_slot(buyer).settled, 200_000);
        assertEq(_slot(buyer).h1, 200_000);
        assertEq(_slot(delegate).settled, 0, "a different channel");
        assertEq(escrow.delegationOf(buyer, delegate).spentInWindow, 0);
    }

    function test_settle_partialCharge_waivesTheRest() public {
        ChannelVoucher memory v = _cv(CH, 500_000, 5);
        vm.expectEmit(true, true, true, true, address(escrow));
        emit ChannelDoor.ChannelSettled(
            _key(delegate),
            buyer,
            delegate,
            provider,
            CH,
            500_000,
            5,
            300_000,
            200_000,
            uint24(_maturity()),
            TAKE_RATE_BPS
        );
        _settle(v, _sign(delegateKey, v), 0, 300_000);
        assertEq(_slot(delegate).settled, 500_000);
        assertEq(_slot(delegate).h1, 300_000);
        assertEq(escrow.escrowOf(buyer).balance, 500e6 - 300_000);
    }

    function test_settle_zeroCharge_isAPureWaive() public {
        ChannelVoucher memory v = _cv(CH, 500_000, 5);
        _settle(v, _sign(delegateKey, v), 0, 0);
        S memory s = _slot(delegate);
        assertEq(s.settled, 500_000);
        assertEq(s.calls, 5);
        assertEq(s.h1 + s.h2 + s.m1 + s.r1, 0);
        assertEq(escrow.escrowOf(buyer).balance, 500e6);
        assertEq(escrow.escrowOf(buyer).spentInWindow, 0);
        assertEq(_held(), 0);
    }

    function test_settle_successiveSettlements_chainOnTheSettledBase() public {
        _settleD(0, 300_000, 3);
        _settleD(300_000, 700_000, 7);
        S memory s = _slot(delegate);
        assertEq(s.settled, 700_000);
        assertEq(s.calls, 7);
        assertEq(s.h1, 700_000, "same maturity hour and rate: one bucket");
        assertEq(_held(), 700_000);
    }

    function test_settle_twoChannelsOfOnePayerInOneBatch() public {
        ChannelVoucher[] memory vs = new ChannelVoucher[](2);
        vs[0] = _cv(CH, 100_000, 1);
        vs[1] = _cv(keccak256("lane-2"), 200_000, 2);
        bytes memory sigs = abi.encodePacked(_sign(delegateKey, vs[0]), _sign(delegateKey, vs[1]));
        uint64[] memory from = new uint64[](2);
        uint64[] memory ch = new uint64[](2);
        ch[0] = 100_000;
        ch[1] = 200_000;
        vm.prank(redeemer);
        escrow.settleChannels(vs, sigs, from, ch);
        assertEq(_held(), 300_000);
        assertEq(escrow.escrowOf(buyer).spentInWindow, 300_000);
        assertEq(escrow.delegationOf(buyer, delegate).spentInWindow, 300_000);
    }

    // ---------------------------------------------------------------------- settle: buckets

    function test_buckets_secondHourUsesTheSecondBucket_thirdHourSkipsUntilCollected() public {
        _settleD(0, 100_000, 1);
        uint256 m1 = _slot(delegate).m1;
        vm.warp(_now() + 3600);
        _settleD(100_000, 300_000, 3);
        S memory s = _slot(delegate);
        assertEq(s.h1, 100_000);
        assertEq(s.h2, 200_000);
        assertEq(s.m2, m1 + 1);

        vm.warp(_now() + 3600);
        ChannelVoucher memory v = _cv(CH, 600_000, 6);
        _expectSkip(0, _key(delegate), 600_000, ChannelDoor.SettleSkip.NoBucket);
        _settle(v, _sign(delegateKey, v), 300_000, 300_000);
        assertEq(_slot(delegate).settled, 300_000, "a skip writes nothing");

        // bucket 1 has matured: collect it, then the same voucher settles into the freed bucket
        vm.prank(redeemer);
        escrow.collectChannels(_ref(delegate), _u(0));
        _settle(v, _sign(delegateKey, v), 300_000, 300_000);
        s = _slot(delegate);
        assertEq(s.settled, 600_000);
        assertEq(s.h1, 300_000);
        assertEq(s.m1, m1 + 2);
        assertEq(s.h2, 200_000);
    }

    function test_buckets_aRateChangeOpensTheOtherBucket_neverMixesRates() public {
        _settleD(0, 100_000, 1);
        ParamSet memory p = config.params();
        p.takeRateBps = 2_000;
        vm.prank(admin);
        config.updateConfig(p);
        _settleD(100_000, 300_000, 3);
        S memory s = _slot(delegate);
        assertEq(s.m1, s.m2, "same hour");
        assertEq(s.r1, TAKE_RATE_BPS);
        assertEq(s.r2, 2_000);
        assertEq(s.h1, 100_000);
        assertEq(s.h2, 200_000);
    }

    function test_buckets_maturityFollowsTheHoldOnTheHourGrid() public {
        uint64[3] memory holds = [uint64(60), 3600, 86_400];
        for (uint256 i = 0; i < 3; ++i) {
            vm.prank(admin);
            config.setCollectHold(holds[i]);
            bytes32 ch = keccak256(abi.encode("hold", i));
            ChannelVoucher memory v = _cv(ch, 100_000, 1);
            _settle(v, _sign(delegateKey, v), 0, 100_000);
            (uint256 w,,,) = escrow.channelBooks(
                keccak256(abi.encode(buyer, delegate, provider, ch)), address(0)
            );
            uint256 m = (w >> 128) & 0xFFFFFF;
            assertEq(m, (uint256(_now()) + holds[i] + 3599) / 3600);
            assertGe(m * 3600, uint256(_now()) + holds[i], "never pays early");
            assertLt(m * 3600, uint256(_now()) + holds[i] + 3600, "at most an hour late");
        }
    }

    // ---------------------------------------------------------------------- settle: reverts

    function test_revert_notRedeemer() public {
        ChannelVoucher memory v = _cv(CH, 100_000, 1);
        bytes memory sig = _sign(delegateKey, v);
        vm.expectRevert(NotRedeemer.selector);
        escrow.settleChannels(_one(v), sig, _u(0), _u(100_000));
    }

    function test_revert_paused() public {
        vm.prank(admin);
        config.setPaused(true);
        ChannelVoucher memory v = _cv(CH, 100_000, 1);
        bytes memory sig = _sign(delegateKey, v);
        vm.prank(redeemer);
        vm.expectRevert(ProgramPaused.selector);
        escrow.settleChannels(_one(v), sig, _u(0), _u(100_000));
    }

    function test_revert_batchShape() public {
        ChannelVoucher memory v = _cv(CH, 100_000, 1);
        bytes memory sig = _sign(delegateKey, v);
        vm.startPrank(redeemer);
        vm.expectRevert(EmptyBatch.selector);
        escrow.settleChannels(new ChannelVoucher[](0), "", new uint64[](0), new uint64[](0));
        vm.expectRevert(BatchLengthMismatch.selector);
        escrow.settleChannels(_one(v), sig, new uint64[](2), _u(1));
        vm.expectRevert(BatchLengthMismatch.selector);
        escrow.settleChannels(_one(v), sig, _u(0), new uint64[](0));
        vm.expectRevert(BatchLengthMismatch.selector);
        escrow.settleChannels(_one(v), abi.encodePacked(sig, bytes1(0)), _u(0), _u(1));
        ChannelVoucher[] memory many = new ChannelVoucher[](65);
        vm.expectRevert(BatchTooLarge.selector);
        escrow.settleChannels(many, new bytes(65 * 65), new uint64[](65), new uint64[](65));
        vm.stopPrank();
    }

    function _expectSettleRevert(ChannelVoucher memory v, uint64 from, uint64 charge, bytes4 err)
        internal
    {
        bytes memory sig = _sign(delegateKey, v);
        vm.prank(redeemer);
        vm.expectRevert(err);
        escrow.settleChannels(_one(v), sig, _u(from), _u(charge));
    }

    function test_revert_calldataOnlyConditions() public {
        ChannelVoucher memory v = _cv(CH, 100_000, 1);
        v.expiresAt = v.issuedAt;
        _expectSettleRevert(v, 0, 1, InvalidVoucherWindow.selector);

        v = _cv(CH, 100_000, 1);
        v.expiresAt = v.issuedAt + 301;
        _expectSettleRevert(v, 0, 1, VoucherLifetimeTooLong.selector);

        _expectSettleRevert(_cv(CH, uint64(1 << 56), 1), 0, 1, ChannelValueOutOfRange.selector);
        _expectSettleRevert(
            _cv(CH, 100_000, uint32(1 << 24)), 0, 1, ChannelValueOutOfRange.selector
        );
        _expectSettleRevert(_cv(CH, 100_000, 1), 100_000, 0, ChannelNothingToSettle.selector);
        _expectSettleRevert(_cv(CH, 100_000, 1), 40_000, 60_001, ChannelChargeTooLarge.selector);
        // the largest values that fit are accepted (here as a pure waive)
        ChannelVoucher memory top = _cv(CH, uint64((1 << 56) - 1), uint32((1 << 24) - 1));
        _settle(top, _sign(delegateKey, top), 0, 0);
        assertEq(_slot(delegate).settled, (1 << 56) - 1);
        assertEq(_slot(delegate).calls, (1 << 24) - 1);
    }

    function test_revert_malformedSignatures() public {
        ChannelVoucher memory v = _cv(CH, 100_000, 1);
        bytes memory sig = _sign(delegateKey, v);
        vm.startPrank(redeemer);
        vm.expectRevert(MalleableSignature.selector);
        escrow.settleChannels(_one(v), VoucherSigner.malleate(sig), _u(0), _u(100_000));
        bytes memory badV = abi.encodePacked(sig);
        badV[64] = bytes1(uint8(29));
        vm.expectRevert(BadSignatureV.selector);
        escrow.settleChannels(_one(v), badV, _u(0), _u(100_000));
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------- settle: skips

    function test_skip_notYetValid_and_expired_keyZero_batchContinues() public {
        ChannelVoucher[] memory vs = new ChannelVoucher[](3);
        vs[0] = _cv(CH, 100_000, 1);
        vs[0].issuedAt = _now() + 121;
        vs[0].expiresAt = vs[0].issuedAt + 60;
        vs[1] = _cv(keccak256("lane-2"), 100_000, 1);
        vs[1].issuedAt = _now() - 8000;
        vs[1].expiresAt = vs[1].issuedAt + 100; // expiresAt + 7200 < now
        vs[2] = _cv(keccak256("lane-3"), 100_000, 1);
        bytes memory sigs = abi.encodePacked(
            _sign(delegateKey, vs[0]), _sign(delegateKey, vs[1]), _sign(delegateKey, vs[2])
        );
        _expectSkip(0, bytes32(0), 100_000, ChannelDoor.SettleSkip.NotYetValid);
        _expectSkip(1, bytes32(0), 100_000, ChannelDoor.SettleSkip.Expired);
        uint64[] memory ch = new uint64[](3);
        ch[0] = ch[1] = ch[2] = 100_000;
        vm.prank(redeemer);
        escrow.settleChannels(vs, sigs, new uint64[](3), ch);
        assertEq(_held(), 100_000, "only the third settled");
    }

    function test_skip_baseMismatch_staleAndDuplicate() public {
        _settleD(0, 300_000, 3);
        // stale: the redeemer still thinks the channel is at 0
        ChannelVoucher memory v = _cv(CH, 500_000, 5);
        _expectSkip(0, _key(delegate), 500_000, ChannelDoor.SettleSkip.BaseMismatch);
        _settle(v, _sign(delegateKey, v), 0, 500_000);
        assertEq(_slot(delegate).settled, 300_000);

        // duplicate in one batch: the second item names a base the first already moved
        ChannelVoucher[] memory vs = new ChannelVoucher[](2);
        vs[0] = _cv(CH, 500_000, 5);
        vs[1] = vs[0];
        uint64[] memory from = new uint64[](2);
        from[0] = from[1] = 300_000;
        uint64[] memory ch = new uint64[](2);
        ch[0] = ch[1] = 200_000;
        bytes memory sig = _sign(delegateKey, vs[0]);
        _expectSkip(1, _key(delegate), 500_000, ChannelDoor.SettleSkip.BaseMismatch);
        vm.prank(redeemer);
        escrow.settleChannels(vs, abi.encodePacked(sig, sig), from, ch);
        assertEq(_slot(delegate).settled, 500_000);
        assertEq(_held(), 500_000, "charged once");
    }

    function test_skip_authority_strangerExpiredRevoked() public {
        // a stranger's signature: the key it derives has no delegation
        uint256 strangerKey = 0x5172A;
        ChannelVoucher memory v = _cv(CH, 100_000, 1);
        bytes32 k = keccak256(abi.encode(buyer, vm.addr(strangerKey), provider, CH));
        _expectSkip(0, k, 100_000, ChannelDoor.SettleSkip.Authority);
        _settle(v, _sign(strangerKey, v), 0, 100_000);

        // revoked: still signs during the grace, not after
        vm.prank(buyer);
        escrow.revokeDelegate(delegate);
        _settleD(0, 100_000, 1);
        assertEq(_slot(delegate).settled, 100_000, "inside the revocation grace");
        vm.warp(_now() + Constants.TIGHTEN_DELAY_SECONDS + 1);
        v = _cv(CH, 200_000, 2);
        _expectSkip(0, _key(delegate), 200_000, ChannelDoor.SettleSkip.Authority);
        _settle(v, _sign(delegateKey, v), 100_000, 100_000);
    }

    function test_skip_authority_delegationExpired() public {
        vm.warp(_now() + 30 days + 1);
        ChannelVoucher memory v = _cv(CH, 100_000, 1);
        _expectSkip(0, _key(delegate), 100_000, ChannelDoor.SettleSkip.Authority);
        _settle(v, _sign(delegateKey, v), 0, 100_000);
    }

    function test_skip_calls_mustGrow() public {
        _settleD(0, 300_000, 3);
        ChannelVoucher memory v = _cv(CH, 400_000, 3);
        _expectSkip(0, _key(delegate), 400_000, ChannelDoor.SettleSkip.Calls);
        _settle(v, _sign(delegateKey, v), 300_000, 100_000);
    }

    function test_skip_blocked_payerProviderDelegate() public {
        address[3] memory who = [buyer, provider, delegate];
        for (uint256 i = 0; i < 3; ++i) {
            vm.prank(admin);
            config.setBlocked(who[i], true);
            ChannelVoucher memory v = _cv(CH, 100_000, 1);
            _expectSkip(0, _key(delegate), 100_000, ChannelDoor.SettleSkip.Blocked);
            _settle(v, _sign(delegateKey, v), 0, 100_000);
            vm.prank(admin);
            config.setBlocked(who[i], false);
        }
        // a pure waive moves no money and is not blocklist-gated
        vm.prank(admin);
        config.setBlocked(buyer, true);
        ChannelVoucher memory w = _cv(CH, 100_000, 1);
        _settle(w, _sign(delegateKey, w), 0, 0);
        assertEq(_slot(delegate).settled, 100_000);
    }

    function test_cap_isAnAverageOverTheCalls() public {
        // 3 calls may charge up to 3 * V in one settlement, even if one call alone exceeded V
        _settleD(0, 3 * V, 3);
        assertEq(_held(), 3 * V);
        ChannelVoucher memory v = _cv(CH, 3 * V + 2 * V + 1, 5);
        _expectSkip(0, _key(delegate), 5 * V + 1, ChannelDoor.SettleSkip.PerCallCap);
        _settle(v, _sign(delegateKey, v), 3 * V, 2 * V + 1);
    }

    function test_skip_escrowWindow_and_delegateWindow() public {
        // delegate window (50) binds before the escrow window (100)
        ChannelVoucher memory v = _cv(CH, DW + 1, 60);
        _expectSkip(0, _key(delegate), DW + 1, ChannelDoor.SettleSkip.DelegateWindow);
        _settle(v, _sign(delegateKey, v), 0, DW + 1);
        // the payer itself has only the escrow window
        v = _cv(CH, W + 1, 120);
        bytes32 kp = keccak256(abi.encode(buyer, buyer, provider, CH));
        _expectSkip(0, kp, W + 1, ChannelDoor.SettleSkip.EscrowWindow);
        _settle(v, _sign(buyerKey, v), 0, W + 1);
    }

    function test_heldCaps_honouredDuringTheTightenDelay_onlyWhole() public {
        // the payer lowers its caps; vouchers under the old pair stay settleable for the delay
        vm.prank(buyer);
        escrow.setLimits(V / 2, W / 10);
        vm.prank(buyer);
        escrow.authorizeDelegate(delegate, V / 2, W / 10, uint64(_now() + 30 days));
        _settleD(0, 3 * V, 3); // 3 USDG over 3 calls: fits the held pair, not the current one
        assertEq(_held(), 3 * V);
        vm.warp(_now() + Constants.TIGHTEN_DELAY_SECONDS + 1);
        ChannelVoucher memory v = _cv(CH, 6 * V, 6);
        _expectSkip(0, _key(delegate), 6 * V, ChannelDoor.SettleSkip.PerCallCap);
        _settle(v, _sign(delegateKey, v), 3 * V, 3 * V);
    }

    function test_skip_stake_and_balance() public {
        _setBonded(provider, MINIMUM_STAKE - 1);
        ChannelVoucher memory v = _cv(CH, 100_000, 1);
        _expectSkip(0, _key(delegate), 100_000, ChannelDoor.SettleSkip.Stake);
        _settle(v, _sign(delegateKey, v), 0, 100_000);
        _setBonded(provider, MINIMUM_STAKE);

        // drain the balance with a matured withdrawal, then a charge has nothing to take
        vm.prank(buyer);
        escrow.requestWithdraw(500e6);
        vm.warp(_now() + Constants.WITHDRAW_DELAY_SECONDS);
        vm.prank(buyer);
        escrow.withdraw();
        v = _cv(CH, 100_000, 1);
        _expectSkip(0, _key(delegate), 100_000, ChannelDoor.SettleSkip.Balance);
        _settle(v, _sign(delegateKey, v), 0, 100_000);
    }

    // ---------------------------------------------------------------------- domain separation

    function test_aPerCallVoucherSignatureIsNotAChannelSignature() public {
        Voucher memory pv = Voucher({
            payer: buyer,
            provider: provider,
            amount: 100_000,
            resourceHash: bytes32(0),
            requestHash: bytes32(0),
            seq: 1,
            issuedAt: _now(),
            expiresAt: _now() + 240
        });
        bytes memory psig = VoucherSigner.signVoucher(delegateKey, escrow.DOMAIN_SEPARATOR(), pv);
        ChannelVoucher memory v = _cv(CH, 100_000, 1);
        vm.recordLogs();
        _settle(v, psig, 0, 100_000);
        assertEq(_held(), 0, "a per-call signature charges nothing on the channel door");
    }

    function test_aChannelSignatureForAnotherEscrowIsWorthless() public {
        AssayEscrow other = _deployEscrow(address(usdg));
        ChannelVoucher memory v = _cv(CH, 100_000, 1);
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
            delegateKey, keccak256(abi.encodePacked("\x19\x01", other.DOMAIN_SEPARATOR(), sh))
        );
        _settle(v, abi.encodePacked(r, s, vv), 0, 100_000);
        assertEq(_held(), 0);
    }

    // ---------------------------------------------------------------------- collect

    function test_collect_beforeMaturity_isANoOp() public {
        _settleD(0, 300_000, 3);
        uint256 pb = usdg.balanceOf(provider);
        vm.prank(redeemer);
        escrow.collectChannels(_ref(delegate), _u(0));
        assertEq(usdg.balanceOf(provider), pb);
        assertEq(_held(), 300_000);
    }

    function test_collect_byRedeemerAtMaturity_paysProviderAndTreasury() public {
        _settleD(0, 300_000, 3);
        uint256 m = _slot(delegate).m1;
        vm.warp(m * 3600);
        uint256 pb = usdg.balanceOf(provider);
        uint256 tb = usdg.balanceOf(treasury);
        vm.expectEmit(true, true, false, true, address(escrow));
        emit ChannelDoor.ChannelCollected(_key(delegate), provider, uint24(m), 300_000, 30_000);
        vm.prank(redeemer);
        escrow.collectChannels(_ref(delegate), _u(0));
        assertEq(usdg.balanceOf(provider) - pb, 270_000);
        assertEq(usdg.balanceOf(treasury) - tb, 30_000);
        assertEq(_held(), 0);
        S memory s = _slot(delegate);
        assertEq(s.h1 + s.m1 + s.r1, 0, "an emptied bucket zeroes its maturity and rate");
        assertEq(s.settled, 300_000);
        _assertBooks();
    }

    function test_collect_byStranger_onlyAfterTheTimeout_andNeverWithKeepHeld() public {
        _settleD(0, 300_000, 3);
        uint256 m = _slot(delegate).m1;
        vm.warp(m * 3600);
        escrow.collectChannels(_ref(delegate), _u(0));
        assertEq(_held(), 300_000, "a stranger before the timeout pays nothing");
        vm.expectRevert(NotRedeemer.selector);
        escrow.collectChannels(_ref(delegate), _u(1));
        vm.warp(m * 3600 + Constants.HELD_TIMEOUT_SECONDS);
        uint256 pb = usdg.balanceOf(provider);
        escrow.collectChannels(_ref(delegate), _u(0));
        assertEq(usdg.balanceOf(provider) - pb, 270_000);
        assertEq(_held(), 0);
    }

    function test_collect_keepHeld_paysOldestFirst_remainderStaysInTheNewest() public {
        _settleD(0, 100_000, 1);
        uint256 m1 = _slot(delegate).m1;
        vm.warp(_now() + 3600);
        _settleD(100_000, 300_000, 3);
        vm.warp((m1 + 1) * 3600); // both matured
        uint256 pb = usdg.balanceOf(provider);
        vm.prank(redeemer);
        escrow.collectChannels(_ref(delegate), _u(50_000));
        S memory s = _slot(delegate);
        assertEq(s.h1, 0, "oldest emptied");
        assertEq(s.m1, 0);
        assertEq(s.h2, 50_000, "the kept amount stays in the newest bucket");
        assertEq(s.m2, m1 + 1, "with its maturity unchanged");
        assertEq(usdg.balanceOf(provider) - pb, 225_000); // 250k gross, 10% fee
        assertEq(_held(), 50_000);
    }

    function test_collect_keepHeldCoveringEverything_isANoOp() public {
        _settleD(0, 100_000, 1);
        vm.warp(_slot(delegate).m1 * 3600);
        vm.prank(redeemer);
        escrow.collectChannels(_ref(delegate), _u(100_000));
        assertEq(_held(), 100_000);
    }

    function test_collect_blockedParty_isSkipped() public {
        _settleD(0, 100_000, 1);
        vm.warp(_slot(delegate).m1 * 3600);
        vm.prank(admin);
        config.setBlocked(provider, true);
        vm.expectEmit(true, false, false, false, address(escrow));
        emit ChannelDoor.ChannelCollectSkipped(_key(delegate));
        vm.prank(redeemer);
        escrow.collectChannels(_ref(delegate), _u(0));
        assertEq(_held(), 100_000);
    }

    function test_collect_pausedReverts() public {
        _settleD(0, 100_000, 1);
        vm.warp(_slot(delegate).m1 * 3600);
        vm.prank(admin);
        config.setPaused(true);
        vm.prank(redeemer);
        vm.expectRevert(ProgramPaused.selector);
        escrow.collectChannels(_ref(delegate), _u(0));
    }

    function test_collect_feeRoundsDownPerBucket() public {
        _settleD(0, 19, 1); // 10% of 19 = 1.9 -> 1
        vm.warp(_slot(delegate).m1 * 3600);
        uint256 tb = usdg.balanceOf(treasury);
        uint256 pb = usdg.balanceOf(provider);
        vm.prank(redeemer);
        escrow.collectChannels(_ref(delegate), _u(0));
        assertEq(usdg.balanceOf(treasury) - tb, 1);
        assertEq(usdg.balanceOf(provider) - pb, 18);
    }

    // ---------------------------------------------------------------------- unpaid

    function test_unpaid_aFrozenProviderDefersOnlyItself_thenClaims() public mockTokenOnly {
        _settleD(0, 300_000, 3);
        vm.warp(_slot(delegate).m1 * 3600);
        usdg.setBlocked(provider, true); // the issuer freezes the provider
        uint256 tb = usdg.balanceOf(treasury);
        vm.expectEmit(true, false, false, true, address(escrow));
        emit ChannelDoor.TransferDeferred(provider, 270_000);
        vm.prank(redeemer);
        escrow.collectChannels(_ref(delegate), _u(0));
        assertEq(usdg.balanceOf(treasury) - tb, 30_000, "the treasury is still paid");
        (uint128 a, uint128 t) = _unpaid(provider);
        assertEq(a, 270_000);
        assertEq(t, 270_000);
        assertEq(_held(), 0, "the bucket is free again");
        _assertBooks();

        // still frozen: the claim reverts and keeps the record
        vm.expectRevert(TransferFailed.selector);
        escrow.claimUnpaid(provider);
        usdg.setBlocked(provider, false);
        uint256 pb = usdg.balanceOf(provider);
        escrow.claimUnpaid(provider); // anyone may trigger; it pays `provider` only
        assertEq(usdg.balanceOf(provider) - pb, 270_000);
        (a, t) = _unpaid(provider);
        assertEq(a + t, 0);
        escrow.claimUnpaid(provider); // nothing left: a no-op
        _assertBooks();
    }

    function test_unpaid_claimIsBlocklistAndPauseGated() public mockTokenOnly {
        _settleD(0, 300_000, 3);
        vm.warp(_slot(delegate).m1 * 3600);
        usdg.setBlocked(provider, true);
        vm.prank(redeemer);
        escrow.collectChannels(_ref(delegate), _u(0));
        usdg.setBlocked(provider, false);
        vm.prank(admin);
        config.setBlocked(provider, true);
        vm.expectRevert(AddressBlocked.selector);
        escrow.claimUnpaid(provider);
        vm.prank(admin);
        config.setBlocked(provider, false);
        vm.prank(admin);
        config.setPaused(true);
        vm.expectRevert(ProgramPaused.selector);
        escrow.claimUnpaid(provider);
    }

    function test_unpaid_aCallerCannotForceADeferralByStarvingGas() public {
        GasBurnToken t = new GasBurnToken();
        AssayEscrow e2 = _deployEscrow(address(t));
        t.mint(buyer, 10e6);
        vm.startPrank(buyer);
        t.approve(address(e2), type(uint256).max);
        e2.deposit(5e6);
        e2.setLimits(V, W);
        vm.stopPrank();
        ChannelVoucher memory v = _cv(CH, 100_000, 1);
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
        (uint8 vv, bytes32 r, bytes32 s) =
            vm.sign(buyerKey, keccak256(abi.encodePacked("\x19\x01", e2.DOMAIN_SEPARATOR(), sh)));
        vm.prank(redeemer);
        e2.settleChannels(_one(v), abi.encodePacked(r, s, vv), _u(0), _u(100_000));
        vm.warp(((uint256(_now()) + 3600 + 3599) / 3600) * 3600);
        ChannelRef[] memory refs = new ChannelRef[](1);
        refs[0] = ChannelRef(buyer, buyer, provider, CH);
        // every transfer of this token runs out of gas: the collect must revert, not defer
        vm.prank(redeemer);
        vm.expectRevert(TransferGasTooLow.selector);
        e2.collectChannels{gas: 2_000_000}(refs, _u(0));
    }

    // ---------------------------------------------------------------------- refund

    function test_refund_returnsToTheBalance_insideTheWindow_evenWhilePaused() public {
        _settleD(0, 300_000, 3);
        uint24 m = uint24(_slot(delegate).m1);
        vm.prank(admin);
        config.setPaused(true);
        uint128 escrowedBefore = escrow.totalEscrowed();
        uint24[] memory ms = new uint24[](1);
        ms[0] = m;
        vm.prank(redeemer);
        escrow.refundChannels(_ref(delegate), ms, _u(100_000));
        AssayEscrow.Escrow memory e = escrow.escrowOf(buyer);
        assertEq(e.balance, 500e6 - 200_000);
        assertEq(e.totalRedeemed, 200_000);
        assertEq(e.spentInWindow, 300_000, "refund does not restore window spend");
        assertEq(escrow.totalEscrowed(), escrowedBefore + 100_000);
        assertEq(_held(), 200_000);
        assertEq(_slot(delegate).h1, 200_000);
        _assertBooks();
    }

    function test_refund_skips_noSuchBucket_insufficient_windowClosed() public {
        _settleD(0, 300_000, 3);
        uint24 m = uint24(_slot(delegate).m1);
        uint24[] memory ms = new uint24[](1);
        vm.startPrank(redeemer);
        ms[0] = m + 1;
        vm.expectEmit(true, false, false, true, address(escrow));
        emit ChannelDoor.ChannelRefundSkipped(
            _key(delegate), m + 1, 1, uint8(ChannelDoor.RefundSkip.NoSuchBucket)
        );
        escrow.refundChannels(_ref(delegate), ms, _u(1));
        ms[0] = m;
        vm.expectEmit(true, false, false, true, address(escrow));
        emit ChannelDoor.ChannelRefundSkipped(
            _key(delegate), m, 300_001, uint8(ChannelDoor.RefundSkip.Insufficient)
        );
        escrow.refundChannels(_ref(delegate), ms, _u(300_001));
        escrow.refundChannels(_ref(delegate), ms, _u(0)); // zero: a no-op
        vm.warp(uint256(m) * 3600 + Constants.HELD_TIMEOUT_SECONDS);
        vm.expectEmit(true, false, false, true, address(escrow));
        emit ChannelDoor.ChannelRefundSkipped(
            _key(delegate), m, 1, uint8(ChannelDoor.RefundSkip.WindowClosed)
        );
        escrow.refundChannels(_ref(delegate), ms, _u(1));
        vm.stopPrank();
        assertEq(_held(), 300_000);
    }

    function test_refund_redeemerOnly() public {
        _settleD(0, 300_000, 3);
        uint24[] memory ms = new uint24[](1);
        ms[0] = uint24(_slot(delegate).m1);
        vm.expectRevert(NotRedeemer.selector);
        escrow.refundChannels(_ref(delegate), ms, _u(1));
    }

    function test_refund_thenCollect_paysOnlyTheRest() public {
        _settleD(0, 300_000, 3);
        uint24[] memory ms = new uint24[](1);
        ms[0] = uint24(_slot(delegate).m1);
        vm.prank(redeemer);
        escrow.refundChannels(_ref(delegate), ms, _u(100_000));
        vm.warp(uint256(ms[0]) * 3600);
        uint256 pb = usdg.balanceOf(provider);
        vm.prank(redeemer);
        escrow.collectChannels(_ref(delegate), _u(0));
        assertEq(usdg.balanceOf(provider) - pb, 180_000);
        assertEq(_held(), 0);
        _assertBooks();
    }

    // ---------------------------------------------------------------------- both doors share

    function test_bothDoorsShareTheWindowAndTheBalance() public {
        // fill most of the delegate window through the per-call door
        for (uint64 i = 1; i <= 49; ++i) {
            Voucher memory pv = Voucher({
                payer: buyer,
                provider: provider,
                amount: V,
                resourceHash: bytes32(0),
                requestHash: bytes32(uint256(i)),
                seq: i,
                issuedAt: _now(),
                expiresAt: _now() + 240
            });
            bytes memory psig =
                VoucherSigner.signVoucher(delegateKey, escrow.DOMAIN_SEPARATOR(), pv);
            vm.prank(redeemer);
            escrow.redeemVoucher(pv, psig);
        }
        // 49 used of 50 in the delegate window: a 2-USDG channel charge no longer fits
        ChannelVoucher memory v = _cv(CH, 2 * V, 2);
        _expectSkip(0, _key(delegate), 2 * V, ChannelDoor.SettleSkip.DelegateWindow);
        _settle(v, _sign(delegateKey, v), 0, 2 * V);
        _settleD(0, V, 1); // one more fits
        assertEq(escrow.delegationOf(buyer, delegate).spentInWindow, DW);
        assertEq(escrow.totalHeld(), 49 * V, "per-call holds in totalHeld");
        assertEq(_held(), V, "channel holds apart");
        _assertBooks();
    }

    // ---------------------------------------------------------------------- the library's views

    function test_libraryViews_matchTheIndependentDecoder() public {
        _settleD(0, 300_000, 3);
        vm.warp(_now() + 3600);
        _settleD(300_000, 500_000, 5);
        (uint256 w,,,) = escrow.channelBooks(_key(delegate), address(0));
        ChannelDoor.Slot memory a = ChannelDoor.unpack(w);
        S memory b = _slot(delegate);
        assertEq(a.settled, b.settled);
        assertEq(a.calls, b.calls);
        assertEq(a.h1, b.h1);
        assertEq(a.m1, b.m1);
        assertEq(a.r1, b.r1);
        assertEq(a.h2, b.h2);
        assertEq(a.m2, b.m2);
        assertEq(a.r2, b.r2);
        assertEq(ChannelDoor.keyOf(buyer, delegate, provider, CH), _key(delegate));
    }

    // ---------------------------------------------------------------------- layout (I16)

    function test_layout_pinsTheGuardConfigAndTheChannelSlots() public {
        bytes32 slot2 = vm.load(address(escrow), bytes32(uint256(2)));
        assertEq(uint256(slot2), 1, "OZ ReentrancyGuard _status stays at slot 2 (NOT_ENTERED)");
        bytes32 slot3 = vm.load(address(escrow), bytes32(uint256(3)));
        assertEq(address(uint160(uint256(slot3))), address(config), "CONFIG stays at slot 3");
        _settleD(0, 300_000, 3);
        (uint256 w,,, uint128 held) = escrow.channelBooks(_key(delegate), address(0));
        bytes32 at = keccak256(abi.encode(_key(delegate), uint256(14)));
        assertEq(
            uint256(vm.load(address(escrow), at)), w, "channels.state is the mapping at slot 14"
        );
        assertEq(
            uint256(vm.load(address(escrow), bytes32(uint256(16)))) >> 128,
            held,
            "held is the high half of slot 16"
        );
    }
}
