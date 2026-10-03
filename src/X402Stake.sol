// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

import {IX402Config} from "./interfaces/IX402Config.sol";
import {IX402StakeView} from "./interfaces/IX402StakeView.sol";
import {IERC20Decimals} from "./interfaces/IERC20Decimals.sol";
import {Attestation712} from "./libraries/Attestation712.sol";
import {Cast} from "./libraries/Cast.sol";
import {Fee} from "./libraries/Fee.sol";
import {Sig} from "./libraries/Sig.sol";
import {Window} from "./libraries/Window.sol";
import {Constants} from "./Constants.sol";
import {CancelReason, ParamSet, ResponseClass, SlashAttestation, SlashStatus} from "./Types.sol";
import "./Errors.sol";

/// Provider collateral, and the two-phase slash. Holds no buyer money and holds no
/// reference to X402Escrow — the only edge between them points the other way and is a view.
///
/// Deployed behind an ERC1967Proxy and upgraded through UUPS (D-1), with the same single
/// authority: `CONFIG.admin()`, a Ledger, immediate, no timelock. The proxy address is the
/// verifier's EIP-712 `verifyingContract`, so an upgrade does not invalidate an attestation
/// that is already in flight.
///
/// **Pause closes nothing on this contract's deposit and exit half.** `deposit_stake.rs` has no
/// pause
/// check and neither does `depositStakeFor`: pausing a provider's own top-up would strand a
/// provider trying to cure an under-stake. `requestUnstake` and `withdrawStake` are owner exits,
/// and `withdraw_stake.rs:14-16` states the rule for them — "a pause that could hold a
/// provider's own capital would be worth more to whoever stole the admin key than the slashing
/// machinery it exists to halt".
contract X402Stake is Initializable, UUPSUpgradeable, IX402StakeView, EIP712, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// `state.rs:370`'s `ProviderStake`, minus the two Solana-only fields (`provider`, which is
    /// the mapping key here, and `bump`). Four slots, asserted by `script/check-layout.sh`.
    ///
    /// The widths follow `X402Escrow.Escrow`'s rule: cumulative counters are `uint128` (they are
    /// sums of many amounts and must not be able to wrap where an amount cannot), and everything
    /// an instruction takes as an argument or compares against a clock is `uint64`.
    struct ProviderStake {
        uint128 bonded; //           slot 0  state.rs:373
        uint64 unbonding; //          ↑      state.rs:376
        uint64 unbondingStartedAt; // ↑      state.rs:378
        uint64 slashedInWindow; //   slot 1  state.rs:385
        uint64 slashWindowStartedAt; //  ↑   state.rs:388
        uint64 pendingSlash; //          ↑   state.rs:400
        uint64 __gap; //                 ↑   struct padding, and nothing else
        uint128 totalDeposited; //   slot 2  state.rs:392
        uint128 totalWithdrawn; //       ↑   state.rs:393
        uint128 totalSlashed; //     slot 3  state.rs:394
    }

    /// The verifier's rolling daily cap counter lives HERE, not in X402Config: it is a
    /// consequence of slashing, and X402Config must never be written by another contract
    /// (D-3). X402Config owns only the key's lifecycle. On Solana both halves sit on the
    /// one `VerifierKey` account (`state.rs:236-239`) because there is only one program.
    struct VerifierWindow {
        uint64 slashedInWindow;
        uint64 windowStartedAt;
    }

    /// Storage, not immutables, since D-1 (design decision that makes this
    /// contract upgradeable). Written once in `initialize`; the names and getters are unchanged.
    IX402Config public CONFIG;
    IERC20 public ASSET;

    /// `internal` rather than `public` for `X402Escrow.escrows`'s reason: the generated getter
    /// for a struct-valued mapping returns a flattened tuple, which reorders silently when a
    /// field is appended. [`stakeOf`] returns the struct, so a decoder breaks loudly instead.
    mapping(address => ProviderStake) internal stakes;
    mapping(address => VerifierWindow) internal verifierWindows;

    /// `state.rs:95-101` keeps these on Solana's `Config`. Here they live on the contract that
    /// holds the custody (D-3), exactly as `X402Escrow.totalEscrowed` does, because
    /// X402Config must never be written by another contract.
    ///
    /// The identity they maintain, asserted directly by the tests:
    /// `totalStaked == totalDeposited - totalWithdrawn - totalSlashed`.
    uint128 public totalStaked;
    uint128 public totalDeposited;
    uint128 public totalWithdrawn;
    uint128 public totalSlashed;

    /// `events.rs::StakeDeposited` (`events.rs:61-69`). `funder` is indexed as well as
    /// `provider` for `X402Escrow.Deposited`'s reason: "who funded this provider" and "what did
    /// this address fund" are both queries the reconciler makes.
    event StakeDeposited(
        address indexed provider, address indexed funder, uint64 amount, uint128 bonded
    );
    event UnstakeRequested(
        address indexed provider, uint64 amount, uint128 bonded, uint64 unbonding, uint64 endsAt
    );
    event StakeWithdrawn(address indexed provider, uint64 amount, uint128 bonded, uint64 unbonding);

    /// The name and version are ShortString immutables baked in here, and every future
    /// implementation must be constructed with the SAME two strings or the attestation
    /// domain moves under the verifier's feet (D-1; asserted in `test/Upgrade.t.sol`).
    constructor() EIP712("x402 Settlement", "2") {
        _disableInitializers();
    }

    function initialize(IX402Config config, IERC20 asset) external initializer {
        if (address(config) == address(0) || address(asset) == address(0)) revert ZeroAddress();
        if (IERC20Decimals(address(asset)).decimals() != 6) revert AssetDecimalsNotSix();
        CONFIG = config;
        ASSET = asset;
    }

    /// The upgrade door (D-1): one key, read live from CONFIG, no timelock.
    function _authorizeUpgrade(address) internal view override {
        if (msg.sender != CONFIG.admin()) revert NotAdmin();
    }

    // --- views ----------------------------------------------------------------------------

    function stakeOf(address provider) external view returns (ProviderStake memory) {
        return stakes[provider];
    }

    /// Saturating: `bonded` is uint128 and the caller compares it against a uint64 minimum,
    /// so clamping is correct and truncation would be a silent under-report. The `Cast` after
    /// the clamp can never revert — that is the point of the clamp — and it is written anyway
    /// under `Cast`'s no-exceptions rule.
    function bondedOf(address provider) external view override returns (uint64) {
        uint128 b = stakes[provider].bonded;
        return b > type(uint64).max ? type(uint64).max : Cast.toUint64(b);
    }

    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /// `state.rs:436`'s `at_risk`. Unbonding stake counts: it stays slashable until it is
    /// actually withdrawn, which is the whole point of the period.
    function _atRisk(ProviderStake storage s) internal view returns (uint128) {
        return s.bonded + s.unbonding;
    }

    /// `state.rs:492`'s `withdrawable` — `min(matured unbonding, atRisk - pendingSlash)`.
    ///
    /// The `pendingSlash` term is measured against `atRisk` rather than against `unbonding`, so
    /// it bites only once it exceeds the bonded balance: the reserved portion has to sit
    /// somewhere and where it sits is not the claimant's business.
    ///
    /// Saturating like the Rust `saturating_sub`. `pendingSlash <= atRisk` is an invariant of
    /// this contract's four writers, but this is a view a guard reads and it must not be the
    /// thing that panics.
    function withdrawableOf(address provider) public view returns (uint64) {
        ProviderStake storage s = stakes[provider];
        uint64 period = CONFIG.params().unbondingPeriodSeconds;
        if (s.unbonding == 0) return 0;
        if (block.timestamp < uint256(s.unbondingStartedAt) + period) return 0;
        uint128 atRisk = _atRisk(s);
        uint128 free = atRisk > s.pendingSlash ? atRisk - s.pendingSlash : 0;
        uint128 capped = s.unbonding < free ? s.unbonding : free;
        return Cast.toUint64(capped); // <= s.unbonding, which is uint64
    }

    // --- collateral in --------------------------------------------------------------------

    function depositStake(uint64 amount) external {
        depositStakeFor(msg.sender, amount);
    }

    /// Anyone may fund anyone, matching `deposit_stake.rs:15-18`: "Not required to be the
    /// provider: this is also how the treasury compensates an overturned executed judgement,
    /// and a deposit can only ever increase what the provider owns."
    ///
    /// Not pause-gated, also matching `deposit_stake.rs`, which has no pause check: pausing a
    /// provider's own top-up would strand a provider trying to cure an under-stake, and curing it
    /// is a PRECONDITION for the moment the pause lifts rather than something the pause has
    /// already closed. `X402Escrow.depositFor` IS gated and that is not an inconsistency; the
    /// rule that predicts both is written out at that function, together with the earlier wording
    /// of it — "money coming in is on the closed side of the line" — which predicted this door
    /// wrongly and which a review caught by reading the two comments against each
    /// other. Both doors are tested, in `Pause.t.sol`:
    /// `test_pauseClosesEveryDepositDoorOnTheEscrow` and
    /// `test_pauseNeverClosesAProvidersOwnStakeTopUp`.
    ///
    /// **What stops re-entrancy here is the measured delta, not the modifier.** A token that
    /// calls back into this function from inside `transferFrom` makes the OUTER call's balance
    /// delta larger than the outer `amount`, so [`TransferAmountMismatch`] fires whether or not
    /// `nonReentrant` is present — the same finding `test/MUTATION-LOG.md` rows E4 and E23
    /// record on `X402Escrow.depositFor`. The modifier is the belt.
    function depositStakeFor(address provider, uint64 amount) public nonReentrant {
        if (provider == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        uint256 before = ASSET.balanceOf(address(this));
        ASSET.safeTransferFrom(msg.sender, address(this), amount);
        if (ASSET.balanceOf(address(this)) - before != amount) revert TransferAmountMismatch();

        ProviderStake storage s = stakes[provider];
        // Deposits accumulate: a second deposit adds to the first (deposit_stake.rs:69).
        s.bonded += amount;
        s.totalDeposited += amount;
        totalStaked += amount;
        totalDeposited += amount;

        emit StakeDeposited(provider, msg.sender, amount, s.bonded);
    }

    // --- collateral out -------------------------------------------------------------------

    /// `request_unstake.rs`. Nothing is checked beyond the balance: unbonding stake is still
    /// fully slashable, so asking to leave costs nobody anything, and what a pending judgement
    /// has reserved binds where money actually leaves, in [`withdrawStake`].
    ///
    /// One clock for the whole unbonding balance, restarted on every request
    /// (`request_unstake.rs:51-55`). Tracking a maturity per request would need an unbounded
    /// list; restarting is the conservative collapse of that — it can only ever delay a
    /// withdrawal, never let an amount out before its own period has elapsed.
    ///
    /// Neither `totalStaked` nor the token balance moves: the money has not left, it changed
    /// bucket, and both buckets stay slashable.
    function requestUnstake(uint64 amount) external nonReentrant {
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
            uint64(block.timestamp) + CONFIG.params().unbondingPeriodSeconds
        );
    }

    /// `withdraw_stake.rs`. Three checks, one definition: the amount is inside `unbonding`, the
    /// unbonding period has elapsed, and the amount is inside [`withdrawableOf`], which
    /// subtracts what pending judgements have reserved.
    ///
    /// **msg.sender-only, pays msg.sender, no destination** — the same argument
    /// `X402Escrow.withdraw()` makes. The Anchor original takes a `destination` token account
    /// and has to defend it with `DestinationIsVault`; here there is nothing to defend because
    /// there is nothing to choose.
    ///
    /// **`pendingSlash` shields exactly the reserved remainder**, so a `Pending` judgement
    /// cannot be outrun by an exit.
    ///
    /// **What stops re-entrancy here is the ordering.** Every effect is written before
    /// `safeTransfer`, so a token that calls back finds `unbonding` already reduced and
    /// `totalWithdrawn` already raised. `nonReentrant` is the belt and only changes the error
    /// name — `test/MUTATION-LOG.md` row W12 measured exactly that on `X402Escrow.withdraw`.
    function withdrawStake(uint64 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        ProviderStake storage s = stakes[msg.sender];

        if (amount > s.unbonding) revert InsufficientUnbondingStake();
        uint64 period = CONFIG.params().unbondingPeriodSeconds;
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

    // --- the two-phase slash, phase one -----------------------------------------------------

    /// `state.rs:292`'s `SlashRecord`, minus `request_id` (the mapping key here) and `bump`.
    /// **Never `delete`d**: a reclaimable record is a reusable request id, which is
    /// `constants.rs:44`'s reason for never closing the PDA — and here it is sharper still,
    /// because `delete` would make `status == None` true again and the captured attestation
    /// would resubmit.
    ///
    /// Five slots. The two `__gap` members are struct padding and mean nothing; they are named
    /// so the packing reads as chosen rather than as whatever the compiler did.
    ///
    /// Four fields of the Anchor record are deliberately absent, and each is derivable from the
    /// event: `attested_at` (the attestation's own `issuedAt`), `agent_amount`,
    /// `platform_amount` and `slash_agent_bps`/`slash_platform_bps` (all four are in
    /// `SlashExecuted`, and all four are `applied` times a parameter), and `cancelled_at` (in
    /// `SlashCancelled`). On Solana an account is the only place an operator can read a value
    /// back; here `eth_getLogs` is that place, and a slot per record is not.
    struct SlashRecord {
        address provider; //     slot 0
        SlashStatus status; //    ↑
        uint64 penalty; //        ↑
        address beneficiary; //  slot 1
        uint64 proposedAt; //     ↑
        uint32 __gap; //          ↑
        address verifier; //     slot 2
        uint64 executableAt; //   ↑
        uint32 __gap2; //         ↑
        uint64 reserved; //      slot 3
        uint64 capAllowance; //   ↑
        uint64 applied; //        ↑
        uint64 executedAt; //     ↑
        bytes32 policy; //       slot 4
    }

    mapping(bytes32 => SlashRecord) internal slashRecords;

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

    function slashRecordOf(bytes32 requestId) external view returns (SlashRecord memory) {
        return slashRecords[requestId];
    }

    /// `propose_slash.rs`. Phase one: prove the verifier's signature, reserve the stake, start
    /// the 72-hour clock. **Moves no money.**
    ///
    /// **Permissionless to SUBMIT: the authority is the signature, not the sender.** On Solana
    /// the `VerifierKey` PDA is passed and `require_signed_by` proves that key signed. Here
    /// `Sig.recover` yields the signer and `CONFIG.assertCanSign` decides whether that address
    /// may judge — one fewer parameter, one fewer place for the caller to point at the wrong
    /// account, and the same property.
    ///
    /// **The replay lock.** `slashRecords[requestId].status != None` is the EVM counterpart of
    /// the Anchor `init` on a PDA seeded by the signed `request_id`: a captured attestation can
    /// be submitted exactly once.
    ///
    /// **`executableAt` is frozen here** so that nothing during the wait can pull the judgement
    /// forward, and so is `capAllowance` — "a figure re-derived at execution is a figure the
    /// party being judged can move in between" (`propose_slash.rs:110-111`).
    ///
    /// Nothing external is called except `CONFIG`, which is this system's own contract and
    /// holds no tokens, so there is no point from which anything could re-enter.
    /// `nonReentrant` is belt with no brace behind it, exactly as `test/MUTATION-LOG.md` row
    /// T13 records for the escrow's four limit and withdrawal doors.
    function proposeSlash(SlashAttestation calldata a, bytes calldata sig) external nonReentrant {
        if (CONFIG.paused()) revert ProgramPaused();
        if (a.penalty == 0) revert ZeroAmount();
        if (a.beneficiary == address(0)) revert MissingBeneficiary();
        // The response-class rule: only DataFail touches stake. The class is a SIGNED byte, so
        // the platform cannot relabel a judgement to move it between rows.
        if (a.status != uint8(ResponseClass.DataFail)) revert StatusDoesNotSlash();
        if (slashRecords[a.requestId].status != SlashStatus.None) revert SlashAlreadyExists();

        uint64 nowTs = uint64(block.timestamp);
        // `attestation.rs:167-177`'s `require_valid_window`, in its order.
        if (
            a.expiresAt <= a.issuedAt
                || a.expiresAt - a.issuedAt > Constants.MAX_ATTESTATION_LIFETIME_SECONDS
        ) revert InvalidAttestationWindow();
        if (a.issuedAt > nowTs) revert AttestationNotYetValid();
        if (nowTs > a.expiresAt) revert AttestationExpired();

        address verifier = Sig.recover(_hashTypedDataV4(Attestation712.hashAttestation(a)), sig);
        CONFIG.assertCanSign(verifier);

        ParamSet memory p = CONFIG.params();
        // A ceiling rather than an equality: the verifier computes the penalty off chain and a
        // deliberately reduced judgement is legal (`propose_slash.rs:95-99`).
        if (a.penalty > p.penaltyAmount) revert PenaltyExceedsMaximum();

        ProviderStake storage s = stakes[a.provider];
        uint128 atRisk = _atRisk(s);
        if (atRisk == 0) revert NothingToSlash();

        uint64 capAllowance =
            Cast.toUint64((uint256(atRisk) * p.slashCapBps) / Constants.BPS_DENOMINATOR);
        if (capAllowance == 0) revert SlashCapExceeded();

        // What this judgement may EVER be paid: the penalty, cut to the ceiling, cut to what
        // other standing judgements have not already reserved. Reservations stack up to the
        // whole stake — a leaked key can freeze a provider's exit for the ten days until the
        // records expire or the key is revoked. It cannot take it.
        uint128 free = atRisk > s.pendingSlash ? atRisk - s.pendingSlash : 0;
        uint64 reserved = a.penalty;
        if (reserved > capAllowance) reserved = capAllowance;
        if (reserved > free) reserved = Cast.toUint64(free);
        if (reserved == 0) revert NothingToSlash();

        s.pendingSlash += reserved;

        SlashRecord storage rec = slashRecords[a.requestId];
        rec.provider = a.provider;
        rec.status = SlashStatus.Pending;
        rec.penalty = a.penalty;
        rec.beneficiary = a.beneficiary;
        rec.proposedAt = nowTs;
        rec.verifier = verifier;
        rec.executableAt = nowTs + Constants.SLASH_DELAY_SECONDS;
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

    // --- the two-phase slash, phase two: the three exits from Pending ------------------------

    /// `events.rs::SlashExecuted`. `slashCapBps` is the one Anchor field left out: the record's
    /// frozen `capAllowance` is what actually bound this execution, and it is already in
    /// `SlashProposed`.
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

    /// `events.rs::SlashCancelled`. One event for both exits that release, because they are one
    /// event with a different `reason` — `cancel_slash.rs` and `expire_slash.rs` emit the same
    /// struct on Solana too.
    event SlashCancelled(
        bytes32 indexed requestId,
        address indexed provider,
        CancelReason reason,
        uint64 released,
        uint64 pendingSlash,
        uint64 cancelledAt
    );

    /// `execute_slash.rs`. Phase two: the delay was served, the execution window has not closed,
    /// the key can still sign, and the penalty is paid under both caps.
    ///
    /// **Permissionless.** Being front-run for the privilege of paying gas is harmless — the
    /// judgement, its beneficiary and its amount were all fixed 72 hours ago, and every one of
    /// them is read from the record rather than from the caller.
    ///
    /// **THE CRUX OF THE WHOLE TWO-PHASE DESIGN is `CONFIG.assertCanSign(rec.verifier)`.** A key
    /// revoked or expired inside the window can never pay, so `revokeVerifier` reaches backwards
    /// into every judgement that key already signed, and [`expireSlash`] then releases the
    /// collateral. That is what turns revocation from a stop into a cleanup.
    ///
    /// It calls the REVERTING `assertCanSign` and not the boolean `canSign`, because here the
    /// unusable key is a failure and the caller needs the diagnosis;
    /// [`expireSlash`] calls the boolean, because there the same fact is the CONDITION.
    ///
    /// **Effects strictly before interactions, which is where this diverges from the reference.**
    /// `execute_slash.rs:243` pays before it mutates a single account, and says so out loud —
    /// that ordering is safe on Solana, where a CPI cannot re-enter this instruction. On EVM it
    /// is the classic hole, so the order is inverted here. `nonReentrant` is the belt;
    /// `test_everyEffectIsWrittenBeforeTheSlashTransfers` is the brace, and it observes the
    /// effects from inside the first payout.
    function executeSlash(bytes32 requestId) external nonReentrant {
        if (CONFIG.paused()) revert ProgramPaused();

        SlashRecord storage rec = slashRecords[requestId];
        if (rec.status != SlashStatus.Pending) revert SlashNotPending();

        uint64 nowTs = uint64(block.timestamp);
        // The wait, against the instant frozen at proposal.
        if (nowTs < rec.executableAt) revert SlashNotYetExecutable();
        // And the ceiling: from `executableAt + grace` the record belongs to `expireSlash`,
        // whose test is `>=` the SAME instant, so the two doors never overlap and never leave a
        // gap. `uint256` because a record written near `type(uint64).max` must not turn this
        // comparison into a panic — the Anchor original saturates for the same reason.
        if (nowTs >= uint256(rec.executableAt) + Constants.SLASH_EXECUTION_GRACE_SECONDS) {
            revert SlashExecutionWindowClosed();
        }

        CONFIG.assertCanSign(rec.verifier);

        ParamSet memory p = CONFIG.params();
        ProviderStake storage s = stakes[rec.provider];

        uint128 atRisk = _atRisk(s);
        if (atRisk == 0) revert NothingToSlash();

        // The provider's rolling window, against the allowance FROZEN at proposal.
        uint64 providerCarried = Window.decay(s.slashedInWindow, s.slashWindowStartedAt, nowTs);
        uint64 windowRemaining =
            rec.capAllowance > providerCarried ? rec.capAllowance - providerCarried : 0;
        if (windowRemaining == 0) revert SlashCapExceeded();

        // The key's rolling window, against the absolute cap, read LIVE. Nothing is reserved
        // against it at proposal, so a leaked key cannot burn a day's capacity on judgements it
        // never intends to execute.
        VerifierWindow storage vw = verifierWindows[rec.verifier];
        uint64 keyCarried = Window.decay(vw.slashedInWindow, vw.windowStartedAt, nowTs);
        uint64 keyRemaining = p.verifierDailyCap > keyCarried ? p.verifierDailyCap - keyCarried : 0;
        if (keyRemaining == 0) revert VerifierDailyCapExceeded();

        // Never more than was reserved, than either window admits, or than the provider still
        // holds. Any of the three binding leaves `penalty - applied` discharged, not carried;
        // the request id is spent either way.
        uint64 atRiskCapped = atRisk > type(uint64).max ? type(uint64).max : Cast.toUint64(atRisk);
        uint64 applied = rec.reserved;
        if (applied > windowRemaining) applied = windowRemaining;
        if (applied > keyRemaining) applied = keyRemaining;
        if (applied > atRiskCapped) applied = atRiskCapped;

        uint64 agentAmount = Fee.bpsOf(applied, p.slashAgentBps);
        uint64 platformAmount = Fee.bpsOf(applied, p.slashPlatformBps);
        uint64 taken = agentAmount + platformAmount;
        // The provider KEEPS the remainder. `applied - taken` is never transferred,
        // and it is a deliberate economic property rather than an accounting leftover.
        uint64 providerAmount = applied - taken;
        // A penalty too small to divide leaves the record PENDING — this reverts, so every
        // write above is rolled back — to be retried as the window rolls.
        if (taken == 0) revert PenaltyTooSmallToSplit();

        // --- effects ---------------------------------------------------------------------
        // The WHOLE reservation is released; `applied` of it is paid and the rest returns to the
        // provider's free balance. Saturating for `cancel_slash.rs:74-78`'s reason.
        uint64 released = rec.reserved;
        s.pendingSlash = s.pendingSlash > released ? s.pendingSlash - released : 0;

        // Unbonding first: a provider on their way out pays from the stake they were leaving
        // with (`execute_slash.rs:264`).
        uint64 fromUnbonding = taken < s.unbonding ? taken : s.unbonding;
        uint64 fromBonded = taken - fromUnbonding;
        s.unbonding -= fromUnbonding;
        s.bonded -= fromBonded;
        if (s.unbonding == 0) s.unbondingStartedAt = 0;

        s.totalSlashed += taken;
        // Both counters meter `applied` — the gross judged — not `taken`. The anchors never move
        // backwards: a clock that stepped back must not hand capacity to whoever noticed.
        s.slashedInWindow = providerCarried + applied;
        s.slashWindowStartedAt = nowTs > s.slashWindowStartedAt ? nowTs : s.slashWindowStartedAt;

        vw.slashedInWindow = keyCarried + applied;
        vw.windowStartedAt = nowTs > vw.windowStartedAt ? nowTs : vw.windowStartedAt;

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

    /// `cancel_slash.rs`. Withdraw a pending judgement before it pays, on the ADMIN's signature.
    ///
    /// An arbitration outcome is a human decision and the party that decided it should sign its
    /// consequence. A verifier-signed cancel would mean a leaked verifier key — the thing the
    /// whole two-phase design assumes — could void every honest judgement in flight.
    ///
    /// An earlier hardening design proposed a verifier-attested cancel instead; **the shipped
    /// Anchor code
    /// wins**, and the divergence is recorded in `docs/divergences.md`.
    ///
    /// **NOT pause-gated** (`cancel_slash.rs:31`): it can only release a hold, and pausing it
    /// could only extend one.
    function cancelSlash(bytes32 requestId) external nonReentrant {
        if (msg.sender != CONFIG.admin()) revert NotAdmin();
        _release(requestId, CancelReason.Withdrawn);
    }

    /// `expire_slash.rs`. Release a reservation nobody is going to act on. **Permissionless, and
    /// that is the whole design: a hold anybody can end is a hold nobody can extend.** Any
    /// authority that can be withheld is an authority whose holder can keep the hold in place.
    ///
    /// Two conditions, either of which is enough:
    ///
    /// - **The proposing key can no longer sign.** [`executeSlash`] will refuse it for ever, so
    ///   the reservation is dead weight the moment `revokeVerifier` lands. This is the half that
    ///   bounds what a leaked verifier key can do to a provider's exit.
    /// - **The grace period ran out.** Seven days after the judgement became executable, a
    ///   platform that has not executed its own judgement has abandoned it.
    ///
    /// It calls the BOOLEAN `canSign`, never `assertCanSign`: an unusable key is the *condition*
    /// here, not a failure, and the reverting form would revert on exactly the records this door
    /// exists to clean up.
    ///
    /// Not pause-gated and it reads no parameters: there is no flag anywhere, and no key, that
    /// turns this door off. It moves no token either — the only writes are a status and a
    /// release.
    function expireSlash(bytes32 requestId) external nonReentrant {
        SlashRecord storage rec = slashRecords[requestId];
        if (rec.status != SlashStatus.Pending) revert SlashNotPending();

        bool verifierUnavailable = !CONFIG.canSign(rec.verifier);
        bool graceElapsed =
            block.timestamp >= uint256(rec.executableAt) + Constants.SLASH_EXECUTION_GRACE_SECONDS;
        if (!verifierUnavailable && !graceElapsed) revert SlashNotExpired();

        // The more specific fact wins when both hold: "the key is gone" tells an operator
        // something "nobody executed it" does not.
        _release(
            requestId, verifierUnavailable ? CancelReason.VerifierUnavailable : CancelReason.Expired
        );
    }

    /// The one way out of `Pending` that returns the reservation whole. `Pending` is left
    /// EXACTLY once: the status check here is what makes both terminal states absorbing, and
    /// the record is never `delete`d.
    ///
    /// The reservation is released whole, never in part: a judgement is withdrawn or it is not.
    /// Saturating for `cancel_slash.rs:74-78`'s reason — `pendingSlash` is the sum of the
    /// standing reservations and this one is among them, so the subtraction cannot underflow
    /// through this contract's own doors, and this is the door that gives capital back. It must
    /// not be the one that bricks.
    function _release(bytes32 requestId, CancelReason reason) internal {
        SlashRecord storage rec = slashRecords[requestId];
        if (rec.status != SlashStatus.Pending) revert SlashNotPending();

        ProviderStake storage s = stakes[rec.provider];
        uint64 released = rec.reserved;
        s.pendingSlash = s.pendingSlash > released ? s.pendingSlash - released : 0;

        rec.status = SlashStatus.Cancelled;
        emit SlashCancelled(
            requestId, rec.provider, reason, released, s.pendingSlash, uint64(block.timestamp)
        );
    }

    /// The append budget the D-7 upgrade-safety gate spends.
    ///
    /// **50 → 49 for the slash records**: `slashRecords` is one mapping, one slot, and it is paid
    /// for out
    /// of here. The contract's total footprint is unchanged, which is the property the gate
    /// checks — a field appended without paying for it out of the gap moves every slot after it.
    uint256[49] private __gap;
}
