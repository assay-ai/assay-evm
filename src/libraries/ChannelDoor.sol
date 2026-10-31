// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.38;

import {IAssayConfig} from "../interfaces/IAssayConfig.sol";
import {IAssayStakeView} from "../interfaces/IAssayStakeView.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AssayEscrowStorage} from "../AssayEscrowStorage.sol";
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
///      and one take rate; its maturity only ever moves LATER, when a settlement folds into it
///      before it matures (`_fold`).
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
    /// @dev Gas handed to every payout transfer. Far above a USDG transfer (about 26k on 4663,
    ///      measured), so a payout is set aside only when the token refused it or burned all of
    ///      this; never because the caller starved the call (see `_payOrDefer`).
    uint256 internal constant TRANSFER_GAS = 300_000;
    /// @dev What must be left before a payout: the stipend un-trimmed by the 63/64 rule, plus
    ///      room for the set-aside writes if it fails.
    uint256 internal constant TRANSFER_GAS_FLOOR = TRANSFER_GAS * 64 / 63 + 50_000;

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

    /// @notice Why a collect item was skipped. Append-only.
    enum CollectSkip {
        Blocked
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
    /// @notice Emitted when a settlement moved a bucket's maturity later (`_fold`): the bucket
    ///         named `fromHour << 16 | takeRateBps` is now named `toHour << 16 | takeRateBps`.
    event ChannelBucketDeferred(
        bytes32 indexed key, uint24 fromHour, uint24 toHour, uint16 takeRateBps
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
    /// @notice Emitted for a collect item left untouched (a party is blocked).
    event ChannelCollectSkipped(bytes32 indexed key, uint8 reason);
    /// @notice Emitted per bucket refunded to the payer's balance.
    event ChannelRefunded(bytes32 indexed key, address indexed payer, uint40 bucket, uint64 amount);
    /// @notice Emitted when a payout transfer failed and the amount was set aside for `to`.
    event TransferDeferred(address indexed to, uint128 amount);
    /// @notice Emitted when an amount set aside for `to` was paid to it.
    event UnpaidClaimed(address indexed to, uint128 amount);
    /// @notice Emitted for a refund item that changed nothing.
    event ChannelRefundSkipped(bytes32 indexed key, uint40 bucket, uint64 amount, uint8 reason);

    /// @dev One read of every external parameter a door needs. Reverts while paused, so every
    ///      door that builds a context is pause-gated. `withHold` is false for collect, which
    ///      never reads the hold (`x.hold` is then zero).
    function _ctx(
        IAssayConfig config,
        IAssayStakeView stake,
        IERC20 asset,
        bytes32 ds,
        bool withHold
    ) private view returns (Ctx memory x, address redeemer) {
        if (config.paused()) revert ProgramPaused();
        ParamSet memory p = config.params();
        x = Ctx({
            config: config,
            stake: stake,
            asset: asset,
            domainSeparator: ds,
            minimumStake: p.minimumStake,
            takeRateBps: p.takeRateBps,
            hold: withHold ? config.collectHoldSeconds() : 0,
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
        bool b = _blockedOf(config, a);
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
        bool ok = _freeBondedOf(x.stake, provider) >= x.minimumStake;
        c.prov[c.pn] = provider;
        c.staked[c.pn] = ok;
        ++c.pn;
        return ok;
    }

    /// @dev `config.blocked(a)` without the ABI encoder's memory allocation per lookup (the
    ///      blocklist is read up to three times per settle item). Same outcomes as the
    ///      high-level call: a revert is bubbled verbatim; a target without code, short return
    ///      data or a word that is not a bool reverts empty.
    function _blockedOf(IAssayConfig config, address a) private view returns (bool b) {
        bytes4 sel = IAssayConfig.blocked.selector;
        uint256 w = _staticWord(address(config), sel, a);
        if (w > 1) revert();
        b = w == 1;
    }

    /// @dev `stake.freeBondedOf(provider)`, as `_blockedOf`; a word above `uint64` reverts empty.
    function _freeBondedOf(IAssayStakeView stake, address provider) private view returns (uint64) {
        uint256 w = _staticWord(address(stake), IAssayStakeView.freeBondedOf.selector, provider);
        if (w > type(uint64).max) revert();
        return uint64(w);
    }

    /// @dev STATICCALLs `target.sel(arg)` and returns the first return word, in scratch space.
    function _staticWord(address target, bytes4 sel, address arg)
        private
        view
        returns (uint256 w)
    {
        assembly ("memory-safe") {
            mstore(0x00, sel)
            mstore(0x04, and(arg, 0xffffffffffffffffffffffffffffffffffffffff))
            let ok := staticcall(gas(), target, 0x00, 0x24, 0x00, 0x20)
            if iszero(ok) {
                let p := mload(0x40)
                returndatacopy(p, 0, returndatasize())
                revert(p, returndatasize())
            }
            if lt(returndatasize(), 0x20) { revert(0, 0) }
            w := mload(0x00)
        }
    }

    // --- caps (same semantics as `AssayEscrow._redeem` with `_heldRefusal`) ---------------

    /// @dev 0 = passes, 1 = no pair passes the per-call term, 2 = a pair passes the per-call
    ///      term but not its window. Each pair is checked whole (D-21). The per-call term is the
    ///      average `charge ≤ dCalls · cap`; with dCalls = 1 this is exactly `_redeem`'s rule.
    function _caps(
        uint64 curV,
        uint64 curW,
        AssayEscrowStorage.PriorCaps storage held,
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
        AssayEscrowStorage.Delegation storage d,
        AssayEscrowStorage.PriorCaps storage prior,
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
        mapping(address => AssayEscrowStorage.Escrow) storage escrows,
        mapping(address => mapping(address => AssayEscrowStorage.Delegation)) storage delegations,
        mapping(address => AssayEscrowStorage.PriorCaps) storage priorEscrowCaps,
        mapping(address => mapping(address => AssayEscrowStorage.PriorCaps)) storage
            priorDelegateCaps,
        IAssayConfig config,
        IAssayStakeView stake,
        bytes32 domainSeparator,
        ChannelVoucher[] calldata vs,
        bytes calldata sigs,
        uint64[] calldata fromSettled,
        uint64[] calldata charges
    ) external returns (uint256 total) {
        (Ctx memory x, address redeemer) =
            _ctx(config, stake, IERC20(address(0)), domainSeparator, true);
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
        mapping(address => AssayEscrowStorage.Escrow) storage escrows,
        mapping(address => mapping(address => AssayEscrowStorage.Delegation)) storage delegations,
        mapping(address => AssayEscrowStorage.PriorCaps) storage priorEscrowCaps,
        mapping(address => mapping(address => AssayEscrowStorage.PriorCaps)) storage
            priorDelegateCaps,
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
            (bool pass, SettleSkip why) =
                _gate(escrows, delegations, priorEscrowCaps, priorDelegateCaps, x, c, v, it, nowTs);
            if (!pass) {
                _skip(i, v, it.key, why);
                return 0;
            }
            // Bucket: the one already holding (maturity, rate), else an empty one, else the
            // newest bucket of this rate with its maturity moved later (`_fold`).
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
            } else if (!_fold(sl, it, r, nowTs)) {
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

    /// @dev Both buckets hold money of other (maturity, rate) pairs. Adds the charge to the
    ///      newest bucket of the same rate, if it has NOT matured, and moves that bucket's
    ///      maturity to the later of its own and the charge's, so no money matures earlier than
    ///      its own hold and every older amount in it is only held longer (its refund window
    ///      moves with it). Without this a matured bucket left uncollected next to a pending one,
    ///      or a hold above one hour, refused every settlement into a new hour until the newest
    ///      voucher expired unsettled. False (the item skips `NoBucket`) when neither bucket has
    ///      this rate, the newest of it has matured (collect first), the other bucket is still
    ///      pending at another rate (only around a take-rate change), or it would overflow. The two
    ///      buckets stay distinct (I11): the chosen one is the newest of its rate, so its new
    ///      maturity is above the other's whenever the rates match. On `it.m` it leaves the
    ///      maturity the charge landed in.
    function _fold(Slot memory sl, Item memory it, uint256 r, uint256 nowTs)
        private
        returns (bool)
    {
        bool one = sl.r1 == r && (sl.r2 != r || sl.m1 >= sl.m2);
        if (!one && sl.r2 != r) return false;
        uint256 mOld = one ? sl.m1 : sl.m2;
        // Never a matured bucket: its money (a dispute's `keepHeld` included) is payable now and
        // its anyone-can-collect deadline must not move. Collect it first.
        if (mOld * GRID <= nowTs) return false;
        // Never while the OTHER bucket is pending at another rate: a take rate switched back and
        // forth would make each bucket the newest of its rate in turn, and folds would keep both
        // from ever maturing. With this, the other bucket is the same rate (older, its maturity
        // fixed) or has matured (fixed too), so the folded bucket stops moving once it clears.
        if ((one ? sl.r2 : sl.r1) != r && (one ? sl.m2 : sl.m1) * GRID > nowTs) return false;
        uint256 h = one ? sl.h1 : sl.h2;
        if (h + it.charge > MAX_BUCKET) return false;
        uint256 mNew = mOld > it.m ? mOld : it.m;
        if (one) (sl.h1, sl.m1) = (h + it.charge, mNew);
        else (sl.h2, sl.m2) = (h + it.charge, mNew);
        if (mNew != mOld) emit ChannelBucketDeferred(it.key, uint24(mOld), uint24(mNew), uint16(r));
        it.m = mNew;
        return true;
    }

    function _noBucket(uint256 i, ChannelVoucher calldata v, Item memory it)
        private
        returns (uint256)
    {
        _skip(i, v, it.key, SettleSkip.NoBucket);
        return 0;
    }

    /// @dev Every gate on a positive charge, in the spec's order: `(true, _)` passes, else the
    ///      first refusal.
    function _gate(
        mapping(address => AssayEscrowStorage.Escrow) storage escrows,
        mapping(address => mapping(address => AssayEscrowStorage.Delegation)) storage delegations,
        mapping(address => AssayEscrowStorage.PriorCaps) storage priorEscrowCaps,
        mapping(address => mapping(address => AssayEscrowStorage.PriorCaps)) storage
            priorDelegateCaps,
        Ctx memory x,
        Cache memory c,
        ChannelVoucher calldata v,
        Item memory it,
        uint256 nowTs
    ) private view returns (bool, SettleSkip) {
        if (
            _isBlocked(c, x.config, v.payer) || _isBlocked(c, x.config, v.provider)
                || (it.delegate != address(0) && _isBlocked(c, x.config, it.delegate))
        ) return (false, SettleSkip.Blocked);

        AssayEscrowStorage.Escrow storage e = escrows[v.payer];
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
        if (why == 1) return (false, SettleSkip.PerCallCap);
        if (why == 2) return (false, SettleSkip.EscrowWindow);

        if (it.delegate != address(0)) {
            AssayEscrowStorage.Delegation storage d = delegations[v.payer][it.delegate];
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
            if (why == 1) return (false, SettleSkip.PerCallCap);
            if (why == 2) return (false, SettleSkip.DelegateWindow);
        }

        if (!_isStaked(c, x, v.provider)) return (false, SettleSkip.Stake);
        if (e.balance < it.charge) return (false, SettleSkip.Balance);
        return (true, SettleSkip.Expired);
    }

    /// @dev The escrow side of a positive charge, as `_redeem` does it.
    function _debit(
        mapping(address => AssayEscrowStorage.Escrow) storage escrows,
        mapping(address => mapping(address => AssayEscrowStorage.Delegation)) storage delegations,
        address payer,
        Item memory it,
        uint256 nowTs
    ) private {
        AssayEscrowStorage.Escrow storage e = escrows[payer];
        uint64 n64 = uint64(nowTs);
        // `spent` passed a uint64 cap, so the narrowing cannot truncate.
        e.balance -= uint128(it.charge);
        e.spentInWindow = uint64(it.spent);
        e.windowStartedAt = n64 > e.windowStartedAt ? n64 : e.windowStartedAt;
        e.totalRedeemed += uint128(it.charge);
        if (it.delegate != address(0)) {
            AssayEscrowStorage.Delegation storage d = delegations[payer][it.delegate];
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
        (Ctx memory x, address redeemer) =
            _ctx(config, IAssayStakeView(address(0)), asset, 0, false);
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
        if (!_transfer(asset, to, amount, gasleft())) revert TransferFailed();
        emit UnpaidClaimed(to, amount);
    }

    /// @dev Transfers, or sets the amount aside for `to` if the transfer fails. The transfer
    ///      always gets exactly `TRANSFER_GAS`: a caller that leaves less than
    ///      `TRANSFER_GAS_FLOOR` reverts here, so a set-aside means the token refused the
    ///      transfer (a frozen address) or burned the whole stipend, never a starved call.
    function _payOrDefer(Store storage s, IERC20 asset, address to, uint256 amount) private {
        if (amount == 0) return;
        if (gasleft() < TRANSFER_GAS_FLOOR) revert TransferGasTooLow();
        if (_transfer(asset, to, amount, TRANSFER_GAS)) return;
        s.unpaid[to] += uint128(amount);
        s.totalUnpaid += uint128(amount);
        emit TransferDeferred(to, uint128(amount));
    }

    /// @dev `transfer` with `gasLimit`; true on success: no return data, or a 32-byte word equal
    ///      to 1 (more return data is accepted if its first word is 1).
    function _transfer(IERC20 asset, address to, uint256 amount, uint256 gasLimit)
        private
        returns (bool ok)
    {
        bytes memory data = abi.encodeCall(IERC20.transfer, (to, amount));
        assembly ("memory-safe") {
            ok := call(gasLimit, asset, 0, add(data, 0x20), mload(data), 0, 0x20)
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
            emit ChannelCollectSkipped(key, uint8(CollectSkip.Blocked));
            return;
        }
        uint256 pay = payable_ - keepHeld;
        uint256 paidToProvider;
        // Pays the oldest payable bucket first, then the next. What `keepHeld` keeps is whatever
        // the payment did not reach: it may sit in one bucket or, when it exceeds the newest
        // bucket, partly in the older one too.
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

    /// @notice Returns held channel money to the payer's balance, from the named bucket, while
    ///         it is inside its refund window. A bucket is named by `maturityHour << 16 | rate`:
    ///         two buckets of one channel never share both (I11). Returns the total.
    function refund(
        Store storage s,
        mapping(address => AssayEscrowStorage.Escrow) storage escrows,
        IAssayConfig config,
        ChannelRef[] calldata refs,
        uint40[] calldata buckets,
        uint64[] calldata amounts
    ) external returns (uint256 total) {
        // Not pause-gated: it moves no token.
        if (msg.sender != config.params().redeemer) revert NotRedeemer();
        _shape(refs.length, buckets.length, amounts.length);
        uint256 nowTs = block.timestamp;
        for (uint256 i = 0; i < refs.length; ++i) {
            total += _refundOne(s, escrows, refs[i], buckets[i], amounts[i], nowTs);
        }
        s.held -= uint128(total);
    }

    function _refundOne(
        Store storage s,
        mapping(address => AssayEscrowStorage.Escrow) storage escrows,
        ChannelRef calldata ref,
        uint256 bucket,
        uint256 amount,
        uint256 nowTs
    ) private returns (uint256) {
        if (amount == 0) return 0;
        bytes32 key = keyOf(ref.payer, ref.signer, ref.provider, ref.channelId);
        Slot memory sl = unpack(s.state[key]);
        uint256 m = bucket >> 16;
        uint256 r = bucket & 0xFFFF;
        bool one = sl.h1 != 0 && sl.m1 == m && sl.r1 == r;
        if (!one && !(sl.h2 != 0 && sl.m2 == m && sl.r2 == r)) {
            emit ChannelRefundSkipped(
                key, uint40(bucket), uint64(amount), uint8(RefundSkip.NoSuchBucket)
            );
            return 0;
        }
        if (nowTs >= m * GRID + Constants.HELD_TIMEOUT_SECONDS) {
            emit ChannelRefundSkipped(
                key, uint40(bucket), uint64(amount), uint8(RefundSkip.WindowClosed)
            );
            return 0;
        }
        uint256 h = one ? sl.h1 : sl.h2;
        if (amount > h) {
            emit ChannelRefundSkipped(
                key, uint40(bucket), uint64(amount), uint8(RefundSkip.Insufficient)
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
        AssayEscrowStorage.Escrow storage e = escrows[ref.payer];
        e.balance += uint128(amount);
        e.totalRedeemed -= uint128(amount);
        emit ChannelRefunded(key, ref.payer, uint40(bucket), uint64(amount));
        return amount;
    }
}
