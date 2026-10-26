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
import {Voucher712} from "./libraries/Voucher712.sol";
import {Sig} from "./libraries/Sig.sol";
import {Window} from "./libraries/Window.sol";
import {Fee} from "./libraries/Fee.sol";
import {Cast} from "./libraries/Cast.sol";
import {Constants} from "./Constants.sol";
import {Voucher, ParamSet} from "./Types.sol";
import "./Errors.sol";

/// @title AssayEscrow
/// @notice Holds every buyer's USDG in one pooled balance with per-buyer accounting. Money leaves a
///         buyer's balance only by a signed voucher redeemed into hold, or by the buyer's own
///         delayed `withdraw`.
/// @dev UUPS behind an ERC1967 proxy; the upgrade authority is the Config owner, read on every
///      call. The proxy is the EIP-712 `verifyingContract`: an upgrade keeps vouchers valid, a
///      redeploy voids them. No role can move a token to an address of its choosing: a held
///      payment pays the voucher's provider and Config's treasury, or returns to the buyer.
///      Solvency is `totalEscrowed + totalHeld`, never `balanceOf`. The plain OZ EIP712 and
///      ReentrancyGuard are proxy-safe (separator rebuilt per address, zero slot = not entered).
contract AssayEscrow is Initializable, UUPSUpgradeable, EIP712, ReentrancyGuard {
    using SafeERC20 for IERC20;

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

    /// @dev The EIP-712 name and version must never change across implementations, or every
    ///      outstanding voucher dies. The implementation itself can never be initialised.
    constructor() EIP712("Assay Settlement", "2") {
        _disableInitializers();
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

    /// @notice Redeems a signed voucher into hold. Redeemer only.
    /// @dev The payer's (or its delegate's) signature is the whole authority over the money; the
    ///      redeemer only decides when. `params` is read once so every check uses one set.
    /// @param v The voucher.
    /// @param sig Signature by the payer or an authorised delegate.
    function redeemVoucher(Voucher calldata v, bytes calldata sig) external nonReentrant {
        ParamSet memory p = _params();
        if (msg.sender != p.redeemer) revert NotRedeemer();
        _redeem(v, sig, p); // the pause is checked in `_redeem`
    }

    /// @notice Redeems up to `MAX_REDEEM_BATCH` vouchers atomically. Redeemer only.
    /// @dev One bad voucher reverts the whole batch. Each item runs the same `_redeem` rules
    ///      against one `params` read.
    /// @param vs The vouchers.
    /// @param sigs One signature per voucher.
    function redeemVoucherBatch(Voucher[] calldata vs, bytes[] calldata sigs)
        external
        nonReentrant
    {
        ParamSet memory p = _params();
        if (msg.sender != p.redeemer) revert NotRedeemer();
        // The pause is checked per item in `_redeem`.

        uint256 n = vs.length;
        _assertBatch(n, sigs.length);

        for (uint256 i = 0; i < n; ++i) {
            _redeem(vs[i], sigs[i], p);
        }
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

    /// @notice Emitted when a buyer requests a withdrawal maturing at `availableAt` (0 cancels).
    event WithdrawRequested(address indexed buyer, uint64 amount, uint64 availableAt);

    /// @notice Relayed `setLimits`, authorised by the buyer's EIP-712 signature.
    /// @dev Lets a buyer without gas lower a cap. Pause- and blocklist-gated.
    /// @param buyer The buyer whose caps are set.
    /// @param maxVoucherAmount Maximum amount per voucher, in base units.
    /// @param maxPerWindow Maximum total per rolling window, in base units.
    /// @param nonce The buyer's current `authNonce`.
    /// @param deadline Last valid timestamp of the signature.
    /// @param sig The buyer's signature.
    function setLimitsBySig(
        address buyer,
        uint64 maxVoucherAmount,
        uint64 maxPerWindow,
        uint64 nonce,
        uint64 deadline,
        bytes calldata sig
    ) external nonReentrant {
        _assertActive(buyer, address(0), address(0));
        _consumeAuth(
            buyer,
            Voucher712.hashSetLimits(buyer, maxVoucherAmount, maxPerWindow, nonce, deadline),
            nonce,
            deadline,
            sig
        );
        _setLimits(buyer, maxVoucherAmount, maxPerWindow);
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

    /// @notice Relayed `requestWithdraw`, authorised by the buyer's EIP-712 signature.
    /// @param buyer The buyer whose clock starts.
    /// @param amount Amount requested, in base units; 0 cancels.
    /// @param nonce The buyer's current `authNonce`.
    /// @param deadline Last valid timestamp of the signature.
    /// @param sig The buyer's signature.
    function requestWithdrawBySig(
        address buyer,
        uint64 amount,
        uint64 nonce,
        uint64 deadline,
        bytes calldata sig
    ) external nonReentrant {
        _assertActive(buyer, address(0), address(0));
        _consumeAuth(
            buyer,
            Voucher712.hashRequestWithdraw(buyer, amount, nonce, deadline),
            nonce,
            deadline,
            sig
        );
        _requestWithdraw(buyer, amount);
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

    /// @notice Emitted on withdrawal; `amount` is below `requested` if redemptions landed since.
    event EscrowWithdrawn(address indexed buyer, uint64 requested, uint64 amount);

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

    /// @dev Verifies and consumes a relayed payer authorisation: deadline, nonce, then signature.
    ///      One `authNonce` serves every payer decision, so signatures at the same nonce are
    ///      alternatives; each kind has its own typehash, so none is valid at another door.
    function _consumeAuth(
        address buyer,
        bytes32 structHash,
        uint64 nonce,
        uint64 deadline,
        bytes calldata sig
    ) internal {
        if (buyer == address(0)) revert ZeroAddress();
        if (block.timestamp > deadline) revert SignatureExpired();
        // Bounds how far ahead a deadline may be; the shared nonce kills a withheld signature.
        if (deadline > block.timestamp + Constants.MAX_SIGNATURE_LIFETIME_SECONDS) {
            revert SignatureDeadlineTooFar();
        }

        Escrow storage e = escrows[buyer];
        if (nonce != e.authNonce) revert BadNonce();
        if (Sig.recover(_hashTypedDataV4(structHash), sig) != buyer) revert SignerIsNotBuyer();

        e.authNonce = nonce + 1;
    }

    /// @dev The rule set shared by single and batch redemption: amount, window, seq, signature,
    ///      pause and blocklist, caps, stake floor, balance. Seq is checked before the signature.
    ///      Transfers no token; every external read precedes the effects. A refusal leaves the
    ///      seq unused.
    function _redeem(Voucher calldata v, bytes calldata sig, ParamSet memory p) internal {
        uint64 nowTs = Cast.toUint64(block.timestamp);

        if (v.amount == 0) revert ZeroAmount();

        // Order matters: the lifetime and skew bounds keep `expiresAt + grace` from overflowing.
        if (v.expiresAt <= v.issuedAt) revert InvalidVoucherWindow();
        if (v.expiresAt - v.issuedAt > Constants.VOUCHER_MAX_LIFETIME_SECONDS) {
            revert VoucherLifetimeTooLong();
        }
        if (v.issuedAt > nowTs + Constants.CLOCK_SKEW_TOLERANCE_SECONDS) {
            revert VoucherNotYetValid();
        }
        if (nowTs > v.expiresAt + Constants.REDEEM_GRACE_SECONDS) revert VoucherExpired();

        // Each (payer, seq) redeems at most once, in any order.
        Escrow storage e = escrows[v.payer];
        if (v.seq == 0) revert VoucherSeqZero();
        if (heldPayments[v.payer][v.seq].status != HeldStatus.None) revert VoucherSeqUsed();
        // Jump cap, applied only above the high-water mark; the first operand keeps the
        // subtraction from underflowing.
        if (v.seq > e.seqHigh && v.seq - e.seqHigh > Constants.MAX_SEQ_GAP) {
            revert VoucherSeqGapTooLarge();
        }

        // `address(0)` if the payer signed, else the authorised delegate.
        address delegate =
            _voucherAuthority(v.payer, _hashTypedDataV4(Voucher712.hashVoucher(v)), sig, nowTs);

        // After recovery, because the signing delegate is only known here.
        _assertActive(v.payer, v.provider, delegate);

        // A voucher passes the current caps or, while a hold runs, the held pair, each whole.
        uint256 spent = uint256(Window.decay(e.spentInWindow, e.windowStartedAt, nowTs)) + v.amount;
        if (v.amount > e.maxVoucherAmount || spent > e.maxPerWindow) {
            uint256 why =
                _heldRefusal(priorEscrowCaps[v.payer], v.amount, spent, e.maxVoucherAmount, nowTs);
            if (why == 1) revert VoucherExceedsPerCallLimit();
            if (why == 2) revert EscrowWindowLimitExceeded();
        }

        // A delegate-signed voucher must also fit the delegate's own caps.
        Delegation storage d = delegations[v.payer][delegate];
        uint256 delegateSpent;
        if (delegate != address(0)) {
            delegateSpent =
                uint256(Window.decay(d.spentInWindow, d.windowStartedAt, nowTs)) + v.amount;
            if (v.amount > d.maxVoucherAmount || delegateSpent > d.maxPerWindow) {
                uint256 why = _heldRefusal(
                    priorDelegateCaps[v.payer][delegate],
                    v.amount,
                    delegateSpent,
                    d.maxVoucherAmount,
                    nowTs
                );
                if (why == 1) revert DelegateVoucherExceedsPerCallLimit();
                if (why == 2) revert DelegateWindowLimitExceeded();
            }
        }

        // Only free bonded stake counts toward the provider's minimum.
        if (STAKE.freeBondedOf(v.provider) < p.minimumStake) revert ProviderBelowMinimumStake();

        if (e.balance < v.amount) revert EscrowInsufficient();

        // The collect hold in force now, frozen into the record.
        uint64 collectableAt = nowTs + CONFIG.collectHoldSeconds();

        // effects
        if (v.seq > e.seqHigh) e.seqHigh = v.seq;
        e.balance -= v.amount;
        uint64 spentAfter = Cast.toUint64(spent);
        e.spentInWindow = spentAfter;
        // Never moves backwards.
        e.windowStartedAt = nowTs > e.windowStartedAt ? nowTs : e.windowStartedAt;
        e.totalRedeemed += v.amount;
        totalEscrowed -= v.amount;
        uint64 delegateSpentAfter;
        if (delegate != address(0)) {
            delegateSpentAfter = Cast.toUint64(delegateSpent);
            d.spentInWindow = delegateSpentAfter;
            d.windowStartedAt = nowTs > d.windowStartedAt ? nowTs : d.windowStartedAt;
        }

        // Into hold; `fee` is computed here only for the event.
        HeldPayment storage h = heldPayments[v.payer][v.seq];
        h.provider = v.provider;
        h.amount = v.amount;
        h.takeRateBps = p.takeRateBps;
        h.status = HeldStatus.Held;
        h.collectableAt = collectableAt;
        totalHeld += v.amount;
        (uint64 fee,) = Fee.splitFee(v.amount, p.takeRateBps);

        emit PaymentHeld(v.payer, v.seq, v.provider, v.amount, collectableAt);
        emit VoucherRedeemed(
            v.payer,
            v.provider,
            v.requestHash,
            v.resourceHash,
            v.amount,
            fee,
            v.seq,
            p.takeRateBps,
            spentAfter
        );
        if (delegate != address(0)) {
            emit DelegateVoucherRedeemed(v.payer, delegate, v.seq, v.amount, delegateSpentAfter);
        }
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
        _assertBatch(payers.length, seqs.length);
        ParamSet memory p = _params();
        for (uint256 i = 0; i < payers.length; ++i) {
            _collectHeld(payers[i], seqs[i], p);
        }
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

    /// @dev Batch shape: non-empty, at most `MAX_REDEEM_BATCH`, equal array lengths.
    function _assertBatch(uint256 n, uint256 m) internal pure {
        if (n == 0) revert EmptyBatch();
        if (n > Constants.MAX_REDEEM_BATCH) revert BatchTooLarge();
        if (m != n) revert BatchLengthMismatch();
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

    /// @dev Returns `address(0)` if `payer` signed, or the signer if it is a delegate that can
    ///      sign now (a revoked one during its grace). Otherwise reverts with `DelegateIsRevoked`,
    ///      `DelegateIsExpired` or `SignerIsNotPayer`. Strict recovery; no EIP-1271.
    function _voucherAuthority(address payer, bytes32 digest, bytes calldata sig, uint64 nowTs)
        internal
        view
        returns (address)
    {
        address signer = Sig.recover(digest, sig);
        if (signer == payer) return address(0);

        Delegation storage d = delegations[payer][signer];
        if (d.validUntil != 0) {
            if (!_canSign(d, priorDelegateCaps[payer][signer], nowTs)) {
                if (d.revoked) revert DelegateIsRevoked();
                revert DelegateIsExpired();
            }
            return signer;
        }
        revert SignerIsNotPayer();
    }

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

    /// @notice Upper bound of the caps redemption applies now: the escrow's and `delegate`'s
    ///         (zero if it cannot sign now).
    /// @dev Necessary, not sufficient: a voucher must also fit one pair (current or held)
    ///      whole. The current caps are in `escrowOf` and `delegationOf`.
    /// @param payer The payer.
    /// @param delegate The delegate, or zero.
    /// @return maxVoucherAmount Escrow per-voucher cap.
    /// @return maxPerWindow Escrow per-window cap.
    /// @return delegateMaxVoucherAmount Delegate per-voucher cap.
    /// @return delegateMaxPerWindow Delegate per-window cap.
    function effectiveCapsOf(address payer, address delegate)
        external
        view
        returns (
            uint64 maxVoucherAmount,
            uint64 maxPerWindow,
            uint64 delegateMaxVoucherAmount,
            uint64 delegateMaxPerWindow
        )
    {
        uint64 nowTs = Cast.toUint64(block.timestamp);
        Escrow storage e = escrows[payer];
        (maxVoucherAmount, maxPerWindow) =
            _effectiveCaps(e.maxVoucherAmount, e.maxPerWindow, priorEscrowCaps[payer], nowTs);
        Delegation storage d = delegations[payer][delegate];
        PriorCaps storage prior = priorDelegateCaps[payer][delegate];
        if (d.validUntil != 0 && _canSign(d, prior, nowTs)) {
            (delegateMaxVoucherAmount, delegateMaxPerWindow) =
                _effectiveCaps(d.maxVoucherAmount, d.maxPerWindow, prior, nowTs);
        }
    }

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

    /// @dev For a voucher the current caps refused: 0 if the running held pair allows it whole,
    ///      1 if no pair allows its amount, 2 if one does but not its window total.
    function _heldRefusal(
        PriorCaps storage p,
        uint256 amount,
        uint256 spent,
        uint64 curV,
        uint64 nowTs
    ) internal view returns (uint256) {
        if (nowTs <= p.until && amount <= p.maxVoucherAmount) {
            return spent <= p.maxPerWindow ? 0 : 2;
        }
        return amount > curV ? 1 : 2;
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

    /// @notice Relayed `authorizeDelegate`, authorised by the payer's EIP-712 signature.
    /// @param payer The payer granting the delegate.
    /// @param delegate The delegate key.
    /// @param maxVoucherAmount Maximum amount per voucher, in base units.
    /// @param maxPerWindow Maximum total per rolling window, in base units.
    /// @param validUntil Expiry; at least `now + TIGHTEN_DELAY`.
    /// @param nonce The payer's current `authNonce`.
    /// @param deadline Last valid timestamp of the signature.
    /// @param sig The payer's signature.
    function authorizeDelegateBySig(
        address payer,
        address delegate,
        uint64 maxVoucherAmount,
        uint64 maxPerWindow,
        uint64 validUntil,
        uint64 nonce,
        uint64 deadline,
        bytes calldata sig
    ) external nonReentrant {
        _assertActive(payer, delegate, address(0));
        _consumeAuth(
            payer,
            Voucher712.hashAuthorizeDelegate(
                payer, delegate, maxVoucherAmount, maxPerWindow, validUntil, nonce, deadline
            ),
            nonce,
            deadline,
            sig
        );
        _authorizeDelegate(payer, delegate, maxVoucherAmount, maxPerWindow, validUntil);
    }

    /// @notice Revokes `delegate`. Vouchers it already signed stay redeemable for
    ///         `TIGHTEN_DELAY`, never past `validUntil`.
    /// @dev Consumes `authNonce`. Never pause- or blocklist-gated.
    /// @param delegate The delegate to revoke.
    function revokeDelegate(address delegate) external nonReentrant {
        _bumpAuthNonce(msg.sender);
        _revokeDelegate(msg.sender, delegate);
    }

    /// @notice Relayed `revokeDelegate`, authorised by the payer's EIP-712 signature. Never
    ///         pause- or blocklist-gated.
    /// @param payer The payer revoking the delegate.
    /// @param delegate The delegate to revoke.
    /// @param nonce The payer's current `authNonce`.
    /// @param deadline Last valid timestamp of the signature.
    /// @param sig The payer's signature.
    function revokeDelegateBySig(
        address payer,
        address delegate,
        uint64 nonce,
        uint64 deadline,
        bytes calldata sig
    ) external nonReentrant {
        _consumeAuth(
            payer,
            Voucher712.hashRevokeDelegate(payer, delegate, nonce, deadline),
            nonce,
            deadline,
            sig
        );
        _revokeDelegate(payer, delegate);
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

    /// @dev Reserved storage: a new field goes above and shrinks this by the slots it uses.
    uint256[45] private __gap;
}
