// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IAssayConfig} from "./interfaces/IAssayConfig.sol";
import {IAssayStakeView} from "./interfaces/IAssayStakeView.sol";
import {Cast} from "./libraries/Cast.sol";
import {Constants} from "./Constants.sol";
import {ParamSet} from "./Types.sol";
import {ChannelDoor} from "./libraries/ChannelDoor.sol";
import "./Errors.sol";

/// @title AssayEscrowStorage
/// @notice The escrow's state, types, events and the internal rules both of its contracts use.
/// @dev Inherited by `AssayEscrow` (the implementation behind the proxy) and by
///      `AssayEscrowExtension` (reached from the implementation's `fallback` by DELEGATECALL), so
///      both run against one compiler-derived layout. Each inheritor places exactly two string
///      slots and `ReentrancyGuard._status` ahead of this contract, in that order: OZ EIP712's
///      `_nameFallback`/`_versionFallback` in the escrow, two reserved slots of the same name
///      and type in the extension. `check-layout.sh` compares both layouts with the snapshot.
///      Holds no constructor and no external function of its own beyond the variables' getters.
abstract contract AssayEscrowStorage {
    /// @dev The EIP-712 domain. Must never change across implementations, or every outstanding
    ///      voucher and authorisation dies. The escrow passes these to OZ EIP712; the extension
    ///      builds the same separator from them.
    string internal constant EIP712_NAME = "Assay Settlement";
    string internal constant EIP712_VERSION = "2";

    /// @dev One buyer's account, packed into exactly four slots; do not reorder. Amounts are in
    ///      USDG base units (6 decimals), times in unix seconds.
    struct Escrow {
        uint128 balance; // slot 0
        uint64 seqHigh; // highest seq redeemed; anchor of the seq gap cap
        uint64 authNonce; // shared nonce of every payer decision
        uint64 maxVoucherAmount; // slot 1; 0 refuses every voucher
        uint64 maxPerWindow; // 0 refuses every voucher
        uint64 spentInWindow;
        uint64 windowStartedAt;
        uint64 withdrawRequested; // slot 2
        uint64 withdrawAvailableAt;
        uint128 totalRedeemed;
        uint128 totalWithdrawn; // slot 3
        uint128 totalFunded; // lifetime deposits; never decreases
    }

    /// @dev A payer's grant to a delegate key to sign vouchers on the payer's escrow, within the
    ///      delegate's own caps in addition to the escrow's. `validUntil == 0` means never
    ///      authorised. Window counters survive revocation, so a re-grant adds no capacity.
    struct Delegation {
        uint64 maxVoucherAmount; // slot 0
        uint64 maxPerWindow;
        uint64 spentInWindow;
        uint64 windowStartedAt;
        uint64 validUntil; // slot 1
        uint32 listPosition; // 1-based index in `delegateList[payer]`; 0 when unlisted
        bool revoked; // the grant still signs for `TIGHTEN_DELAY` after revocation
    }

    /// @notice Protocol configuration: roles, parameters, pause and blocklist. Set once.
    IAssayConfig public CONFIG;
    /// @notice Provider stake contract, read for the minimum-stake check. Set once.
    IAssayStakeView public STAKE;
    /// @notice Settlement token (6 decimals). Set once.
    IERC20 public ASSET;

    /// @dev buyer => escrow; read through `escrowOf`.
    mapping(address => Escrow) internal escrows;

    /// @notice Sum of all buyer balances, in base units.
    uint128 public totalEscrowed;

    /// @dev payer => delegate => grant.
    mapping(address => mapping(address => Delegation)) internal delegations;

    /// @dev payer => listed delegates (authorised, not revoked); at most `MAX_DELEGATES_PER_PAYER`.
    mapping(address => address[]) internal delegateList;

    /// @dev Caps in force before a payer lowered them, honoured until `until` so a voucher valid at
    ///      that time stays redeemable for `TIGHTEN_DELAY`. Each pair is checked whole.
    struct PriorCaps {
        uint64 maxVoucherAmount;
        uint64 maxPerWindow;
        uint64 until;
    }

    /// @dev payer => escrow caps held after the last lowering.
    mapping(address => PriorCaps) internal priorEscrowCaps;

    /// @dev payer => delegate => caps held after the last lowering or revocation. For a revoked
    ///      grant `until` is also the end of its grace.
    mapping(address => mapping(address => PriorCaps)) internal priorDelegateCaps;

    /// @dev Held payment state. `Held` moves exactly once, to `Collected` or `Refunded`.
    ///      Append-only.
    enum HeldStatus {
        None,
        Held,
        Collected,
        Refunded
    }

    /// @dev `takeRateBps` and `collectableAt` are frozen at redemption; the treasury is read at
    ///      collect time.
    struct HeldPayment {
        address provider; // slot 0
        uint64 amount;
        uint16 takeRateBps;
        HeldStatus status;
        uint64 collectableAt; // slot 1
    }

    /// @dev payer => seq => held payment. A record other than `None` marks the seq redeemed.
    ///      Records are never deleted, so each seq redeems at most once per payer, in any order.
    mapping(address => mapping(uint64 => HeldPayment)) internal heldPayments;

    /// @notice Sum of all `Held` amounts: money out of buyer balances but not yet paid out.
    uint128 public totalHeld;

    /// @dev Channel state, the `unpaid` ledger of deferred transfers, their total and the total
    ///      held in channel buckets. Three slots. Channel holds are NOT in `totalHeld`, which
    ///      keeps counting the per-call door only.
    ChannelDoor.Store internal channels;

    /// @dev Reserved storage: a new field goes above and shrinks this by the slots it uses.
    uint256[42] private __gap;

    // --- events (one declaration; emitted from the proxy address by either contract) --------

    /// @notice Emitted when a redemption lands in hold until `collectableAt`.
    event PaymentHeld(
        address indexed payer,
        uint64 indexed seq,
        address indexed provider,
        uint64 amount,
        uint64 collectableAt
    );

    /// @notice Emitted when a held payment is paid to the provider and the treasury.
    event HeldCollected(
        address indexed payer,
        uint64 indexed seq,
        address indexed provider,
        uint64 providerAmount,
        uint64 fee
    );

    /// @notice Emitted when a held payment returns to the buyer's balance in full.
    event HeldRefunded(address indexed payer, uint64 indexed seq, uint64 amount);

    /// @notice Emitted when caps are held until `until`; `delegate` is zero for the escrow's caps.
    event CapsHeld(
        address indexed payer,
        address indexed delegate,
        uint64 maxVoucherAmount,
        uint64 maxPerWindow,
        uint64 until
    );

    /// @notice Emitted when `funder` deposits `amount` into `buyer`'s escrow.
    event Deposited(address indexed buyer, address indexed funder, uint64 amount, uint128 balance);

    /// @notice Emitted when a voucher is redeemed into hold. `fee` uses the applied
    ///         `takeRateBps`; `spentInWindow` is the escrow's counter after this redemption.
    event VoucherRedeemed(
        address indexed payer,
        address indexed provider,
        bytes32 requestHash,
        bytes32 resourceHash,
        uint64 amount,
        uint64 fee,
        uint64 seq,
        uint16 takeRateBps,
        uint64 spentInWindow
    );

    /// @notice Emitted when a buyer sets its per-voucher and per-window caps.
    event EscrowLimitsSet(address indexed buyer, uint64 maxVoucherAmount, uint64 maxPerWindow);

    /// @notice Emitted when a buyer requests a withdrawal maturing at `availableAt` (0 cancels).
    event WithdrawRequested(address indexed buyer, uint64 amount, uint64 availableAt);

    /// @notice Emitted on withdrawal; `amount` is below `requested` if redemptions landed since.
    event EscrowWithdrawn(address indexed buyer, uint64 requested, uint64 amount);

    /// @notice Emitted when a payer grants a new delegate.
    event DelegateAuthorized(
        address indexed payer,
        address indexed delegate,
        uint64 maxVoucherAmount,
        uint64 maxPerWindow,
        uint64 validUntil
    );
    /// @notice Emitted when a standing grant's caps or `validUntil` change.
    event DelegateUpdated(
        address indexed payer,
        address indexed delegate,
        uint64 maxVoucherAmount,
        uint64 maxPerWindow,
        uint64 validUntil
    );
    /// @notice Emitted when a payer revokes a delegate.
    event DelegateRevoked(address indexed payer, address indexed delegate);

    /// @notice Emitted beside `VoucherRedeemed` when a delegate signed the voucher;
    ///         `spentInWindow` is the delegate's counter after this redemption.
    event DelegateVoucherRedeemed(
        address indexed payer,
        address indexed delegate,
        uint64 seq,
        uint64 amount,
        uint64 spentInWindow
    );

    // --- shared call sites (one per external read, for bytecode size) ----------------------

    /// @dev The single `CONFIG.params` call site.
    function _params() internal view returns (ParamSet memory) {
        return CONFIG.params();
    }

    /// @dev Pause and blocklist check of every gated door.
    function _assertActive(address a, address b, address c) internal view {
        CONFIG.assertActive(a, b, c);
    }

    /// @dev Consumes `authNonce` on a direct payer decision, voiding any pending signature.
    function _bumpAuthNonce(address payer) internal {
        escrows[payer].authNonce += 1;
    }

    /// @dev Multiplier for the in-memory hash tables: the slot is the high bits of the product,
    ///      so every bit of the address moves it. The multiplier is public, so collisions can
    ///      still be ground (about one try per slot); that costs probes, bounded by the table
    ///      size, never a wrong answer.
    uint256 internal constant SET_HASH = 0x9e3779b97f4a7c15f39cc0605cedc8341082276bf3a27251;

    /// @dev True if `x` is in the open-addressing set `t` (entries `x | 1 << 160`; length a
    ///      power of two that the caller keeps above the number of entries, so the probe always
    ///      ends); otherwise inserts it and returns false. A colliding address costs probes,
    ///      never a wrong answer: an entry matches only its own address.
    function _seen(uint256[] memory t, address x) internal pure returns (bool hit) {
        assembly ("memory-safe") {
            let mask := sub(mload(t), 1)
            let key := or(x, shl(160, 1))
            let i := and(shr(128, mul(key, SET_HASH)), mask)
            for {} 1 {} {
                let ptr := add(add(t, 0x20), shl(5, i))
                let e := mload(ptr)
                if eq(e, key) {
                    hit := 1
                    break
                }
                if iszero(e) {
                    mstore(ptr, key)
                    break
                }
                i := and(add(i, 1), mask)
            }
        }
    }

    /// @dev Batch shape: non-empty, at most `MAX_REDEEM_BATCH`, equal array lengths.
    function _assertBatch(uint256 n, uint256 m) internal pure {
        if (n == 0) revert EmptyBatch();
        if (n > Constants.MAX_REDEEM_BATCH) revert BatchTooLarge();
        if (m != n) revert BatchLengthMismatch();
    }

    // --- payer decisions (direct doors in the escrow, relayed twins in the extension) -------

    /// @dev Reverts on a no-op. Holds the previous caps for `TIGHTEN_DELAY` if either is lowered.
    function _setLimits(address buyer, uint64 maxVoucherAmount, uint64 maxPerWindow) internal {
        Escrow storage e = escrows[buyer];
        if (e.maxVoucherAmount == maxVoucherAmount && e.maxPerWindow == maxPerWindow) {
            revert EscrowLimitsUnchanged();
        }
        _holdIfLowered(
            priorEscrowCaps[buyer],
            buyer,
            address(0),
            e.maxVoucherAmount,
            e.maxPerWindow,
            maxVoucherAmount,
            maxPerWindow,
            Cast.toUint64(block.timestamp) + Constants.TIGHTEN_DELAY_SECONDS
        );
        e.maxVoucherAmount = maxVoucherAmount;
        e.maxPerWindow = maxPerWindow;
        emit EscrowLimitsSet(buyer, maxVoucherAmount, maxPerWindow);
    }

    /// @dev Records the request for the authorised `buyer`, never the caller of a relayed door.
    ///      Not bounded by the balance. Only vouchers signed before the request are guaranteed to
    ///      expire before it matures.
    function _requestWithdraw(address buyer, uint64 amount) internal {
        Escrow storage e = escrows[buyer];
        uint64 availableAt =
            amount == 0 ? 0 : Cast.toUint64(block.timestamp) + Constants.WITHDRAW_DELAY_SECONDS;
        e.withdrawRequested = amount;
        e.withdrawAvailableAt = availableAt;
        emit WithdrawRequested(buyer, amount, availableAt);
    }

    // --- voucher delegation ------------------------------------------------------------------

    /// @dev Whether a written grant can sign now: not past `validUntil` and, if revoked, not past
    ///      its grace (`prior.until`).
    function _canSign(Delegation storage d, PriorCaps storage prior, uint64 nowTs)
        internal
        view
        returns (bool)
    {
        if (nowTs > d.validUntil) return false;
        return !d.revoked || nowTs <= prior.until;
    }

    /// @dev Field-wise maximum of the current caps and a running hold.
    function _effectiveCaps(uint64 curV, uint64 curW, PriorCaps storage p, uint64 nowTs)
        internal
        view
        returns (uint64 capV, uint64 capW)
    {
        capV = curV;
        capW = curW;
        if (nowTs <= p.until) {
            if (p.maxVoucherAmount > capV) capV = p.maxVoucherAmount;
            if (p.maxPerWindow > capW) capW = p.maxPerWindow;
        }
    }

    /// @dev Holds the current caps until `until` if either is lowered; a raise applies at once.
    function _holdIfLowered(
        PriorCaps storage p,
        address payer,
        address delegate,
        uint64 curV,
        uint64 curW,
        uint64 newV,
        uint64 newW,
        uint64 until
    ) internal {
        if (newV >= curV && newW >= curW) return;
        _hold(p, payer, delegate, curV, curW, until);
    }

    /// @dev Writes a hold, merged field-wise with any running one, and emits `CapsHeld`.
    function _hold(
        PriorCaps storage p,
        address payer,
        address delegate,
        uint64 curV,
        uint64 curW,
        uint64 until
    ) internal {
        (uint64 capV, uint64 capW) = _effectiveCaps(curV, curW, p, Cast.toUint64(block.timestamp));
        p.maxVoucherAmount = capV;
        p.maxPerWindow = capW;
        p.until = until;
        emit CapsHeld(payer, delegate, capV, capW, until);
    }

    /// @dev End of a delegate hold: `now + TIGHTEN_DELAY`, capped at the grant's prior
    ///      `validUntil` so a lapsed grant's caps cannot return.
    function _delegateHoldEnd(uint64 validUntil, uint64 nowTs) internal pure returns (uint64) {
        uint64 end = nowTs + Constants.TIGHTEN_DELAY_SECONDS;
        return validUntil < end ? validUntil : end;
    }

    /// @dev Validates and writes a grant. Caps must be non-zero and within the escrow's.
    function _authorizeDelegate(
        address payer,
        address delegate,
        uint64 maxVoucherAmount,
        uint64 maxPerWindow,
        uint64 validUntil
    ) internal {
        if (delegate == address(0)) revert ZeroAddress();
        if (delegate == payer) revert DelegateIsPayer();
        if (maxVoucherAmount == 0 || maxPerWindow == 0 || maxVoucherAmount > maxPerWindow) {
            revert DelegateCapsInvalid();
        }
        Escrow storage e = escrows[payer];
        if (maxVoucherAmount > e.maxVoucherAmount || maxPerWindow > e.maxPerWindow) {
            revert DelegateCapsExceedEscrowLimits();
        }
        uint64 nowTs = Cast.toUint64(block.timestamp);
        if (
            validUntil < nowTs + Constants.TIGHTEN_DELAY_SECONDS
                || validUntil - nowTs > Constants.MAX_DELEGATION_LIFETIME_SECONDS
        ) revert DelegateValidUntilInvalid();

        Delegation storage d = delegations[payer][delegate];
        if (
            d.listPosition != 0 && d.maxVoucherAmount == maxVoucherAmount
                && d.maxPerWindow == maxPerWindow && d.validUntil == validUntil
        ) revert DelegationUnchanged();
        // Only a grant that can still sign gets a hold; otherwise a lowering re-grant would
        // revive the stored caps of a grant revoked and past its grace.
        PriorCaps storage prior = priorDelegateCaps[payer][delegate];
        if (d.validUntil != 0 && _canSign(d, prior, nowTs)) {
            _holdIfLowered(
                prior,
                payer,
                delegate,
                d.maxVoucherAmount,
                d.maxPerWindow,
                maxVoucherAmount,
                maxPerWindow,
                _delegateHoldEnd(d.validUntil, nowTs)
            );
        }

        bool isNew = d.listPosition == 0;
        if (isNew) {
            address[] storage list = delegateList[payer];
            if (list.length >= Constants.MAX_DELEGATES_PER_PAYER) revert TooManyDelegates();
            list.push(delegate);
            // Bounded by `MAX_DELEGATES_PER_PAYER`.
            d.listPosition = uint32(list.length);
        }
        d.maxVoucherAmount = maxVoucherAmount;
        d.maxPerWindow = maxPerWindow;
        d.validUntil = validUntil;
        d.revoked = false;
        if (isNew) {
            emit DelegateAuthorized(payer, delegate, maxVoucherAmount, maxPerWindow, validUntil);
        } else {
            emit DelegateUpdated(payer, delegate, maxVoucherAmount, maxPerWindow, validUntil);
        }
    }

    /// @dev Unlists the grant, marks it revoked and holds its caps for the grace period.
    function _revokeDelegate(address payer, address delegate) internal {
        Delegation storage d = delegations[payer][delegate];
        uint256 pos = d.listPosition;
        if (pos == 0) revert DelegateNotActive();

        // Swap-and-pop, keeping every moved entry's position true.
        address[] storage list = delegateList[payer];
        uint256 last = list.length;
        if (pos != last) {
            address moved = list[last - 1];
            list[pos - 1] = moved;
            delegations[payer][moved].listPosition = uint32(pos);
        }
        list.pop();

        d.listPosition = 0;
        d.revoked = true;
        // The grace, read by `_canSign`; a lapsed grant signs nothing and gets no hold.
        uint64 nowTs = Cast.toUint64(block.timestamp);
        if (nowTs <= d.validUntil) {
            _hold(
                priorDelegateCaps[payer][delegate],
                payer,
                delegate,
                d.maxVoucherAmount,
                d.maxPerWindow,
                _delegateHoldEnd(d.validUntil, nowTs)
            );
        }
        emit DelegateRevoked(payer, delegate);
    }
}
