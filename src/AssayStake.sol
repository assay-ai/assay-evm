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
import {Attestation712} from "./libraries/Attestation712.sol";
import {Cast} from "./libraries/Cast.sol";
import {Fee} from "./libraries/Fee.sol";
import {Sig} from "./libraries/Sig.sol";
import {Window} from "./libraries/Window.sol";
import {Constants} from "./Constants.sol";
import {CancelReason, ParamSet, ResponseClass, SlashAttestation, SlashStatus} from "./Types.sol";
import "./Errors.sol";

/// @title AssayStake
/// @notice Provider collateral and the two-phase slash: a verifier-signed judgement is proposed,
/// waits out a dispute delay, then executes, is cancelled, or expires.
/// @dev Holds no buyer money and no reference to AssayEscrow. Behind an ERC1967 proxy (UUPS);
/// the upgrade authority is the AssayConfig owner. The proxy is the EIP-712 verifying contract.
/// Pause and blocklist close deposits and exits; dispute, cancel, expire and uphold stay open.
/// Nothing can seize or sweep a provider's stake.
contract AssayStake is Initializable, UUPSUpgradeable, IAssayStakeView, EIP712, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice A provider's collateral. Four storage slots; amounts in asset base units.
    struct ProviderStake {
        uint128 bonded; // slot 0
        uint64 unbonding;
        uint64 unbondingStartedAt; // start of the single unbonding clock
        uint64 slashedInWindow; // slot 1, rolling per-provider slash meter
        uint64 slashWindowStartedAt;
        uint64 pendingSlash; // sum of standing slash reservations
        uint64 __gap; // padding
        uint128 totalDeposited; // slot 2
        uint128 totalWithdrawn;
        uint128 totalSlashed; // slot 3
    }

    /// @dev Retired and unused; kept only so the storage layout stays append-only.
    struct VerifierWindow {
        uint64 slashedInWindow;
        uint64 windowStartedAt;
    }

    /// @notice The AssayConfig proxy; set once in `initialize`.
    IAssayConfig public CONFIG;
    /// @notice The 6-decimal settlement asset; set once in `initialize`.
    IERC20 public ASSET;

    mapping(address => ProviderStake) internal stakes;
    /// @dev Retired and unused; kept for the storage layout only.
    mapping(address => VerifierWindow) internal verifierWindows;

    /// @dev Invariant: `totalStaked == totalDeposited - totalWithdrawn - totalSlashed`.
    uint128 public totalStaked;
    uint128 public totalDeposited;
    uint128 public totalWithdrawn;
    uint128 public totalSlashed;

    /// @notice Emitted when stake is deposited for a provider.
    event StakeDeposited(
        address indexed provider, address indexed funder, uint64 amount, uint128 bonded
    );
    /// @notice Emitted when a provider moves bonded stake into unbonding.
    event UnstakeRequested(
        address indexed provider, uint64 amount, uint128 bonded, uint64 unbonding, uint64 endsAt
    );
    /// @notice Emitted when a provider withdraws matured unbonding stake.
    event StakeWithdrawn(address indexed provider, uint64 amount, uint128 bonded, uint64 unbonding);

    /// @dev The EIP-712 name and version are fixed here; changing them moves the attestation
    /// domain. Locks the implementation against direct initialisation.
    constructor() EIP712("Assay Settlement", "2") {
        _disableInitializers();
    }

    /// @notice Initialises the proxy once.
    /// @param config The AssayConfig proxy.
    /// @param asset The settlement asset; must have 6 decimals.
    function initialize(IAssayConfig config, IERC20 asset) external initializer {
        if (address(config) == address(0) || address(asset) == address(0)) revert ZeroAddress();
        if (IERC20Decimals(address(asset)).decimals() != 6) revert AssetDecimalsNotSix();
        CONFIG = config;
        ASSET = asset;
    }

    /// @dev Only the AssayConfig owner, read live, may upgrade; no timelock.
    function _authorizeUpgrade(address) internal view override {
        if (msg.sender != CONFIG.owner()) revert NotOwner();
    }

    // --- views -------------------------------------------------------------------------------

    // Each external read below is routed through one internal call site to save bytecode.

    function _params() internal view returns (ParamSet memory) {
        return CONFIG.params();
    }

    /// @dev Pause and blocklist check for every user door.
    function _assertActive(address a, address b, address c) internal view {
        CONFIG.assertActive(a, b, c);
    }

    function _paused() internal view returns (bool) {
        return CONFIG.paused();
    }

    function _assertCanSign(address verifier) internal view {
        CONFIG.assertCanSign(verifier);
    }

    function _assetBalance() internal view returns (uint256) {
        return ASSET.balanceOf(address(this));
    }

    /// @notice Returns a provider's full stake record.
    /// @param provider The provider.
    /// @return The stored record.
    function stakeOf(address provider) external view returns (ProviderStake memory) {
        return stakes[provider];
    }

    /// @notice Returns a provider's bonded stake, saturated at `type(uint64).max`.
    /// @param provider The provider.
    /// @return The bonded amount in base units.
    function bondedOf(address provider) external view returns (uint64) {
        uint128 b = stakes[provider].bonded;
        return b > type(uint64).max ? type(uint64).max : Cast.toUint64(b);
    }

    /// @inheritdoc IAssayStakeView
    /// @dev Charges all of `pendingSlash` to `bonded`, the conservative reading.
    function freeBondedOf(address provider) external view override returns (uint64) {
        ProviderStake storage s = stakes[provider];
        uint128 b = s.bonded;
        uint128 pending = s.pendingSlash;
        uint128 free = b > pending ? b - pending : 0;
        return free > type(uint64).max ? type(uint64).max : Cast.toUint64(free);
    }

    /// @notice Returns the EIP-712 domain separator for slash attestations.
    /// @return The domain separator of this proxy.
    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /// @dev Bonded plus unbonding: unbonding stake stays slashable until withdrawn.
    function _atRisk(ProviderStake storage s) internal view returns (uint128) {
        return s.bonded + s.unbonding;
    }

    /// @notice Returns how much a provider may withdraw now.
    /// @param provider The provider.
    /// @return `min(matured unbonding, atRisk - pendingSlash)`, or 0 before maturity.
    /// @dev Checked subtraction: `pendingSlash <= atRisk` always holds, so a break reverts.
    function withdrawableOf(address provider) public view returns (uint64) {
        ProviderStake storage s = stakes[provider];
        uint64 period = _params().unbondingPeriodSeconds;
        if (s.unbonding == 0) return 0;
        if (block.timestamp < uint256(s.unbondingStartedAt) + period) return 0;
        uint128 free = _atRisk(s) - s.pendingSlash;
        uint128 capped = s.unbonding < free ? s.unbonding : free;
        return Cast.toUint64(capped); // <= s.unbonding, which is uint64
    }

    // --- collateral in -----------------------------------------------------------------------

    /// @notice Deposits stake for the caller.
    /// @param amount Amount in base units.
    function depositStake(uint64 amount) external {
        depositStakeFor(msg.sender, amount);
    }

    /// @notice Deposits stake for any provider; anyone may fund anyone.
    /// @param provider The provider credited.
    /// @param amount Amount in base units; the received balance must equal it exactly.
    /// @dev Pause- and blocklist-gated on provider and funder. The exact balance-delta check also
    /// rejects fee-on-transfer and re-entrant tokens.
    function depositStakeFor(address provider, uint64 amount) public nonReentrant {
        _assertActive(provider, msg.sender, address(0));
        if (provider == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        uint256 before = _assetBalance();
        ASSET.safeTransferFrom(msg.sender, address(this), amount);
        if (_assetBalance() - before != amount) revert TransferAmountMismatch();

        ProviderStake storage s = stakes[provider];
        s.bonded += amount;
        s.totalDeposited += amount;
        totalStaked += amount;
        totalDeposited += amount;

        emit StakeDeposited(provider, msg.sender, amount, s.bonded);
    }

    // --- collateral out ----------------------------------------------------------------------

    /// @notice Moves bonded stake into unbonding and restarts the unbonding clock.
    /// @param amount Amount in base units; at most the caller's bonded stake.
    /// @dev Pause- and blocklist-gated. Unbonding stake remains slashable.
    function requestUnstake(uint64 amount) external nonReentrant {
        _assertActive(msg.sender, address(0), address(0));
        if (amount == 0) revert ZeroAmount();
        ProviderStake storage s = stakes[msg.sender];
        if (amount > s.bonded) revert InsufficientBondedStake();

        s.bonded -= amount;
        s.unbonding += amount;
        s.unbondingStartedAt = uint64(block.timestamp);

        emit UnstakeRequested(
            msg.sender,
            amount,
            s.bonded,
            s.unbonding,
            uint64(block.timestamp) + _params().unbondingPeriodSeconds
        );
    }

    /// @notice Withdraws matured unbonding stake to the caller.
    /// @param amount Amount in base units; at most `withdrawableOf` the caller.
    /// @dev Pays only `msg.sender`. Pause- and blocklist-gated. Effects precede the transfer
    /// (CEI); `pendingSlash` stays covered, so an exit cannot outrun a pending judgement.
    function withdrawStake(uint64 amount) external nonReentrant {
        _assertActive(msg.sender, address(0), address(0));
        if (amount == 0) revert ZeroAmount();
        ProviderStake storage s = stakes[msg.sender];

        if (amount > s.unbonding) revert InsufficientUnbondingStake();
        uint64 period = _params().unbondingPeriodSeconds;
        if (block.timestamp < uint256(s.unbondingStartedAt) + period) {
            revert UnbondingPeriodNotElapsed();
        }
        if (amount > withdrawableOf(msg.sender)) revert InsufficientUnbondingStake();

        s.unbonding -= amount;
        s.totalWithdrawn += amount;
        if (s.unbonding == 0) s.unbondingStartedAt = 0;
        totalStaked -= amount;
        totalWithdrawn += amount;

        ASSET.safeTransfer(msg.sender, amount);
        emit StakeWithdrawn(msg.sender, amount, s.bonded, s.unbonding);
    }

    // --- two-phase slash: propose ------------------------------------------------------------

    /// @notice A slash judgement, keyed by request id. Six storage slots.
    /// @dev Never deleted: a cleared record would let the same attestation be replayed.
    struct SlashRecord {
        address provider; // slot 0
        SlashStatus status;
        uint64 penalty; // signed penalty
        address beneficiary; // slot 1
        uint64 proposedAt;
        uint32 __gap; // padding
        address verifier; // slot 2, recovered signer
        uint64 executableAt; // frozen at proposal
        uint32 __gap2; // padding
        uint64 reserved; // slot 3, stake held for this record
        uint64 capAllowance; // frozen at proposal
        uint64 applied;
        uint64 executedAt;
        bytes32 policy; // slot 4
        uint64 disputedAt; // slot 5, 0 until disputed
    }

    mapping(bytes32 => SlashRecord) internal slashRecords;

    /// @notice Emitted when a slash is proposed and stake is reserved.
    event SlashProposed(
        bytes32 indexed requestId,
        address indexed provider,
        address indexed verifier,
        address beneficiary,
        bytes32 policy,
        uint64 penalty,
        uint64 reserved,
        uint64 capAllowance,
        uint64 pendingSlash,
        uint64 proposedAt,
        uint64 executableAt
    );

    /// @notice Returns a slash record.
    /// @param requestId The attestation's request id.
    /// @return The stored record; status `None` if never proposed.
    function slashRecordOf(bytes32 requestId) external view returns (SlashRecord memory) {
        return slashRecords[requestId];
    }

    /// @notice Proposes a slash from a verifier-signed attestation and reserves the stake. Moves
    /// no money. Permissionless: the authority is the signature.
    /// @param a The attestation.
    /// @param sig The verifier's EIP-712 signature over `a`.
    /// @dev Each request id can be proposed once. `executableAt` and `capAllowance` are frozen
    /// here. The reservation is all or nothing against the provider's unreserved stake.
    function proposeSlash(SlashAttestation calldata a, bytes calldata sig) external nonReentrant {
        if (_paused()) revert ProgramPaused();
        if (a.penalty == 0) revert ZeroAmount();
        if (a.beneficiary == address(0) || a.beneficiary == address(this)) {
            revert MissingBeneficiary();
        }
        // Only DataFail slashes; the class is signed, so it cannot be relabelled.
        if (a.status != uint8(ResponseClass.DataFail)) revert StatusDoesNotSlash();
        if (slashRecords[a.requestId].status != SlashStatus.None) revert SlashAlreadyExists();

        uint64 nowTs = uint64(block.timestamp);
        if (
            a.expiresAt <= a.issuedAt
                || a.expiresAt - a.issuedAt > Constants.MAX_ATTESTATION_LIFETIME_SECONDS
        ) revert InvalidAttestationWindow();
        if (a.issuedAt > nowTs) revert AttestationNotYetValid();
        if (nowTs > a.expiresAt) revert AttestationExpired();

        address verifier = Sig.recover(_hashTypedDataV4(Attestation712.hashAttestation(a)), sig);
        _assertCanSign(verifier);

        ParamSet memory p = _params();
        // A ceiling, not an equality: a reduced penalty is legal.
        if (a.penalty > p.penaltyAmount) revert PenaltyExceedsMaximum();

        ProviderStake storage s = stakes[a.provider];
        uint128 atRisk = _atRisk(s);
        if (atRisk == 0) revert NothingToSlash();

        uint64 capAllowance =
            Cast.toUint64((uint256(atRisk) * p.slashCapBps) / Constants.BPS_DENOMINATOR);
        if (capAllowance == 0) revert SlashCapExceeded();

        // Checked: every writer preserves `pendingSlash <= atRisk`.
        uint128 free = atRisk - s.pendingSlash;
        uint64 reserved = a.penalty;
        if (reserved > capAllowance) reserved = capAllowance;
        // All or nothing: a reservation the free stake cannot cover is refused, not shortened.
        if (reserved > free) revert NothingToSlash();
        // Refuse a reservation the current split cannot divide; it could never execute.
        if (
            Fee.bpsOf(reserved, p.slashAgentBps) == 0
                || (p.slashPlatformBps != 0 && Fee.bpsOf(reserved, p.slashPlatformBps) == 0)
        ) revert PenaltyTooSmallToSplit();

        s.pendingSlash += reserved;

        SlashRecord storage rec = slashRecords[a.requestId];
        rec.provider = a.provider;
        rec.status = SlashStatus.Pending;
        rec.penalty = a.penalty;
        rec.beneficiary = a.beneficiary;
        rec.proposedAt = nowTs;
        rec.verifier = verifier;
        rec.executableAt = nowTs + CONFIG.slashDelaySeconds();
        rec.reserved = reserved;
        rec.capAllowance = capAllowance;
        rec.policy = a.policy;

        emit SlashProposed(
            a.requestId,
            a.provider,
            verifier,
            a.beneficiary,
            a.policy,
            a.penalty,
            reserved,
            capAllowance,
            s.pendingSlash,
            nowTs,
            rec.executableAt
        );
    }

    // --- two-phase slash: execute, cancel, expire --------------------------------------------

    /// @notice Emitted when a slash executes and pays out.
    event SlashExecuted(
        bytes32 indexed requestId,
        address indexed provider,
        address indexed verifier,
        address beneficiary,
        bytes32 policy,
        uint64 penalty,
        uint64 applied,
        uint64 agentAmount,
        uint64 platformAmount,
        uint64 providerAmount,
        uint16 slashAgentBps,
        uint16 slashPlatformBps,
        uint64 released,
        uint64 pendingSlash,
        uint128 bonded,
        uint64 unbonding,
        uint64 executedAt,
        uint64 proposedAt
    );

    /// @notice Emitted when a slash is cancelled or expires and its reservation is released.
    event SlashCancelled(
        bytes32 indexed requestId,
        address indexed provider,
        CancelReason reason,
        uint64 released,
        uint64 pendingSlash,
        uint64 cancelledAt
    );

    /// @notice Executes a pending slash after its delay and pays the agent and platform shares.
    /// Permissionless; every value comes from the record.
    /// @param requestId The record to execute.
    /// @dev Re-checks the verifier key, so a key revoked or expired during the delay can never
    /// pay. Pays the whole reservation or reverts. Effects precede transfers (CEI).
    function executeSlash(bytes32 requestId) external nonReentrant {
        if (_paused()) revert ProgramPaused();

        SlashRecord storage rec = slashRecords[requestId];
        if (rec.status != SlashStatus.Pending) revert SlashNotPending();

        uint64 nowTs = uint64(block.timestamp);
        if (nowTs < rec.executableAt) revert SlashNotYetExecutable();
        // From the deadline on, the record belongs to `expireSlash`: no overlap, no gap.
        if (nowTs >= _deadline(rec)) revert SlashExecutionWindowClosed();

        _assertCanSign(rec.verifier);

        ParamSet memory p = _params();
        ProviderStake storage s = stakes[rec.provider];

        // All or wait: pay the whole reservation only if it fits the provider's rolling window
        // under the frozen allowance; otherwise revert and retry later.
        uint64 providerCarried = Window.decay(s.slashedInWindow, s.slashWindowStartedAt, nowTs);
        uint64 applied = rec.reserved;
        if (uint256(providerCarried) + applied > rec.capAllowance) revert SlashWindowNotDrained();

        uint64 agentAmount = Fee.bpsOf(applied, p.slashAgentBps);
        uint64 platformAmount = Fee.bpsOf(applied, p.slashPlatformBps);
        uint64 taken = agentAmount + platformAmount;
        // The provider keeps the remainder; it is never transferred.
        uint64 providerAmount = applied - taken;
        if (taken == 0) revert PenaltyTooSmallToSplit();

        // --- effects ---------------------------------------------------------------------
        uint64 released = rec.reserved;
        s.pendingSlash -= released;

        // Unbonding stake is taken first.
        uint64 fromUnbonding = taken < s.unbonding ? taken : s.unbonding;
        uint64 fromBonded = taken - fromUnbonding;
        s.unbonding -= fromUnbonding;
        s.bonded -= fromBonded;
        if (s.unbonding == 0) s.unbondingStartedAt = 0;

        s.totalSlashed += taken;
        // The window meters `applied`, and its anchor never moves backwards.
        s.slashedInWindow = providerCarried + applied;
        s.slashWindowStartedAt = nowTs > s.slashWindowStartedAt ? nowTs : s.slashWindowStartedAt;

        totalStaked -= taken;
        totalSlashed += taken;

        rec.applied = applied;
        rec.executedAt = nowTs;
        rec.status = SlashStatus.Executed;

        // --- interactions ----------------------------------------------------------------
        if (agentAmount > 0) ASSET.safeTransfer(rec.beneficiary, agentAmount);
        if (platformAmount > 0) ASSET.safeTransfer(p.treasury, platformAmount);

        emit SlashExecuted(
            requestId,
            rec.provider,
            rec.verifier,
            rec.beneficiary,
            rec.policy,
            rec.penalty,
            applied,
            agentAmount,
            platformAmount,
            providerAmount,
            p.slashAgentBps,
            p.slashPlatformBps,
            released,
            s.pendingSlash,
            s.bonded,
            s.unbonding,
            nowTs,
            rec.proposedAt
        );
    }

    /// @notice Cancels a pending or disputed slash and releases its reservation. Admin or
    /// arbiter only; not pause-gated.
    /// @param requestId The record to cancel.
    function cancelSlash(bytes32 requestId) external nonReentrant {
        _assertCanCancel();
        _release(requestId, CancelReason.Withdrawn);
    }

    /// @notice Atomic batch of `cancelSlash`. Admin or arbiter only.
    /// @param requestIds The records to cancel.
    function cancelSlashBatch(bytes32[] calldata requestIds) external nonReentrant {
        _assertBatch(requestIds.length);
        _assertCanCancel();
        for (uint256 i = 0; i < requestIds.length; ++i) {
            _release(requestIds[i], CancelReason.Withdrawn);
        }
    }

    /// @dev Reverts unless the caller is the admin or the arbiter.
    function _assertCanCancel() internal view {
        if (msg.sender != CONFIG.admin() && msg.sender != CONFIG.arbiter()) revert NotAdmin();
    }

    /// @dev Batch size bounds. Batches are atomic: one bad or duplicate id reverts them all.
    function _assertBatch(uint256 n) internal pure {
        if (n == 0) revert EmptyBatch();
        if (n > Constants.MAX_SLASH_BATCH) revert BatchTooLarge();
    }

    /// @notice Releases a reservation nobody will act on. Permissionless; never paused.
    /// @param requestId The record to expire.
    /// @dev Allowed when the verifier key can no longer sign, or at the record's deadline
    /// (execution grace for `Pending`, dispute timeout for `Disputed`). Moves no tokens.
    function expireSlash(bytes32 requestId) external nonReentrant {
        SlashRecord storage rec = slashRecords[requestId];
        bool disputed = rec.status == SlashStatus.Disputed;
        if (rec.status != SlashStatus.Pending && !disputed) revert SlashNotPending();

        bool verifierUnavailable = !CONFIG.canSign(rec.verifier);
        if (!verifierUnavailable && block.timestamp < _deadline(rec)) revert SlashNotExpired();

        // The more specific reason wins when both hold.
        _release(
            requestId,
            verifierUnavailable
                ? CancelReason.VerifierUnavailable
                : disputed ? CancelReason.DisputeUnresolved : CancelReason.Expired
        );
    }

    // --- dispute -----------------------------------------------------------------------------

    /// @notice Emitted when a provider disputes a pending slash.
    event SlashDisputed(
        bytes32 indexed requestId, address indexed provider, uint64 disputedAt, uint64 executableAt
    );
    /// @notice Emitted when the arbiter upholds a disputed slash.
    event SlashUpheld(
        bytes32 indexed requestId,
        address indexed provider,
        address indexed arbiter,
        uint64 executableAt
    );

    /// @notice Disputes a pending slash before its `executableAt`, freezing it. Slashed provider
    /// only; once per record; never pause- or blocklist-gated.
    /// @param requestId The record to dispute.
    /// @dev The reservation stays, so a dispute cannot be used to outrun the slash.
    function disputeSlash(bytes32 requestId) external nonReentrant {
        _dispute(requestId);
    }

    /// @notice Atomic batch of `disputeSlash`.
    /// @param requestIds The records to dispute.
    function disputeSlashBatch(bytes32[] calldata requestIds) external nonReentrant {
        _assertBatch(requestIds.length);
        for (uint256 i = 0; i < requestIds.length; ++i) {
            _dispute(requestIds[i]);
        }
    }

    function _dispute(bytes32 requestId) internal {
        SlashRecord storage rec = slashRecords[requestId];
        if (rec.status != SlashStatus.Pending) revert SlashNotPending();
        if (msg.sender != rec.provider) revert NotSlashedProvider();
        if (rec.disputedAt != 0) revert SlashAlreadyDisputed();
        if (block.timestamp >= rec.executableAt) revert DisputeWindowClosed();

        uint64 nowTs = uint64(block.timestamp);
        rec.status = SlashStatus.Disputed;
        rec.disputedAt = nowTs;
        emit SlashDisputed(requestId, rec.provider, nowTs, rec.executableAt);
    }

    /// @notice Rules against the provider: returns a disputed slash to `Pending`, executable from
    /// `max(executableAt, now)`. Arbiter only; before the dispute timeout.
    /// @param requestId The record to uphold.
    /// @dev Moves no money; `executeSlash` still re-checks the verifier and the window. To rule
    /// for the provider the arbiter calls `cancelSlash`.
    function upholdSlash(bytes32 requestId) external nonReentrant {
        _uphold(requestId, _assertArbiter());
    }

    /// @notice Atomic batch of `upholdSlash`. Arbiter only.
    /// @param requestIds The records to uphold.
    function upholdSlashBatch(bytes32[] calldata requestIds) external nonReentrant {
        _assertBatch(requestIds.length);
        address arb = _assertArbiter();
        for (uint256 i = 0; i < requestIds.length; ++i) {
            _uphold(requestIds[i], arb);
        }
    }

    function _assertArbiter() internal view returns (address arb) {
        arb = CONFIG.arbiter();
        if (msg.sender != arb) revert NotArbiter();
    }

    function _uphold(bytes32 requestId, address arb) internal {
        SlashRecord storage rec = slashRecords[requestId];
        if (rec.status != SlashStatus.Disputed) revert SlashNotDisputed();
        if (block.timestamp >= _deadline(rec)) revert DisputeTimedOut();

        uint64 nowTs = uint64(block.timestamp);
        rec.status = SlashStatus.Pending;
        if (nowTs > rec.executableAt) rec.executableAt = nowTs;
        emit SlashUpheld(requestId, rec.provider, arb, rec.executableAt);
    }

    /// @dev The single deadline of an open record: `disputedAt + DISPUTE_TIMEOUT_SECONDS` when
    /// disputed, else `executableAt + SLASH_EXECUTION_GRACE_SECONDS`. uint256 to avoid overflow.
    function _deadline(SlashRecord storage rec) internal view returns (uint256) {
        return rec.status == SlashStatus.Disputed
            ? uint256(rec.disputedAt) + Constants.DISPUTE_TIMEOUT_SECONDS
            : uint256(rec.executableAt) + Constants.SLASH_EXECUTION_GRACE_SECONDS;
    }

    /// @dev Moves a `Pending` or `Disputed` record to `Cancelled` and releases its whole
    /// reservation (checked subtraction).
    function _release(bytes32 requestId, CancelReason reason) internal {
        SlashRecord storage rec = slashRecords[requestId];
        if (rec.status != SlashStatus.Pending && rec.status != SlashStatus.Disputed) {
            revert SlashNotPending();
        }

        ProviderStake storage s = stakes[rec.provider];
        uint64 released = rec.reserved;
        s.pendingSlash -= released;

        rec.status = SlashStatus.Cancelled;
        emit SlashCancelled(
            requestId, rec.provider, reason, released, s.pendingSlash, uint64(block.timestamp)
        );
    }

    /// @dev Reserved slots for future storage; shrink by the slots any new field takes.
    uint256[49] private __gap;
}
