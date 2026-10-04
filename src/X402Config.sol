// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.24;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

import {ParamSet} from "./Types.sol";
import {Constants} from "./Constants.sol";
import {IX402Config} from "./interfaces/IX402Config.sol";
import "./Errors.sol";

/// Parameters, the admin, the pause flag and the verifier registry.
///
/// The port of `state.rs::Config` minus everything that is Solana bookkeeping. What was left
/// behind, and where it went:
///
/// - `stake_mint` (`state.rs:26`) — on EVM the asset is an immutable of the contract that holds
///   it, so the choice is made once at deployment of X402Stake / X402Escrow rather than stored
///   here. `initialize_config.rs:24-32` refuses Token-2022 for a reason that has an EVM analogue
///   (fee-on-transfer and hook tokens break `vault >= total_staked`); that refusal becomes a
///   decimals check and a measured-balance transfer in those contracts, not a field here.
/// - `total_staked` / `total_deposited` / `total_withdrawn` / `total_slashed` (`state.rs:95-101`)
///   — custody totals belong to the contract that holds the custody, which is X402Stake.
/// - `bump` / `vault_bump` / `_reserved` (`state.rs:103-104, 119`) — PDA artefacts. `_reserved`'s job
///   (room for a later field without a redeploy) is done here by `__gap` plus UUPS.
///
/// This contract NEVER holds a token and never gains a function that moves one. It is the
/// only shared leaf of the dependency graph, and both edges into it are views.
///
/// Deployed behind an ERC1967Proxy and upgraded through UUPS (D-1). `admin` is both the
/// parameter authority and the upgrade authority — for all three contracts, because the other
/// two read `CONFIG.admin()` live. It is a Ledger, and it is never an environment variable.
contract X402Config is Initializable, UUPSUpgradeable, IX402Config {
    /// `state.rs:23`. May change parameters, pause, enrol and revoke verifier keys, and cancel a
    /// pending judgement — **and upgrade all three contracts**, which is the one authority the
    /// Solana admin does not hold (there the upgrade authority is a separate BPF-loader key).
    address public admin;

    /// `state.rs:85`. The emergency stop, read by the doors that move money on somebody else's
    /// say-so.
    bool public override paused;

    /// The economic parameter set, stored as one struct so `params()` cannot hand a caller two
    /// fields from two different reads.
    ParamSet internal _params;

    /// `events.rs::ConfigInitialized`. Flattened to `(admin, params)`: the Anchor event lists
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
    /// `slash_provider_bps` — derived, never stored, on both chains. It is not dropped: it is
    /// `slashProviderBps()` on this contract, readable at any block, whereas the Anchor program
    /// can only put a derived value in the event. The event carries the two shares it is the
    /// complement of, so no information is lost.
    event ConfigInitialized(address indexed admin, ParamSet params);

    /// `events.rs::PauseToggled`, field names kept. `at` is `i64` on Solana and `uint64` here,
    /// matching `block.timestamp`.
    event PauseToggled(address indexed admin, bool paused, uint64 at);

    /// `events.rs::ConfigUpdated`, flattened to `(admin, params)` for the same reason
    /// [`ConfigInitialized`] is: the Anchor event lists each parameter as its own field and
    /// `ParamSet` is exactly that list.
    ///
    /// `admin` is the **post**-state — `update_config.rs:90` emits `config.admin` after the
    /// handover has landed, so on a call that hands over, this is the incoming key rather than
    /// the outgoing one that signed. `slash_provider_bps` is absent for the same reason it is
    /// absent from [`ConfigInitialized`]: derived, and readable at any block from
    /// [`slashProviderBps`].
    event ConfigUpdated(address indexed admin, ParamSet params);

    /// `set_paused.rs:33` — the `has_one = admin` constraint, raising `ErrorCode::NotAdmin`.
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

    /// `initialize_config.rs:55-109`.
    ///
    /// Was a constructor in the immutable draft; design decision D-1 makes this
    /// contract upgradeable, and a constructor writes the implementation's
    /// storage rather than the proxy's. `initializer` makes it callable exactly once — the
    /// EVM form of `init` on the singleton `["config"]` PDA, which can succeed once and then
    /// never again.
    ///
    /// `initialParams` is validated **as a whole set**, exactly as `initialize_config.rs:92`
    /// calls `config.validate()` after every field has landed rather than checking each
    /// argument as it arrives. The two split shares are only meaningful together.
    function initialize(ParamSet memory initialParams, address initialAdmin) external initializer {
        // Not a port: on Solana the admin is `Signer<'info>` and a signature by the zero key is
        // unforgeable, so `initialize_config` cannot receive one. Here it is a plain argument,
        // and a config whose admin is `address(0)` can never be paused or upgraded again.
        if (initialAdmin == address(0)) revert InvalidAdmin();
        _validate(initialParams);
        admin = initialAdmin;
        _params = initialParams;
        // `paused` is left at its zero value — `initialize_config.rs:81` writes `false`.
        emit ConfigInitialized(initialAdmin, initialParams);
    }

    /// The upgrade door. Immediate, by the same decision that leaves updateConfig immediate
    /// (D-1, D-6): the Solana upgrade authority has no timelock either.
    function _authorizeUpgrade(address) internal override onlyAdmin {}

    function params() external view override returns (ParamSet memory) {
        return _params;
    }

    /// `state.rs:127-131` — `Config::slash_provider_bps()`. **Derived, never stored**, so it
    /// cannot disagree with the two shares it is the complement of; and derived *here*, so
    /// X402Stake does not grow a second copy of the same arithmetic.
    ///
    /// Saturating, exactly as the Anchor original is, and for the reason its comment gives: an
    /// abort inside a split is the least debuggable place for a missing validation to surface.
    /// `_validate` makes `slashAgentBps + slashPlatformBps <= 10_000` true of every set that
    /// reaches storage, and **both** doors that write `_params` — `initialize` and
    /// `updateConfig` — run it before the assignment, so the saturation is unreachable today
    /// (mutation log C22). It is a belt for whatever writes `_params` next. Any future writer
    /// that skips `_validate` makes this branch live, which is the defect, not the belt. The
    /// `uint32` widening is the same one `_validate` uses, for the same overflow.
    function slashProviderBps() external view override returns (uint16) {
        uint32 taken = uint32(_params.slashAgentBps) + _params.slashPlatformBps;
        return taken >= 10_000 ? 0 : uint16(10_000 - taken);
    }

    /// `set_paused.rs:38-49`. Reversible, admin-only, and it never adds a door — it can only
    /// close one that already exists.
    function setPaused(bool value) external onlyAdmin {
        paused = value;
        emit PauseToggled(msg.sender, value, uint64(block.timestamp));
    }

    /// `update_config.rs:32-104`, one-for-one.
    ///
    /// **The shape differs and the behaviour does not.** Anchor takes eleven `Option`s, `None`
    /// meaning "leave it"; Solidity has no `Option`, so the caller sends the WHOLE set — the
    /// console reads `params()`, patches, and sends it back. What the two forms share is the
    /// property that matters: the set that ends up in storage is validated as a set.
    ///
    /// Validated once, after every field has landed (`update_config.rs:79-82`). The two split
    /// shares are only meaningful together, and a field-at-a-time check would refuse a legal
    /// move depending on the order the fields arrive in — moving `(6000, 3000)` to
    /// `(3000, 7000)` transits `(6000, 7000)` if `platform` lands first.
    ///
    /// The admin handover is one step and applied LAST (`update_config.rs:84-87`), so it cannot
    /// invalidate the checks above it mid-instruction; `address(0)` means "leave it", because
    /// the zero address is the one nobody can ever sign for. The Anchor original spends an
    /// explicit `require!(value != Pubkey::default())` on that, because `Some(default)` and
    /// `None` are distinguishable there; here they are the same value, so the sentinel *is* the
    /// refusal and `InvalidAdmin` has no producer on this path. (`initialize` keeps it — there
    /// the zero admin arrives as a plain argument with no sentinel meaning.)
    ///
    /// No timelock, no pending slot, no two-step handover, by design decision D-1 —
    /// one logic on both chains. `update_config.rs:20-21`: "a 72-hour wait for the adverse
    /// direction was built and retired because it defends against an injected transaction, not
    /// against the holder of a hardware wallet."
    ///
    /// `unbondingPeriodSeconds` re-dates every unbonding already in flight, in both directions —
    /// X402Stake's maturity check will read it live, as `ProviderStake::unbonding_matured` does
    /// (`update_config.rs:23-26`). Decide which you are doing before you sign.
    function updateConfig(ParamSet calldata p, address newAdmin) external onlyAdmin {
        ParamSet memory q = p; // `_validate` takes memory; one copy on a cold path
        _validate(q);
        _params = q;
        if (newAdmin != address(0)) admin = newAdmin;
        emit ConfigUpdated(admin, q);
    }

    /// Ported from `state.rs::Config::validate` (`state.rs:134-164`) and `validate_split`
    /// (`state.rs:168-191`), in that source's order. Every bound is a statement about a
    /// parameter that has stopped being what it is called: a 100% take rate is not a take rate,
    /// a 100% slash cap is not a cap.
    ///
    /// `penaltyAmount` is checked nowhere, deliberately: `state.rs:68-75` leaves it unbounded at
    /// both ends — `0` is on-chain shadow mode, and what bounds the damage above is
    /// `slashCapBps`, a fraction of the provider's own stake.
    function _validate(ParamSet memory p) internal pure {
        if (p.treasury == address(0)) revert MissingBeneficiary();
        if (p.redeemer == address(0)) revert MissingRedeemer();
        if (p.takeRateBps > Constants.MAX_TAKE_RATE_BPS) revert InvalidTakeRateBps();
        // `uint32` because the sum of two `uint16` overflows `uint16` — `state.rs:180` widens to
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
        if (p.verifierDailyCap == 0) revert InvalidVerifierDailyCap();
    }

    // -------------------------------------------------------------------------------------
    // the verifier registry — `register_verifier.rs`, `revoke_verifier.rs`, `state.rs:213-258`
    // -------------------------------------------------------------------------------------

    /// `state.rs:213-242`, minus two fields that are deliberately not here.
    ///
    /// - `verifier` and `bump` — Solana PDA artefacts. There the pubkey is stored *as well as*
    ///   seeded so `assert_can_sign` compares against stored state rather than the caller's
    ///   account choice; here the key IS the mapping key, so there is nothing a caller could
    ///   choose and nothing to cross-check.
    /// - `label` — written to the event and never read on chain. `register_verifier.rs:60` stores
    ///   it because a Solana account is the only place an operator can read it back; here the log
    ///   is that place. Storing it would cost a slot per key to serve a query `eth_getLogs`
    ///   already answers.
    /// - `slashed_in_window` / `slash_window_started_at` — **the per-key rolling daily cap, which
    ///   lives in X402Stake** (D-3). It is a consequence of slashing, and putting it here
    ///   would hand X402Stake write authority over this contract, which is the one property the
    ///   three-contract split exists to deny. Its absence is the design, not an omission.
    ///
    /// The two booleans are `state.rs:218`'s `status` plus the account existence Anchor gets for
    /// free, and **both are load-bearing**: `registered` is what makes enrolment one-shot, and
    /// `revoked` is what stops a key. Neither is derived from a timestamp.
    ///
    /// The first draft of this port dropped `status` and read revocation off `revokedAt != 0`, on
    /// the argument that two representations of one fact can disagree. That was wrong twice over.
    /// Anchor carries **both** `status` and `revoked_at` (`state.rs:218, 226`), so collapsing them
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
        /// `state.rs:221`. Stamped from the clock the registration ran at, and read by nothing on
        /// chain — it is the operator's and the investigator's, which is why only a whole-record
        /// assertion can see it go wrong.
        uint64 registeredAt;
        /// `state.rs:224`. When this key stops being accepted regardless of status. Always in the
        /// future at registration and never further out than `MAX_VERIFIER_KEY_LIFETIME_SECONDS`.
        uint64 expiresAt;
        /// `state.rs:226`. `0` until [`revokeVerifier`] runs, then the instant it ran — **which may
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
        /// `state.rs:218`'s `VerifierStatus` — `false` is `Active`, `true` is `Revoked`. Set once,
        /// by [`revokeVerifier`], with no edge back out (`revoke_verifier.rs:35-45`).
        bool revoked;
    }

    /// `["verifier", verifier_pubkey]` (`constants.rs:35`) as a mapping. One entry per key, never
    /// removed — `revoke_verifier.rs:35-45`: closing the account would refund the rent and free
    /// the address, at which point a key revoked during a breach can be quietly reinstated.
    ///
    /// **New storage, appended after every existing field and paid for out of `__gap`** (D-1):
    /// this contract runs behind an ERC1967 proxy, so a slot inserted above `_params` would
    /// reinterpret live state. `__gap` goes 50 → 49 in the same change.
    mapping(address => VerifierKey) internal verifiers;

    /// `events.rs:89-96`, field names kept. `label` is indexed nowhere and stored nowhere; this
    /// event is the only place it exists, which is why the whole data payload matters.
    event VerifierRegistered(
        address indexed verifier,
        address indexed admin,
        bytes32 label,
        uint64 registeredAt,
        uint64 expiresAt
    );

    /// `events.rs:98-103`, name and fields kept — including the `Event` suffix Anchor needs to
    /// avoid colliding with its `VerifierRevoked` *error*, which this codebase also has.
    event VerifierRevokedEvent(address indexed verifier, address indexed admin, uint64 revokedAt);

    /// `register_verifier.rs:44-76`. Admin-only, and deliberately not something the running
    /// backend can do: the allowlist is what makes a stolen verifier key a recoverable incident,
    /// and a service that could both sign and enrol would be enough to slash every provider. The
    /// key may sign at once — an activation delay defends only against a stolen admin key, which
    /// the threat model trusts (it is a Ledger).
    ///
    /// **Registration is one-shot, forever.** `register_verifier.rs:32-38` gets that from `init`
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
        // `register_verifier.rs:52-55`, both ends: strictly future, and no further out than the
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
        emit VerifierRegistered(verifier, msg.sender, label, nowTs, expiresAt);
    }

    /// `revoke_verifier.rs:46-68`. The emergency control, and the first step of incident response
    /// for a suspected verifier key compromise.
    ///
    /// It is deliberately NOT timelocked and deliberately irreversible. **This is the single
    /// control the two-phase slash exists to make usable**: `X402Stake.executeSlash` re-checks
    /// [`assertCanSign`] on the record's verifier at execution time, so revoking a key voids every
    /// judgement it signed that is still inside its 72-hour delay — including ones already
    /// proposed. A revocation that could be undone, or one that had to wait out a delay of its
    /// own, would give that re-check nothing to find.
    ///
    /// A second revoke is **refused rather than ignored** (`revoke_verifier.rs:50-57`): the state
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
        // revocation — deliberately: `verifierExpiry` is on `IX402Config` and
        // `X402Stake.expireSlash` reads it for a key that may well have been revoked, and the
        // registration
        // stamp is the other half of the audit trail this record exists to be. A "tidy up the
        // slot" edit here changes the reap path in `X402Stake`;
        // `test_wrongState_revocationCanNeverBeUndone` is what refuses it.
        emit VerifierRevokedEvent(verifier, msg.sender, k.revokedAt);
    }

    /// The whole entry, for operators and for the console. Reading `registered` is the only way
    /// to tell "never enrolled" from "enrolled with every field at zero", which cannot happen but
    /// is what a caller would have to assume without the flag.
    function verifierKey(address verifier) external view returns (VerifierKey memory) {
        return verifiers[verifier];
    }

    /// `state.rs:224`. Zero for an address that was never enrolled — a value no registration can
    /// produce, since `expiresAt > now` is enforced.
    function verifierExpiry(address verifier) external view override returns (uint64) {
        return verifiers[verifier].expiresAt;
    }

    /// `state.rs:248-258` as a predicate. Non-reverting, for `expireSlash`'s "the key can no
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
    /// unacceptable as one that was revoked" (`state.rs:245-247`), and the same argument makes
    /// this a conjunction rather than three checks a caller might do two of.
    ///
    /// `<=` and not `<`: `state.rs:254` is `now <= self.expires_at`, so the shared instant belongs
    /// to the key.
    function canSign(address verifier) public view override returns (bool) {
        VerifierKey storage k = verifiers[verifier];
        return k.registered && !k.revoked && block.timestamp <= k.expiresAt;
    }

    /// `state.rs:248-258`. Reverting, for `proposeSlash` and `executeSlash`, so the diagnosis
    /// survives to the caller instead of collapsing into one boolean.
    ///
    /// **The order is Anchor's** (`state.rs:249-256`): status before expiry, so a key that is both
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

    /// The append budget the D-7 upgrade-safety gate spends. Every contract here ends with
    /// one, and adding a field means shrinking it by exactly the slots the field consumes.
    ///
    /// **50 → 49 for the verifier registry**: `verifiers` is one mapping, one slot. The contract's
    /// total footprint
    /// is unchanged, which is the property the gate checks — a field appended without paying for
    /// it out of here moves every slot after it.
    uint256[49] private __gap;
}
