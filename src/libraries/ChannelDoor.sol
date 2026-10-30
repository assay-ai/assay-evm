// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.38;

import {IAssayConfig} from "../interfaces/IAssayConfig.sol";
import {IAssayStakeView} from "../interfaces/IAssayStakeView.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AssayEscrow} from "../AssayEscrow.sol";
import {Sig} from "./Sig.sol";
import {Window} from "./Window.sol";
import {Constants} from "../Constants.sol";
import {ChannelVoucher, ChannelRef, CHANNEL_VOUCHER_TYPEHASH, ParamSet} from "../Types.sol";
import "../Errors.sol";

/// @title ChannelDoor
/// @notice The channel door of `AssayEscrow`: cumulative vouchers, one settlement for many calls.
/// @dev An EXTERNAL library, reached by DELEGATECALL from `AssayEscrow`, so it runs in the
///      escrow's storage and as the escrow's address. It holds no state of its own and never
///      builds the EIP-712 domain: the escrow passes the domain separator in. Channel holds are
///      counted in `Store.held`, apart from the per-call door's `totalHeld`, so solvency reads
///      `balanceOf >= totalEscrowed + totalHeld + Store.held + Store.totalUnpaid`. Every
///      transfer happens after every state change of its call.
///
///      A channel is `keccak256(abi.encode(payer, signer, provider, channelId))`; `signer` is the
///      payer when the payer signed. Its state is one packed slot: what was settled, the calls
///      counter at that point, and two hold buckets. A bucket holds money of one maturity hour
///      and one take rate; its maturity never moves while it holds money.
///
///      Settlement skips (never reverts on) any item whose outcome depends on state or time, so
///      one item cannot block a batch; only calldata-only conditions revert.
library ChannelDoor {
    /// @dev Packed field widths. `settled` u56 | `calls` u24 | h1 u48 | m1 u24 | r1 u16 | h2 u48 |
    ///      m2 u24 | r2 u16. A maturity is in hours since the unix epoch.
    uint256 internal constant MAX_CUMULATIVE = (1 << 56) - 1;
    uint256 internal constant CALLS_LIMIT = 1 << 24; // `calls` must be below this
    uint256 internal constant MAX_BUCKET = (1 << 48) - 1;
    uint256 internal constant GRID = 3600;

    /// @dev The escrow's channel storage. One state variable of this type, appended to the
    ///      escrow's layout.
    struct Store {
        mapping(bytes32 => uint256) state;
        mapping(address => uint128) unpaid;
        uint128 totalUnpaid;
        uint128 held; // sum of every channel bucket
    }

    /// @dev One channel's slot, unpacked.
    struct Slot {
        uint256 settled;
        uint256 calls;
        uint256 h1;
        uint256 m1;
        uint256 r1;
        uint256 h2;
        uint256 m2;
        uint256 r2;
    }

    /// @dev What the escrow hands every door: read once per transaction.
    struct Ctx {
        IAssayConfig config;
        IAssayStakeView stake;
        IERC20 asset;
        bytes32 domainSeparator;
        uint64 minimumStake;
        uint16 takeRateBps;
        uint64 hold;
        address treasury;
    }

    /// @notice Why a settle item was skipped. Append-only.
    enum SettleSkip {
        Expired,
        NotYetValid,
        BaseMismatch,
        Authority,
        Calls,
        Blocked,
        PerCallCap,
        EscrowWindow,
        DelegateWindow,
        Stake,
        Balance,
        NoBucket
    }

    /// @notice Why a refund item was skipped. Append-only.
    enum RefundSkip {
        NoSuchBucket,
        Insufficient,
        WindowClosed
    }

    /// @notice Emitted when a channel settles: `charge` moves into hold, `waived` is forgiven.
    event ChannelSettled(
        bytes32 indexed key,
        address indexed payer,
        address signer,
        address indexed provider,
        bytes32 channelId,
        uint64 cumulative,
        uint32 calls,
        uint64 charge,
        uint64 waived,
        uint24 maturityHour,
        uint16 takeRateBps
    );
    /// @notice Emitted for a settle item that changed nothing. `key` is zero when the signer
    ///         was not recovered yet.
    event ChannelSettleSkipped(
        uint256 indexed index, address indexed payer, bytes32 key, uint64 cumulative, uint8 reason
    );
    /// @notice Emitted per bucket paid out: `gross` left hold, `fee` of it went to the treasury.
    event ChannelCollected(
        bytes32 indexed key, address indexed provider, uint24 maturityHour, uint64 gross, uint64 fee
    );
    /// @notice Emitted for a collect item left untouched because a party is blocked.
    event ChannelCollectSkipped(bytes32 indexed key);
    /// @notice Emitted per bucket refunded to the payer's balance.
    event ChannelRefunded(
        bytes32 indexed key, address indexed payer, uint24 maturityHour, uint64 amount
    );
    /// @notice Emitted when a payout transfer failed and the amount was set aside for `to`.
    event TransferDeferred(address indexed to, uint128 amount);
    /// @notice Emitted when an amount set aside for `to` was paid to it.
    event UnpaidClaimed(address indexed to, uint128 amount);
    /// @notice Emitted for a refund item that changed nothing.
    event ChannelRefundSkipped(
        bytes32 indexed key, uint24 maturityHour, uint64 amount, uint8 reason
    );

    /// @dev One read of every external parameter a door needs. Reverts while paused, so every
    ///      door that builds a context is pause-gated.
    function _ctx(IAssayConfig config, IAssayStakeView stake, IERC20 asset, bytes32 ds)
        private
        view
        returns (Ctx memory x, address redeemer)
    {
        if (config.paused()) revert ProgramPaused();
        ParamSet memory p = config.params();
        x = Ctx({
            config: config,
            stake: stake,
            asset: asset,
            domainSeparator: ds,
            minimumStake: p.minimumStake,
            takeRateBps: p.takeRateBps,
            hold: config.collectHoldSeconds(),
            treasury: p.treasury
        });
        redeemer = p.redeemer;
    }

    /// @dev Batch shape: 1..`MAX_REDEEM_BATCH` items, every array the same length.
    function _shape(uint256 n, uint256 a, uint256 b2) private pure {
        if (n == 0) revert EmptyBatch();
        if (n > Constants.MAX_REDEEM_BATCH) revert BatchTooLarge();
        if (a != n || b2 != n) revert BatchLengthMismatch();
    }

    // --- packing --------------------------------------------------------------------------

    function unpack(uint256 w) public pure returns (Slot memory s) {
        s.settled = w & MAX_CUMULATIVE;
        s.calls = (w >> 56) & (CALLS_LIMIT - 1);
        s.h1 = (w >> 80) & MAX_BUCKET;
        s.m1 = (w >> 128) & 0xFFFFFF;
        s.r1 = (w >> 152) & 0xFFFF;
        s.h2 = (w >> 168) & MAX_BUCKET;
        s.m2 = (w >> 216) & 0xFFFFFF;
        s.r2 = (w >> 240) & 0xFFFF;
    }

    /// @dev Callers keep every field inside its width; an emptied bucket has m and r zeroed.
    function pack(Slot memory s) internal pure returns (uint256) {
        return s.settled | (s.calls << 56) | (s.h1 << 80) | (s.m1 << 128) | (s.r1 << 152)
            | (s.h2 << 168) | (s.m2 << 216) | (s.r2 << 240);
    }

    function keyOf(address payer, address signer, address provider, bytes32 channelId)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(payer, signer, provider, channelId));
    }

    function digestOf(ChannelVoucher calldata v, bytes32 domainSeparator)
        internal
        pure
        returns (bytes32)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                CHANNEL_VOUCHER_TYPEHASH,
                v.payer,
                v.provider,
                v.channelId,
                v.cumulative,
                v.calls,
                v.issuedAt,
                v.expiresAt
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }

    // --- per-transaction caches (blocklist and stake only; window and balance are read live) --

    struct Cache {
        address[] addr;
        bool[] blocked;
        uint256 n;
        address[] prov;
        bool[] staked;
        uint256 pn;
    }

    function _newCache(uint256 n) private pure returns (Cache memory c) {
        c.addr = new address[](3 * n);
        c.blocked = new bool[](3 * n);
        c.prov = new address[](n);
        c.staked = new bool[](n);
    }

    function _isBlocked(Cache memory c, IAssayConfig config, address a)
        private
        view
        returns (bool)
    {
        for (uint256 i = 0; i < c.n; ++i) {
            if (c.addr[i] == a) return c.blocked[i];
        }
        bool b = config.blocked(a);
        c.addr[c.n] = a;
        c.blocked[c.n] = b;
        ++c.n;
        return b;
    }

    function _isStaked(Cache memory c, Ctx memory x, address provider)
        private
        view
        returns (bool)
    {
        for (uint256 i = 0; i < c.pn; ++i) {
            if (c.prov[i] == provider) return c.staked[i];
        }
        bool ok = x.stake.freeBondedOf(provider) >= x.minimumStake;
        c.prov[c.pn] = provider;
        c.staked[c.pn] = ok;
        ++c.pn;
        return ok;
    }

    // --- caps (same semantics as `AssayEscrow._redeem` with `_heldRefusal`) ---------------

    /// @dev 0 = passes, 1 = no pair passes the per-call term, 2 = a pair passes the per-call
    ///      term but not its window. Each pair is checked whole (D-21). The per-call term is the
    ///      average `charge ≤ dCalls · cap`; with dCalls = 1 this is exactly `_redeem`'s rule.
    function _caps(
        uint64 curV,
        uint64 curW,
        AssayEscrow.PriorCaps storage held,
        uint256 charge,
        uint256 dCalls,
        uint256 spent,
        uint256 nowTs
    ) private view returns (uint256) {
        bool curOkV = charge <= dCalls * curV;
        if (curOkV && spent <= curW) return 0;
        bool heldOkV = nowTs <= held.until && charge <= dCalls * held.maxVoucherAmount;
        if (heldOkV && spent <= held.maxPerWindow) return 0;
        return (!curOkV && !heldOkV) ? 1 : 2;
    }

    function _canSign(
        AssayEscrow.Delegation storage d,
        AssayEscrow.PriorCaps storage prior,
        uint256 nowTs
    ) private view returns (bool) {
        if (d.validUntil == 0 || nowTs > d.validUntil) return false;
        return !d.revoked || nowTs <= prior.until;
    }

    // --- settle -------------------------------------------------------------------------

    /// @dev Locals of one settle item, kept in memory against stack depth.
    struct Item {
        address signer;
        address delegate;
        bytes32 key;
        uint256 charge;
        uint256 dCalls;
        uint256 spent;
        uint256 dSpent;
        uint256 m;
    }

    /// @notice Settles a batch of channel vouchers into hold, for the Config redeemer only.
    ///         Returns the total charged, which the escrow takes off `totalEscrowed`.
    /// @dev `msg.sender` is the escrow's caller (DELEGATECALL keeps it).
    function settle(
        Store storage s,
        mapping(address => AssayEscrow.Escrow) storage escrows,
        mapping(address => mapping(address => AssayEscrow.Delegation)) storage delegations,
        mapping(address => AssayEscrow.PriorCaps) storage priorEscrowCaps,
        mapping(address => mapping(address => AssayEscrow.PriorCaps)) storage priorDelegateCaps,
        IAssayConfig config,
        IAssayStakeView stake,
        bytes32 domainSeparator,
        ChannelVoucher[] calldata vs,
        bytes calldata sigs,
        uint64[] calldata fromSettled,
        uint64[] calldata charges
    ) external returns (uint256 total) {
        (Ctx memory x, address redeemer) = _ctx(config, stake, IERC20(address(0)), domainSeparator);
        if (msg.sender != redeemer) revert NotRedeemer();
        // One 65-byte signature per voucher, concatenated.
        if (sigs.length != vs.length * 65) revert BatchLengthMismatch();
        _shape(vs.length, fromSettled.length, charges.length);
        Cache memory c = _newCache(vs.length);
        for (uint256 i = 0; i < vs.length; ++i) {
            total += _settleOne(
                s,
                escrows,
                delegations,
                priorEscrowCaps,
                priorDelegateCaps,
                x,
                c,
                i,
                vs[i],
                sigs[i * 65:i * 65 + 65],
                fromSettled[i],
                charges[i]
            );
        }
        s.held += uint128(total);
    }

    function _skip(uint256 i, ChannelVoucher calldata v, bytes32 key, SettleSkip why) private {
        emit ChannelSettleSkipped(i, v.payer, key, v.cumulative, uint8(why));
    }

    function _settleOne(
        Store storage s,
        mapping(address => AssayEscrow.Escrow) storage escrows,
        mapping(address => mapping(address => AssayEscrow.Delegation)) storage delegations,
        mapping(address => AssayEscrow.PriorCaps) storage priorEscrowCaps,
        mapping(address => mapping(address => AssayEscrow.PriorCaps)) storage priorDelegateCaps,
        Ctx memory x,
        Cache memory c,
        uint256 i,
        ChannelVoucher calldata v,
        bytes calldata sig,
        uint64 from,
        uint64 chargeIn
    ) private returns (uint256) {
        // Calldata-only refusals: these revert the batch, and only a broken sender reaches them.
        if (v.expiresAt <= v.issuedAt) revert InvalidVoucherWindow();
        if (v.expiresAt - v.issuedAt > Constants.VOUCHER_MAX_LIFETIME_SECONDS) {
            revert VoucherLifetimeTooLong();
        }
        if (v.cumulative > MAX_CUMULATIVE || v.calls >= CALLS_LIMIT) {
            revert ChannelValueOutOfRange();
        }
        if (v.cumulative <= from) revert ChannelNothingToSettle();
        if (chargeIn > v.cumulative - from) revert ChannelChargeTooLarge();

        uint256 nowTs = block.timestamp;
        // Time, in `_redeem`'s order, in uint256 so nothing can overflow.
        if (uint256(v.issuedAt) > nowTs + Constants.CLOCK_SKEW_TOLERANCE_SECONDS) {
            _skip(i, v, bytes32(0), SettleSkip.NotYetValid);
            return 0;
        }
        if (nowTs > uint256(v.expiresAt) + Constants.REDEEM_GRACE_SECONDS) {
            _skip(i, v, bytes32(0), SettleSkip.Expired);
            return 0;
        }

        Item memory it;
        it.signer = Sig.recover(digestOf(v, x.domainSeparator), sig); // malformed: reverts
        it.key = keyOf(v.payer, it.signer, v.provider, v.channelId);
        Slot memory sl = unpack(s.state[it.key]);

        if (sl.settled != from) {
            _skip(i, v, it.key, SettleSkip.BaseMismatch);
            return 0;
        }
        if (it.signer != v.payer) {
            if (
                !_canSign(
                    delegations[v.payer][it.signer], priorDelegateCaps[v.payer][it.signer], nowTs
                )
            ) {
                _skip(i, v, it.key, SettleSkip.Authority);
                return 0;
            }
            it.delegate = it.signer;
        }
        if (v.calls <= sl.calls) {
            _skip(i, v, it.key, SettleSkip.Calls);
            return 0;
        }
        it.dCalls = v.calls - sl.calls;
        it.charge = chargeIn;

        if (it.charge > 0) {
            SettleSkip why =
                _gate(escrows, delegations, priorEscrowCaps, priorDelegateCaps, x, c, v, it, nowTs);
            if (why != SettleSkip.Expired) {
                // `Expired` doubles as "passed" here: it can no longer occur at this point.
                _skip(i, v, it.key, why);
                return 0;
            }
            // Bucket: the one already holding (maturity, rate), else an empty one; never merge.
            it.m = (nowTs + x.hold + GRID - 1) / GRID;
            uint256 r = x.takeRateBps;
            if (sl.h1 != 0 && sl.m1 == it.m && sl.r1 == r) {
                if (sl.h1 + it.charge > MAX_BUCKET) return _noBucket(i, v, it);
                sl.h1 += it.charge;
            } else if (sl.h2 != 0 && sl.m2 == it.m && sl.r2 == r) {
                if (sl.h2 + it.charge > MAX_BUCKET) return _noBucket(i, v, it);
                sl.h2 += it.charge;
            } else if (sl.h1 == 0) {
                if (it.charge > MAX_BUCKET) return _noBucket(i, v, it);
                (sl.h1, sl.m1, sl.r1) = (it.charge, it.m, r);
            } else if (sl.h2 == 0) {
                if (it.charge > MAX_BUCKET) return _noBucket(i, v, it);
                (sl.h2, sl.m2, sl.r2) = (it.charge, it.m, r);
            } else {
                return _noBucket(i, v, it);
            }
            _debit(escrows, delegations, v.payer, it, nowTs);
        }

        sl.settled = v.cumulative;
        sl.calls = v.calls;
        s.state[it.key] = pack(sl);
        emit ChannelSettled(
            it.key,
            v.payer,
            it.signer,
            v.provider,
            v.channelId,
            v.cumulative,
            v.calls,
            uint64(it.charge),
            uint64(v.cumulative - from - it.charge),
            uint24(it.m),
            it.charge > 0 ? x.takeRateBps : 0
        );
        return it.charge;
    }

    function _noBucket(uint256 i, ChannelVoucher calldata v, Item memory it)
        private
        returns (uint256)
    {
        _skip(i, v, it.key, SettleSkip.NoBucket);
        return 0;
    }

    /// @dev Every gate on a positive charge, in the spec's order. Returns `Expired` as "passed".
    function _gate(
        mapping(address => AssayEscrow.Escrow) storage escrows,
        mapping(address => mapping(address => AssayEscrow.Delegation)) storage delegations,
        mapping(address => AssayEscrow.PriorCaps) storage priorEscrowCaps,
        mapping(address => mapping(address => AssayEscrow.PriorCaps)) storage priorDelegateCaps,
        Ctx memory x,
        Cache memory c,
        ChannelVoucher calldata v,
        Item memory it,
        uint256 nowTs
    ) private view returns (SettleSkip) {
        if (
            _isBlocked(c, x.config, v.payer) || _isBlocked(c, x.config, v.provider)
                || (it.delegate != address(0) && _isBlocked(c, x.config, it.delegate))
        ) return SettleSkip.Blocked;

        AssayEscrow.Escrow storage e = escrows[v.payer];
        it.spent =
            uint256(Window.decay(e.spentInWindow, e.windowStartedAt, uint64(nowTs))) + it.charge;
        uint256 why = _caps(
            e.maxVoucherAmount,
            e.maxPerWindow,
            priorEscrowCaps[v.payer],
            it.charge,
            it.dCalls,
            it.spent,
            nowTs
        );
        if (why == 1) return SettleSkip.PerCallCap;
        if (why == 2) return SettleSkip.EscrowWindow;

        if (it.delegate != address(0)) {
            AssayEscrow.Delegation storage d = delegations[v.payer][it.delegate];
            it.dSpent =
                uint256(Window.decay(d.spentInWindow, d.windowStartedAt, uint64(nowTs))) + it.charge;
            why = _caps(
                d.maxVoucherAmount,
                d.maxPerWindow,
                priorDelegateCaps[v.payer][it.delegate],
                it.charge,
                it.dCalls,
                it.dSpent,
                nowTs
            );
            if (why == 1) return SettleSkip.PerCallCap;
            if (why == 2) return SettleSkip.DelegateWindow;
        }

        if (!_isStaked(c, x, v.provider)) return SettleSkip.Stake;
        if (e.balance < it.charge) return SettleSkip.Balance;
        return SettleSkip.Expired;
    }

    /// @dev The escrow side of a positive charge, as `_redeem` does it.
    function _debit(
        mapping(address => AssayEscrow.Escrow) storage escrows,
        mapping(address => mapping(address => AssayEscrow.Delegation)) storage delegations,
        address payer,
        Item memory it,
        uint256 nowTs
    ) private {
        AssayEscrow.Escrow storage e = escrows[payer];
        uint64 n64 = uint64(nowTs);
        // `spent` passed a uint64 cap, so the narrowing cannot truncate.
        e.balance -= uint128(it.charge);
        e.spentInWindow = uint64(it.spent);
        e.windowStartedAt = n64 > e.windowStartedAt ? n64 : e.windowStartedAt;
        e.totalRedeemed += uint128(it.charge);
        if (it.delegate != address(0)) {
            AssayEscrow.Delegation storage d = delegations[payer][it.delegate];
            d.spentInWindow = uint64(it.dSpent);
            d.windowStartedAt = n64 > d.windowStartedAt ? n64 : d.windowStartedAt;
        }
    }

    // --- collect ------------------------------------------------------------------------

    /// @dev What one collect pays out, aggregated per recipient.
    struct Payout {
        address[] to;
        uint256[] amount;
        uint256 n;
        uint256 fee;
        uint256 gross;
    }

    /// @notice Releases matured buckets. The redeemer may collect from maturity and leave an
    ///         amount held; anyone else only from maturity + `HELD_TIMEOUT_SECONDS`, leaving
    ///         nothing. Pays oldest maturity first. All state changes precede the transfers; a
    ///         failed transfer is set aside in `unpaid` for that recipient alone.
    function collect(
        Store storage s,
        IAssayConfig config,
        IERC20 asset,
        ChannelRef[] calldata refs,
        uint64[] calldata keepHeld
    ) external {
        (Ctx memory x, address redeemer) = _ctx(config, IAssayStakeView(address(0)), asset, 0);
        _shape(refs.length, keepHeld.length, keepHeld.length);
        bool byRedeemer = msg.sender == redeemer;
        Payout memory out;
        out.to = new address[](refs.length);
        out.amount = new uint256[](refs.length);
        Cache memory c = _newCache(refs.length);
        uint256 nowTs = block.timestamp;
        uint256 wait = byRedeemer ? 0 : Constants.HELD_TIMEOUT_SECONDS;
        for (uint256 i = 0; i < refs.length; ++i) {
            if (!byRedeemer && keepHeld[i] != 0) revert NotRedeemer();
            _collectOne(s, x, c, out, refs[i], keepHeld[i], nowTs, wait);
        }
        // effects done; interactions
        s.held -= uint128(out.gross);
        for (uint256 j = 0; j < out.n; ++j) {
            _payOrDefer(s, x.asset, out.to[j], out.amount[j]);
        }
        _payOrDefer(s, x.asset, x.treasury, out.fee);
    }

    /// @notice Pays `to` what a failed payout set aside for it, to `to` only. Pause- and
    ///         blocklist-gated. A zero balance is a no-op.
    function claimUnpaid(Store storage s, IAssayConfig config, IERC20 asset, address to) external {
        config.assertActive(to, address(0), address(0));
        uint128 amount = s.unpaid[to];
        if (amount == 0) return;
        s.unpaid[to] = 0;
        s.totalUnpaid -= amount;
        if (!_transfer(asset, to, amount)) revert TransferFailed();
        emit UnpaidClaimed(to, amount);
    }

    /// @dev Transfers, or sets the amount aside for `to` if the transfer fails. A caller cannot
    ///      force the failure by starving the call: when the callee ran out of the gas it was
    ///      given, the 1/64 kept here is below 1/63 of what was available, and that reverts.
    function _payOrDefer(Store storage s, IERC20 asset, address to, uint256 amount) private {
        if (amount == 0) return;
        uint256 gasBefore = gasleft();
        if (_transfer(asset, to, amount)) return;
        if (gasleft() < gasBefore / 63) revert TransferGasTooLow();
        s.unpaid[to] += uint128(amount);
        s.totalUnpaid += uint128(amount);
        emit TransferDeferred(to, uint128(amount));
    }

    /// @dev `transfer`; true on success: no return data, or a 32-byte word equal to 1.
    function _transfer(IERC20 asset, address to, uint256 amount) private returns (bool ok) {
        bytes memory data = abi.encodeCall(IERC20.transfer, (to, amount));
        assembly ("memory-safe") {
            ok := call(gas(), asset, 0, add(data, 0x20), mload(data), 0, 0x20)
            if ok {
                switch returndatasize()
                case 0 { ok := 1 }
                default { ok := and(gt(returndatasize(), 31), eq(mload(0), 1)) }
            }
        }
    }

    function _collectOne(
        Store storage s,
        Ctx memory x,
        Cache memory c,
        Payout memory out,
        ChannelRef calldata ref,
        uint256 keepHeld,
        uint256 nowTs,
        uint256 wait
    ) private {
        bytes32 key = keyOf(ref.payer, ref.signer, ref.provider, ref.channelId);
        Slot memory sl = unpack(s.state[key]);
        bool p1 = sl.h1 != 0 && sl.m1 * GRID + wait <= nowTs;
        bool p2 = sl.h2 != 0 && sl.m2 * GRID + wait <= nowTs;
        uint256 payable_ = (p1 ? sl.h1 : 0) + (p2 ? sl.h2 : 0);
        if (payable_ <= keepHeld) return; // nothing to pay: a no-op
        if (_isBlocked(c, x.config, ref.payer) || _isBlocked(c, x.config, ref.provider)) {
            emit ChannelCollectSkipped(key);
            return;
        }
        uint256 pay = payable_ - keepHeld;
        uint256 paidToProvider;
        // Oldest payable bucket first; the remainder of `keepHeld` stays in the newest one.
        bool firstIsOne = p1 && (!p2 || sl.m1 <= sl.m2);
        for (uint256 k = 0; k < 2 && pay > 0; ++k) {
            bool one = (k == 0) == firstIsOne;
            if (one ? !p1 : !p2) continue;
            uint256 h = one ? sl.h1 : sl.h2;
            uint256 take = h < pay ? h : pay;
            uint256 r = one ? sl.r1 : sl.r2;
            uint256 fee = (take * r) / Constants.BPS_DENOMINATOR;
            uint256 m = one ? sl.m1 : sl.m2;
            if (one) {
                sl.h1 = h - take;
                if (sl.h1 == 0) (sl.m1, sl.r1) = (0, 0);
            } else {
                sl.h2 = h - take;
                if (sl.h2 == 0) (sl.m2, sl.r2) = (0, 0);
            }
            pay -= take;
            out.gross += take;
            out.fee += fee;
            paidToProvider += take - fee;
            emit ChannelCollected(key, ref.provider, uint24(m), uint64(take), uint64(fee));
        }
        s.state[key] = pack(sl);
        if (paidToProvider == 0) return;
        uint256 j;
        while (j < out.n && out.to[j] != ref.provider) ++j;
        if (j == out.n) {
            out.to[j] = ref.provider;
            ++out.n;
        }
        out.amount[j] += paidToProvider;
    }

    // --- refund -------------------------------------------------------------------------

    /// @notice Returns held channel money to the payer's balance, from the bucket of the named
    ///         maturity, while that bucket is inside its refund window. Returns the total.
    function refund(
        Store storage s,
        mapping(address => AssayEscrow.Escrow) storage escrows,
        IAssayConfig config,
        ChannelRef[] calldata refs,
        uint24[] calldata maturityHours,
        uint64[] calldata amounts
    ) external returns (uint256 total) {
        // Not pause-gated: it moves no token.
        if (msg.sender != config.params().redeemer) revert NotRedeemer();
        _shape(refs.length, maturityHours.length, amounts.length);
        uint256 nowTs = block.timestamp;
        for (uint256 i = 0; i < refs.length; ++i) {
            total += _refundOne(s, escrows, refs[i], maturityHours[i], amounts[i], nowTs);
        }
        s.held -= uint128(total);
    }

    function _refundOne(
        Store storage s,
        mapping(address => AssayEscrow.Escrow) storage escrows,
        ChannelRef calldata ref,
        uint256 m,
        uint256 amount,
        uint256 nowTs
    ) private returns (uint256) {
        if (amount == 0) return 0;
        bytes32 key = keyOf(ref.payer, ref.signer, ref.provider, ref.channelId);
        Slot memory sl = unpack(s.state[key]);
        bool one = sl.h1 != 0 && sl.m1 == m;
        if (!one && !(sl.h2 != 0 && sl.m2 == m)) {
            emit ChannelRefundSkipped(
                key, uint24(m), uint64(amount), uint8(RefundSkip.NoSuchBucket)
            );
            return 0;
        }
        if (nowTs >= m * GRID + Constants.HELD_TIMEOUT_SECONDS) {
            emit ChannelRefundSkipped(
                key, uint24(m), uint64(amount), uint8(RefundSkip.WindowClosed)
            );
            return 0;
        }
        uint256 h = one ? sl.h1 : sl.h2;
        if (amount > h) {
            emit ChannelRefundSkipped(
                key, uint24(m), uint64(amount), uint8(RefundSkip.Insufficient)
            );
            return 0;
        }
        if (one) {
            sl.h1 = h - amount;
            if (sl.h1 == 0) (sl.m1, sl.r1) = (0, 0);
        } else {
            sl.h2 = h - amount;
            if (sl.h2 == 0) (sl.m2, sl.r2) = (0, 0);
        }
        s.state[key] = pack(sl);
        AssayEscrow.Escrow storage e = escrows[ref.payer];
        e.balance += uint128(amount);
        e.totalRedeemed -= uint128(amount);
        emit ChannelRefunded(key, ref.payer, uint24(m), uint64(amount));
        return amount;
    }
}
