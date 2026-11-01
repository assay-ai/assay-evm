// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

import {IAssayConfig} from "./interfaces/IAssayConfig.sol";
import {IAssayStakeView} from "./interfaces/IAssayStakeView.sol";
import {IERC20Decimals} from "./interfaces/IERC20Decimals.sol";
import {Fee} from "./libraries/Fee.sol";
import {Cast} from "./libraries/Cast.sol";
import {Constants} from "./Constants.sol";
import {ParamSet, ChannelVoucher, ChannelRef} from "./Types.sol";
import {ChannelDoor} from "./libraries/ChannelDoor.sol";
import {AssayEscrowStorage} from "./AssayEscrowStorage.sol";
import {AssayEscrowExtension} from "./AssayEscrowExtension.sol";
import "./Errors.sol";

/// @title AssayEscrow
/// @notice Holds every buyer's USDG in one pooled balance with per-buyer accounting. Money leaves a
///         buyer's balance only by a signed voucher redeemed into hold, or by the buyer's own
///         delayed `withdraw`.
/// @dev UUPS behind an ERC1967 proxy; the upgrade authority is the Config owner, read on every
///      call. The proxy is the EIP-712 `verifyingContract`: an upgrade keeps vouchers valid, a
///      redeploy voids them. No role can move a token to an address of its choosing: a held
///      payment pays the voucher's provider and Config's treasury, or returns to the buyer.
///      Solvency is `totalEscrowed + totalHeld` plus the channel door's held and set-aside
///      totals (`channelBooks`), never `balanceOf`. The plain OZ EIP712 and
///      ReentrancyGuard are proxy-safe (separator rebuilt per address, zero slot = not entered).
///
///      This contract is the CORE: every door that moves money, every exit and brake a buyer
///      needs without the platform (deposit, withdraw, caps, delegate grant and revocation), the
///      channel door and the upgrade authority. Every other selector (the per-call voucher door,
///      the relayed BySig decisions, `effectiveCapsOf`) is answered by `EXTENSION`, which
///      `fallback` reaches by DELEGATECALL in this storage (D-29).
contract AssayEscrow is
    Initializable,
    UUPSUpgradeable,
    EIP712,
    ReentrancyGuard,
    AssayEscrowStorage
{
    using SafeERC20 for IERC20;

    /// @notice The extension this implementation forwards unknown selectors to. Created by the
    ///         constructor, so it is bound to this implementation for its whole life.
    address public immutable EXTENSION;

    /// @dev The EIP-712 name and version must never change across implementations, or every
    ///      outstanding voucher dies. The implementation itself can never be initialised.
    constructor() EIP712(EIP712_NAME, EIP712_VERSION) {
        _disableInitializers();
        EXTENSION = _newExtension();
    }

    /// @dev The extension this implementation is bound to, created here so its code comes from
    ///      this implementation's own creation code. Virtual only so a test build can bind a
    ///      deliberately wrong extension (`test/helpers/AssayEscrowSilentDomainV2.sol`).
    function _newExtension() internal virtual returns (address) {
        return address(new AssayEscrowExtension());
    }

    /// @notice Initialises the proxy. Callable once.
    /// @param config The Config contract.
    /// @param stake The Stake contract.
    /// @param asset The settlement token; must have 6 decimals.
    function initialize(IAssayConfig config, IAssayStakeView stake, IERC20 asset)
        external
        initializer
    {
        if (address(config) == address(0) || address(stake) == address(0)) revert ZeroAddress();
        if (address(asset) == address(0)) revert ZeroAddress();
        if (IERC20Decimals(address(asset)).decimals() != 6) revert AssetDecimalsNotSix();

        // A withdrawal must not mature while a voucher signed before the request is redeemable.
        if (Constants.WITHDRAW_DELAY_SECONDS <= Constants.MAX_VOUCHER_REDEEMABLE_LIFE_SECONDS) {
            revert WithdrawDelayTooShort();
        }

        CONFIG = config;
        STAKE = stake;
        ASSET = asset;
    }

    /// @dev Only the current Config owner, read on every call. The admin cannot upgrade.
    function _authorizeUpgrade(address) internal view override {
        if (msg.sender != CONFIG.owner()) revert NotOwner();
    }

    /// @dev Every selector this contract does not have runs in `EXTENSION`, in this storage,
    ///      with the caller's `msg.sender`; its return data or revert data comes back verbatim.
    ///      Not payable (a call with value reverts, as before) and not `nonReentrant` (each
    ///      extension door takes the shared guard itself).
    fallback() external {
        address ext = EXTENSION;
        assembly ("memory-safe") {
            let p := mload(0x40)
            calldatacopy(p, 0, calldatasize())
            let ok := delegatecall(gas(), ext, p, calldatasize(), 0, 0)
            returndatacopy(p, 0, returndatasize())
            if iszero(ok) { revert(p, returndatasize()) }
            return(p, returndatasize())
        }
    }

    /// @dev Used only as the two halves of `_pullExact`'s balance delta.
    function _assetBalance() internal view returns (uint256) {
        return ASSET.balanceOf(address(this));
    }

    /// @notice Returns a buyer's escrow.
    /// @param buyer The buyer.
    /// @return The escrow record.
    function escrowOf(address buyer) external view returns (Escrow memory) {
        return escrows[buyer];
    }

    /// @notice Returns the held payment of a payer's seq.
    /// @param payer The payer.
    /// @param seq The voucher sequence number.
    /// @return The held payment record.
    function held(address payer, uint64 seq) external view returns (HeldPayment memory) {
        return heldPayments[payer][seq];
    }

    /// @notice Returns the EIP-712 domain separator of this proxy.
    /// @return The domain separator.
    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /// @notice Deposits into the caller's own escrow.
    /// @param amount Amount in base units.
    function deposit(uint64 amount) external {
        depositFor(msg.sender, amount);
    }

    /// @notice Deposits from the caller into `buyer`'s escrow. Anyone may fund anyone.
    /// @dev Pause- and blocklist-gated. Pulls before crediting because the credit is the measured
    ///      delta; safe only because this path pays nothing out. Payout paths stay effects-first.
    /// @param buyer The escrow to credit.
    /// @param amount Amount in base units.
    function depositFor(address buyer, uint64 amount) public nonReentrant {
        _assertActive(buyer, msg.sender, address(0));
        if (buyer == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        _pullExact(msg.sender, amount);
        _credit(buyer, amount);
    }

    /// @dev Pulls exactly `amount` from `from`, reverting on any other delta (fee-on-transfer).
    ///      The only `balanceOf` reads; never use `balanceOf` for solvency.
    function _pullExact(address from, uint64 amount) internal {
        uint256 before = _assetBalance();
        ASSET.safeTransferFrom(from, address(this), amount);
        if (_assetBalance() - before != amount) revert TransferAmountMismatch();
    }

    /// @dev Adds a deposit to the balance, `totalFunded` and `totalEscrowed`.
    function _credit(address buyer, uint64 amount) internal {
        Escrow storage e = escrows[buyer];
        e.balance += amount;
        e.totalFunded += amount;
        totalEscrowed += amount;
        emit Deposited(buyer, msg.sender, amount, e.balance);
    }

    /// @notice Sets the caller's caps. A zero cap refuses every voucher.
    /// @dev Pause- and blocklist-gated. Consumes `authNonce`. A lowering binds already-valid
    ///      vouchers only after `TIGHTEN_DELAY`.
    /// @param maxVoucherAmount Maximum amount per voucher, in base units.
    /// @param maxPerWindow Maximum total per rolling window, in base units.
    function setLimits(uint64 maxVoucherAmount, uint64 maxPerWindow) external nonReentrant {
        _assertActive(msg.sender, address(0), address(0));
        _bumpAuthNonce(msg.sender);
        _setLimits(msg.sender, maxVoucherAmount, maxPerWindow);
    }

    /// @notice Starts the caller's withdrawal clock of `WITHDRAW_DELAY_SECONDS`; 0 cancels.
    /// @dev Moves no money and does not block redemption: the delay outlives every voucher signed
    ///      before the request. Pause- and blocklist-gated. Consumes `authNonce`.
    /// @param amount Amount requested, in base units.
    function requestWithdraw(uint64 amount) external nonReentrant {
        _assertActive(msg.sender, address(0), address(0));
        _bumpAuthNonce(msg.sender);
        _requestWithdraw(msg.sender, amount);
    }

    /// @notice Pays the caller `min(requested, balance)` once its request has matured.
    /// @dev Pays only `msg.sender` and has no relayed form, by design. Pause- and blocklist-gated;
    ///      the gates hold the money in place but never move it. An empty escrow reverts and keeps
    ///      the request. All effects precede the transfer; `totalFunded` is not touched.
    function withdraw() external nonReentrant {
        _assertActive(msg.sender, address(0), address(0));
        Escrow storage e = escrows[msg.sender];

        uint64 requested = e.withdrawRequested;
        if (requested == 0) revert NoWithdrawRequested();
        if (block.timestamp < e.withdrawAvailableAt) revert WithdrawNotYetAvailable();

        uint128 balance = e.balance;
        // Narrows only when `balance < requested`, a uint64.
        uint64 amount = Cast.toUint64(requested <= balance ? requested : balance);
        if (amount == 0) revert EscrowInsufficient();

        // effects
        e.balance = balance - amount;
        e.totalWithdrawn += amount;
        e.withdrawRequested = 0;
        e.withdrawAvailableAt = 0;
        totalEscrowed -= amount;

        // interactions
        ASSET.safeTransfer(msg.sender, amount);
        emit EscrowWithdrawn(msg.sender, requested, amount);
    }

    // --- redeem into hold ---------------------------------------------------------------

    /// @notice Pays a held payment to its provider and the fee to the treasury, at the frozen rate.
    /// @dev The redeemer may call from `collectableAt`, anyone from `collectableAt +
    ///      HELD_TIMEOUT_SECONDS`. Pause- and blocklist-gated (payer and provider).
    /// @param payer The payer.
    /// @param seq The voucher sequence number.
    function collectHeld(address payer, uint64 seq) external nonReentrant {
        _collectHeld(payer, seq, _params());
    }

    /// @notice Collects many held payments atomically; one bad item reverts the batch.
    /// @param payers The payers.
    /// @param seqs One sequence number per payer.
    function collectHeldBatch(address[] calldata payers, uint64[] calldata seqs)
        external
        nonReentrant
    {
        uint256 n = payers.length;
        _assertBatch(n, seqs.length);
        ParamSet memory p = _params();
        if (n == 1) return _collectHeld(payers[0], seqs[0], p); // the single-item door's path
        // One payout per distinct provider and one fee payout per batch, after every item's
        // checks and effects. Each item's `HeldCollected` is emitted as before; the payouts
        // move the same totals to the same recipients (a zero total makes no call).
        Payout memory o = _newPayout(n);
        for (uint256 i = 0; i < n; ++i) {
            _takeHeld(payers[i], seqs[i], p, o);
        }
        totalHeld -= uint128(o.sum); // at most MAX_REDEEM_BATCH uint64 amounts
        for (uint256 j = 0; j < o.k; ++j) {
            if (o.owed[j] > 0) ASSET.safeTransfer(o.provs[j], o.owed[j]);
        }
        if (o.fees > 0) ASSET.safeTransfer(p.treasury, o.fees);
    }

    /// @dev A batch collect's running books: `assertActive` passes, provider -> index map,
    ///      distinct providers in first-seen order with their totals, fee total, held total.
    struct Payout {
        uint256[] active;
        uint256[] slot;
        address[] provs;
        uint256[] owed;
        uint256 k;
        uint256 fees;
        uint256 sum;
    }

    function _newPayout(uint256 n) internal pure returns (Payout memory o) {
        uint256 cap = 4;
        while (cap < 4 * n) cap <<= 1;
        o.active = new uint256[](cap);
        o.slot = new uint256[](cap >> 1);
        o.provs = new address[](n);
        o.owed = new uint256[](n);
    }

    /// @dev Index of `x` in the provider map `t`, inserting it at `next` when absent.
    function _indexOf(uint256[] memory t, address x, uint256 next)
        internal
        pure
        returns (uint256 j)
    {
        assembly ("memory-safe") {
            let mask := sub(mload(t), 1)
            let key := or(x, shl(160, 1))
            let i := and(shr(128, mul(key, SET_HASH)), mask)
            for {} 1 {} {
                let ptr := add(add(t, 0x20), shl(5, i))
                let e := mload(ptr)
                if iszero(e) {
                    mstore(ptr, or(key, shl(168, next)))
                    j := next
                    break
                }
                if eq(and(e, sub(shl(168, 1), 1)), key) {
                    j := shr(168, e)
                    break
                }
                i := and(add(i, 1), mask)
            }
        }
    }

    /// @dev One batch item's checks and effects, booked into `o`; no transfer. `assertActive`
    ///      runs unless the payer, the provider and the zero third all passed it in this call.
    function _takeHeld(address payer, uint64 seq, ParamSet memory p, Payout memory o) internal {
        HeldPayment storage h = heldPayments[payer][seq];
        if (h.status != HeldStatus.Held) revert HeldPaymentNotHeld();
        uint256 opensAt = uint256(h.collectableAt);
        if (msg.sender != p.redeemer) opensAt += Constants.HELD_TIMEOUT_SECONDS;
        if (block.timestamp < opensAt) revert HeldNotYetCollectable();
        address provider = h.provider;
        bool known = _seen(o.active, payer);
        known = _seen(o.active, provider) && known;
        known = _seen(o.active, address(0)) && known;
        if (!known) _assertActive(payer, provider, address(0));

        uint64 amount = h.amount;
        h.status = HeldStatus.Collected;
        (uint64 fee, uint64 providerAmount) = Fee.splitFee(amount, h.takeRateBps);
        o.sum += amount;
        o.fees += fee;
        uint256 j = _indexOf(o.slot, provider, o.k);
        if (j == o.k) o.provs[o.k++] = provider;
        o.owed[j] += providerAmount;
        emit HeldCollected(payer, seq, provider, providerAmount, fee);
    }

    /// @notice Returns a held payment to the buyer's balance in full. Redeemer only.
    /// @dev Open until `collectableAt + HELD_TIMEOUT_SECONDS`. Lowers `totalRedeemed` but does
    ///      not restore `spentInWindow`. Not pause-gated: it transfers no token.
    /// @param payer The payer.
    /// @param seq The voucher sequence number.
    function refundHeld(address payer, uint64 seq) external nonReentrant {
        if (msg.sender != _params().redeemer) revert NotRedeemer();
        _refundHeld(payer, seq);
    }

    /// @notice Refunds many held payments atomically. Redeemer only.
    /// @param payers The payers.
    /// @param seqs One sequence number per payer.
    function refundHeldBatch(address[] calldata payers, uint64[] calldata seqs)
        external
        nonReentrant
    {
        _assertBatch(payers.length, seqs.length);
        if (msg.sender != _params().redeemer) revert NotRedeemer();
        for (uint256 i = 0; i < payers.length; ++i) {
            _refundHeld(payers[i], seqs[i]);
        }
    }

    /// @dev Marks a `Held` record collected, then pays out. Effects precede the transfers.
    function _collectHeld(address payer, uint64 seq, ParamSet memory p) internal {
        HeldPayment storage h = heldPayments[payer][seq];
        if (h.status != HeldStatus.Held) revert HeldPaymentNotHeld();
        uint256 opensAt = uint256(h.collectableAt);
        if (msg.sender != p.redeemer) opensAt += Constants.HELD_TIMEOUT_SECONDS;
        if (block.timestamp < opensAt) revert HeldNotYetCollectable();
        address provider = h.provider;
        _assertActive(payer, provider, address(0));

        // effects
        uint64 amount = h.amount;
        h.status = HeldStatus.Collected;
        totalHeld -= amount;
        (uint64 fee, uint64 providerAmount) = Fee.splitFee(amount, h.takeRateBps);

        // interactions; zero amounts make no call
        if (providerAmount > 0) ASSET.safeTransfer(provider, providerAmount);
        if (fee > 0) ASSET.safeTransfer(p.treasury, fee);
        emit HeldCollected(payer, seq, provider, providerAmount, fee);
    }

    /// @dev Returns a `Held` record to the payer's balance while the refund window is open.
    function _refundHeld(address payer, uint64 seq) internal {
        HeldPayment storage h = heldPayments[payer][seq];
        if (h.status != HeldStatus.Held) revert HeldPaymentNotHeld();
        if (block.timestamp >= uint256(h.collectableAt) + Constants.HELD_TIMEOUT_SECONDS) {
            revert HeldRefundWindowClosed();
        }
        uint64 amount = h.amount;
        h.status = HeldStatus.Refunded;
        totalHeld -= amount;
        Escrow storage e = escrows[payer];
        e.balance += amount;
        e.totalRedeemed -= amount;
        totalEscrowed += amount;
        emit HeldRefunded(payer, seq, amount);
    }

    // --- voucher delegation ------------------------------------------------------------------

    /// @notice Returns a payer's grant to a delegate.
    /// @param payer The payer.
    /// @param delegate The delegate.
    /// @return The grant.
    function delegationOf(address payer, address delegate)
        external
        view
        returns (Delegation memory)
    {
        return delegations[payer][delegate];
    }

    /// @notice Returns a payer's listed delegates.
    /// @param payer The payer.
    /// @return The delegate addresses.
    function delegatesOf(address payer) external view returns (address[] memory) {
        return delegateList[payer];
    }

    /// @notice Lets `delegate` sign vouchers on the caller's escrow within caps until `validUntil`.
    /// @dev A delegate can only sign vouchers. Consumes `authNonce`, so a withheld relayed
    ///      signature cannot undo a later decision. Lowering a live grant's caps holds the old
    ///      ones for `TIGHTEN_DELAY`. Pause- and blocklist-gated (payer and delegate).
    /// @param delegate The delegate key.
    /// @param maxVoucherAmount Maximum amount per voucher, in base units.
    /// @param maxPerWindow Maximum total per rolling window, in base units.
    /// @param validUntil Expiry; at least `now + TIGHTEN_DELAY`.
    function authorizeDelegate(
        address delegate,
        uint64 maxVoucherAmount,
        uint64 maxPerWindow,
        uint64 validUntil
    ) external nonReentrant {
        _assertActive(msg.sender, delegate, address(0));
        _bumpAuthNonce(msg.sender);
        _authorizeDelegate(msg.sender, delegate, maxVoucherAmount, maxPerWindow, validUntil);
    }

    /// @notice Revokes `delegate`. Vouchers it already signed stay redeemable for
    ///         `TIGHTEN_DELAY`, never past `validUntil`.
    /// @dev Consumes `authNonce`. Never pause- or blocklist-gated.
    /// @param delegate The delegate to revoke.
    function revokeDelegate(address delegate) external nonReentrant {
        _bumpAuthNonce(msg.sender);
        _revokeDelegate(msg.sender, delegate);
    }

    // --- channel door (cumulative vouchers; logic in the `ChannelDoor` library) -----------

    /// @notice Settles channel vouchers into hold. Redeemer only; pause-gated.
    /// @dev An item charges at most `cumulative - fromSettled[i]`, and only if its channel's
    ///      settled value is exactly `fromSettled[i]`. An item that state or time refuses is
    ///      skipped with an event, never reverting the batch. Settlement never pays out. The
    ///      caller, pause and batch checks run in `ChannelDoor.settle`.
    /// @param vs The vouchers.
    /// @param sigs The signatures, 65 bytes each, concatenated in voucher order; each by the
    ///        payer or an authorised delegate.
    /// @param fromSettled Per item, the settled value the redeemer expects the channel to have.
    /// @param charges Per item, what moves into hold; the rest of the delta is waived.
    function settleChannels(
        ChannelVoucher[] calldata vs,
        bytes calldata sigs,
        uint64[] calldata fromSettled,
        uint64[] calldata charges
    ) external nonReentrant {
        // Forwards this call's own ABI tail to the library verbatim instead of re-encoding it:
        // the library's head is 8 fixed words (5 storage slots, config, stake, domain separator)
        // followed by the same 4 offsets, each shifted by those 8 words. Solidity has already
        // bounds-checked the 4 calldata arguments, and the library decodes and checks them again,
        // so a non-canonical encoding decodes as what it says or reverts. The target is the
        // linked `ChannelDoor` (a link-time constant).
        (vs, sigs, fromSettled, charges);
        address lib = address(ChannelDoor);
        bytes4 sel = ChannelDoor.settle.selector;
        IAssayConfig cfg = CONFIG;
        IAssayStakeView stk = STAKE;
        bytes32 ds = _domainSeparatorV4();
        uint256 total;
        assembly ("memory-safe") {
            let p := mload(0x40)
            mstore(p, sel)
            let h := add(p, 4)
            mstore(h, channels.slot)
            mstore(add(h, 0x20), escrows.slot)
            mstore(add(h, 0x40), delegations.slot)
            mstore(add(h, 0x60), priorEscrowCaps.slot)
            mstore(add(h, 0x80), priorDelegateCaps.slot)
            mstore(add(h, 0xa0), cfg)
            mstore(add(h, 0xc0), stk)
            mstore(add(h, 0xe0), ds)
            for { let k := 0 } lt(k, 4) { k := add(k, 1) } {
                let o := calldataload(add(4, mul(k, 0x20)))
                // An offset into the 4-word head would be re-read differently once shifted.
                // Solidity's own decoding has bounded `o` by the calldata size, so `o + 0x100`
                // cannot overflow.
                if lt(o, 0x80) { revert(0, 0) }
                mstore(add(h, add(0x100, mul(k, 0x20))), add(o, 0x100))
            }
            let tail := sub(calldatasize(), 0x84)
            calldatacopy(add(h, 0x180), 0x84, tail)
            let len := add(0x184, tail)
            let ok := delegatecall(gas(), lib, p, len, 0, 0x20)
            if iszero(ok) {
                returndatacopy(p, 0, returndatasize())
                revert(p, returndatasize())
            }
            if lt(returndatasize(), 0x20) { revert(0, 0) }
            total := mload(0)
        }
        totalEscrowed -= uint128(total);
    }

    /// @notice Pays matured channel buckets to their providers and the fee to the treasury.
    /// @dev The redeemer may collect from maturity and leave an amount held per channel;
    ///      anyone else from maturity + `HELD_TIMEOUT_SECONDS`, leaving nothing. Pause-gated.
    ///      A failed transfer is set aside in `unpaid` for that recipient alone.
    /// @param refs The channels.
    /// @param keepHeld Per channel, the matured amount to keep held (redeemer only).
    function collectChannels(ChannelRef[] calldata refs, uint64[] calldata keepHeld)
        external
        nonReentrant
    {
        ChannelDoor.collect(channels, CONFIG, ASSET, refs, keepHeld);
    }

    /// @notice Returns held channel money to payers' balances. Redeemer only; not pause-gated.
    /// @param refs The channels.
    /// @param buckets Per item, the bucket to refund from: `maturityHour << 16 | takeRateBps`.
    /// @param amounts Per item, the amount to refund.
    /// @param refundIds Per item, an id applied at most once per channel (D-31).
    function refundChannels(
        ChannelRef[] calldata refs,
        uint40[] calldata buckets,
        uint64[] calldata amounts,
        bytes32[] calldata refundIds
    ) external nonReentrant {
        totalEscrowed += uint128(
            ChannelDoor.refund(channels, escrows, CONFIG, refs, buckets, amounts, refundIds)
        );
    }

    /// @notice Pays `to` what a failed payout set aside for it, to `to` only. Anyone may call.
    /// @dev Pause- and blocklist-gated; a zero balance is a no-op.
    function claimUnpaid(address to) external nonReentrant {
        ChannelDoor.claimUnpaid(channels, CONFIG, ASSET, to);
    }

    /// @notice A channel's packed slot (decode with `ChannelDoor.unpack`; key from
    ///         `ChannelDoor.keyOf`), what failed payouts set aside for `to`, the total set
    ///         aside, and the total held in channel buckets.
    function channelBooks(bytes32 key, address to)
        external
        view
        returns (uint256 state, uint128 unpaid, uint128 totalUnpaid, uint128 held)
    {
        return (channels.state[key], channels.unpaid[to], channels.totalUnpaid, channels.held);
    }
}
