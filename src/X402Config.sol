// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.24;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Ownable2StepUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";

import {ParamSet} from "./Types.sol";
import {Constants} from "./Constants.sol";
import {IX402Config} from "./interfaces/IX402Config.sol";
import "./Errors.sol";

/// Parameters, the three roles (owner, admin, arbiter), the pause flag, the verifier registry,
/// the address blocklist and the slash delay.
///
/// The port of `state.rs::Config` minus everything that is Solana bookkeeping. What was left
/// behind, and where it went:
///
/// - `stake_mint` — on EVM the asset is an immutable of the contract that holds
///   it, so the choice is made once at deployment of X402Stake / X402Escrow rather than stored
///   here. `initialize_config.rs` refuses Token-2022 for a reason that has an EVM analogue
///   (fee-on-transfer and hook tokens break `vault >= total_staked`); that refusal becomes a
///   decimals check and a measured-balance transfer in those contracts, not a field here.
/// - `total_staked` / `total_deposited` / `total_withdrawn` / `total_slashed`
///   — custody totals belong to the contract that holds the custody, which is X402Stake.
/// - `bump` / `vault_bump` / `_reserved` — PDA artefacts. `_reserved`'s job
///   (room for a later field without a redeploy) is done here by `__gap` plus UUPS.
///
/// This contract NEVER holds a token and never gains a function that moves one. It is the
/// only shared leaf of the dependency graph, and both edges into it are views.
///
/// Deployed behind an ERC1967Proxy and upgraded through UUPS (D-1, amended by D-17).
///
/// # Three roles (D-17, D-19)
///
/// - **`owner()`** — OpenZeppelin's `Ownable2StepUpgradeable`, held cold (a Ledger or a Safe). It
///   is the UUPS upgrade authority of all three contracts (the other two read `CONFIG.owner()`
///   live), and it appoints the admin (`setAdmin`). It moves in two steps — `transferOwnership`
///   then `acceptOwnership` by the incoming key — and can never be renounced or become
///   `address(0)`. **It holds no door that moves a token**: no sweep, no rescue. Its one residual
///   power over user money is the upgrade itself.
/// - **`admin`** — operational and used often: `updateConfig`, `setPaused`, the verifier registry,
///   and `cancelSlash` on X402Stake. Every value it sets is bounded by `_validate`.
///   It can neither upgrade anything nor appoint its successor. It appoints the arbiter
///   (`setArbiter`), sets the slash delay (`setSlashDelay`) and the escrow's collect hold
///   (`setCollectHold`), and blocks or unblocks addresses.
/// - **`arbiter`** — a person's wallet (or a Safe), never the backend. It rules on a disputed
///   slash (`X402Stake.upholdSlash`), cancels a pending or disputed one (`cancelSlash`, beside
///   the admin) and may BLOCK an address — never unblock it. It reads `address(0)` only before
///   the first appointment; after that it is replaced, never unset. The admin, the arbiter, the
///   redeemer and the verifiers are distinct keys ([`_assertRolesDistinct`]).
///
/// The owner's storage is ERC-7201 namespaced (`openzeppelin.storage.Ownable` and
/// `openzeppelin.storage.Ownable2Step`), so adopting it appends no sequential slot.
contract X402Config is Initializable, UUPSUpgradeable, Ownable2StepUpgradeable, IX402Config {
    /// May change parameters, pause, enrol and revoke verifier keys, and cancel a
    /// pending judgement. **It is not the upgrade authority**: that is `owner()`, which is also
    /// what appoints this key (D-17).
    address public admin;

    /// The emergency stop. Since D-19 it closes every user door — deposits,
    /// redemption, the exits, limits and delegate grants — and leaves open only what releases a
    /// hold or removes authority (`revokeDelegate`, the dispute, cancel and expire doors).
    bool public override paused;

    /// The economic parameter set, stored as one struct so `params()` cannot hand a caller two
    /// fields from two different reads.
    ParamSet internal _params;

    /// Flattened to `(admin, params)`: the Anchor event lists
    /// each parameter as its own field, and `ParamSet` is exactly that list, so a decoder gets
    /// the same values under the same names one level down.
    ///
    /// **Two Anchor fields are absent, both deliberately.**
    ///
    /// `stake_mint` — on EVM the settlement asset is `X402Escrow.ASSET` / `X402Stake.ASSET`,
    /// an immutable fixed at each deployment rather than a parameter of `Config`. There is no
    /// mint for `Config` to announce, and adding one would create a second place the asset is
    /// named. Read the omission as the split, not as an oversight.
    ///
    /// `slash_provider_bps` — derived, never stored, on both chains: it is
    /// `10_000 - slashAgentBps - slashPlatformBps`. The event carries the two shares it is the
    /// complement of, so no information is lost.
    event ConfigInitialized(address indexed admin, ParamSet params);

    /// `events.rs::PauseToggled`, field names kept. `at` is `i64` on Solana and `uint64` here,
    /// matching `block.timestamp`.
    event PauseToggled(address indexed admin, bool paused, uint64 at);

    /// `events.rs::ConfigUpdated`, flattened to `(admin, params)` for the same reason
    /// [`ConfigInitialized`] is: the Anchor event lists each parameter as its own field and
    /// `ParamSet` is exactly that list.
    ///
    /// `admin` is the admin that signed. `slash_provider_bps` is absent for the same reason it is
    /// absent from [`ConfigInitialized`]: derived from the two shares the event carries.
    event ConfigUpdated(address indexed admin, ParamSet params);

    /// The owner replaced the admin.
    event AdminSet(address indexed previousAdmin, address indexed newAdmin);

    /// `set_paused.rs` — the `has_one = admin` constraint, raising `ErrorCode::NotAdmin`.
    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    /// The implementation is never initialised and never usable on its own. Without this,
    /// anybody may call `initialize` on the implementation, become its admin, and (for a
    /// UUPS implementation) call `upgradeToAndCall` on it directly.
    constructor() {
        _disableInitializers();
    }

    /// An initialiser rather than a constructor because the contract is upgradeable (D-1), and a
    /// constructor writes the implementation's storage rather than the proxy's. `initializer`
    /// makes it callable exactly once — the EVM form of `init` on the singleton `["config"]` PDA,
    /// which can succeed once and then never again.
    ///
    /// `initialParams` is validated **as a whole set**, exactly as `initialize_config.rs`
    /// calls `config.validate()` after every field has landed rather than checking each
    /// argument as it arrives. The two split shares are only meaningful together.
    ///
    /// **A fresh deployment names both roles, and neither may be the deployer's to keep.**
    ///
    /// **Initializer versions.** All three contracts start at version 1 (plain `initializer`) on
    /// a fresh proxy. The first upgrade that needs an initialiser call therefore uses
    /// `reinitializer(2)`, the next `reinitializer(3)`, and so on: a reused number reverts
    /// `InvalidInitialization` inside the upgrade's `upgradeToAndCall`.
    function initialize(ParamSet memory initialParams, address initialAdmin, address initialOwner)
        external
        initializer
    {
        // Not a port: on Solana the admin is `Signer<'info>` and a signature by the zero key is
        // unforgeable, so `initialize_config` cannot receive one. Here it is a plain argument,
        // and a config whose admin is `address(0)` can never be paused or upgraded again.
        if (initialAdmin == address(0)) revert InvalidAdmin();
        // `__Ownable_init` refuses `address(0)` with `OwnableInvalidOwner(0)`.
        __Ownable_init(initialOwner);
        _validate(initialParams);
        admin = initialAdmin;
        _params = initialParams;
        // `paused` is left at its zero value — `initialize_config.rs` writes `false`.
        emit ConfigInitialized(initialAdmin, initialParams);
    }

    /// The upgrade door, for this contract — and through `CONFIG.owner()` for the other two.
    /// Immediate, with no timelock (D-1); the authority is the owner (D-17).
    function _authorizeUpgrade(address) internal override onlyOwner {}

    /// `Ownable.owner()`, re-declared only because `IX402Config` names it as well.
    function owner() public view override(OwnableUpgradeable, IX402Config) returns (address) {
        return super.owner();
    }

    /// Disabled. `Ownable2Step` already makes an accidental hand-over to a wrong address
    /// recoverable (the wrong address never accepts); renouncing is the one move that is not, so
    /// it does not exist here.
    function renounceOwnership() public pure override {
        revert OwnershipCannotBeRenounced();
    }

    /// The owner appoints (or replaces) the admin, in one step: the owner is the recovery path if
    /// the address is wrong, which is what the single-key D-6 handover never had.
    /// The new admin may not hold another role ([`_assertRolesDistinct`]).
    function setAdmin(address newAdmin) external onlyOwner {
        if (newAdmin == address(0)) revert InvalidAdmin();
        emit AdminSet(admin, newAdmin);
        admin = newAdmin;
        _assertRolesDistinct();
    }

    /// **The one place the role table lives** (audit F R5): the admin is not a live verifier; the
    /// arbiter, once appointed, is neither the admin, nor the redeemer, nor a live verifier.
    /// "Live" is registered and not revoked — an expired key is still live here, so it cannot be
    /// re-used in another role. Called at the END of every writer of a role or of the redeemer
    /// (`setAdmin`, `setArbiter`, `registerVerifier`, `updateConfig`), so a refusal rolls the
    /// write back. A rule added later goes here and nowhere else.
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

    function params() external view override returns (ParamSet memory) {
        return _params;
    }

    /// Reversible, admin-only, and it never adds a door — it can only
    /// close one that already exists.
    function setPaused(bool value) external onlyAdmin {
        paused = value;
        emit PauseToggled(msg.sender, value, uint64(block.timestamp));
    }

    /// `update_config.rs`, one-for-one.
    ///
    /// **The shape differs and the behaviour does not.** Anchor takes eleven `Option`s, `None`
    /// meaning "leave it"; Solidity has no `Option`, so the caller sends the WHOLE set — the
    /// console reads `params()`, patches, and sends it back. What the two forms share is the
    /// property that matters: the set that ends up in storage is validated as a set.
    ///
    /// Validated once, after every field has landed. The two split
    /// shares are only meaningful together, and a field-at-a-time check would refuse a legal
    /// move depending on the order the fields arrive in — moving `(6000, 3000)` to
    /// `(3000, 7000)` transits `(6000, 7000)` if `platform` lands first.
    ///
    /// No timelock, no pending slot, no two-step handover, by design decision D-1 —
    /// one logic on both chains. `update_config.rs`: "a 72-hour wait for the adverse
    /// direction was built and retired because it defends against an injected transaction, not
    /// against the holder of a hardware wallet."
    ///
    /// `unbondingPeriodSeconds` re-dates every unbonding already in flight, in both directions —
    /// X402Stake's maturity check will read it live, as `ProviderStake::unbonding_matured` does.
    /// Decide which you are doing before you sign.
    ///
    /// It never moves the admin: appointing the admin is the owner's `setAdmin` (D-17).
    function updateConfig(ParamSet calldata p) external onlyAdmin {
        ParamSet memory q = p; // `_validate` takes memory; one copy on a cold path
        _validate(q);
        _params = q;
        _assertRolesDistinct(); // the redeemer is never the arbiter
        emit ConfigUpdated(admin, q);
    }

    /// Ported from `state.rs::Config::validate` and `validate_split`,
    /// in that source's order. Every bound is a statement about a
    /// parameter that has stopped being what it is called: a 100% take rate is not a take rate,
    /// a 100% slash cap is not a cap.
    ///
    /// `penaltyAmount` has no bound of its own: `0` is on-chain shadow mode.
    /// Its only ceiling is the cross-check against `verifierDailyCap` below (audit C7).
    ///
    /// Parameters only. The role table (the redeemer is not the arbiter) is
    /// [`_assertRolesDistinct`]'s, and the slash delay is no longer coupled to the unbonding
    /// period (audit F R3): a proposed penalty is held by `pendingSlash` however long the delay,
    /// so only the breach-to-proposal leg needs `MIN_UNBONDING_PERIOD_SECONDS`.
    function _validate(ParamSet memory p) internal pure {
        if (p.treasury == address(0)) revert MissingBeneficiary();
        if (p.redeemer == address(0)) revert MissingRedeemer();
        if (p.takeRateBps > Constants.MAX_TAKE_RATE_BPS) revert InvalidTakeRateBps();
        // `uint32` because the sum of two `uint16` overflows `uint16` — `state.rs` widens to
        // `u32` for the same reason. Checked arithmetic would panic rather than revert with the
        // name, and a `Panic(0x11)` is not the diagnosis an operator needs.
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
        // A provider at the minimum must fit two maximal records in one provider-day (the
        // provider-side twin of G-1): with all or wait, a record that fills the whole cap pays
        // only on an empty window, so one small execution a day starves it until it expires.
        // With a penalty above 0 this also keeps that cap allowance above 0; a penalty of 0
        // (shadow mode) slashes nothing, so it needs no allowance.
        if (
            uint256(p.minimumStake) * p.slashCapBps / Constants.BPS_DENOMINATOR
                < 2 * uint256(p.penaltyAmount)
        ) {
            revert InvalidMinimumStake();
        }
        if (p.verifierDailyCap == 0) revert InvalidVerifierDailyCap();
        // At least two maximal judgements must fit in one key-day (audit G G-1): with all or
        // wait, a cap of one penalty lets a single record fill the day and crowd out the next.
        // `uint256`, so a large `penaltyAmount` cannot overflow the doubling.
        if (uint256(p.verifierDailyCap) < 2 * uint256(p.penaltyAmount)) {
            revert InvalidVerifierDailyCap();
        }
    }

    // -------------------------------------------------------------------------------------
    // the verifier registry — `register_verifier.rs`, `revoke_verifier.rs`, `state.rs`
    // -------------------------------------------------------------------------------------

    /// `state.rs`, minus two fields that are deliberately not here.
    ///
    /// - `verifier` and `bump` — Solana PDA artefacts. There the pubkey is stored *as well as*
    ///   seeded so `assert_can_sign` compares against stored state rather than the caller's
    ///   account choice; here the key IS the mapping key, so there is nothing a caller could
    ///   choose and nothing to cross-check.
    /// - `label` — written to the event and never read on chain. `register_verifier.rs` stores
    ///   it because a Solana account is the only place an operator can read it back; here the log
    ///   is that place. Storing it would cost a slot per key to serve a query `eth_getLogs`
    ///   already answers.
    /// - `slashed_in_window` / `slash_window_started_at` — **the per-key rolling daily cap, which
    ///   lives in X402Stake** (D-3). It is a consequence of slashing, and putting it here
    ///   would hand X402Stake write authority over this contract, which is the one property the
    ///   three-contract split exists to deny. Its absence is the design, not an omission.
    ///
    /// The two booleans are `state.rs`'s `status` plus the account existence Anchor gets for
    /// free, and **both are load-bearing**: `registered` is what makes enrolment one-shot, and
    /// `revoked` is what stops a key. Neither is derived from a timestamp.
    ///
    /// The first draft of this port dropped `status` and read revocation off `revokedAt != 0`, on
    /// the argument that two representations of one fact can disagree. That was wrong twice over.
    /// Anchor carries **both** `status` and `revoked_at`, so collapsing them
    /// is the divergence, not the parity; and the collapse put the whole control on a sentinel
    /// that `0` is a legal stamp for — at `block.timestamp == 0` `revokeVerifier` wrote
    /// `revokedAt = 0` and the revocation was a silent no-op, as a review measured.
    /// `revoked` restores the reference's shape and closes that at every clock. `revokedAt` is now
    /// what its Anchor twin is: the recorded instant, evidence for an investigator, read by no
    /// predicate.
    ///
    /// All five fields pack into **one** slot (8 + 8 + 8 + 1 + 1 = 26 bytes), so a registration is
    /// one `SSTORE` and `canSign` is one `SLOAD`. That follows from `state.rs`'s own field order;
    /// reordering costs gas on the hottest read in the slash path.
    struct VerifierKey {
        /// Stamped from the clock the registration ran at, and read by nothing on
        /// chain — it is the operator's and the investigator's, which is why only a whole-record
        /// assertion can see it go wrong.
        uint64 registeredAt;
        /// When this key stops being accepted regardless of status. Always in the
        /// future at registration and never further out than `MAX_VERIFIER_KEY_LIFETIME_SECONDS`.
        uint64 expiresAt;
        /// `0` until [`revokeVerifier`] runs, then the instant it ran — **which may
        /// itself be `0`**, at genesis. Written once and never cleared. Evidence, not a predicate:
        /// `revoked` is the predicate.
        uint64 revokedAt;
        /// **No Anchor counterpart, and it carries the property that account had.** On Solana
        /// "this address was never enrolled" is the absence of the `["verifier", pubkey]` PDA, and
        /// `register_verifier`'s `init` is what makes enrolment one-shot. A Solidity mapping has
        /// no absence — every unread slot reads back as zeros — so the flag has to exist, and it
        /// is what `registerVerifier` keys its refusal on. Once true it is never set false again:
        /// that is what makes revocation a one-way door, because a revoked address can never be
        /// enrolled a second time.
        bool registered;
        /// `state.rs`'s `VerifierStatus` — `false` is `Active`, `true` is `Revoked`. Set once,
        /// by [`revokeVerifier`], with no edge back out.
        bool revoked;
    }

    /// `["verifier", verifier_pubkey]` as a mapping. One entry per key, never
    /// removed — `revoke_verifier.rs`: closing the account would refund the rent and free
    /// the address, at which point a key revoked during a breach can be quietly reinstated.
    ///
    /// **New storage, appended after every existing field and paid for out of `__gap`** (D-1):
    /// this contract runs behind an ERC1967 proxy, so a slot inserted above `_params` would
    /// reinterpret live state. `__gap` goes 50 → 49 in the same change.
    mapping(address => VerifierKey) internal verifiers;
    /// `events.rs`, field names kept. `label` is indexed nowhere and stored nowhere; this
    /// event is the only place it exists, which is why the whole data payload matters.

    event VerifierRegistered(
        address indexed verifier,
        address indexed admin,
        bytes32 label,
        uint64 registeredAt,
        uint64 expiresAt
    );

    /// `events.rs`, name and fields kept — including the `Event` suffix Anchor needs to
    /// avoid colliding with its `VerifierRevoked` *error*, which this codebase also has.
    event VerifierRevokedEvent(address indexed verifier, address indexed admin, uint64 revokedAt);

    /// Admin-only, and deliberately not something the running
    /// backend can do: the allowlist is what makes a stolen verifier key a recoverable incident,
    /// and a service that could both sign and enrol would be enough to slash every provider. The
    /// key may sign at once — an activation delay defends only against a stolen admin key, which
    /// the threat model trusts (it is a Ledger).
    ///
    /// **Registration is one-shot, forever.** `register_verifier.rs` gets that from `init`
    /// on a PDA that nothing closes; here it is the `registered` flag, which no path clears. That
    /// is what makes [`revokeVerifier`] terminal rather than a pause, and it means rotation is
    /// always a NEW address — never this one re-enrolled with a later expiry.
    ///
    /// Not gated on [`paused`], exactly as the Anchor instruction is not: this moves no money.
    function registerVerifier(address verifier, bytes32 label, uint64 expiresAt)
        external
        onlyAdmin
    {
        // Not a port: on Solana a `Pubkey::default()` verifier would still get a PDA and would
        // simply be a key nobody can sign for. Here `address(0)` is the value every uninitialised
        // slot and every failed `ecrecover` produces, so enrolling it would make a recovery
        // failure look like a registered verifier at the `X402Stake` call site.
        if (verifier == address(0)) revert ZeroAddress();
        if (verifiers[verifier].registered) revert VerifierAlreadyRegistered();

        uint64 nowTs = uint64(block.timestamp);
        // `register_verifier.rs`, both ends: strictly future, and no further out than the
        // rotation ceiling. The ceiling is computed in `uint256` because Anchor adds it with
        // `saturating_add` — a clock close enough to the end of the type makes the ceiling stop
        // binding there, where Solidity's checked `+` would panic with `Panic(0x11)` instead of
        // either admitting or naming a reason. `expiresAt` is `uint64`, so the widened comparison
        // admits exactly what the saturating one does.
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
        _assertRolesDistinct(); // never the admin or the arbiter
        emit VerifierRegistered(verifier, msg.sender, label, nowTs, expiresAt);
    }

    /// The emergency control, and the first step of incident response
    /// for a suspected verifier key compromise.
    ///
    /// It is deliberately NOT timelocked and deliberately irreversible. **This is the single
    /// control the two-phase slash exists to make usable**: `X402Stake.executeSlash` re-checks
    /// [`assertCanSign`] on the record's verifier at execution time, so revoking a key voids every
    /// judgement it signed that is still inside its slash delay — including ones already
    /// proposed. A revocation that could be undone, or one that had to wait out a delay of its
    /// own, would give that re-check nothing to find.
    ///
    /// A second revoke is **refused rather than ignored**: the state
    /// is already what the operator wanted, so nothing is at risk either way, but `revokedAt` is
    /// when the key stopped being trusted, and a silent overwrite would move that timestamp
    /// forward past the window an investigator is trying to bound.
    ///
    /// Expiry is not consulted. An already-expired key may still be revoked, and should be: the
    /// stamp is evidence, and `assertCanSign` will then name the revocation rather than the lapse.
    function revokeVerifier(address verifier) external onlyAdmin {
        VerifierKey storage k = verifiers[verifier];
        // Checked before `revoked`, because a never-enrolled address reads back `revoked == false`
        // and would otherwise be diagnosed as an active key.
        if (!k.registered) revert VerifierNotRegistered();
        if (k.revoked) revert VerifierAlreadyRevoked();
        k.revoked = true;
        k.revokedAt = uint64(block.timestamp);
        // Nothing else in this function writes. `registeredAt` and `expiresAt` SURVIVE a
        // revocation — deliberately: they are the audit trail (when the key was trusted, and
        // until when it would have been), readable through `verifierKey`.
        // `test_wrongState_revocationCanNeverBeUndone` is what refuses a "tidy up" edit here.
        emit VerifierRevokedEvent(verifier, msg.sender, k.revokedAt);
    }

    /// The whole entry, for operators and for the console. Reading `registered` is the only way
    /// to tell "never enrolled" from "enrolled with every field at zero", which cannot happen but
    /// is what a caller would have to assume without the flag.
    function verifierKey(address verifier) external view returns (VerifierKey memory) {
        return verifiers[verifier];
    }

    /// `state.rs` as a predicate. Non-reverting, for `expireSlash`'s "the key can no
    /// longer sign" branch, which needs the answer rather than a revert.
    ///
    /// **Every conjunct is a stored flag or the stored expiry — none is inferred from another
    /// field being zero.** `registered` is not `expiresAt != 0` and `revoked` is not
    /// `revokedAt != 0`, even though each pair agrees on every state this contract can reach
    /// today. `test_theTwoFlagsAreLoadBearingAtEveryDoor` constructs, with `vm.store`, the states
    /// where they disagree — which is what a future writer of this struct, or a layout change,
    /// would produce.
    ///
    /// **All three conditions, in one place.** Anchor puts expiry inside `assert_can_sign` rather
    /// than at the call site "because a key that outlived its registration is exactly as
    /// unacceptable as one that was revoked", and the same argument makes
    /// this a conjunction rather than three checks a caller might do two of.
    ///
    /// `<=` and not `<`: `state.rs` is `now <= self.expires_at`, so the shared instant belongs
    /// to the key.
    function canSign(address verifier) public view override returns (bool) {
        VerifierKey storage k = verifiers[verifier];
        return k.registered && !k.revoked && block.timestamp <= k.expiresAt;
    }

    /// Reverting, for `proposeSlash` and `executeSlash`, so the diagnosis
    /// survives to the caller instead of collapsing into one boolean.
    ///
    /// **The order is Anchor's**: status before expiry, so a key that is both
    /// revoked and expired reverts [`VerifierRevoked`]. `VerifierNotRegistered` comes first and has
    /// no Anchor counterpart — there the account's absence is the refusal, before the handler runs.
    ///
    /// `k.revoked`, not `k.revokedAt != 0`: see the struct. A key revoked at `block.timestamp == 0`
    /// stamps `revokedAt = 0`, and under the sentinel spelling that revocation was a no-op.
    function assertCanSign(address verifier) external view override {
        VerifierKey storage k = verifiers[verifier];
        if (!k.registered) revert VerifierNotRegistered();
        if (k.revoked) revert VerifierRevoked();
        if (block.timestamp > k.expiresAt) revert VerifierKeyExpired();
    }

    // -------------------------------------------------------------------------------------
    // the dispute upgrade — arbiter, slash delay, blocklist (EVM only)
    // -------------------------------------------------------------------------------------

    /// The arbiter (see the contract header). Appended storage, paid for out of `__gap`.
    address public override arbiter;

    /// The admin-set slash delay; `0` means never set, which reads back as the default. Packed
    /// beside `arbiter`, one slot for both.
    uint64 internal _slashDelaySeconds;

    /// The blocklist. One mapping, one slot. Read by the money contracts through
    /// [`assertActive`]; nothing here can move a blocked party's funds.
    ///
    /// **It binds the SUBJECTS of a door — buyer, payer, payee (provider), delegate, provider,
    /// funder — never the operators around them**: not a relayer landing a `…BySig`, not the
    /// redeemer or a keeper calling `proposeSlash` / `executeSlash` / `expireSlash`, not the slash
    /// beneficiary or the treasury, not the admin or the arbiter, and **not the verifier**.
    /// Blocking a verifier address does not stop its signatures: a forging verifier is stopped
    /// only by `revokeVerifier`, which is admin-only. The arbiter's own tool against a forged
    /// slash is `X402Stake.cancelSlash`.
    mapping(address => bool) internal _blocked;

    event ArbiterSet(address indexed previousArbiter, address indexed newArbiter);
    event SlashDelaySet(uint64 previousDelay, uint64 newDelay);
    event BlockedSet(address indexed account, bool blocked, address indexed by);

    /// **`address(0)` is refused**: with no arbiter a dispute is a free 30-day veto (audit A
    /// M-2). A lost or compromised arbiter is REPLACED, never removed. (Before the first
    /// appointment the slot reads `address(0)`; the runbook appoints it in the upgrade session.)
    ///
    /// The arbiter is a separate person: never the admin, the redeemer or a live verifier
    /// ([`_assertRolesDistinct`], `InvalidArbiter`).
    function setArbiter(address newArbiter) external onlyAdmin {
        if (newArbiter == address(0)) revert InvalidArbiter();
        emit ArbiterSet(arbiter, newArbiter);
        arbiter = newArbiter;
        _assertRolesDistinct();
    }

    /// The delay a NEW proposal waits before `executeSlash`, and so the provider's dispute
    /// window. A record already proposed keeps the `executableAt` frozen into it.
    ///
    /// Reads back as `Constants.SLASH_DELAY_SECONDS` until set, so an upgraded proxy keeps 72
    /// hours with no initializer call.
    function slashDelaySeconds() public view override returns (uint64) {
        uint64 d = _slashDelaySeconds;
        return d == 0 ? Constants.SLASH_DELAY_SECONDS : d;
    }

    /// Fixed bounds, `[MIN_SLASH_DELAY_SECONDS, MAX_SLASH_DELAY_SECONDS]` (10 min to 22 days),
    /// independent of the unbonding period (audit F R3): once proposed, a penalty is held by
    /// `pendingSlash` and no unbonding exit can take it, however long the delay
    /// (`test_longDelayShortUnbondingCannotBeOutrun`).
    function setSlashDelay(uint64 newDelay) external onlyAdmin {
        if (
            newDelay < Constants.MIN_SLASH_DELAY_SECONDS
                || newDelay > Constants.MAX_SLASH_DELAY_SECONDS
        ) revert InvalidSlashDelay();
        emit SlashDelaySet(slashDelaySeconds(), newDelay);
        _slashDelaySeconds = newDelay;
    }

    function blocked(address account) external view override returns (bool) {
        return _blocked[account];
    }

    /// The admin blocks and unblocks; the arbiter may only block. Blocking stops the address at
    /// every door [`assertActive`] guards and moves none of its money.
    function setBlocked(address account, bool value) external {
        if (msg.sender != admin) {
            if (msg.sender != arbiter) revert NotAdmin();
            if (!value) revert ArbiterCannotUnblock();
        }
        if (account == address(0)) revert ZeroAddress();
        _blocked[account] = value;
        emit BlockedSet(account, value, msg.sender);
    }

    /// The one check the money contracts make at every door the pause or the blocklist closes:
    /// not paused, and none of up to three parties blocked. Unused slots are `address(0)`, which
    /// can never be blocked.
    function assertActive(address a, address b, address c) external view override {
        if (paused) revert ProgramPaused();
        if (_blocked[a] || _blocked[b] || _blocked[c]) revert AddressBlocked();
    }

    // -------------------------------------------------------------------------------------
    // redeem into hold — the collect hold (EVM only)
    // -------------------------------------------------------------------------------------

    /// The admin-set collect hold; `0` means never set, which reads back as the default.
    /// Appended storage, paid for out of `__gap`.
    uint64 internal _collectHoldSeconds;

    event CollectHoldSet(uint64 previous, uint64 next);

    /// How long `X402Escrow` keeps a NEW redemption in `held` before the redeemer may collect it
    /// to the provider, and so how long a buyer dispute can still be refunded for certain. A
    /// record already held keeps the `collectableAt` frozen into it.
    ///
    /// Reads back as `Constants.DEFAULT_COLLECT_HOLD_SECONDS` until set, so an upgraded proxy
    /// holds for an hour with no initializer call (the [`slashDelaySeconds`] pattern).
    function collectHoldSeconds() public view override returns (uint64) {
        uint64 h = _collectHoldSeconds;
        return h == 0 ? Constants.DEFAULT_COLLECT_HOLD_SECONDS : h;
    }

    /// Fixed bounds, `[MIN_COLLECT_HOLD_SECONDS, MAX_COLLECT_HOLD_SECONDS]` (1 min to 1 day). A
    /// stolen admin key can shorten the hold to a minute, never to zero, and it moves no money:
    /// the refund stays open until `collectableAt + HELD_TIMEOUT_SECONDS` whatever the hold.
    function setCollectHold(uint64 newHold) external onlyAdmin {
        if (
            newHold < Constants.MIN_COLLECT_HOLD_SECONDS
                || newHold > Constants.MAX_COLLECT_HOLD_SECONDS
        ) revert InvalidCollectHold();
        emit CollectHoldSet(collectHoldSeconds(), newHold);
        _collectHoldSeconds = newHold;
    }

    /// The append budget the D-7 upgrade-safety gate spends. Every contract here ends with
    /// one, and adding a field means shrinking it by exactly the slots the field consumes.
    ///
    /// **50 → 49 for the verifier registry**: `verifiers` is one mapping, one slot. The contract's
    /// total footprint
    /// is unchanged, which is the property the gate checks — a field appended without paying for
    /// it out of here moves every slot after it.
    ///
    /// **Unchanged by D-17**: the owner role's storage is ERC-7201 namespaced
    /// (`openzeppelin.storage.Ownable`, `openzeppelin.storage.Ownable2Step`), not a slot here.
    ///
    /// **49 → 47 for the dispute upgrade**: `arbiter` + `_slashDelaySeconds` share one slot and
    /// `_blocked` is one mapping slot.
    ///
    /// **47 → 46 for the redeem-into-hold change**: `_collectHoldSeconds` takes one slot (the
    /// `arbiter` slot has 4 bytes left, too few for a `uint64`).
    uint256[46] private __gap;
}
