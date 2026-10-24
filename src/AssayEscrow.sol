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

/// Buyer money. One contract holds every buyer's USDG in one pooled balance, with per-buyer
/// accounting in storage. Money leaves a buyer's balance through exactly two doors —
/// `redeemVoucher` (and its batch), which needs an EIP-712 voucher over an exact amount for an
/// exact request, signed by the payer's own key or by a delegate key the payer authorised on
/// chain within caps, and `withdraw()`, which is msg.sender-only.
///
/// **A redemption pays nobody at once: it moves the amount into a HELD record** (`held`,
/// "redeem into hold"). The record leaves `Held` exactly once — `collectHeld` pays the provider
/// and the treasury the split frozen at redemption, `refundHeld` returns the whole amount to the
/// buyer's balance. The redeemer may collect from `collectableAt` and refund until
/// `collectableAt + HELD_TIMEOUT_SECONDS`; after that ANYBODY may collect, in the provider's
/// favour. Neither door can aim the money: the provider is the signed voucher's and the treasury
/// is Config's.
///
/// **No role — not the owner, not the admin, not the redeemer — has a door that moves a token to
/// an address of its choosing**; the owner's only residual power over this money is the upgrade
/// itself (D-17, `test/NoTokenDoors.t.sol`). There is no `closeEscrow`: closing would have to
/// clear `heldPayments`, the per-seq record that refuses a replay, and so replay every
/// in-window voucher.
///
/// # What this is a port of
///
/// `state.rs::BuyerEscrow` plus the *absence* of `open_escrow.rs`. On
/// Solana an escrow is an account that has to be created before it can be funded, and
/// `handle_open_escrow` writes ten explicit zeroes into it. Here the
/// EVM's default storage is those ten zeroes, so the instruction has no body left: a mapping
/// entry that has never been written reads as an escrow with both limits at `0`, which
/// `state.rs` defines as **refuse every voucher**. `open_escrow.rs`'s one
/// authority check — a bare identity may open a *disarmed* escrow, only the buyer's own
/// signature may open an armed one — therefore has nothing to guard at open time and moves
/// wholly to `setLimits`, whose authority IS `msg.sender`. Its meta-transaction twin
/// `setLimitsBySig` re-proves that authority from an EIP-712 signature. (So
/// `EscrowLimitsRequireBuyer` has no EVM condition — see the `Errors.sol` header.)
///
/// **Three `BuyerEscrow` fields are deliberately absent.** `buyer` is the
/// mapping key, so storing it again would be a second source for one identity. `bump`
/// is a PDA artefact. `_reserved: [u8; 32]` is Solana's
/// version of `__gap`, and this contract has a real one — plus UUPS, which Solana's reserve
/// exists precisely because it lacks.
///
/// **Two fields are additions with no Anchor counterpart.** `balance` and `totalFunded`: on
/// Solana a buyer's balance *is* the lamport-level token balance of their escrow ATA, and there
/// is no per-buyer number to keep because there is a per-buyer account. Pooling every buyer into
/// one contract is what makes the number necessary. `authNonce` is the third — a
/// meta-transaction replay counter that ed25519-instruction-based Solana does not need.
///
/// Deployed behind an ERC1967Proxy and upgraded through UUPS (D-1). The proxy address is
/// the EIP-712 `verifyingContract`, so an UPGRADE keeps every outstanding voucher valid and
/// only a REDEPLOY — a new proxy — invalidates them (D-7).
///
/// The plain (non-upgradeable) OZ 5.1.0 EIP712 and ReentrancyGuard are used deliberately and
/// are proxy-safe: `_domainSeparatorV4()` rebuilds whenever `address(this) != _cachedThis`, so
/// the separator is the PROXY's; `nonReentrant` tests `_status == ENTERED`, so the zero slot a
/// proxy starts with reads as NOT_ENTERED. D-1 carries the full argument and the two edges.
contract AssayEscrow is Initializable, UUPSUpgradeable, EIP712, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// Four slots per buyer, exactly. Asserted by `script/check-layout.sh`, which fails the
    /// build if `numberOfBytes` is anything but 128 — the packing is load-bearing (D-4),
    /// not incidental, because every redeem writes three of these fields at once.
    ///
    /// The field order is the packing, and the packing is the reason each field has the width it
    /// has: cumulative counters are `uint128` (they are sums of many amounts and must not be
    /// able to wrap where an amount cannot), everything an instruction takes as an argument or
    /// compares against a clock is `uint64`.
    struct Escrow {
        uint128 balance; //            slot 0
        uint64 seqHigh; //              ↑ highest seq redeemed; the gap cap's anchor (D-23)
        uint64 authNonce; //            ↑ meta-transaction nonce — EVM only
        uint64 maxVoucherAmount; //    slot 1   0 = refuse every redeem (state.rs)
        uint64 maxPerWindow; //         ↑       0 = refuse every redeem (state.rs)
        uint64 spentInWindow; //        ↑                               (state.rs)
        uint64 windowStartedAt; //      ↑                               (state.rs)
        uint64 withdrawRequested; //   slot 2                           (state.rs)
        uint64 withdrawAvailableAt; //  ↑                               (state.rs)
        uint128 totalRedeemed; //       ↑                               (state.rs)
        uint128 totalWithdrawn; //     slot 3                           (state.rs)
        uint128 totalFunded; //         ↑ EVM only — see the contract note above
    }

    /// A payer's grant to one DELEGATE key: the delegate may sign vouchers on the payer's escrow,
    /// and nothing else. Two slots. The caps are the delegate's own and are applied IN ADDITION
    /// to the escrow's — a delegate-signed voucher must clear both — with its own rolling
    /// window, decayed by the same [`Window.decay`] as the escrow's.
    ///
    /// `validUntil == 0` is "never authorised"; an authorisation always writes a future instant,
    /// so the zero value of an unread entry is exactly that. `listPosition` is the 1-based index
    /// in `delegateList[payer]`, `0` when the delegate is not listed (never authorised, or
    /// revoked). The window counters survive a revocation and a re-authorisation, so revoking
    /// and re-granting inside one window hands the delegate no fresh capacity.
    ///
    /// A revocation sets `revoked` at once and leaves the other fields alone; the grant keeps
    /// redeeming for `TIGHTEN_DELAY` after it, timed by `priorDelegateCaps` (see
    /// [`_revokeDelegate`]).
    struct Delegation {
        uint64 maxVoucherAmount; //    slot 0
        uint64 maxPerWindow; //         ↑
        uint64 spentInWindow; //        ↑
        uint64 windowStartedAt; //      ↑
        uint64 validUntil; //          slot 1
        uint32 listPosition; //         ↑
        bool revoked; //                ↑
    }

    /// Ordinary storage, written once in `initialize` and never again — the standard,
    /// upgrade-safe shape (D-1). The UPPER_SNAKE_CASE names are kept from the pre-proxy draft,
    /// where these were immutables.
    IAssayConfig public CONFIG;
    IAssayStakeView public STAKE;
    IERC20 public ASSET;

    /// `internal` rather than `public` because the generated getter for a struct-valued mapping
    /// returns a flattened tuple, which reorders silently when a field is appended. [`escrowOf`]
    /// returns the struct, so a caller decoding it breaks loudly instead.
    mapping(address => Escrow) internal escrows;

    /// The solvency counter — `Config.total_deposited` minus its withdrawals, in the contract
    /// that holds the custody rather than in Config (`state.rs` keeps the stake totals on
    /// Solana's Config; AssayConfig.sol's header records why the EVM split puts them here).
    ///
    /// Solvency is NEVER derived from `ASSET.balanceOf(address(this))`: USDG is an upgradeable
    /// Paxos proxy with a blocklist, and a blocklisted contract's `balanceOf` and its
    /// entitlements would disagree — a `balanceOf`-based assertion would then refuse *every*
    /// withdrawal rather than the one actually blocked.
    uint128 public totalEscrowed;

    /// `payer → delegate → grant`. Appended for agent delegation: a new slot BEFORE `__gap`,
    /// which shrank by exactly the two slots these two mappings take (D-7).
    mapping(address => mapping(address => Delegation)) internal delegations;

    /// The delegates a payer currently holds (authorised and not revoked; an expired one stays
    /// until revoked), so an off-chain reader can enumerate them without scanning logs. Bounded
    /// by `Constants.MAX_DELEGATES_PER_PAYER`.
    mapping(address => address[]) internal delegateList;

    /// Caps a payer LOWERED, still honoured until `until` ("signed means collectable"). One slot.
    /// While `now <= until` a voucher passes if it fits the current pair of caps OR this pair,
    /// each pair checked whole ([`_heldRefusal`]), so a voucher that was valid when the payer
    /// tightened stays redeemable for `TIGHTEN_DELAY` (10,800 s), longer than any voucher lives
    /// (7,620 s). A delegate's hold never runs past the grant's `validUntil` before the change.
    /// Raising a cap takes effect at once. Every write emits [`CapsHeld`].
    struct PriorCaps {
        uint64 maxVoucherAmount;
        uint64 maxPerWindow;
        uint64 until;
    }

    /// `payer → caps before the last lowering of the escrow's limits`. Appended before `__gap`,
    /// which shrank by the two slots this mapping and the next take (D-7).
    mapping(address => PriorCaps) internal priorEscrowCaps;

    /// `payer → delegate → caps before the last lowering of that delegate's caps`. A revocation
    /// writes it too, and its `until` is then also the end of the revoked grant's grace. A grant
    /// revoked before this mapping existed reads `until == 0`, so it stays dead after the upgrade.
    mapping(address => mapping(address => PriorCaps)) internal priorDelegateCaps;

    /// One redeemed payment waiting to be collected or refunded ("redeem into hold"). Two slots.
    /// `None` is the zero value, so an unredeemed `(payer, seq)` reads as no record; `Held` moves
    /// exactly once, to `Collected` or to `Refunded`, and neither has an edge back out. Appended
    /// last-only like [`SlashStatus`]: reordering it would change what a stored record means.
    enum HeldStatus {
        None,
        Held,
        Collected,
        Refunded
    }

    /// `takeRateBps` and `collectableAt` are FROZEN at redemption, so a later `updateConfig` or
    /// `setCollectHold` changes neither the split nor the clock of a payment already held. The
    /// treasury is not frozen: it is Config's at collect time, as it was at redemption before.
    struct HeldPayment {
        address provider; //          slot 0
        uint64 amount; //              ↑
        uint16 takeRateBps; //         ↑
        HeldStatus status; //          ↑
        uint64 collectableAt; //      slot 1
    }

    /// `payer → seq → held payment`. **The replay rule (D-23)**: a `(payer, seq)` whose record
    /// is not `None` was redeemed, and records are never deleted, so a seq is redeemed at most
    /// once per payer, in any order, and a record is written at most once. Appended before `__gap`, which shrank by the two slots this
    /// mapping and [`totalHeld`] take (D-7). `internal` for [`escrowOf`]'s reason: [`held`]
    /// returns the struct.
    mapping(address => mapping(uint64 => HeldPayment)) internal heldPayments;

    /// The sum of every `Held` record's amount: money that has left the buyers' balances and is
    /// not yet paid out. The solvency statement is `totalEscrowed + totalHeld` (still never
    /// `balanceOf`, see [`totalEscrowed`]).
    uint128 public totalHeld;

    /// A redemption landed in hold: `amount` waits in `held[payer][seq]` until `collectableAt`.
    event PaymentHeld(
        address indexed payer,
        uint64 indexed seq,
        address indexed provider,
        uint64 amount,
        uint64 collectableAt
    );

    /// A held payment was paid out: `providerAmount` to the provider, `fee` to the treasury, by
    /// the split frozen at redemption. Credit the provider on this event, not on
    /// [`VoucherRedeemed`].
    event HeldCollected(
        address indexed payer,
        uint64 indexed seq,
        address indexed provider,
        uint64 providerAmount,
        uint64 fee
    );

    /// A held payment went back to the buyer's balance in full.
    event HeldRefunded(address indexed payer, uint64 indexed seq, uint64 amount);

    /// A hold was written ([`_hold`]): until `until`, a voucher that fits (`maxVoucherAmount`,
    /// `maxPerWindow`) as a pair still redeems where the current caps refuse it. `delegate` is
    /// `address(0)` for the escrow's own caps. For a revoked delegate `until` is also the end of
    /// its grace. A later `CapsHeld` for the same (payer, delegate) replaces this one.
    event CapsHeld(
        address indexed payer,
        address indexed delegate,
        uint64 maxVoucherAmount,
        uint64 maxPerWindow,
        uint64 until
    );

    /// `events.rs::StakeDeposited` is the nearest analogue — the same
    /// `(funder, amount, running-total)` shape, because a buyer deposit and a provider stake
    /// deposit are the same event with a different noun. `funder` is indexed here as well as
    /// `buyer`: "who funded this buyer" and "what did this address fund" are both queries the
    /// reconciler makes.
    event Deposited(address indexed buyer, address indexed funder, uint64 amount, uint128 balance);

    /// The EIP-712 name and version are ShortString IMMUTABLES baked into this implementation
    /// by this constructor, and they must be identical in every future implementation or the
    /// domain separator moves and every outstanding voucher dies (D-1; `test/Upgrade.t.sol` asserts
    /// it).
    /// `_disableInitializers()` makes the implementation itself permanently uninitialisable —
    /// without it anyone may initialize it, become its admin and upgrade it directly.
    constructor() EIP712("Assay Settlement", "2") {
        _disableInitializers();
    }

    /// An initialiser rather than a constructor because the contract is upgradeable (D-1): a
    /// constructor would write the implementation's storage, not the proxy's.
    function initialize(IAssayConfig config, IAssayStakeView stake, IERC20 asset)
        external
        initializer
    {
        if (address(config) == address(0) || address(stake) == address(0)) revert ZeroAddress();
        if (address(asset) == address(0)) revert ZeroAddress();
        if (IERC20Decimals(address(asset)).decimals() != 6) revert AssetDecimalsNotSix();

        // A buyer's withdrawal must not mature while a voucher they signed before asking for it is
        // still redeemable. Every term is a
        // constant, so this folds to nothing and only guards a FRESH proxy's first
        // implementation — `initializer` never runs again on an upgrade. What holds the invariant
        // for every later implementation is CI:
        // `test/AssayEscrow.bysig.t.sol::test_theWithdrawDelayOutlivesEveryVoucherSignedBeforeTheRequest`
        // and `test/Types.t.sol::test_withdrawDelayOutlivesTheLongestRedeemableVoucher`.
        if (Constants.WITHDRAW_DELAY_SECONDS <= Constants.MAX_VOUCHER_REDEEMABLE_LIFE_SECONDS) {
            revert WithdrawDelayTooShort();
        }

        CONFIG = config;
        STAKE = stake;
        ASSET = asset;
    }

    /// The upgrade door (D-1, D-17). The authority is `CONFIG.owner()`, READ FROM CONFIG on every
    /// call and never cached: moving the owner moves the upgrade authority of this contract in
    /// the same transaction. The admin is NOT an upgrade authority.
    function _authorizeUpgrade(address) internal view override {
        if (msg.sender != CONFIG.owner()) revert NotOwner();
    }

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

    /// A direct payer decision consumes `authNonce` (D-18); checked, like every counter here.
    function _bumpAuthNonce(address payer) internal {
        escrows[payer].authNonce += 1;
    }

    /// Both halves of [`_pullExact`]'s before/after delta, and no other read (see there).
    function _assetBalance() internal view returns (uint256) {
        return ASSET.balanceOf(address(this));
    }

    function escrowOf(address buyer) external view returns (Escrow memory) {
        return escrows[buyer];
    }

    function held(address payer, uint64 seq) external view returns (HeldPayment memory) {
        return heldPayments[payer][seq];
    }

    /// The proxy's separator, not the implementation's — see the contract note. The backend
    /// names this value when it asks a buyer's wallet to sign a voucher, so it is exported
    /// rather than left to a caller to recompute.
    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    function deposit(uint64 amount) external {
        depositFor(msg.sender, amount);
    }

    /// Anyone may fund anyone. On Solana funding is a plain SPL transfer to the buyer's escrow
    /// ATA and is equally open — `deposit_stake.rs` says the same thing out loud for the
    /// provider side ("Not required to be the provider … a deposit can only ever increase what
    /// the provider owns"). Keeping it open here keeps the two paths the same.
    ///
    /// **The pause check is a deliberate divergence.** Nothing on Solana can pause a buyer
    /// deposit, because a deposit there is a token transfer that never enters the program. Here
    /// it is a call on this contract, so the flag can reach it — and it should. A paused deposit
    /// traps nothing; it only stops a buyer funding an escrow whose redeem path is closed.
    ///
    /// **The pause rule since the dispute upgrade** (the owner's decision, reversing the earlier
    /// "owner exits are never paused"): the pause closes every door that moves money or changes
    /// a party's standing — deposits, redemption, the exit (`requestWithdraw`, `withdraw`), the
    /// limits and delegate authorisation here, and every deposit, exit and slash door on
    /// AssayStake. It leaves open only what reduces risk or releases a hold: `revokeDelegate`,
    /// `disputeSlash`, `cancelSlash`, `expireSlash`, and the config roles' own calls. **It never
    /// moves anybody's money**: there is no seize and no sweep, and a paused exit reopens on
    /// unpause with the balance untouched. The same doors refuse a blocked party
    /// (`AssayConfig.blocked`); both checks are the one `CONFIG.assertActive` call, made through
    /// [`_assertActive`].
    ///
    /// **This is checks → INTERACTION → effects, and it is not strict CEI. Read this before
    /// copying the shape.** The pull has to happen before the credit, because what is credited is
    /// the *measured* delta of a transfer that has already run — there is no way to measure a
    /// transfer before making it. It is safe here for one reason and one reason only: **this path
    /// pays nothing out.** The worst a re-entrant asset can do is push more money in, and the
    /// delta assertion refuses that (see the `nonReentrant` rows in `test/MUTATION-LOG.md`, which
    /// record that the modifier and the delta check overlap on these two doors).
    ///
    /// `collectHeld`, its batch and `withdraw()` pay
    /// money OUT. **They must not copy this ordering.** There every state change — the held
    /// record's status, `totalHeld`, `balance`, `withdrawRequested`, `totalEscrowed` — is written
    /// before the transfer, with the transfer strictly last, and `nonReentrant` is load-bearing
    /// there in a way it is not here.
    function depositFor(address buyer, uint64 amount) public nonReentrant {
        _assertActive(buyer, msg.sender, address(0));
        if (buyer == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount(); // deposit_stake.rs
        _pullExact(msg.sender, amount);
        _credit(buyer, amount);
    }

    /// **The `balanceOf` rule for this whole contract, stated at the site that motivates it.**
    /// There are TWO `balanceOf` reads here, both in this function, and they are the two halves of
    /// a before/after pair around a single transfer. **No read is ever a solvency assertion, and
    /// none may be added.** Solvency
    /// is [`totalEscrowed`] and the per-buyer balances, nothing else: USDG is an upgradeable
    /// Paxos proxy with a blocklist, so a blocklisted contract's `balanceOf` and its entitlements
    /// disagree, and an assertion built on the former would refuse EVERY withdrawal rather than
    /// the one actually blocked. A third read is allowed only if it is another delta half.
    ///
    /// The delta itself makes a fee-on-transfer surprise fail loudly rather than silently
    /// under-credit.
    ///
    /// It is the EVM half of `initialize_config.rs`'s Token-2022 refusal: Solana can
    /// refuse the *class* of token at configuration time because the mint declares its
    /// extensions; here the asset is an opaque upgradeable proxy that could grow a transfer fee
    /// after deployment, so the check has to be made on every transfer instead of once.
    function _pullExact(address from, uint64 amount) internal {
        uint256 before = _assetBalance();
        ASSET.safeTransferFrom(from, address(this), amount);
        if (_assetBalance() - before != amount) revert TransferAmountMismatch();
    }

    /// `deposit_stake.rs` — "Deposits accumulate: a second deposit adds to the first, it
    /// does not replace it", and the same amount is added to the per-account figure and to the
    /// contract-wide total in the same statement sequence.
    ///
    /// Anchor spells the four additions `checked_add(…).ok_or(MathOverflow)`. Solidity 0.8's
    /// checked arithmetic is that, with `Panic(0x11)` in place of the named error; the widening
    /// from `uint64` to `uint128` is total, so only a `uint128` counter can overflow and it takes
    /// 2^64 maximal deposits to do it.
    function _credit(address buyer, uint64 amount) internal {
        Escrow storage e = escrows[buyer];
        e.balance += amount;
        e.totalFunded += amount;
        totalEscrowed += amount;
        emit Deposited(buyer, msg.sender, amount, e.balance);
    }

    /// `events.rs::VoucherRedeemed`, field for field and name for name. Two
    /// fields are indexed — the buyer whose money moved and the provider it moved to — because
    /// those are the two questions the reconciler asks of this log. `spentInWindow` is the
    /// running counter AFTER this redemption, which is the only published view of the buyer's cap
    /// approaching; `takeRateBps` is the rate that was actually applied, so a split stays
    /// auditable across a parameter change that a voucher signed before it cannot know about.
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

    /// `events.rs::EscrowLimitsSet`. Both ceilings in one event because
    /// they are only meaningful together: a per-call ceiling with no window cap bounds one
    /// redemption and nothing else.
    event EscrowLimitsSet(address indexed buyer, uint64 maxVoucherAmount, uint64 maxPerWindow);

    /// **The only door through which a buyer's money leaves on somebody else's submission.**
    ///
    /// The submitter is pinned to `Config::redeemer` and is consulted
    /// about nothing else: it cannot aim the money anywhere, because the provider comes out of the
    /// signed voucher and the treasury out of Config. Since D-23 a redemption voids no other
    /// voucher (seqs are consumed one by one, in any order), so the pin no longer guards the
    /// sequence; it stays because the redeemer decides WHEN a served call is charged, which is
    /// the backend's verdict (D-10).
    ///
    /// **The whole authority over the money is the buyer's authorisation of the EIP-712 voucher**
    /// — its own signature, or a delegate's within the caps the buyer set on chain
    /// (`_voucherAuthority`) — proved against
    /// `v.payer`, which is also the escrow's mapping key: the account spent and the key required
    /// name one party.
    ///
    /// `params()` is read ONCE, into memory, and the same `ParamSet` is used for the redeemer
    /// pin, the stake floor, the take rate and the treasury. Reading them from four calls would
    /// let a Config upgrade mid-transaction hand this function a redeemer from one parameter set
    /// and a treasury from another; `IAssayConfig.params`'s own note makes the same argument.
    function redeemVoucher(Voucher calldata v, bytes calldata sig) external nonReentrant {
        ParamSet memory p = _params();
        if (msg.sender != p.redeemer) revert NotRedeemer();
        _redeem(v, sig, p); // the pause is `_redeem`'s `_assertActive` (audit F R7)
    }

    /// **Batching returns on EVM, because the constraint that forbade it does not exist here.**
    ///
    /// Solana's `REDEEM_PER_TRANSACTION = 1` is an artefact of the 1,232-byte packet limit and the
    /// account list a CPI transfer needs — not a judgement about how many redemptions belong in
    /// one settlement. Neither constraint travels, so the number is **not** copied and neither is
    /// any Solana gas figure; [`Constants.MAX_REDEEM_BATCH`] is 64 and `docs/gas.md` carries the
    /// measurement that says what 64 costs, taken with the real ABI encoding on this commit.
    ///
    /// # Atomic on purpose, and what that costs the caller
    ///
    /// One bad voucher reverts the whole batch. The alternative — skip and continue — needs a
    /// per-item `try`/`catch`, which means an external self-call per item, an event stream that no
    /// longer says which vouchers settled, and a single malformed item able to drop 63 good ones
    /// into a state nobody reconciles.
    ///
    /// So the batch is all-or-nothing, and **the redemption job must pre-validate every voucher it
    /// batches and retry singly on failure.** That is a backend requirement rather than a
    /// property of this contract, which is exactly why it is written down in `docs/gas.md` as well
    /// as here: an operator reading a reverted batch at 3 a.m. needs the retry rule, not the
    /// rationale.
    ///
    /// # What it shares with [`redeemVoucher`], and why that is the whole point
    ///
    /// `params()` is read ONCE for the batch, for the same reason it is read once per redemption:
    /// a Config upgrade landing mid-transaction must not hand two items different treasuries. The
    /// redeemer pin and the batch bounds are this function's; **every other rule, the pause
    /// included, is [`_redeem`]'s,
    /// reused unchanged.** A batch with its own copy of the check list would be a second place for
    /// the replay rule to live, and `test_theBatchDelegatesToTheOneRedeemPathInTheSource` pins the
    /// delegation as source text so the copy cannot appear quietly.
    ///
    /// `seq` is therefore NOT a batch-wide rule: it is "this `(payer, seq)` is unused", applied
    /// item by item (D-23), so the items may come in any order and two payers' sequences
    /// constrain each other in no way at all.
    ///
    /// `nonReentrant` sits on this external entry point only. [`_redeem`] is internal and must not
    /// carry the modifier — with it, the loop would deadlock on its second item.
    function redeemVoucherBatch(Voucher[] calldata vs, bytes[] calldata sigs)
        external
        nonReentrant
    {
        ParamSet memory p = _params();
        if (msg.sender != p.redeemer) revert NotRedeemer();
        // No pause check here: every item's `_assertActive` in `_redeem` refuses
        // `ProgramPaused` (audit F R7), so an empty or malformed batch is diagnosed first.

        uint256 n = vs.length;
        _assertBatch(n, sigs.length);

        for (uint256 i = 0; i < n; ++i) {
            _redeem(vs[i], sigs[i], p);
        }
    }

    /// The buyer's own ceilings — `set_escrow_limits.rs`. **Pause-gated and blocklist-gated
    /// since the dispute upgrade** (the owner's decision): while paused nothing can redeem, so a
    /// tightened limit protects nothing the pause has not already closed.
    ///
    /// `0` on either field is REFUSE, not "unlimited", which is why a
    /// never-configured escrow pays nobody and why this function is the whole of what
    /// `open_escrow.rs` used to do.
    ///
    /// `setLimitsBySig` is the meta-transaction twin, which re-proves the same
    /// authority from a signature and shares [`_setLimits`] with this one.
    ///
    /// **It consumes `authNonce`**, like every payer decision (D-18): a `SetLimitsBySig` signature
    /// the relayer withheld can then never land after this call and undo it.
    function setLimits(uint64 maxVoucherAmount, uint64 maxPerWindow) external nonReentrant {
        _assertActive(msg.sender, address(0), address(0));
        _bumpAuthNonce(msg.sender);
        _setLimits(msg.sender, maxVoucherAmount, maxPerWindow);
    }

    /// A write that changes nothing is refused rather than accepted silently: the event is the
    /// only record that a buyer moved their own ceiling, and an emitted no-op is an event that
    /// says a decision was taken when none was.
    ///
    /// A LOWERING binds a voucher that is already valid only after `TIGHTEN_DELAY`: the caps in
    /// force before this call are kept in `priorEscrowCaps` until then (see [`_holdIfLowered`]).
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

    /// `events.rs::WithdrawRequested`, field for field. The
    /// maturity instant is carried rather than left for a reader to add `WITHDRAW_DELAY_SECONDS`
    /// onto: the delay is a constant of *this* deployment, and a client that recomputed it would
    /// be recomputing a number a redeploy can move under it.
    event WithdrawRequested(address indexed buyer, uint64 amount, uint64 availableAt);

    /// The relayed twin of [`setLimits`], one of the FOUR relayed doors in this contract (with
    /// `requestWithdrawBySig`, `authorizeDelegateBySig` and `revokeDelegateBySig`). The relayer key
    /// can never move USDG: every money-moving path is authorised by
    /// `msg.sender == buyer`, by a buyer EIP-712 signature over an exact amount, or by a
    /// registered verifier's attestation plus the slash delay. This one exists because a buyer
    /// *lowering* a ceiling — the safety direction, and the one an incident needs — must never be
    /// blocked by not holding gas. `withdraw` does not get a twin, ever; the argument is at its
    /// declaration.
    ///
    /// Its Anchor counterpart is `set_escrow_limits.rs`, whose authority is `buyer: Signer` — an
    /// `is_signer` flag on the transaction. There is no relayed form there because a Solana
    /// transaction can already carry a second signer who pays the fee, so the buyer's signature
    /// and the fee payer are independent by construction. EVM has no such split, so the consent
    /// has to travel as a message, which is what `SET_LIMITS_TYPEHASH` and [`_consumeAuth`] are.
    ///
    /// Pause-gated and blocklist-gated exactly as [`setLimits`] is (a divergence from
    /// `set_escrow_limits.rs`, which takes no `Config` at all).
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

    /// Starts the buyer's exit clock — `request_withdraw.rs`. It moves no money and it may
    /// be relayed. **Pause-gated and blocklist-gated since the dispute upgrade** (the owner's
    /// decision, reversing the earlier "never paused" rule).
    ///
    /// The delay is `WITHDRAW_DELAY_SECONDS`, sized by `constants.rs`'s build-time assertion
    /// rather than chosen: every voucher the buyer signed *before* asking for their money back is
    /// dead before the withdrawal matures (10,800 > 7,620). `initialize` re-states that inequality
    /// because Solidity has no `const _: () = assert!(…)`.
    ///
    /// It does NOT block [`redeemVoucher`], exactly as the Anchor original does not. A voucher
    /// signed before the request is redeemed (or dead) before the withdrawal matures, so the buyer
    /// cannot take out money such a voucher needs. One signed *after* the request is covered by
    /// nothing here: the backend must not admit vouchers while a request stands (below).
    ///
    /// **It consumes `authNonce`**, like every payer decision (D-18): a withheld
    /// `RequestWithdrawBySig` can then never cancel or restart this request.
    function requestWithdraw(uint64 amount) external nonReentrant {
        _assertActive(msg.sender, address(0), address(0));
        _bumpAuthNonce(msg.sender);
        _requestWithdraw(msg.sender, amount);
    }

    /// The relayed twin of [`requestWithdraw`]. Starting a clock moves no money,
    /// so a compromised relayer that could land one of these can delay nothing and take nothing:
    /// the worst it can do with a signature the buyer really produced is *start the buyer's own
    /// exit*, and the buyer cancels it with `requestWithdraw(0)`.
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

    /// `handle_request_withdraw`, line for line.
    ///
    /// **`amount == 0` cancels**, clock and all — the Anchor original's `if amount == 0 { 0 }`.
    /// It is not a special case bolted on: a standing request is a claim against a balance the
    /// platform is still collecting from, and the buyer must be able to retract it in one call
    /// without waiting out a delay to do so.
    ///
    /// The request is NOT bounded by the balance here. `withdraw()` pays
    /// `min(requested, balance)`, so a request larger than the balance is not an error — it is a
    /// buyer asking for everything, which is what they will have to do if a redemption lands
    /// during the hour.
    ///
    /// The `buyer` argument is the AUTHORISED party — `msg.sender` on the direct path, the
    /// recovered signer on the relayed one — and never `msg.sender` on both. Crediting the caller
    /// here would let a relayer start its own clock with somebody else's signature.
    ///
    /// # The half of the guarantee this delay does NOT buy — a backend obligation
    ///
    /// `WITHDRAW_DELAY_SECONDS (10,800) > MAX_VOUCHER_REDEEMABLE_LIFE_SECONDS (7,620)` guarantees
    /// that a voucher signed **before** this call cannot outlive the delay. It says nothing about
    /// one signed after: a voucher signed at `T + 1381` or later is still redeemable past
    /// `T + 10800`, [`withdraw`] reads no outstanding-voucher state and pays `min(requested,
    /// balance)`, and the redemption then fails [`EscrowInsufficient`] — **after the provider has
    /// served the request.**
    ///
    /// No contract-side check is proposed: it would need an outstanding-voucher set this contract
    /// deliberately does not hold, and `withdraw.rs` has none either, so this is parity and not a
    /// port defect. The mitigation is off chain and it is a named backend requirement — **the
    /// router
    /// must stop quoting a buyer with a standing request** — written out in `docs/gas.md`
    /// § "The operational rules" beside the batch pre-validation rule, and accepted in
    /// `docs/risk-register.md` §13.
    function _requestWithdraw(address buyer, uint64 amount) internal {
        Escrow storage e = escrows[buyer];
        uint64 availableAt =
            amount == 0 ? 0 : Cast.toUint64(block.timestamp) + Constants.WITHDRAW_DELAY_SECONDS;
        e.withdrawRequested = amount;
        e.withdrawAvailableAt = availableAt;
        emit WithdrawRequested(buyer, amount, availableAt);
    }

    /// `events.rs::EscrowWithdrawn` minus one field. The Anchor event
    /// carries `destination` because on Solana the buyer names a token account; here the
    /// recipient is `msg.sender`, which is also the indexed `buyer`, so a `destination` field
    /// would be a second copy of one address and an indexer could not tell them apart anyway.
    ///
    /// Both `requested` and `amount` are carried, and they differ whenever a redemption landed
    /// during the hour. An indexer that saw only `amount` could not tell a partly-filled exit
    /// from a smaller one.
    event EscrowWithdrawn(address indexed buyer, uint64 requested, uint64 amount);

    /// The buyer takes their own money out of their own escrow — `handle_withdraw`,
    /// and the second half of the two-step exit [`requestWithdraw`]
    /// opens. A full compromise of every key held in an environment variable (the backend's)
    /// can neither stop a buyer taking their own money out nor take it for them. The cold ADMIN
    /// can hold it in place — pause and block close this door since D-19, an accepted risk
    /// (risk register §18) — but no key can move it anywhere else.
    ///
    /// # It takes no destination and pays `msg.sender`
    ///
    /// `withdraw.rs` takes a `destination` token account and argues the program should not
    /// pin its owner, "because a key that could redirect this is already a key that could
    /// withdraw". That argument is true on Solana and **false here**, and the difference is not a
    /// preference: there a buyer's escrow authority is a PDA and their tokens live in some *other*
    /// account, so a destination has to be named or the money has nowhere to go. On EVM the
    /// address IS the account. A destination parameter would therefore buy nothing and cost the
    /// one thing this door is for — it is a place for a compromised console, or a phished
    /// signature, to aim a withdrawal somewhere else.
    ///
    /// # There is deliberately no `withdrawBySig`
    ///
    /// The relayed doors are the two escrow-control twins and the two delegation twins, and they
    /// stop there. [`requestWithdraw`] already served the one-hour delay, so by the time this function
    /// is callable **the brake is spent**: a phished `withdrawBySig` signature would drain the
    /// escrow immediately with nothing left to stop it, where a phished `requestWithdraw`
    /// signature only starts a clock the buyer can cancel. To take money here an attacker needs
    /// the address itself — and an attacker with the address already has everything.
    ///
    /// The cost is real and is accepted: **a buyer holding zero ETH cannot withdraw.** Both
    /// answers are outside this contract, and neither is built here — the buyer sends themselves
    /// ETH from anywhere, or the relayer funds their address with exactly the gas for one
    /// `withdraw`: bounded, logged, alerted, and never a way to move USDG.
    ///
    /// # It is pause-gated and blocklist-gated (since the dispute upgrade)
    ///
    /// `withdraw.rs` has "no `paused` check anywhere in this file", and this door followed
    /// it until the owner decided otherwise: while paused, or while the buyer is blocked, the
    /// exit is refused. **Neither gate moves the money** — it stays the buyer's, in this escrow,
    /// and the exit reopens on unpause or unblock. A stolen admin key can therefore hold an exit
    /// closed for as long as it holds the pause; that risk is accepted and recorded in
    /// `docs/risk-register.md`.
    ///
    /// # What it pays, and what it refuses
    ///
    /// `min(requested, balance)`, exactly as `withdraw.rs`: a redemption may have landed
    /// during the wait, which is the intended ordering — the platform collects what the buyer
    /// already signed for, and the buyer takes the rest. The request is then spent whether or not
    /// it was filled, because a partly-filled request left standing would
    /// be a claim the buyer never renewed against a balance the platform is still collecting from.
    ///
    /// An **empty** escrow is refused instead (`withdraw.rs`, `EscrowInsufficient`) rather
    /// than paid as zero and cleared, so a buyer whose money arrives a second later does not have
    /// to serve the whole delay again.
    ///
    /// # Effects strictly before interactions
    ///
    /// Every one of the five effects is written before the transfer. `nonReentrant` is a belt
    /// here, not the brace: re-entering after the effects finds `withdrawRequested == 0` and is
    /// refused by [`NoWithdrawRequested`] — measured, and recorded in `test/MUTATION-LOG.md`. The
    /// ordering is what actually stops the double payment, and
    /// `test_everyEffectIsWrittenBeforeTheWithdrawalTransfer` is what stops it being reordered.
    ///
    /// **`totalFunded` is not touched.** It is the lifetime money-in counter, so a balance that
    /// falls must not move it; `_credit` is its only writer.
    function withdraw() external nonReentrant {
        _assertActive(msg.sender, address(0), address(0));
        Escrow storage e = escrows[msg.sender];

        uint64 requested = e.withdrawRequested;
        if (requested == 0) revert NoWithdrawRequested();
        if (block.timestamp < e.withdrawAvailableAt) revert WithdrawNotYetAvailable();

        uint128 balance = e.balance;
        // Safe by construction — the narrowing is reached only when `balance < requested`, and
        // `requested` is a `uint64`. Through `Cast` anyway: `Cast.sol`'s header rules that a
        // provably-dead revert does not earn a bare cast, because the next implementer learns the
        // default from whichever site they open first.
        uint64 amount = Cast.toUint64(requested <= balance ? requested : balance);
        if (amount == 0) revert EscrowInsufficient();

        // --- effects -------------------------------------------------------------------------
        e.balance = balance - amount;
        e.totalWithdrawn += amount;
        e.withdrawRequested = 0;
        e.withdrawAvailableAt = 0;
        totalEscrowed -= amount; // the pooled solvency counter; `totalFunded` is NOT touched

        // --- interactions --------------------------------------------------------------------
        ASSET.safeTransfer(msg.sender, amount);
        emit EscrowWithdrawn(msg.sender, requested, amount);
    }

    /// The whole authorisation of a relayed call, in one place so the two doors cannot drift.
    ///
    /// The `nonce` and the `deadline` are INSIDE the signed struct, so a leaked relayer key can
    /// neither replay an authorisation nor extend one — it can only carry, once, the exact
    /// message the buyer already agreed to. Each door hashes a DISTINCT typehash (four of them in
    /// `Voucher712`), so an authorisation collected at one door cannot be presented at another; that is the EIP-712 form of `attestation.rs`'s
    /// `assert!(ATTESTATION_MESSAGE_LEN != VOUCHER_MESSAGE_LEN)`, and strictly stronger, because
    /// two lengths can be made to collide by a future field and two typehashes cannot.
    ///
    /// **One nonce serves every payer decision** — the four relayed doors here and the four direct
    /// ones, which bump it too (D-18). `authNonce` is a single counter on the escrow, not one
    /// per message kind, so a signature the buyer produced for `SetLimits` at nonce `n` and a
    /// signature they produced for `RequestWithdraw` at the same `n` are alternatives: landing
    /// either one voids the other. Per-kind nonces would let a relayer hold one of each and
    /// choose the order months later.
    ///
    /// The order is deadline, then nonce, then signature: the two cheap state-free rejections
    /// before `ecrecover`, which is the same reasoning the redeem path applies to `seq` on the
    /// redeem path.
    /// It leaks nothing — `escrowOf` already returns `authNonce` to anybody who asks.
    ///
    /// `buyer == address(0)` is belt over brace: [`Sig.recover`] refuses a recovery to the zero
    /// address, so no signature can ever satisfy `signer == address(0)`. It is here so the
    /// refusal names the argument that is wrong instead of the signature that could not have
    /// been right.
    function _consumeAuth(
        address buyer,
        bytes32 structHash,
        uint64 nonce,
        uint64 deadline,
        bytes calldata sig
    ) internal {
        if (buyer == address(0)) revert ZeroAddress();
        if (block.timestamp > deadline) revert SignatureExpired();
        // D-18: when the call lands, `deadline` may be at most `MAX_SIGNATURE_LIFETIME_SECONDS`
        // ahead of now. Not a lifetime: a far deadline still lands in its last hour; the shared
        // `authNonce` is what kills a withheld signature. `uint256`, no overflow.
        if (deadline > block.timestamp + Constants.MAX_SIGNATURE_LIFETIME_SECONDS) {
            revert SignatureDeadlineTooFar();
        }

        Escrow storage e = escrows[buyer];
        if (nonce != e.authNonce) revert BadNonce();
        if (Sig.recover(_hashTypedDataV4(structHash), sig) != buyer) revert SignerIsNotBuyer();

        e.authNonce = nonce + 1;
    }

    /// The whole rule set, in one internal function so the batch reuses it UNCHANGED — a
    /// batch that re-spelled these checks would be a second place for the replay rule to live.
    ///
    /// # The order, and where each line comes from
    ///
    /// `redeem_voucher.rs` states the Anchor order as "redeemer, pause, amount, `pay_to`,
    /// window, signature, sequence, spending limits, stake floor, balance". This function is that
    /// list minus `pay_to` (the EVM voucher drops the field: on Solana it makes the *off-chain*
    /// `payTo` a
    /// signed fact against the escrow PDA, and here `escrows[v.payer]` is derived from the signed
    /// payer with no second address to disagree with) and with **one deliberate reordering**:
    ///
    /// **`seq` is checked BEFORE the signature; `redeem_voucher.rs` checks it after.**
    /// The EVM design specifies it here. It is strictly cheaper — a replayed voucher is
    /// refused without paying for `ecrecover` — and it leaks nothing, because the record is
    /// public state that `held` already returns to anybody who asks. Recorded in
    /// `docs/divergences.md`.
    ///
    /// **`ProviderBelowMinimumStake` is reinstated** at the Anchor program's position, after the
    /// window limit and before the balance check. The EVM design's
    /// check
    /// list omits it; D-2 keeps it, because being paid is the counterpart of being slashable and
    /// the
    /// backend that would otherwise enforce it is assumed compromised by this threat model. Also
    /// recorded in `docs/divergences.md`.
    ///
    /// # Effects strictly before interactions
    ///
    /// **Do not copy [`depositFor`]'s shape here.** That path is checks → interaction → effects,
    /// which is unavoidable for a *measured* `balanceOf` delta and is safe only because nothing is
    /// paid out. Since "redeem into hold" this function transfers no token at all — the payout is
    /// [`collectHeld`]'s — but its only external calls are still the Config and Stake views
    /// above, all made before any effect, and [`_collectHeld`] keeps the effects-first order
    /// for the transfers it now owns. USDG is an upgradeable Paxos proxy, so "this token has no
    /// callbacks" is a statement about today only.
    ///
    /// A refusal rolls all of it back, exactly as an Anchor `require!` does — so a redemption
    /// refused for `EscrowInsufficient` leaves its seq unused and `seqHigh` where it was
    /// (`tests/escrow.rs::an_underfunded_escrow_refuses_without_consuming_the_sequence`).
    function _redeem(Voucher calldata v, bytes calldata sig, ParamSet memory p) internal {
        // Through [`Cast.toUint64`] like every other narrowing in `src/`, and not because
        // anybody expects it to fire: `block.timestamp` reaches `2^64` in the year
        // 584,942,419,325. It is here because a file that checks two of its three
        // narrowings and waives the third teaches the next reader that the waiver is a
        // judgement call. It is not; `Cast`'s NatSpec carries the rule.
        uint64 nowTs = Cast.toUint64(block.timestamp);

        if (v.amount == 0) revert ZeroAmount(); // redeem_voucher.rs

        // `attestation.rs` (`require_valid_voucher_window`), in its order. The Anchor
        // original raises `InvalidVoucherWindow` for both of the first two; this port gives the
        // lifetime bound its own name, which is the Errors.sol rule that one condition gets one
        // name.
        //
        // **The two additions below cannot overflow, and NOT for the same reason.** An earlier
        // version of this comment gave one reason for both, which reached the right conclusion by
        // the wrong route for one of them — one refactor away from being wrong.
        //
        //   `nowTs + CLOCK_SKEW_TOLERANCE_SECONDS` — because `nowTs` is `block.timestamp` and
        //   nothing else. It has nothing to do with any voucher field, and the ORDER of these
        //   four checks is irrelevant to it.
        //
        //   `v.expiresAt + REDEEM_GRACE_SECONDS` — because of the two checks ABOVE it, and this
        //   one IS an ordering invariant with two legs: the lifetime bound pins
        //   `expiresAt <= issuedAt + 300`, the skew bound pins `issuedAt <= nowTs + 120`, so
        //   `expiresAt + 7200 <= nowTs + 7620`. Move either of them below this line and a voucher
        //   with a large `expiresAt` (leg one) or a large `issuedAt` (leg two) answers
        //   `Panic(0x11)` instead of its named refusal. Both legs are pinned, at exact and
        //   `type(uint64).max` inputs, by `test_boundary_theVoucherClockWindowIsBoundedAtBothEnds`.
        //
        // Anchor needs neither argument: `attestation.rs` use `saturating_add`, so there
        // the order is a preference and here it is load-bearing. That is a divergence, recorded
        // in `docs/divergences.md`.
        if (v.expiresAt <= v.issuedAt) revert InvalidVoucherWindow();
        if (v.expiresAt - v.issuedAt > Constants.VOUCHER_MAX_LIFETIME_SECONDS) {
            revert VoucherLifetimeTooLong();
        }
        if (v.issuedAt > nowTs + Constants.CLOCK_SKEW_TOLERANCE_SECONDS) {
            revert VoucherNotYetValid();
        }
        if (nowTs > v.expiresAt + Constants.REDEEM_GRACE_SECONDS) revert VoucherExpired();

        // D-23, replacing `state.rs::admit_seq`'s strictly increasing `seq_high`: exactly one
        // redemption per `(buyer, seq)`, in ANY order, read off the record this redemption is
        // about to write anyway (so the read also warms the slot the effects below store into).
        // A lower seq landing after a higher one is no longer lost. Moved above the signature by
        // design — see the note above.
        Escrow storage e = escrows[v.payer];
        if (v.seq == 0) revert VoucherSeqZero();
        if (heldPayments[v.payer][v.seq].status != HeldStatus.None) revert VoucherSeqUsed();
        // D-17: the jump cap, now only on a seq above the high-water mark; the guard is what
        // keeps the subtraction from wrapping.
        if (v.seq > e.seqHigh && v.seq - e.seqHigh > Constants.MAX_SEQ_GAP) {
            revert VoucherSeqGapTooLarge();
        }

        // `redeem_voucher.rs`, widened for delegation. [`_voucherAuthority`] is the whole
        // authority over the money: the payer's key, or a delegate the payer authorised. It
        // returns the delegate, or `address(0)` when the payer itself signed.
        address delegate =
            _voucherAuthority(v.payer, _hashTypedDataV4(Voucher712.hashVoucher(v)), sig, nowTs);

        // The pause and the blocklist — payer, payee and (when there is one) the delegate that
        // signed. Here and not at the entry point because the delegate is only known once the
        // signature has been recovered; this is the redeem paths' only pause check (audit F R7).
        _assertActive(v.payer, v.provider, delegate);

        // `state.rs::admit_spend`. A limit of `0` refuses everything, so an
        // unarmed escrow needs no separate branch. A voucher passes if it fits the current pair
        // of caps, or the pair held when the payer last lowered them, while that hold runs
        // ([`_heldRefusal`]); a pair is checked whole, never field by field. The hold is read
        // only when the current pair refuses, so the common path reads no extra slot.
        uint256 spent = uint256(Window.decay(e.spentInWindow, e.windowStartedAt, nowTs)) + v.amount;
        if (v.amount > e.maxVoucherAmount || spent > e.maxPerWindow) {
            uint256 why =
                _heldRefusal(priorEscrowCaps[v.payer], v.amount, spent, e.maxVoucherAmount, nowTs);
            if (why == 1) revert VoucherExceedsPerCallLimit();
            if (why == 2) revert EscrowWindowLimitExceeded();
        }

        // A delegate-signed voucher clears the delegate's OWN caps as well as the escrow's. The
        // storage reference is taken unconditionally (it reads nothing); it is only read and
        // written when there is a delegate, and `delegations[payer][address(0)]` is never
        // written because an authorisation refuses the zero address.
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

        // `redeem_voucher.rs` — being paid is the counterpart of being slashable.
        // `bonded` only: stake already asked back is not backing anybody's traffic. And FREE
        // bonded only (D-26): stake reserved by standing slash records is not backing it either.
        if (STAKE.freeBondedOf(v.provider) < p.minimumStake) revert ProviderBelowMinimumStake();

        // `redeem_voucher.rs`. Its job is the DIAGNOSIS: without it `e.balance -=` still
        // refuses, but as `Panic(0x11)`, which is not what an operator needs to read.
        if (e.balance < v.amount) revert EscrowInsufficient();

        // The collect hold in force now, frozen into the record below (a view, read before any
        // effect like every other external read here).
        uint64 collectableAt = nowTs + CONFIG.collectHoldSeconds();

        // --- effects -------------------------------------------------------------------------
        if (v.seq > e.seqHigh) e.seqHigh = v.seq;
        e.balance -= v.amount;
        // The truncation is unreachable — `spent` is at most an effective `maxPerWindow`, checked
        // above, and every cap is a `uint64`. It goes through [`Cast.toUint64`] anyway, and it is
        // narrowed ONCE into a named local rather than cast at each of the two places it is used:
        // the second of those was twenty-four lines from its guard, inside the event argument list.
        // An earlier version argued for a bare cast on the ground that the bound here is the guard
        // itself rather than a claim about a caller — which is `Window.narrow`'s own losing
        // argument restated, not a new one. `Cast`'s NatSpec carries the rule.
        uint64 spentAfter = Cast.toUint64(spent);
        e.spentInWindow = spentAfter;
        // `state.rs` — never moved backwards: a clock that stepped back must not hand
        // capacity to whoever noticed.
        e.windowStartedAt = nowTs > e.windowStartedAt ? nowTs : e.windowStartedAt;
        e.totalRedeemed += v.amount; // redeem_voucher.rs
        totalEscrowed -= v.amount; // the pooled solvency counter; `totalFunded` is NOT touched
        uint64 delegateSpentAfter;
        if (delegate != address(0)) {
            delegateSpentAfter = Cast.toUint64(delegateSpent); // `<=` a uint64 cap, checked above
            d.spentInWindow = delegateSpentAfter;
            d.windowStartedAt = nowTs > d.windowStartedAt ? nowTs : d.windowStartedAt;
        }

        // Redeem into hold: the two payouts of `redeem_voucher.rs`/`:186` move to
        // [`collectHeld`], and this path transfers no token. The take rate and the clock are
        // frozen here; `fee` is computed now only for the event, by the same split collect makes.
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

    /// Pays a held payment out: the provider's share to the voucher's provider, the fee to
    /// Config's treasury, by the take rate frozen at redemption — so the split is exactly the one
    /// the redemption's [`VoucherRedeemed`] reported.
    ///
    /// **Who may call it, and when.** The redeemer from `collectableAt`; anybody from
    /// `collectableAt + HELD_TIMEOUT_SECONDS`, so a redeemer that goes silent cannot keep a
    /// provider's money held for ever. The backend does not collect while a buyer dispute is
    /// open, and [`refundHeld`]s an upheld one.
    ///
    /// **Pause-gated and blocklist-gated** (payer and provider): it moves money, so the pause
    /// and the blocklist freeze it exactly as they freeze redemption. Nothing is lost — the
    /// record stays `Held`, and the timeout still opens it to anybody once the gate lifts.
    ///
    /// Effects strictly before interactions, under `nonReentrant`, as on [`_redeem`].
    function collectHeld(address payer, uint64 seq) external nonReentrant {
        _collectHeld(payer, seq, _params());
    }

    /// [`collectHeld`] over many records, **atomically**, like [`redeemVoucherBatch`]: one bad
    /// item — too early, already collected or refunded, a duplicate, paused, blocked — reverts the
    /// whole batch. The collection job pre-filters with [`held`] and retries singly on failure.
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

    /// Returns a held payment to the buyer's balance, in full. **Redeemer only, no arbiter**:
    /// the redeemer already holds the same power by not redeeming. Open from redemption until
    /// `collectableAt + HELD_TIMEOUT_SECONDS`, then closed for ever (only a collect remains).
    ///
    /// **The buyer's `spentInWindow` is NOT restored** (owner's decision): a refund must not hand
    /// a buyer, or a delegate, fresh capacity inside the window it was spent in. The lifetime
    /// `totalRedeemed` IS lowered, so `totalFunded == balance + totalRedeemed + totalWithdrawn`
    /// keeps holding per escrow.
    ///
    /// It transfers no token and is not pause-gated: it only moves held money back to a balance
    /// that every exit door still guards.
    function refundHeld(address payer, uint64 seq) external nonReentrant {
        if (msg.sender != _params().redeemer) revert NotRedeemer();
        _refundHeld(payer, seq);
    }

    /// [`refundHeld`] over many records, atomically (see [`collectHeldBatch`]).
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

    /// The shape of every batch here — `redeemVoucherBatch` and the two held batches: not empty,
    /// at most `MAX_REDEEM_BATCH`, and the second array exactly as long as the first. The length
    /// is checked in both directions BEFORE the loop rather than left to the indexing: a short
    /// array would otherwise answer `Panic(0x32)` where an operator needs a diagnosis.
    function _assertBatch(uint256 n, uint256 m) internal pure {
        if (n == 0) revert EmptyBatch();
        if (n > Constants.MAX_REDEEM_BATCH) revert BatchTooLarge();
        if (m != n) revert BatchLengthMismatch();
    }

    function _collectHeld(address payer, uint64 seq, ParamSet memory p) internal {
        HeldPayment storage h = heldPayments[payer][seq];
        if (h.status != HeldStatus.Held) revert HeldPaymentNotHeld();
        uint256 opensAt = uint256(h.collectableAt);
        if (msg.sender != p.redeemer) opensAt += Constants.HELD_TIMEOUT_SECONDS;
        if (block.timestamp < opensAt) revert HeldNotYetCollectable();
        address provider = h.provider;
        _assertActive(payer, provider, address(0));

        // --- effects -------------------------------------------------------------------------
        uint64 amount = h.amount;
        h.status = HeldStatus.Collected;
        totalHeld -= amount;
        (uint64 fee, uint64 providerAmount) = Fee.splitFee(amount, h.takeRateBps);

        // --- interactions --------------------------------------------------------------------
        // Guarded on zero exactly as `redeem_voucher.rs`/`:186` are, so a 0% take rate makes
        // no call at all and a blocklisted treasury cannot refuse a payment of nothing.
        if (providerAmount > 0) ASSET.safeTransfer(provider, providerAmount);
        if (fee > 0) ASSET.safeTransfer(p.treasury, fee);
        emit HeldCollected(payer, seq, provider, providerAmount, fee);
    }

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

    /// The voucher's authority (D-16, narrowed by D-18). Exactly one of:
    ///
    ///   (a) an ECDSA signature by `payer` itself;
    ///   (b) an ECDSA signature by a DELEGATE that `payer` authorised here, not past
    ///       `validUntil` (its caps are [`_redeem`]'s to apply, beside the escrow's). A REVOKED
    ///       delegate still counts for `TIGHTEN_DELAY` after the revocation (until
    ///       `priorDelegateCaps[payer][delegate].until`): a voucher it signed before the
    ///       revocation stays collectable. Only the redeemer can redeem, and the backend admits no
    ///       new voucher from a revoked delegate.
    ///
    /// Returns the delegate for (b) and `address(0)` for (a). Recovery is the strict
    /// [`Sig.recover`], so a malformed signature keeps the name its guard gives it
    /// (`InvalidSignature`, `MalleableSignature`, `BadSignatureV`). Otherwise the refusal is the
    /// most specific true one: a known delegate that can no longer sign is named
    /// `DelegateIsRevoked` if it was revoked and `DelegateIsExpired` if not;
    /// anything else is [`SignerIsNotPayer`].
    ///
    /// **There is no EIP-1271 branch (D-18).** It was the only call to payer-chosen code in the
    /// money path, inside the batch loop, and no product path used it. A contract-wallet payer
    /// calls `authorizeDelegate` directly (it reads `msg.sender`) and lets a delegate sign. An
    /// EIP-7702 account signs with its own key under (a).
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

    event DelegateAuthorized(
        address indexed payer,
        address indexed delegate,
        uint64 maxVoucherAmount,
        uint64 maxPerWindow,
        uint64 validUntil
    );
    /// A standing grant's caps or horizon changed. Separate from [`DelegateAuthorized`] so an
    /// indexer can tell a new grant from an update without keeping state of its own.
    event DelegateUpdated(
        address indexed payer,
        address indexed delegate,
        uint64 maxVoucherAmount,
        uint64 maxPerWindow,
        uint64 validUntil
    );
    event DelegateRevoked(address indexed payer, address indexed delegate);

    /// Emitted beside [`VoucherRedeemed`] (whose shape is unchanged, so no reader of it breaks)
    /// when the voucher's authority was a delegate. `spentInWindow` is the delegate's own
    /// running counter after this redemption.
    event DelegateVoucherRedeemed(
        address indexed payer,
        address indexed delegate,
        uint64 seq,
        uint64 amount,
        uint64 spentInWindow
    );

    function delegationOf(address payer, address delegate)
        external
        view
        returns (Delegation memory)
    {
        return delegations[payer][delegate];
    }

    function delegatesOf(address payer) external view returns (address[] memory) {
        return delegateList[payer];
    }

    /// The ENVELOPE of the caps [`_redeem`] applies right now: the escrow's, and `delegate`'s —
    /// zero when `delegate` cannot sign now (no grant, past `validUntil`, or revoked and past
    /// its grace). Each field is the larger of the current cap and the held one while a hold
    /// runs. It is a necessary bound, not a sufficient one: [`_redeem`] also needs the voucher to
    /// fit ONE pair whole (current, or held), so a voucher inside this envelope can still revert
    /// after a payer lowered one cap and raised the other; the held pair itself is in
    /// [`CapsHeld`]. Use it to prevalidate a voucher that was already admitted. ADMISSION of a
    /// new voucher must read the current caps and `revoked` (`delegationOf`), never this.
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

    /// Whether a written grant can sign at `nowTs`: not past `validUntil`, and, if revoked, not
    /// more than `TIGHTEN_DELAY` after the revocation (`prior.until`, which [`_revokeDelegate`]
    /// writes). The hold is read only for a revoked grant.
    function _canSign(Delegation storage d, PriorCaps storage prior, uint64 nowTs)
        internal
        view
        returns (bool)
    {
        if (nowTs > d.validUntil) return false;
        return !d.revoked || nowTs <= prior.until;
    }

    /// The larger of each current cap and the held one, while the hold lasts (`nowTs <= until`;
    /// a never-written hold has `until == 0` and is never in force). Used for the envelope
    /// ([`effectiveCapsOf`]) and to merge a running hold into a new one ([`_hold`]); [`_redeem`]
    /// checks the pairs whole instead ([`_heldRefusal`]).
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

    /// Why a voucher the CURRENT pair refused (its amount above `curV`, or its window total
    /// `spent` above the current window cap) is refused: `0` if it fits the held pair `p` whole
    /// while the hold runs, so it is NOT refused; `1` if no pair in force allows its amount;
    /// `2` if one does, but not with this window total. The window counter is the same one for
    /// both pairs: a hold changes which ceiling a total is compared with, never the total.
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

    /// When a change lowers either stored cap (`curV`/`curW` → `newV`/`newW`), holds the caps in
    /// force now until `until` ([`_hold`]). A change that lowers neither leaves the hold as it
    /// is: a raise applies at once and neither extends nor cuts a hold.
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

    /// Holds the caps in force now until `until`: the stored pair (`curV`, `curW`), merged field
    /// by field with a hold that is still running, since one slot holds one pair and a voucher
    /// valid now may rely on either (the residual is risk register §14b). The escrow's hold
    /// ends at `now + TIGHTEN_DELAY`; a delegate's at [`_delegateHoldEnd`].
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

    /// The end of a delegate hold: `now + TIGHTEN_DELAY`, but never past the grant's own
    /// `validUntil` as it stood BEFORE the change. No voucher that grant signed can redeem after
    /// `validUntil` anyway, so the cut loses no voucher, and it keeps a lapsed grant's caps (or
    /// caps beyond the old horizon) from coming back through a re-grant.
    function _delegateHoldEnd(uint64 validUntil, uint64 nowTs) internal pure returns (uint64) {
        uint64 end = nowTs + Constants.TIGHTEN_DELAY_SECONDS;
        return validUntil < end ? validUntil : end;
    }

    /// The payer grants `delegate` the right to sign vouchers on `msg.sender`'s escrow, within
    /// `maxVoucherAmount` per voucher and `maxPerWindow` per rolling window, until `validUntil`.
    /// Writing again over a standing grant replaces its caps and horizon (the window counters
    /// carry over).
    ///
    /// `validUntil` must be at least `now + TIGHTEN_DELAY`, so neither a new grant nor a
    /// shortened one can end before a voucher valid now has had `TIGHTEN_DELAY` to be redeemed.
    /// Lowering the caps of a grant that can still sign holds its old caps for `TIGHTEN_DELAY`.
    ///
    /// # What a delegate can and cannot do
    ///
    /// It can sign a VOUCHER, which [`_voucherAuthority`] accepts in place of the payer's. Every
    /// other door is closed to it by construction: `withdraw`, `requestWithdraw` and `setLimits`
    /// read `msg.sender`, and every `…BySig` door — including these delegation doors — recovers
    /// to the PAYER through [`_consumeAuth`], never to a delegate. A delegate therefore cannot
    /// take money out, move a ceiling, or authorise anybody, and its worst case is spending the
    /// escrow to providers within its own caps until it is revoked or lapses.
    ///
    /// # Why the nonce is the escrow's shared `authNonce`, and why this direct door consumes it
    ///
    /// With a SEPARATE delegation nonce, an `AuthorizeDelegate` signature the relayer withheld
    /// could be landed AFTER the payer's revocation and switch the delegate back on. With the
    /// shared nonce every payer decision — relayed or direct — consumes `authNonce`, so a
    /// signature collected before a later decision is dead, and two signatures made at the same
    /// nonce are alternatives (landing either voids the other). That is why `authorizeDelegate`
    /// and `revokeDelegate` advance `authNonce` although they take no signature: a direct
    /// revocation must kill a withheld relayed authorisation. The cost is that a `SetLimits`
    /// signature still in flight dies too and has to be signed again.
    ///
    /// Pause-gated and blocklist-gated (payer and delegate) since the dispute upgrade: a new
    /// grant adds authority, which is the risk direction. REVOKING is never gated.
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

    /// The relayed twin of [`authorizeDelegate`], so a payer without gas (an embedded wallet)
    /// signs once and the platform's relayer submits. The relayer can carry exactly the message
    /// the payer signed, once, before `deadline`; it cannot change the delegate, the caps or the
    /// horizon, because they are inside the signed struct.
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

    /// Ends a delegate's authority `TIGHTEN_DELAY` after this call (or at `validUntil`, if that
    /// is sooner): the grant is marked `revoked` and unlisted at once (the backend admits nothing
    /// new from it), and a voucher it signed before the revocation stays redeemable until then,
    /// within the caps in force now — as a withdrawal request waits out the vouchers signed
    /// before it. Consumes `authNonce` (see [`authorizeDelegate`]).
    function revokeDelegate(address delegate) external nonReentrant {
        _bumpAuthNonce(msg.sender);
        _revokeDelegate(msg.sender, delegate);
    }

    /// The relayed twin of [`revokeDelegate`] — the safety direction, so it must never be
    /// blocked by the payer not holding gas. Neither revoke door is pause- or blocklist-gated.
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
        // Only a grant that can still sign has vouchers to protect (a revoked one included,
        // during its grace); a lapsed, long-revoked or never-written grant holds nothing.
        // Keep this precondition: it is not only a skip of a no-op. A grant revoked and past its
        // grace but not yet past `validUntil` cannot sign, yet its caps are still stored here;
        // without the check, a lowering re-grant would hold them until
        // `min(now + TIGHTEN_DELAY, validUntil)` and so revive a dead grant's caps.
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
            // `list.length <= MAX_DELEGATES_PER_PAYER`, a small constant.
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
        // The grace: hold the caps in force now for `TIGHTEN_DELAY`, never past `validUntil`.
        // `until` is also what [`_canSign`] reads for a revoked grant. A grant that has already
        // lapsed signs nothing and has nothing to protect, so its revocation writes no hold.
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

    /// The append budget the D-7 upgrade-safety gate spends. A new field is added ABOVE this
    /// line and the array shrinks by exactly the slots it consumes — the script refuses
    /// anything else. 45 at the fresh deployment (D-22): the contract's own fields end at slot
    /// 13, so the footprint ends at slot 58.
    uint256[45] private __gap;
}
