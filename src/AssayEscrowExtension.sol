// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.38;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {AssayEscrowStorage} from "./AssayEscrowStorage.sol";
import {Voucher712} from "./libraries/Voucher712.sol";
import {Sig} from "./libraries/Sig.sol";
import {Window} from "./libraries/Window.sol";
import {Fee} from "./libraries/Fee.sol";
import {Cast} from "./libraries/Cast.sol";
import {Constants} from "./Constants.sol";
import {Voucher, ParamSet} from "./Types.sol";
import "./Errors.sol";

/// @dev Two reserved slots where `AssayEscrow` has OZ EIP712's `_nameFallback` and
///      `_versionFallback` (never written there: the name and version fit a ShortString). They
///      keep `ReentrancyGuard._status` and every escrow variable at the escrow's own slots.
abstract contract EscrowSlotsReserved {
    string private _nameFallback;
    string private _versionFallback;
}

/// @title AssayEscrowExtension
/// @notice The escrow's second half: the per-call voucher door, the relayed (BySig) payer
///         decisions and `effectiveCapsOf`. Reached only through the escrow proxy: the escrow
///         implementation's `fallback` DELEGATECALLs every selector it does not have here, so
///         this code runs in the proxy's storage, as the proxy's address, with the caller's
///         `msg.sender`.
/// @dev Created by the `AssayEscrow` constructor, so each implementation has exactly one
///      extension. Shares `AssayEscrowStorage` (and `ReentrancyGuard._status`) with the escrow,
///      so `nonReentrant` spans both. Holds no token and no initializer. Its only immutable is its
///      own address; it does NOT inherit EIP712 (whose immutables would let a deployer-built
///      extension carry another domain past a masked code comparison) and builds the escrow's
///      separator from the shared name and version and the proxy's address instead.
contract AssayEscrowExtension is EscrowSlotsReserved, ReentrancyGuard, AssayEscrowStorage {
    bytes32 private constant TYPE_HASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );
    bytes32 private constant HASHED_NAME = keccak256(bytes(EIP712_NAME));
    bytes32 private constant HASHED_VERSION = keccak256(bytes(EIP712_VERSION));

    /// @dev This contract's own address: a direct call (not through the proxy) is refused.
    address private immutable SELF;

    constructor() {
        SELF = address(this);
    }

    /// @dev Every door runs only by DELEGATECALL. A direct call would run against this
    ///      contract's own empty storage; refused anyway, with the OZ error the escrow already has.
    modifier onlyDelegated() {
        if (address(this) == SELF) revert UUPSUpgradeable.UUPSUnauthorizedCallContext();
        _;
    }

    /// @dev The escrow proxy's EIP-712 digest: what OZ EIP712 rebuilds when `address(this)` is
    ///      not the implementation, which under the proxy it never is.
    function _hashTypedDataV4(bytes32 structHash) internal view virtual returns (bytes32) {
        bytes32 ds = keccak256(
            abi.encode(TYPE_HASH, HASHED_NAME, HASHED_VERSION, block.chainid, address(this))
        );
        return MessageHashUtils.toTypedDataHash(ds, structHash);
    }

    // --- per-call voucher door ------------------------------------------------------------

    /// @notice Redeems a signed voucher into hold. Redeemer only.
    /// @dev The payer's (or its delegate's) signature is the whole authority over the money; the
    ///      redeemer only decides when. `params` is read once so every check uses one set.
    /// @param v The voucher.
    /// @param sig Signature by the payer or an authorised delegate.
    function redeemVoucher(Voucher calldata v, bytes calldata sig)
        external
        onlyDelegated
        nonReentrant
    {
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
        onlyDelegated
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

    // --- relayed payer decisions -------------------------------------------------------------

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
    ) external onlyDelegated nonReentrant {
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
    ) external onlyDelegated nonReentrant {
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
    ) external onlyDelegated nonReentrant {
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
    ) external onlyDelegated nonReentrant {
        _consumeAuth(
            payer,
            Voucher712.hashRevokeDelegate(payer, delegate, nonce, deadline),
            nonce,
            deadline,
            sig
        );
        _revokeDelegate(payer, delegate);
    }

    // --- views ---------------------------------------------------------------------------

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
        onlyDelegated
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
}
