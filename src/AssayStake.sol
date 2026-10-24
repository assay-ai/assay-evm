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

/// Provider collateral, and the two-phase slash. Holds no buyer money and holds no
/// reference to AssayEscrow — the only edge between them points the other way and is a view.
///
/// Deployed behind an ERC1967Proxy and upgraded through UUPS (D-1), with the same single
/// authority: `CONFIG.owner()` (D-17), a Ledger or a Safe, immediate, no timelock. The proxy address is the
/// verifier's EIP-712 `verifyingContract`, so an upgrade does not invalidate an attestation
/// that is already in flight.
///
/// **Pause closes the deposit and exit half too, since the dispute upgrade** — a deliberate
/// reversal, by the owner's decision, of the earlier rule (and of `withdraw_stake.rs`)
/// that owner exits are never paused. `depositStake(For)`, `requestUnstake` and `withdrawStake`
/// call `CONFIG.assertActive`, which refuses while paused and refuses a blocked provider (or
/// funder). What stays open while paused is what only releases or freezes a hold:
/// `disputeSlash`, `cancelSlash`, `expireSlash`, and `upholdSlash` (which moves no money). The
/// pause still moves nobody's funds anywhere; there is no seize and no sweep.
contract AssayStake is Initializable, UUPSUpgradeable, IAssayStakeView, EIP712, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// `state.rs`'s `ProviderStake`, minus the two Solana-only fields (`provider`, which is
    /// the mapping key here, and `bump`). Four slots, asserted by `script/check-layout.sh`.
    ///
    /// The widths follow `AssayEscrow.Escrow`'s rule: cumulative counters are `uint128` (they are
    /// sums of many amounts and must not be able to wrap where an amount cannot), and everything
    /// an instruction takes as an argument or compares against a clock is `uint64`.
    struct ProviderStake {
        uint128 bonded; //           slot 0  state.rs
        uint64 unbonding; //          ↑      state.rs
        uint64 unbondingStartedAt; // ↑      state.rs
        uint64 slashedInWindow; //   slot 1  state.rs
        uint64 slashWindowStartedAt; //  ↑   state.rs
        uint64 pendingSlash; //          ↑   state.rs
        uint64 __gap; //                 ↑   struct padding, and nothing else
        uint128 totalDeposited; //   slot 2  state.rs
        uint128 totalWithdrawn; //       ↑   state.rs
        uint128 totalSlashed; //     slot 3  state.rs
    }

    /// RETIRED (D-25). This was the verifier key's rolling daily meter. `executeSlash` no longer
    /// reads or writes it: one shared first-come-first-served window per key let anyone who could
    /// fill it with its own records crowd every other provider's slash into expiry. The type and
    /// the mapping below stay declared only so the storage layout remains append-only
    /// (`script/check-layout.sh`); nothing in this contract touches them.
    struct VerifierWindow {
        uint64 slashedInWindow;
        uint64 windowStartedAt;
    }

    /// Storage, not immutables, since D-1 (design decision that makes this
    /// contract upgradeable). Written once in `initialize`; the names and getters are unchanged.
    IAssayConfig public CONFIG;
    IERC20 public ASSET;

    /// `internal` rather than `public` for `AssayEscrow.escrows`'s reason: the generated getter
    /// for a struct-valued mapping returns a flattened tuple, which reorders silently when a
    /// field is appended. [`stakeOf`] returns the struct, so a decoder breaks loudly instead.
    mapping(address => ProviderStake) internal stakes;
    /// RETIRED (D-25): never read or written. Kept for the storage layout only.
    mapping(address => VerifierWindow) internal verifierWindows;

    /// `state.rs` keeps these on Solana's `Config`. Here they live on the contract that
    /// holds the custody (D-3), exactly as `AssayEscrow.totalEscrowed` does, because
    /// AssayConfig must never be written by another contract.
    ///
    /// The identity they maintain, asserted directly by the tests:
    /// `totalStaked == totalDeposited - totalWithdrawn - totalSlashed`.
    uint128 public totalStaked;
    uint128 public totalDeposited;
    uint128 public totalWithdrawn;
    uint128 public totalSlashed;

    /// `events.rs::StakeDeposited`. `funder` is indexed as well as
    /// `provider` for `AssayEscrow.Deposited`'s reason: "who funded this provider" and "what did
    /// this address fund" are both queries the reconciler makes.
    event StakeDeposited(
        address indexed provider, address indexed funder, uint64 amount, uint128 bonded
    );
    event UnstakeRequested(
        address indexed provider, uint64 amount, uint128 bonded, uint64 unbonding, uint64 endsAt
    );
    event StakeWithdrawn(address indexed provider, uint64 amount, uint128 bonded, uint64 unbonding);

    /// The name and version are ShortString immutables baked in here. An implementation built
    /// with other strings moves the attestation domain under the verifier's feet (D-1; asserted
    /// in `test/Upgrade.t.sol`), so that only ever happens on purpose, together with the backend's domain.
    constructor() EIP712("Assay Settlement", "2") {
        _disableInitializers();
    }

    function initialize(IAssayConfig config, IERC20 asset) external initializer {
        if (address(config) == address(0) || address(asset) == address(0)) revert ZeroAddress();
        if (IERC20Decimals(address(asset)).decimals() != 6) revert AssetDecimalsNotSix();
        CONFIG = config;
        ASSET = asset;
    }

    /// The upgrade door (D-1, D-17): `CONFIG.owner()`, read live, no timelock. Not the admin.
    function _authorizeUpgrade(address) internal view override {
        if (msg.sender != CONFIG.owner()) revert NotOwner();
    }

    // --- views ----------------------------------------------------------------------------

    // --- shared call sites ------------------------------------------------------------------
    //
    // Each external read below has several callers. Under `via_ir` every inline call site
    // carries its own copy of the call, returndata checks and ABI decoding, so routing them
    // through one internal function is a size saving only: the same call, with the same
    // arguments, at the same point of every caller, reverting with the same data.

    /// The one `CONFIG.params()` call site (see the note above).
    function _params() internal view returns (ParamSet memory) {
        return CONFIG.params();
    }

    /// The one `CONFIG.assertActive` call site: the pause and blocklist check of every door.
    function _assertActive(address a, address b, address c) internal view {
        CONFIG.assertActive(a, b, c);
    }

    /// The one `CONFIG.paused()` call site.
    function _paused() internal view returns (bool) {
        return CONFIG.paused();
    }

    /// The one `CONFIG.assertCanSign` call site.
    function _assertCanSign(address verifier) internal view {
        CONFIG.assertCanSign(verifier);
    }

    /// Both halves of `depositStakeFor`'s before/after delta, and no other read.
    function _assetBalance() internal view returns (uint256) {
        return ASSET.balanceOf(address(this));
    }

    function stakeOf(address provider) external view returns (ProviderStake memory) {
        return stakes[provider];
    }

    /// Saturating: `bonded` is uint128 and the caller compares it against a uint64 minimum,
    /// so clamping is correct and truncation would be a silent under-report. The `Cast` after
    /// the clamp can never revert — that is the point of the clamp — and it is written anyway
    /// under `Cast`'s no-exceptions rule.
    function bondedOf(address provider) external view returns (uint64) {
        uint128 b = stakes[provider].bonded;
        return b > type(uint64).max ? type(uint64).max : Cast.toUint64(b);
    }

    /// The bonded stake no standing slash record has reserved: `bonded - pendingSlash`, floored
    /// at zero, saturated like [`bondedOf`]. This is what the escrow's redeem gate reads (D-26):
    /// stake held back by `Pending` or `Disputed` records is not backing new traffic, so a
    /// provider cannot freeze its stake with records it disputes itself and keep being paid.
    ///
    /// `pendingSlash` is reserved against `atRisk = bonded + unbonding`, and a withdrawal must
    /// leave it covered, so once the unbonding has left it sits entirely on `bonded`. Charging it
    /// all to `bonded` now is the conservative reading of where it will end up.
    function freeBondedOf(address provider) external view override returns (uint64) {
        ProviderStake storage s = stakes[provider];
        uint128 b = s.bonded;
        uint128 pending = s.pendingSlash;
        uint128 free = b > pending ? b - pending : 0;
        return free > type(uint64).max ? type(uint64).max : Cast.toUint64(free);
    }

    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /// `state.rs`'s `at_risk`. Unbonding stake counts: it stays slashable until it is
    /// actually withdrawn, which is the whole point of the period.
    function _atRisk(ProviderStake storage s) internal view returns (uint128) {
        return s.bonded + s.unbonding;
    }

    /// `state.rs`'s `withdrawable` — `min(matured unbonding, atRisk - pendingSlash)`.
    ///
    /// The `pendingSlash` term is measured against `atRisk` rather than against `unbonding`, so
    /// it bites only once it exceeds the bonded balance: the reserved portion has to sit
    /// somewhere and where it sits is not the claimant's business.
    ///
    /// **Checked, not saturating** (audit F R2): `pendingSlash <= atRisk` holds on every
    /// reachable state (the trace is at [`proposeSlash`]), so a broken invariant reverts here
    /// rather than being reported as a zero.
    function withdrawableOf(address provider) public view returns (uint64) {
        ProviderStake storage s = stakes[provider];
        uint64 period = _params().unbondingPeriodSeconds;
        if (s.unbonding == 0) return 0;
        if (block.timestamp < uint256(s.unbondingStartedAt) + period) return 0;
        uint128 free = _atRisk(s) - s.pendingSlash;
        uint128 capped = s.unbonding < free ? s.unbonding : free;
        return Cast.toUint64(capped); // <= s.unbonding, which is uint64
    }

    // --- collateral in --------------------------------------------------------------------

    function depositStake(uint64 amount) external {
        depositStakeFor(msg.sender, amount);
    }

    /// Anyone may fund anyone, matching `deposit_stake.rs`: "Not required to be the
    /// provider: this is also how the treasury compensates an overturned executed judgement,
    /// and a deposit can only ever increase what the provider owns."
    ///
    /// **Pause-gated since the dispute upgrade** (the owner's decision; it diverges from
    /// `deposit_stake.rs`, which has no pause check), and refused for a blocked provider or a
    /// blocked funder. `Pause.t.sol::test_pauseClosesEveryStakeDoor` pins it.
    ///
    /// **What stops re-entrancy here is the measured delta, not the modifier.** A token that
    /// calls back into this function from inside `transferFrom` makes the OUTER call's balance
    /// delta larger than the outer `amount`, so [`TransferAmountMismatch`] fires whether or not
    /// `nonReentrant` is present — the same finding `test/MUTATION-LOG.md` rows E4 and E23
    /// record on `AssayEscrow.depositFor`. The modifier is the belt.
    function depositStakeFor(address provider, uint64 amount) public nonReentrant {
        _assertActive(provider, msg.sender, address(0));
        if (provider == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        uint256 before = _assetBalance();
        ASSET.safeTransferFrom(msg.sender, address(this), amount);
        if (_assetBalance() - before != amount) revert TransferAmountMismatch();

        ProviderStake storage s = stakes[provider];
        // Deposits accumulate: a second deposit adds to the first (deposit_stake.rs).
        s.bonded += amount;
        s.totalDeposited += amount;
        totalStaked += amount;
        totalDeposited += amount;

        emit StakeDeposited(provider, msg.sender, amount, s.bonded);
    }

    // --- collateral out -------------------------------------------------------------------

    /// Nothing is checked beyond the balance: unbonding stake is still
    /// fully slashable, so asking to leave costs nobody anything, and what a pending judgement
    /// has reserved binds where money actually leaves, in [`withdrawStake`].
    ///
    /// One clock for the whole unbonding balance, restarted on every request.
    /// Tracking a maturity per request would need an unbounded
    /// list; restarting is the conservative collapse of that — it can only ever delay a
    /// withdrawal, never let an amount out before its own period has elapsed.
    ///
    /// Neither `totalStaked` nor the token balance moves: the money has not left, it changed
    /// bucket, and both buckets stay slashable.
    ///
    /// Pause-gated and blocklist-gated since the dispute upgrade, like [`withdrawStake`].
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

    /// Three checks, one definition: the amount is inside `unbonding`, the
    /// unbonding period has elapsed, and the amount is inside [`withdrawableOf`], which
    /// subtracts what pending judgements have reserved.
    ///
    /// **msg.sender-only, pays msg.sender, no destination** — the same argument
    /// `AssayEscrow.withdraw()` makes. The Anchor original takes a `destination` token account
    /// and has to defend it with `DestinationIsVault`; here there is nothing to defend because
    /// there is nothing to choose.
    ///
    /// **`pendingSlash` shields exactly the reserved remainder**, so a `Pending` judgement
    /// cannot be outrun by an exit.
    ///
    /// **What stops re-entrancy here is the ordering.** Every effect is written before
    /// `safeTransfer`, so a token that calls back finds `unbonding` already reduced and
    /// `totalWithdrawn` already raised. `nonReentrant` is the belt and only changes the error
    /// name — `test/MUTATION-LOG.md` row W12 measured exactly that on `AssayEscrow.withdraw`.
    ///
    /// **Pause-gated and blocklist-gated since the dispute upgrade** — the owner's decision,
    /// reversing `withdraw_stake.rs`. Neither gate moves the stake anywhere: it stays the
    /// provider's, and the door reopens when the pause lifts or the block is removed.
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

    // --- the two-phase slash, phase one -----------------------------------------------------

    /// `state.rs`'s `SlashRecord`, minus `request_id` (the mapping key here) and `bump`.
    /// **Never `delete`d**: a reclaimable record is a reusable request id, which is
    /// `constants.rs`'s reason for never closing the PDA — and here it is sharper still,
    /// because `delete` would make `status == None` true again and the captured attestation
    /// would resubmit.
    ///
    /// Six slots. The two `__gap` members are struct padding and mean nothing; they are named
    /// so the packing reads as chosen rather than as whatever the compiler did. `disputedAt`
    /// (the dispute upgrade) is appended as slot 5 rather than packed into a gap: a record is a
    /// mapping value, so appending a member moves no other record and no other field, and
    /// reads as `0` on every record written before the upgrade.
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
        uint64 disputedAt; //    slot 5  the dispute upgrade; 0 until `disputeSlash`
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

    /// Phase one: prove the verifier's signature, reserve the stake, start
    /// the slash-delay clock (`CONFIG.slashDelaySeconds()`, 72 h by default). **Moves no money.**
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
    /// party being judged can move in between".
    ///
    /// Nothing external is called except `CONFIG`, which is this system's own contract and
    /// holds no tokens, so there is no point from which anything could re-enter.
    /// `nonReentrant` is belt with no brace behind it, exactly as `test/MUTATION-LOG.md` row
    /// T13 records for the escrow's four limit and withdrawal doors.
    function proposeSlash(SlashAttestation calldata a, bytes calldata sig) external nonReentrant {
        if (_paused()) revert ProgramPaused();
        if (a.penalty == 0) revert ZeroAmount();
        // The stake proxy itself would keep the share as an untracked balance. (Stake holds no
        // reference to the escrow; the backend never names it.)
        if (a.beneficiary == address(0) || a.beneficiary == address(this)) {
            revert MissingBeneficiary();
        }
        // The response-class rule: only DataFail touches stake. The class is a SIGNED byte, so
        // the platform cannot relabel a judgement to move it between rows.
        if (a.status != uint8(ResponseClass.DataFail)) revert StatusDoesNotSlash();
        if (slashRecords[a.requestId].status != SlashStatus.None) revert SlashAlreadyExists();

        uint64 nowTs = uint64(block.timestamp);
        // `attestation.rs`'s `require_valid_window`, in its order.
        if (
            a.expiresAt <= a.issuedAt
                || a.expiresAt - a.issuedAt > Constants.MAX_ATTESTATION_LIFETIME_SECONDS
        ) revert InvalidAttestationWindow();
        if (a.issuedAt > nowTs) revert AttestationNotYetValid();
        if (nowTs > a.expiresAt) revert AttestationExpired();

        address verifier = Sig.recover(_hashTypedDataV4(Attestation712.hashAttestation(a)), sig);
        _assertCanSign(verifier);

        ParamSet memory p = _params();
        // A ceiling rather than an equality: the verifier computes the penalty off chain and a
        // deliberately reduced judgement is legal.
        if (a.penalty > p.penaltyAmount) revert PenaltyExceedsMaximum();

        ProviderStake storage s = stakes[a.provider];
        uint128 atRisk = _atRisk(s);
        if (atRisk == 0) revert NothingToSlash();

        uint64 capAllowance =
            Cast.toUint64((uint256(atRisk) * p.slashCapBps) / Constants.BPS_DENOMINATOR);
        if (capAllowance == 0) revert SlashCapExceeded();

        // What this judgement may EVER be paid: the penalty, cut to the ceiling, cut to what
        // other standing judgements have not already reserved. Reservations stack up to the
        // whole stake — a leaked key can freeze a provider's exit until the records expire
        // (delay + 7 d, or the 30-day dispute timeout) or the key is revoked. It cannot take it.
        // Checked: `pendingSlash <= atRisk` on every reachable state. Every writer keeps it —
        // this line reserves at most `free`; an execution lowers `pendingSlash` by `reserved` and
        // `atRisk` by `taken <= reserved`; a release lowers only `pendingSlash`; a withdrawal
        // takes at most `atRisk - pendingSlash`; deposits only raise `atRisk` (audit F §3).
        uint128 free = atRisk - s.pendingSlash;
        uint64 reserved = a.penalty;
        if (reserved > capAllowance) reserved = capAllowance;
        // All or nothing against `free` (D-26): a judgement the provider's free stake cannot
        // cover in full is refused, not written short. A short record would spend the
        // `requestId` for less than the cap allows; refused, the attestation stays unconsumed
        // and can be proposed again once other records release their reservations. The
        // `capAllowance` cut above is the ceiling itself and stays. `reserved >= 1` here (a zero
        // penalty is `ZeroAmount`, a zero ceiling `SlashCapExceeded`), so `free == 0` lands here.
        if (reserved > free) revert NothingToSlash();
        // A reservation the current split cannot divide is refused here (review 2026-10-23 L-1):
        // written, it could never execute (`PenaltyTooSmallToSplit`), would expire, and would
        // burn the `requestId` for good. The agent share must be non-zero, and so must the
        // platform share whenever the split gives the platform one. `executeSlash` keeps its own
        // check, because the split is read again there and may have changed since.
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
        // The LIVE delay, frozen into this record: a later `setSlashDelay` moves nothing here.
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

    // --- the two-phase slash, phase two: the three exits from Pending ------------------------

    /// `slashCapBps` is the one Anchor field left out: the record's
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

    /// One event for both exits that release, because they are one
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

    /// Phase two: the delay was served, the execution window has not closed,
    /// the key can still sign, and the penalty fits the provider's rolling window.
    ///
    /// **Permissionless.** Being front-run for the privilege of paying gas is harmless — the
    /// judgement, its beneficiary and its amount were all fixed at proposal, and every one of
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
    /// `execute_slash.rs` pays before it mutates a single account, and says so out loud —
    /// that ordering is safe on Solana, where a CPI cannot re-enter this instruction. On EVM it
    /// is the classic hole, so the order is inverted here. `nonReentrant` is the belt;
    /// `test_everyEffectIsWrittenBeforeTheSlashTransfers` is the brace, and it observes the
    /// effects from inside the first payout.
    function executeSlash(bytes32 requestId) external nonReentrant {
        if (_paused()) revert ProgramPaused();

        SlashRecord storage rec = slashRecords[requestId];
        if (rec.status != SlashStatus.Pending) revert SlashNotPending();

        uint64 nowTs = uint64(block.timestamp);
        // The wait, against the instant frozen at proposal.
        if (nowTs < rec.executableAt) revert SlashNotYetExecutable();
        // And the ceiling: from `executableAt + grace` the record belongs to `expireSlash`,
        // whose test is `>=` the SAME instant, so the two doors never overlap and never leave a
        // gap. `uint256` because a record written near `type(uint64).max` must not turn this
        // comparison into a panic — the Anchor original saturates for the same reason.
        if (nowTs >= _deadline(rec)) revert SlashExecutionWindowClosed();

        _assertCanSign(rec.verifier);

        ParamSet memory p = _params();
        ProviderStake storage s = stakes[rec.provider];

        // **All or wait** (owner decision, audit F R4). The record is paid its WHOLE reservation
        // or not at all: only when it fits under the provider's rolling window (against the
        // allowance FROZEN at proposal). Otherwise `SlashWindowNotDrained`, the record stays
        // Pending, and it is retried as the window drains; one that never fits before its
        // deadline expires in the provider's favour. So `applied == reserved` always: nobody —
        // the party being judged included — can choose an instant at which a judgement is paid
        // as dust.
        //
        // **No per-verifier-key window (D-25).** A key-wide window is one first-come-first-served
        // resource shared by every provider that key judged, so whoever fills it with its own
        // records makes every other provider's slash wait until it expires. A leaked key is
        // bounded instead by `revokeVerifier` (re-checked above, it voids every record the key
        // signed), the slash delay, the dispute and arbiter path, and this per-provider window.
        // `ParamSet.verifierDailyCap` is not read on chain.
        uint64 providerCarried = Window.decay(s.slashedInWindow, s.slashWindowStartedAt, nowTs);
        uint64 applied = rec.reserved;
        if (uint256(providerCarried) + applied > rec.capAllowance) revert SlashWindowNotDrained();

        uint64 agentAmount = Fee.bpsOf(applied, p.slashAgentBps);
        uint64 platformAmount = Fee.bpsOf(applied, p.slashPlatformBps);
        uint64 taken = agentAmount + platformAmount;
        // The provider KEEPS the remainder. `applied - taken` is never transferred,
        // and it is a deliberate economic property rather than an accounting leftover.
        uint64 providerAmount = applied - taken;
        // A penalty too small to divide leaves the record PENDING — this reverts, so every
        // write above is rolled back.
        if (taken == 0) revert PenaltyTooSmallToSplit();

        // --- effects ---------------------------------------------------------------------
        // The reservation is released; all of it was applied, and `applied - taken` stays with the
        // provider as its share. Checked: `reserved <= pendingSlash` (audit F R2), so a broken
        // invariant reverts rather than clamping.
        uint64 released = rec.reserved;
        s.pendingSlash -= released;

        // Unbonding first: a provider on their way out pays from the stake they were leaving
        // with.
        uint64 fromUnbonding = taken < s.unbonding ? taken : s.unbonding;
        uint64 fromBonded = taken - fromUnbonding;
        s.unbonding -= fromUnbonding;
        s.bonded -= fromBonded;
        if (s.unbonding == 0) s.unbondingStartedAt = 0;

        s.totalSlashed += taken;
        // The window meters `applied` — the gross judged — not `taken`. The anchor never moves
        // backwards: a clock that stepped back must not hand capacity to whoever noticed.
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

    /// Withdraw a pending or disputed judgement before it pays, on the
    /// ADMIN's or (since the dispute upgrade) the ARBITER's signature — the arbiter is a person's
    /// wallet, so a routine overturn no longer needs the admin key.
    ///
    /// An arbitration outcome is a human decision and the party that decided it should sign its
    /// consequence. A verifier-signed cancel would mean a leaked verifier key — the thing the
    /// whole two-phase design assumes — could void every honest judgement in flight.
    ///
    /// An earlier hardening design proposed a verifier-attested cancel instead; **the shipped
    /// Anchor code
    /// wins**, and the divergence is recorded in `docs/divergences.md`.
    ///
    /// **NOT pause-gated**: it can only release a hold, and pausing it
    /// could only extend one.
    function cancelSlash(bytes32 requestId) external nonReentrant {
        _assertCanCancel();
        _release(requestId, CancelReason.Withdrawn);
    }

    /// [`cancelSlash`] over many records, atomically (see [`_assertBatch`]).
    function cancelSlashBatch(bytes32[] calldata requestIds) external nonReentrant {
        _assertBatch(requestIds.length);
        _assertCanCancel();
        for (uint256 i = 0; i < requestIds.length; ++i) {
            _release(requestIds[i], CancelReason.Withdrawn);
        }
    }

    /// The admin or the arbiter. Before the first `setArbiter` the slot is `address(0)`, which no
    /// `msg.sender` equals; after it the arbiter can only be replaced, never unset.
    function _assertCanCancel() internal view {
        if (msg.sender != CONFIG.admin() && msg.sender != CONFIG.arbiter()) revert NotAdmin();
    }

    /// The batch forms (`disputeSlashBatch`, `upholdSlashBatch`, `cancelSlashBatch`) are
    /// **atomic**, like `AssayEscrow.redeemVoucherBatch`: each loops over the single call's own
    /// internal function, so one bad id — including a duplicate, which the second iteration's
    /// status check refuses — reverts the whole batch. Clients pre-filter with `slashRecordOf`.
    /// The caller check depends only on `msg.sender`, so it is made once per batch.
    function _assertBatch(uint256 n) internal pure {
        if (n == 0) revert EmptyBatch();
        if (n > Constants.MAX_SLASH_BATCH) revert BatchTooLarge();
    }

    /// Release a reservation nobody is going to act on. **Permissionless, and
    /// that is the whole design: a hold anybody can end is a hold nobody can extend.** Any
    /// authority that can be withheld is an authority whose holder can keep the hold in place.
    ///
    /// Three conditions, any of which is enough:
    ///
    /// - **The proposing key can no longer sign.** [`executeSlash`] will refuse it for ever, so
    ///   the reservation is dead weight the moment `revokeVerifier` lands. This is the half that
    ///   bounds what a leaked verifier key can do to a provider's exit.
    /// - **The grace period ran out.** Seven days after the judgement became executable, a
    ///   platform that has not executed its own judgement has abandoned it.
    /// - **A dispute went unresolved** (a `Disputed` record): `DISPUTE_TIMEOUT_SECONDS` after
    ///   `disputedAt` with no ruling. A disputed record does NOT expire on the grace period — the
    ///   arbiter's `upholdSlash` restarts that clock — but it does on an unusable verifier key.
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
        bool disputed = rec.status == SlashStatus.Disputed;
        if (rec.status != SlashStatus.Pending && !disputed) revert SlashNotPending();

        bool verifierUnavailable = !CONFIG.canSign(rec.verifier);
        if (!verifierUnavailable && block.timestamp < _deadline(rec)) revert SlashNotExpired();

        // The more specific fact wins when both hold: "the key is gone" tells an operator
        // something "nobody executed it" does not.
        _release(
            requestId,
            verifierUnavailable
                ? CancelReason.VerifierUnavailable
                : disputed ? CancelReason.DisputeUnresolved : CancelReason.Expired
        );
    }

    // --- the dispute (EVM only) ----------------------------------------------------------------

    event SlashDisputed(
        bytes32 indexed requestId, address indexed provider, uint64 disputedAt, uint64 executableAt
    );
    event SlashUpheld(
        bytes32 indexed requestId,
        address indexed provider,
        address indexed arbiter,
        uint64 executableAt
    );

    /// The provider contests a pending judgement inside its delay, which freezes it:
    /// `executeSlash` refuses a `Disputed` record. The reservation stays, so the dispute cannot
    /// be used to outrun the judgement with a withdrawal.
    ///
    /// **Neither pause- nor blocklist-gated**: it only protects the provider, it moves no money,
    /// and a pause (or a block) that stopped it would let the slash ripen undisputed.
    ///
    /// **Exactly one dispute per record**, explicitly: a record with `disputedAt != 0` is refused
    /// with [`SlashAlreadyDisputed`], so an upheld record whose frozen `executableAt` is still ahead
    /// cannot be disputed again.
    ///
    /// **The provider is never worse off for disputing early.** An uphold never makes the record
    /// executable before the `executableAt` frozen at proposal (`max(frozen, now)`), so the
    /// admin's window to see a forged judgement and revoke its key survives a dispute.
    function disputeSlash(bytes32 requestId) external nonReentrant {
        _dispute(requestId);
    }

    /// [`disputeSlash`] over many records, atomically (see [`_assertBatch`]). Never paused.
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

    /// The arbiter rules against the provider: the record goes back to `Pending`, executable
    /// from `max(frozen executableAt, now)` — never earlier than it would have been undisputed —
    /// and the ordinary [`executeSlash`], with its verifier re-check and the provider window, must
    /// still run inside the 7-day grace counted from that `executableAt`.
    ///
    /// **Only before the dispute timed out.** At and after `disputedAt + DISPUTE_TIMEOUT_SECONDS`
    /// this refuses [`DisputeTimedOut`] and only `expireSlash` works: the two doors share that
    /// instant with no overlap and no gap, the same convention as `executeSlash`/`expireSlash`. The arbiter chooses nothing else: amount,
    /// beneficiary and verifier are the record's. To rule FOR the provider it calls
    /// [`cancelSlash`].
    ///
    /// The arbiter is never a live verifier: `AssayConfig` refuses that at every role writer
    /// (`_assertRolesDistinct`). The only way the arbiter can equal a record's verifier is a key
    /// REVOKED after it judged, and such a record can never pay (`executeSlash` re-checks the
    /// key), so the per-record `ArbiterIsVerifier` check defended nothing and is gone (audit F
    /// R5). Not pause-gated: it moves no money, and `executeSlash` is.
    function upholdSlash(bytes32 requestId) external nonReentrant {
        _uphold(requestId, _assertArbiter());
    }

    /// [`upholdSlash`] over many records, atomically (see [`_assertBatch`]).
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

    /// **The one deadline of an open record** (audit F R1). A `Disputed` record's is
    /// `disputedAt + DISPUTE_TIMEOUT_SECONDS`, a `Pending` record's `executableAt + grace`. At
    /// and after it `executeSlash` and `upholdSlash` refuse and `expireSlash` accepts — one
    /// instant per state, no overlap and no gap. `uint256`, so a clock near `type(uint64).max`
    /// cannot make the addition panic.
    function _deadline(SlashRecord storage rec) internal view returns (uint256) {
        return rec.status == SlashStatus.Disputed
            ? uint256(rec.disputedAt) + Constants.DISPUTE_TIMEOUT_SECONDS
            : uint256(rec.executableAt) + Constants.SLASH_EXECUTION_GRACE_SECONDS;
    }

    /// The one way out of `Pending` or `Disputed` that returns the reservation whole. Each
    /// record reaches a terminal state EXACTLY once: the status check here is what makes both
    /// terminal states absorbing, and the record is never `delete`d.
    ///
    /// The reservation is released whole, never in part: a judgement is withdrawn or it is not.
    /// **Checked** (audit F R2; Anchor saturates, `cancel_slash.rs`): `pendingSlash` is
    /// the sum of the standing reservations and this one is among them, so the subtraction cannot
    /// underflow through this contract's own doors — and if that invariant ever broke, reverting
    /// is the honest answer, not a silent zero.
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

    /// The append budget the D-7 upgrade-safety gate spends.
    ///
    /// **50 → 49 for the slash records**: `slashRecords` is one mapping, one slot, and it is paid
    /// for out
    /// of here. The contract's total footprint is unchanged, which is the property the gate
    /// checks — a field appended without paying for it out of the gap moves every slot after it.
    uint256[49] private __gap;
}
