// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.38;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Ownable2StepUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";

import {ParamSet} from "./Types.sol";
import {Constants} from "./Constants.sol";
import {IAssayConfig} from "./interfaces/IAssayConfig.sol";
import "./Errors.sol";

/// @title AssayConfig
/// @notice Protocol parameters, roles, pause flag, verifier registry, address blocklist, slash
/// delay and collect hold, read by AssayEscrow and AssayStake.
/// @dev Never holds a token and nothing here can move one. Behind an ERC1967 proxy (UUPS).
/// Owner (Ownable2Step, never renounceable): upgrades all three contracts and appoints the
/// admin. Admin: bounded parameters, pause, verifiers, arbiter, slash delay, collect hold,
/// blocklist. Arbiter: rules on disputed slashes, may block but never unblock.
/// Admin, arbiter, redeemer and live verifiers are always distinct keys.
contract AssayConfig is Initializable, UUPSUpgradeable, Ownable2StepUpgradeable, IAssayConfig {
    /// @notice The operational admin; not the upgrade authority.
    address public admin;

    /// @inheritdoc IAssayConfig
    bool public override paused;

    /// @dev Stored as one struct so `params` always returns a consistent set.
    ParamSet internal _params;

    /// @notice Emitted once by `initialize`.
    event ConfigInitialized(address indexed admin, ParamSet params);

    /// @notice Emitted when the admin sets the pause flag.
    event PauseToggled(address indexed admin, bool paused, uint64 at);

    /// @notice Emitted when the admin replaces the parameter set.
    event ConfigUpdated(address indexed admin, ParamSet params);

    /// @notice Emitted when the owner replaces the admin.
    event AdminSet(address indexed previousAdmin, address indexed newAdmin);

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    /// @dev Locks the implementation so it can never be initialised directly.
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialises the proxy once with validated parameters, the admin and the owner.
    /// @param initialParams The parameter set, validated as a whole.
    /// @param initialAdmin The operational admin; must be non-zero.
    /// @param initialOwner The upgrade authority; must be non-zero.
    /// @dev Later upgrades that need an initialiser use `reinitializer(2)`, `(3)`, and so on.
    function initialize(ParamSet memory initialParams, address initialAdmin, address initialOwner)
        external
        initializer
    {
        if (initialAdmin == address(0)) revert InvalidAdmin();
        __Ownable_init(initialOwner);
        _validate(initialParams);
        admin = initialAdmin;
        _params = initialParams;
        emit ConfigInitialized(initialAdmin, initialParams);
    }

    /// @dev Upgrade authority is the owner; immediate, no timelock.
    function _authorizeUpgrade(address) internal override onlyOwner {}

    /// @inheritdoc IAssayConfig
    function owner() public view override(OwnableUpgradeable, IAssayConfig) returns (address) {
        return super.owner();
    }

    /// @notice Always reverts: ownership can never be renounced.
    function renounceOwnership() public pure override {
        revert OwnershipCannotBeRenounced();
    }

    /// @notice Appoints or replaces the admin. Owner only.
    /// @param newAdmin The new admin; non-zero and not holding another role.
    function setAdmin(address newAdmin) external onlyOwner {
        if (newAdmin == address(0)) revert InvalidAdmin();
        emit AdminSet(admin, newAdmin);
        admin = newAdmin;
        _assertRolesDistinct();
    }

    /// @dev Reverts unless the admin is not a live verifier and the arbiter (once appointed) is
    /// neither the admin, the redeemer nor a live verifier. Called last by every role writer.
    function _assertRolesDistinct() internal view {
        VerifierKey storage a = verifiers[admin];
        if (a.registered && !a.revoked) revert InvalidAdmin();
        address arb = arbiter;
        if (arb == address(0)) return; // before the first appointment
        VerifierKey storage k = verifiers[arb];
        if (arb == admin || arb == _params.redeemer || (k.registered && !k.revoked)) {
            revert InvalidArbiter();
        }
    }

    /// @inheritdoc IAssayConfig
    function params() external view override returns (ParamSet memory) {
        return _params;
    }

    /// @notice Sets the pause flag. Admin only.
    /// @param value True to pause, false to unpause.
    function setPaused(bool value) external onlyAdmin {
        paused = value;
        emit PauseToggled(msg.sender, value, uint64(block.timestamp));
    }

    /// @notice Replaces the whole parameter set. Admin only; takes effect immediately.
    /// @param p The new parameter set, validated as a whole.
    /// @dev A new `unbondingPeriodSeconds` also applies to unbondings already in flight.
    function updateConfig(ParamSet calldata p) external onlyAdmin {
        ParamSet memory q = p;
        _validate(q);
        _params = q;
        _assertRolesDistinct();
        emit ConfigUpdated(admin, q);
    }

    /// @dev Reverts unless every parameter is within its bound. `penaltyAmount` may be 0
    /// (shadow mode); otherwise a provider at `minimumStake` must fit two maximal penalties
    /// under its slash cap.
    function _validate(ParamSet memory p) internal pure {
        if (p.treasury == address(0)) revert MissingBeneficiary();
        if (p.redeemer == address(0)) revert MissingRedeemer();
        if (p.takeRateBps > Constants.MAX_TAKE_RATE_BPS) revert InvalidTakeRateBps();
        // Widened so the sum cannot overflow and panic instead of reverting with the name.
        if (p.slashAgentBps == 0 || uint32(p.slashAgentBps) + p.slashPlatformBps > 10_000) {
            revert InvalidSplitBps();
        }
        if (p.slashCapBps == 0 || p.slashCapBps > Constants.MAX_SLASH_CAP_BPS) {
            revert InvalidSlashCapBps();
        }
        if (p.unbondingPeriodSeconds < Constants.MIN_UNBONDING_PERIOD_SECONDS) {
            revert UnbondingPeriodTooShort();
        }
        if (p.unbondingPeriodSeconds > Constants.MAX_UNBONDING_PERIOD_SECONDS) {
            revert UnbondingPeriodTooLong();
        }
        if (p.minimumStake == 0) revert InvalidMinimumStake();
        if (
            uint256(p.minimumStake) * p.slashCapBps / Constants.BPS_DENOMINATOR
                < 2 * uint256(p.penaltyAmount)
        ) {
            revert InvalidMinimumStake();
        }
        // Not read on chain; kept in `ParamSet` for ABI and layout stability. Zero is refused.
        if (p.verifierDailyCap == 0) revert InvalidVerifierDailyCap();
    }

    // --- verifier registry -------------------------------------------------------------------

    /// @dev One storage slot per key. Registration is one-shot and revocation is permanent.
    struct VerifierKey {
        /// Registration timestamp; informational only.
        uint64 registeredAt;
        /// Last timestamp (inclusive) at which the key may sign.
        uint64 expiresAt;
        /// Revocation timestamp; evidence only, `revoked` is the predicate.
        uint64 revokedAt;
        /// Set on registration and never cleared, so an address can be enrolled only once.
        bool registered;
        /// Set by `revokeVerifier` and never cleared.
        bool revoked;
    }

    /// @dev Entries are never deleted, so a revoked key can never be re-enrolled.
    mapping(address => VerifierKey) internal verifiers;

    /// @notice Emitted when the admin enrols a verifier key. `label` exists only in this event.
    event VerifierRegistered(
        address indexed verifier,
        address indexed admin,
        bytes32 label,
        uint64 registeredAt,
        uint64 expiresAt
    );

    /// @notice Emitted when the admin revokes a verifier key.
    event VerifierRevokedEvent(address indexed verifier, address indexed admin, uint64 revokedAt);

    /// @notice Enrols a verifier key that may sign slash attestations at once. Admin only.
    /// @param verifier The key's address; non-zero and never enrolled before.
    /// @param label Free-form label, emitted only.
    /// @param expiresAt Expiry, in the future and within `MAX_VERIFIER_KEY_LIFETIME_SECONDS`.
    /// @dev Not pause-gated. Rotation always uses a new address.
    function registerVerifier(address verifier, bytes32 label, uint64 expiresAt)
        external
        onlyAdmin
    {
        if (verifier == address(0)) revert ZeroAddress();
        if (verifiers[verifier].registered) revert VerifierAlreadyRegistered();

        uint64 nowTs = uint64(block.timestamp);
        // Ceiling computed in uint256 so a clock near the end of uint64 cannot panic.
        if (
            expiresAt <= nowTs
                || uint256(expiresAt) > uint256(nowTs) + Constants.MAX_VERIFIER_KEY_LIFETIME_SECONDS
        ) revert InvalidVerifierExpiry();

        verifiers[verifier] = VerifierKey({
            registeredAt: nowTs,
            expiresAt: expiresAt,
            revokedAt: 0,
            registered: true,
            revoked: false
        });
        _assertRolesDistinct();
        emit VerifierRegistered(verifier, msg.sender, label, nowTs, expiresAt);
    }

    /// @notice Permanently revokes a verifier key. Admin only; immediate and irreversible.
    /// @param verifier The key to revoke; must be registered and not yet revoked.
    /// @dev `executeSlash` re-checks the key, so this voids every unexecuted slash it signed.
    function revokeVerifier(address verifier) external onlyAdmin {
        VerifierKey storage k = verifiers[verifier];
        if (!k.registered) revert VerifierNotRegistered();
        if (k.revoked) revert VerifierAlreadyRevoked();
        k.revoked = true;
        k.revokedAt = uint64(block.timestamp);
        // `registeredAt` and `expiresAt` are kept as the audit trail.
        emit VerifierRevokedEvent(verifier, msg.sender, k.revokedAt);
    }

    /// @notice Returns the full registry entry of a verifier key.
    /// @param verifier The key's address.
    /// @return The stored entry; all zero if never registered.
    function verifierKey(address verifier) external view returns (VerifierKey memory) {
        return verifiers[verifier];
    }

    /// @inheritdoc IAssayConfig
    function canSign(address verifier) public view override returns (bool) {
        VerifierKey storage k = verifiers[verifier];
        return k.registered && !k.revoked && block.timestamp <= k.expiresAt;
    }

    /// @inheritdoc IAssayConfig
    function assertCanSign(address verifier) external view override {
        VerifierKey storage k = verifiers[verifier];
        if (!k.registered) revert VerifierNotRegistered();
        if (k.revoked) revert VerifierRevoked();
        if (block.timestamp > k.expiresAt) revert VerifierKeyExpired();
    }

    // --- dispute: arbiter, slash delay, blocklist --------------------------------------------

    /// @inheritdoc IAssayConfig
    address public override arbiter;

    /// @dev Admin-set slash delay in seconds; 0 means unset (use the default).
    uint64 internal _slashDelaySeconds;

    /// @dev Blocklist of door subjects (buyer, payer, payee, provider, delegate, funder), never
    /// operators or verifiers; a verifier is stopped only by `revokeVerifier`.
    mapping(address => bool) internal _blocked;

    /// @notice Emitted when the admin appoints or replaces the arbiter.
    event ArbiterSet(address indexed previousArbiter, address indexed newArbiter);
    /// @notice Emitted when the admin changes the slash delay.
    event SlashDelaySet(uint64 previousDelay, uint64 newDelay);
    /// @notice Emitted when an address is blocked or unblocked.
    event BlockedSet(address indexed account, bool blocked, address indexed by);

    /// @notice Appoints or replaces the arbiter. Admin only.
    /// @param newArbiter Non-zero; not the admin, the redeemer or a live verifier.
    function setArbiter(address newArbiter) external onlyAdmin {
        if (newArbiter == address(0)) revert InvalidArbiter();
        emit ArbiterSet(arbiter, newArbiter);
        arbiter = newArbiter;
        _assertRolesDistinct();
    }

    /// @inheritdoc IAssayConfig
    function slashDelaySeconds() public view override returns (uint64) {
        uint64 d = _slashDelaySeconds;
        if (d == 0) return Constants.SLASH_DELAY_SECONDS;
        uint64 floor = minSlashDelaySeconds();
        return d < floor ? floor : d;
    }

    /// @inheritdoc IAssayConfig
    function minSlashDelaySeconds() public view override returns (uint64) {
        return block.chainid == Constants.ROBINHOOD_TESTNET_CHAIN_ID
            || block.chainid == Constants.LOCAL_CHAIN_ID
            ? Constants.MIN_SLASH_DELAY_SECONDS_TESTNET
            : Constants.MIN_SLASH_DELAY_SECONDS;
    }

    /// @notice Sets the slash delay for new proposals. Admin only.
    /// @param newDelay Seconds, within `[minSlashDelaySeconds, MAX_SLASH_DELAY_SECONDS]`.
    function setSlashDelay(uint64 newDelay) external onlyAdmin {
        if (newDelay < minSlashDelaySeconds() || newDelay > Constants.MAX_SLASH_DELAY_SECONDS) {
            revert InvalidSlashDelay();
        }
        emit SlashDelaySet(slashDelaySeconds(), newDelay);
        _slashDelaySeconds = newDelay;
    }

    /// @inheritdoc IAssayConfig
    function blocked(address account) external view override returns (bool) {
        return _blocked[account];
    }

    /// @notice Blocks or unblocks an address. Admin may do both; the arbiter may only block.
    /// @param account The address; non-zero.
    /// @param value True to block, false to unblock.
    function setBlocked(address account, bool value) external {
        if (msg.sender != admin) {
            if (msg.sender != arbiter) revert NotAdmin();
            if (!value) revert ArbiterCannotUnblock();
        }
        if (account == address(0)) revert ZeroAddress();
        _blocked[account] = value;
        emit BlockedSet(account, value, msg.sender);
    }

    /// @inheritdoc IAssayConfig
    function assertActive(address a, address b, address c) external view override {
        if (paused) revert ProgramPaused();
        if (_blocked[a] || _blocked[b] || _blocked[c]) revert AddressBlocked();
    }

    // --- collect hold ------------------------------------------------------------------------

    /// @dev Admin-set collect hold in seconds; 0 means unset (use the default).
    uint64 internal _collectHoldSeconds;

    /// @notice Emitted when the admin changes the collect hold.
    event CollectHoldSet(uint64 previous, uint64 next);

    /// @inheritdoc IAssayConfig
    function collectHoldSeconds() public view override returns (uint64) {
        uint64 h = _collectHoldSeconds;
        return h == 0 ? Constants.DEFAULT_COLLECT_HOLD_SECONDS : h;
    }

    /// @notice Sets the collect hold for new redemptions. Admin only.
    /// @param newHold Seconds, within `[MIN_COLLECT_HOLD_SECONDS, MAX_COLLECT_HOLD_SECONDS]`.
    function setCollectHold(uint64 newHold) external onlyAdmin {
        if (
            newHold < Constants.MIN_COLLECT_HOLD_SECONDS
                || newHold > Constants.MAX_COLLECT_HOLD_SECONDS
        ) revert InvalidCollectHold();
        emit CollectHoldSet(collectHoldSeconds(), newHold);
        _collectHoldSeconds = newHold;
    }

    /// @dev Reserved slots for future storage; shrink by the slots any new field takes.
    uint256[46] private __gap;
}
