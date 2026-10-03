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
import {IPermit2} from "./interfaces/IPermit2.sol";
import {Voucher712} from "./libraries/Voucher712.sol";
import {Sig} from "./libraries/Sig.sol";
import {Window} from "./libraries/Window.sol";
import {Fee} from "./libraries/Fee.sol";
import {Cast} from "./libraries/Cast.sol";
import {Constants} from "./Constants.sol";
import {Voucher, ParamSet} from "./Types.sol";
import "./Errors.sol";

/// Buyer money. One contract holds every buyer's USDG in one pooled balance, with per-buyer
/// accounting in storage. Money leaves through exactly two doors — `redeemVoucher`, which
/// needs the buyer's EIP-712 signature over an exact amount for an exact request, and
/// `withdraw()`, which is msg.sender-only. There is no admin path beside them, and there is
/// no `closeEscrow`: closing would reset `seqHigh` and replay every in-window voucher.
///
/// # What this is a port of
///
/// `state.rs::BuyerEscrow` (`state.rs:525-559`) plus the *absence* of `open_escrow.rs`. On
/// Solana an escrow is an account that has to be created before it can be funded, and
/// `handle_open_escrow` (`open_escrow.rs:99-111`) writes ten explicit zeroes into it. Here the
/// EVM's default storage is those ten zeroes, so the instruction has no body left: a mapping
/// entry that has never been written reads as an escrow with both limits at `0`, which
/// `state.rs:545-551` defines as **refuse every voucher**. `open_escrow.rs:94-97`'s one
/// authority check — a bare identity may open a *disarmed* escrow, only the buyer's own
/// signature may open an armed one — therefore has nothing to guard at open time and moves
/// wholly to `setLimits`, whose authority IS `msg.sender`. Its meta-transaction twin
/// `setLimitsBySig` re-proves that authority from an EIP-712 signature.
///
/// **[`EscrowLimitsRequireBuyer`] therefore has no producer, and this line used to predict that
/// `setLimitsBySig` would be one.** Measured against the shipped code: it is not. That error names
/// "non-zero limits set with NO buyer authorisation offered at all", and neither door can reach
/// that state — `setLimits` takes `msg.sender` as the buyer, and `setLimitsBySig` refuses with
/// [`SignerIsNotBuyer`] before it reaches [`_setLimits`]. The condition is structurally absent
/// rather than unchecked: on Solana `is_signer` is a flag that can be false while the account is
/// still present, and here the authority IS the identity the write is keyed by. Recorded in
/// `docs/divergences.md`.
///
/// **Three `BuyerEscrow` fields are deliberately absent.** `buyer` (`state.rs:530`) is the
/// mapping key, so storing it again would be a second source for one identity. `bump`
/// (`state.rs:556`) is a PDA artefact. `_reserved: [u8; 32]` (`state.rs:558`) is Solana's
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
contract X402Escrow is Initializable, UUPSUpgradeable, EIP712, ReentrancyGuard {
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
        uint64 seqHigh; //              ↑ strictly-increasing high-water mark (state.rs:535)
        uint64 authNonce; //            ↑ meta-transaction nonce — EVM only
        uint64 maxVoucherAmount; //    slot 1   0 = refuse every redeem (state.rs:548)
        uint64 maxPerWindow; //         ↑       0 = refuse every redeem (state.rs:551)
        uint64 spentInWindow; //        ↑                               (state.rs:553)
        uint64 windowStartedAt; //      ↑                               (state.rs:555)
        uint64 withdrawRequested; //   slot 2                           (state.rs:538)
        uint64 withdrawAvailableAt; //  ↑                               (state.rs:540)
        uint128 totalRedeemed; //       ↑                               (state.rs:542)
        uint128 totalWithdrawn; //     slot 3                           (state.rs:544)
        uint128 totalFunded; //         ↑ EVM only — see the contract note above
    }

    /// These four were `immutable` in the pre-proxy draft of this design. Under D-1 they are
    /// ordinary storage, written once in `initialize` and never again — the standard,
    /// upgrade-safe shape. The UPPER_SNAKE_CASE names and the public getters are kept
    /// deliberately so Fixture, Deploy.s.sol and verify-deployment.sh do not change.
    IX402Config public CONFIG;
    IX402StakeView public STAKE;
    IERC20 public ASSET;
    address public PERMIT2;

    /// `internal` rather than `public` because the generated getter for a struct-valued mapping
    /// returns a flattened tuple, which reorders silently when a field is appended. [`escrowOf`]
    /// returns the struct, so a caller decoding it breaks loudly instead.
    mapping(address => Escrow) internal escrows;

    /// The solvency counter — `Config.total_deposited` minus its withdrawals, in the contract
    /// that holds the custody rather than in Config (`state.rs:95-101` keeps the stake totals on
    /// Solana's Config; X402Config.sol's header records why the EVM split puts them here).
    ///
    /// Solvency is NEVER derived from `ASSET.balanceOf(address(this))`: USDG is an upgradeable
    /// Paxos proxy with a blocklist, and a blocklisted contract's `balanceOf` and its
    /// entitlements would disagree — a `balanceOf`-based assertion would then refuse *every*
    /// withdrawal rather than the one actually blocked.
    uint128 public totalEscrowed;

    /// `events.rs::StakeDeposited` (`events.rs:61-69`) is the nearest analogue — the same
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
    constructor() EIP712("x402 Settlement", "2") {
        _disableInitializers();
    }

    /// Was a constructor before design decision D-1. Everything it
    /// asserted, it still asserts — a constructor simply does not write the proxy's storage.
    function initialize(IX402Config config, IX402StakeView stake, IERC20 asset, address permit2)
        external
        initializer
    {
        if (address(config) == address(0) || address(stake) == address(0)) revert ZeroAddress();
        if (address(asset) == address(0)) revert ZeroAddress();
        if (IERC20Decimals(address(asset)).decimals() != 6) revert AssetDecimalsNotSix();

        // `constants.rs:285` states this as
        // `const _: () = assert!(WITHDRAW_DELAY_SECONDS > MAX_VOUCHER_REDEEMABLE_LIFE_SECONDS)`,
        // so lowering the delay fails the Rust build. Solidity has no constant assertion, so it
        // becomes a check here and a test in `test/Types.t.sol`. A buyer's withdrawal must not
        // mature while a voucher they signed before asking for it is still redeemable.
        //
        // It names the DERIVED constant, exactly as the Rust assert does, rather than re-spelling
        // the three-term sum: `MAX_VOUCHER_REDEEMABLE_LIFE_SECONDS` exists so the 2,220 is written
        // once, and a second spelling here would go on checking the old form after an edit.
        //
        // Every term is a compile-time constant, so the optimiser folds this to nothing today
        // and it costs no gas. It turns a future edit to `Constants` into a FRESH DEPLOYMENT that
        // cannot be initialised.
        //
        // **And only a fresh one — read this before relying on it.** An earlier wording here said
        // "a deployment that cannot be initialised", full stop. Under UUPS this function carries
        // `initializer` and never runs again, so an implementation compiled with a lowered
        // `WITHDRAW_DELAY_SECONDS` upgrades in cleanly and this check never fires. It guards the
        // first implementation of a proxy and nothing after it.
        //
        // What holds the invariant for every implementation after the first is CI, and it is two
        // named tests rather than this line:
        // `test/X402Escrow.bysig.t.sol::test_theWithdrawDelayOutlivesEveryVoucherSignedBeforeTheRequest`
        // (which also asserts by source text that this very check is still here, spelled against
        // the derived constant) and `test/Types.t.sol::test_withdrawDelayOutlivesTheLongestRedeemableVoucher`.
        // Moving the check into `_authorizeUpgrade` would make it live on every upgrade; it is
        // left here, matching `constants.rs:285`'s placement, and the gate is named instead.
        if (Constants.WITHDRAW_DELAY_SECONDS <= Constants.MAX_VOUCHER_REDEEMABLE_LIFE_SECONDS) {
            revert WithdrawDelayTooShort();
        }

        CONFIG = config;
        STAKE = stake;
        ASSET = asset;
        PERMIT2 = permit2;
    }

    /// The upgrade door (D-1). The authority is READ FROM CONFIG on every call, never cached:
    /// moving `Config.admin` moves the upgrade authority of this contract in the same
    /// transaction, which is the property that keeps "one key" true.
    ///
    /// On Solana this authority does not exist at all — the BPF loader holds it and it is a
    /// different key from `Config.admin`. That divergence is D-1's, recorded at
    /// `X402Config.admin`'s declaration.
    function _authorizeUpgrade(address) internal view override {
        if (msg.sender != CONFIG.admin()) revert NotAdmin();
    }

    function escrowOf(address buyer) external view returns (Escrow memory) {
        return escrows[buyer];
    }

    /// The proxy's separator, not the implementation's — see the contract note. The backend
    /// names this value when it asks a buyer's wallet to sign a voucher, so it is exported
    /// rather than left to a caller to recompute.
    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /// The address whose key signed this voucher — the whole authority over a buyer's money.
    /// `redeem_voucher.rs:137-142` proves the same thing through the ed25519 precompile and
    /// against `voucher.payer`, "a field of these signed bytes and never an account of the
    /// instruction" (`attestation.rs:306`). The comparison against `v.payer` is the CALLER's,
    /// here as there: this function answers "who signed", `redeemVoucher` decides
    /// whether that is the right somebody and raises [`SignerIsNotPayer`] when it is not.
    ///
    /// `view` rather than `pure` because the domain separator reads `block.chainid` and
    /// `address(this)`.
    ///
    /// **Why it is exposed at all: the OFF-CHAIN pre-flight.** The backend and the console recover
    /// a voucher's signer before spending gas on a redemption that would revert, and every
    /// recovery property below is then directly testable rather than only reachable through a path
    /// that also moves money. It grants nothing: recovery is a pure function of arguments the
    /// caller already holds, and a caller who can call this can compute the same answer off chain.
    ///
    /// **`public` rather than `external` buys nothing today, and probably never will.** An earlier
    /// version of this comment said `redeemVoucher` would call it internally; it does not —
    /// `_redeem` calls [`_recover`] directly, which is one hash cheaper. So
    /// `external` would serve the pre-flight identically, and `test/MUTATION-LOG.md` records the
    /// swap as a surviving degenerate (W2) that the redeem tests will NOT kill either. It stays
    /// `public` because the published interface says `public` and because an internal caller is
    /// cheap to add; it is not load-bearing, and nobody should write a test pretending it is.
    function recoverVoucherSigner(Voucher calldata v, bytes calldata sig)
        public
        view
        returns (address)
    {
        return _recover(_hashTypedDataV4(Voucher712.hashVoucher(v)), sig);
    }

    /// Four guards, in this order, and every one of them is load-bearing:
    ///   1. exactly 65 bytes — the 64-byte EIP-2098 compact form is refused, so there is
    ///      exactly ONE acceptable encoding of any signature;
    ///   2. low-s (EIP-2) — a malleated twin is different bytes for the same voucher, which
    ///      breaks any idempotency key built on the signature string;
    ///   3. v in {27, 28};
    ///   4. signer != address(0) — forget this and garbage "recovers" to the zero address.
    ///
    /// **Guard 1 must come first**, or `calldataload` reads words that are not the signature.
    ///
    /// **The relative order of guards 2 and 3 is a PREFERENCE, not an invariant, and a reader of
    /// this comment used to be told otherwise.** It was justified as "low-s before `v`, so a
    /// malleated twin is diagnosed as malleable rather than as whatever its flipped `v` happens to
    /// trip" — but a twin's `v` is always 27 or 28, so it reaches guard 2 under either order. The
    /// two spellings differ only on bytes that are simultaneously high-s and `v ∉ {27,28}`, where
    /// they name two different true defects. Measured: exchanging them passes the whole suite
    /// (`test/MUTATION-LOG.md` rows S8/W1, confirmed by a review). Nobody
    /// should write a test that pins one of two equally correct diagnoses.
    ///
    /// **Guards 2 and 4 duplicate checks OZ's `tryRecover` makes, and both duplications are
    /// deliberate.** OZ answers `RecoverError.InvalidSignatureS` and `RecoverError.InvalidSignature`
    /// for the same two conditions; checking first is what lets each condition keep its own name
    /// from `Errors.sol` instead of collapsing into one. `test/MUTATION-LOG.md` records guard 4 as
    /// an *equivalent mutant* — nothing can distinguish it from the `err` disjunct beside it —
    /// rather than pretending a test proves it.
    ///
    /// **Read that last paragraph with its condition attached: it holds ONLY while
    /// `ECDSA.tryRecover` is the call below.** "Name-only" and "equivalent" are statements about
    /// this pair of lines *together with OZ*, never about the guards alone. Replace `tryRecover`
    /// with a bare `ecrecover` — behaviour-preserving on its own, measured — and guard 2 becomes
    /// the ONLY thing refusing a malleated twin and guard 4 the only thing refusing
    /// `address(0)`. So the two changes are safe apart and unsafe together, which is exactly the
    /// pair a future engineer citing those log rows would make. Anyone who drops OZ here owns
    /// both guards from that moment on.
    ///
    /// **There is no `ecrecover` anywhere else in this codebase, and there must not be** — the
    /// four guards are only guards if every recovery goes through this function.
    /// `test_recoveryHappensAtExactlyOneCallSiteInSrc` is what enforces it, by counting
    /// occurrences across `src/` rather than trusting this sentence.
    ///
    /// **That move has been made.** The body is now `src/libraries/Sig.sol` and this is the
    /// one-line forwarder it left behind, so `X402Stake` shares the four guards *through the
    /// library* — it cannot call this `internal` function directly, and an earlier version of
    /// this comment claimed it would. Every paragraph above still describes the implementation;
    /// it simply lives one file over, and the gate's allowed filename moved with it in the same
    /// commit. The forwarder stays so that no call site in this contract changed.
    ///
    /// Its Solana counterpart is `ed25519_instruction_proves` (`attestation.rs:563-622`), which
    /// is longer for a reason that does not apply here: there the *parser* is the attack surface,
    /// since the precompile's offsets can point into another instruction's data, so it refuses
    /// everything but the canonical self-contained layout rather than following a pointer. On EVM
    /// `ecrecover` takes the digest by value, so there is no pointer to chase — what is left is
    /// the encoding ambiguity ed25519 does not have.
    function _recover(bytes32 digest, bytes calldata sig) internal pure returns (address) {
        return Sig.recover(digest, sig);
    }

    function deposit(uint64 amount) external {
        depositFor(msg.sender, amount);
    }

    /// Anyone may fund anyone. On Solana funding is a plain SPL transfer to the buyer's escrow
    /// ATA and is equally open — `deposit_stake.rs:15-18` says the same thing out loud for the
    /// provider side ("Not required to be the provider … a deposit can only ever increase what
    /// the provider owns"). Keeping it open here keeps the two paths the same.
    ///
    /// **The pause check is a deliberate divergence.** Nothing on Solana can pause a buyer
    /// deposit, because a deposit there is a token transfer that never enters the program. Here
    /// it is a call on this contract, so the flag can reach it — and it should. A paused deposit
    /// traps nothing; it only stops a buyer funding an escrow whose redeem path is closed.
    ///
    /// **The rule, stated so that it predicts all four money doors** — because the earlier
    /// wording here did not. It said `set_paused.rs` draws the line at doors that "return money
    /// to the party it already belongs to", and then added that "money coming *in* is on the
    /// other side of that line". The second half is wrong: it predicts that
    /// `X402Stake.depositStakeFor` should be gated, and it deliberately is not
    /// (`Pause.t.sol::test_pauseNeverClosesAProvidersOwnStakeTopUp`). A review read
    /// the two comments against each other and found they disagreed.
    ///
    /// The line that does predict the code: **the pause closes a door whose only purpose is
    /// served by another door the pause has already closed, and never a door that lets a party
    /// take their own money back or restore their own standing.**
    ///
    /// - a buyer deposit funds redemption, and redemption is paused — closing it is free;
    /// - a provider stake top-up cures an under-stake, which is a PRECONDITION for the moment the
    ///   pause lifts — closing it would extend the outage past the unpause;
    /// - `withdraw()` and `withdrawStake()` return money to its owner — never gated, which is
    ///   `set_paused.rs`'s own line and the one half of the old wording that was right.
    ///
    /// **This is checks → INTERACTION → effects, and it is not strict CEI. Read this before
    /// copying the shape.** The pull has to happen before the credit, because what is credited is
    /// the *measured* delta of a transfer that has already run — there is no way to measure a
    /// transfer before making it. It is safe here for one reason and one reason only: **this path
    /// pays nothing out.** The worst a re-entrant asset can do is push more money in, and the
    /// delta assertion refuses that (see the `nonReentrant` rows in `test/MUTATION-LOG.md`, which
    /// record that the modifier and the delta check overlap on these two doors).
    ///
    /// `redeemVoucher`, `redeemVoucherBatch` and `withdraw()` pay
    /// money OUT. **They must not copy this ordering.** There every state change — `balance`,
    /// `seqHigh`, `spentInWindow`, `withdrawRequested`, `totalEscrowed` — is written before the
    /// transfer, with the transfer strictly last, and `nonReentrant` is load-bearing there in a
    /// way it is not here.
    function depositFor(address buyer, uint64 amount) public nonReentrant {
        if (CONFIG.paused()) revert ProgramPaused();
        if (buyer == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount(); // deposit_stake.rs:56
        _pullExact(msg.sender, amount);
        _credit(buyer, amount);
    }

    /// USDG implements neither EIP-3009 nor EIP-2612 (measured — `docs/chain-facts.md`), so
    /// Permit2 is the only signature-based fund-in. It needs a one-time `approve(PERMIT2, max)`
    /// from the buyer, which is a transaction — there is no gasless FIRST deposit on this chain
    /// (D-11).
    ///
    /// **`buyer` is the signer, never the caller.** Permit2 checks the signature against the
    /// `owner` argument and binds `msg.sender` — this contract — into the digest as the spender.
    /// Crediting `owner` is therefore the only crediting rule under which a relayer cannot point
    /// somebody else's signature at an account it controls, and a signature made for one escrow
    /// cannot be replayed against another.
    ///
    /// Checks → interaction → effects, for the same measured-delta reason as [`depositFor`] and
    /// with the same warning attached: nothing here pays out, and the payout paths must not copy
    /// it.
    function depositWithPermit2(
        address buyer,
        uint64 amount,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external nonReentrant {
        if (PERMIT2 == address(0)) revert Permit2NotConfigured();
        if (CONFIG.paused()) revert ProgramPaused();
        if (buyer == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        uint256 before = ASSET.balanceOf(address(this));
        IPermit2(PERMIT2).permitTransferFrom(
            IPermit2.PermitTransferFrom({
                permitted: IPermit2.TokenPermissions({token: address(ASSET), amount: amount}),
                nonce: nonce,
                deadline: deadline
            }),
            IPermit2.SignatureTransferDetails({to: address(this), requestedAmount: amount}),
            buyer,
            signature
        );
        if (ASSET.balanceOf(address(this)) - before != amount) revert TransferAmountMismatch();
        _credit(buyer, amount);
    }

    /// **The `balanceOf` rule for this whole contract, stated at the site that motivates it.**
    /// There are FOUR `balanceOf` reads here — two in this function and two in
    /// [`depositWithPermit2`] — and every one of them is half of a before/after pair around a
    /// single transfer. **No read is ever a solvency assertion, and none may be added.** Solvency
    /// is [`totalEscrowed`] and the per-buyer balances, nothing else: USDG is an upgradeable
    /// Paxos proxy with a blocklist, so a blocklisted contract's `balanceOf` and its entitlements
    /// disagree, and an assertion built on the former would refuse EVERY withdrawal rather than
    /// the one actually blocked. A fifth read is allowed only if it is another delta half.
    ///
    /// The delta itself makes a fee-on-transfer surprise fail loudly rather than silently
    /// under-credit.
    ///
    /// It is the EVM half of `initialize_config.rs:24-32`'s Token-2022 refusal: Solana can
    /// refuse the *class* of token at configuration time because the mint declares its
    /// extensions; here the asset is an opaque upgradeable proxy that could grow a transfer fee
    /// after deployment, so the check has to be made on every transfer instead of once.
    function _pullExact(address from, uint64 amount) internal {
        uint256 before = ASSET.balanceOf(address(this));
        ASSET.safeTransferFrom(from, address(this), amount);
        if (ASSET.balanceOf(address(this)) - before != amount) revert TransferAmountMismatch();
    }

    /// `deposit_stake.rs:75-92` — "Deposits accumulate: a second deposit adds to the first, it
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

    /// `events.rs::VoucherRedeemed` (`events.rs:201-213`), field for field and name for name. Two
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

    /// `events.rs::EscrowLimitsSet` (`events.rs:192`). Both ceilings in one event because
    /// they are only meaningful together: a per-call ceiling with no window cap bounds one
    /// redemption and nothing else.
    event EscrowLimitsSet(address indexed buyer, uint64 maxVoucherAmount, uint64 maxPerWindow);

    /// **The only door through which a buyer's money leaves on somebody else's submission.**
    ///
    /// `redeem_voucher.rs:121`. The submitter is pinned to `Config::redeemer` and is consulted
    /// about nothing else: it cannot aim the money anywhere, because the provider comes out of the
    /// signed voucher and the treasury out of Config. The pin is about `seq` — a redemption
    /// advances `seqHigh`, so anyone who could land one could void every voucher a buyer had
    /// already served (`redeem_voucher.rs:19-24`).
    ///
    /// **The whole authority over the money is the buyer's EIP-712 signature**, proved against
    /// `v.payer`, which is also the escrow's mapping key: the account spent and the key required
    /// name one party.
    ///
    /// `params()` is read ONCE, into memory, and the same `ParamSet` is used for the redeemer
    /// pin, the stake floor, the take rate and the treasury. Reading them from four calls would
    /// let a Config upgrade mid-transaction hand this function a redeemer from one parameter set
    /// and a treasury from another; `IX402Config.params`'s own note makes the same argument.
    function redeemVoucher(Voucher calldata v, bytes calldata sig) external nonReentrant {
        ParamSet memory p = CONFIG.params();
        if (msg.sender != p.redeemer) revert NotRedeemer();
        if (CONFIG.paused()) revert ProgramPaused();
        _redeem(v, sig, p);
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
    /// redeemer pin and the pause check are this function's; **every other rule is [`_redeem`]'s,
    /// reused unchanged.** A batch with its own copy of the check list would be a second place for
    /// the replay rule to live, and `test_theBatchDelegatesToTheOneRedeemPathInTheSource` pins the
    /// delegation as source text so the copy cannot appear quietly.
    ///
    /// `seq` is therefore NOT a batch-wide rule: it is `seq > seqHigh` per escrow, applied item by
    /// item, so two payers' sequences in one batch constrain each other in no way at all.
    ///
    /// `nonReentrant` sits on this external entry point only. [`_redeem`] is internal and must not
    /// carry the modifier — with it, the loop would deadlock on its second item.
    function redeemVoucherBatch(Voucher[] calldata vs, bytes[] calldata sigs)
        external
        nonReentrant
    {
        ParamSet memory p = CONFIG.params();
        if (msg.sender != p.redeemer) revert NotRedeemer();
        if (CONFIG.paused()) revert ProgramPaused();

        uint256 n = vs.length;
        if (n == 0) revert EmptyBatch();
        if (n > Constants.MAX_REDEEM_BATCH) revert BatchTooLarge();
        // Both directions, and it is checked BEFORE the loop rather than left to `sigs[i]`: a
        // short array would otherwise answer `Panic(0x32)` where an operator needs a diagnosis.
        if (sigs.length != n) revert BatchLengthMismatch();

        for (uint256 i = 0; i < n; ++i) {
            _redeem(vs[i], sigs[i], p);
        }
    }

    /// The buyer's own ceilings — `set_escrow_limits.rs`. **Deliberately NOT pause-gated**:
    /// lowering a limit is the safety direction, and an admin key must never be able to stop a
    /// buyer tightening their own. `set_paused.rs:14-21` draws the same line.
    ///
    /// `0` on either field is REFUSE, not "unlimited" (`state.rs:545-551`), which is why a
    /// never-configured escrow pays nobody and why this function is the whole of what
    /// `open_escrow.rs` used to do.
    ///
    /// `setLimitsBySig` is the meta-transaction twin, which re-proves the same
    /// authority from a signature and shares [`_setLimits`] with this one.
    function setLimits(uint64 maxVoucherAmount, uint64 maxPerWindow) external nonReentrant {
        _setLimits(msg.sender, maxVoucherAmount, maxPerWindow);
    }

    /// A write that changes nothing is refused rather than accepted silently: the event is the
    /// only record that a buyer moved their own ceiling, and an emitted no-op is an event that
    /// says a decision was taken when none was.
    function _setLimits(address buyer, uint64 maxVoucherAmount, uint64 maxPerWindow) internal {
        Escrow storage e = escrows[buyer];
        if (e.maxVoucherAmount == maxVoucherAmount && e.maxPerWindow == maxPerWindow) {
            revert EscrowLimitsUnchanged();
        }
        e.maxVoucherAmount = maxVoucherAmount;
        e.maxPerWindow = maxPerWindow;
        emit EscrowLimitsSet(buyer, maxVoucherAmount, maxPerWindow);
    }

    /// `events.rs::WithdrawRequested` (`request_withdraw.rs:39-43`), field for field. The
    /// maturity instant is carried rather than left for a reader to add `WITHDRAW_DELAY_SECONDS`
    /// onto: the delay is a constant of *this* deployment, and a client that recomputed it would
    /// be recomputing a number a redeploy can move under it.
    event WithdrawRequested(address indexed buyer, uint64 amount, uint64 availableAt);

    /// The relayed twin of [`setLimits`], and one of exactly TWO relayed doors in this contract.
    /// The relayer key can never move USDG: every money-moving path is authorised by
    /// `msg.sender == buyer`, by a buyer EIP-712 signature over an exact amount, or by a
    /// registered verifier's attestation plus 72 hours. This one exists because a buyer
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
    /// Not pause-gated, exactly as [`setLimits`] is not: `set_escrow_limits.rs:16-19` takes no
    /// `Config` at all, and "there is no account here to read a pause flag out of" is the
    /// structural form of the same promise.
    function setLimitsBySig(
        address buyer,
        uint64 maxVoucherAmount,
        uint64 maxPerWindow,
        uint64 nonce,
        uint64 deadline,
        bytes calldata sig
    ) external nonReentrant {
        _consumeAuth(
            buyer,
            Voucher712.hashSetLimits(buyer, maxVoucherAmount, maxPerWindow, nonce, deadline),
            nonce,
            deadline,
            sig
        );
        _setLimits(buyer, maxVoucherAmount, maxPerWindow);
    }

    /// Starts the buyer's exit clock — `request_withdraw.rs:27-44`. It moves no money, so it is
    /// not pause-gated and it may be relayed.
    ///
    /// The delay is `WITHDRAW_DELAY_SECONDS`, sized by `constants.rs:285`'s build-time assertion
    /// rather than chosen: every voucher the buyer signed *before* asking for their money back is
    /// dead before the withdrawal matures (3,600 > 2,220). `initialize` re-states that inequality
    /// because Solidity has no `const _: () = assert!(…)`.
    ///
    /// It does NOT block [`redeemVoucher`], exactly as the Anchor original does not: a voucher the
    /// buyer signs *after* the request is the platform's risk, not the buyer's.
    function requestWithdraw(uint64 amount) external nonReentrant {
        _requestWithdraw(msg.sender, amount);
    }

    /// The relayed twin, and the second and last of the two. Starting a clock moves no money,
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
        _consumeAuth(
            buyer,
            Voucher712.hashRequestWithdraw(buyer, amount, nonce, deadline),
            nonce,
            deadline,
            sig
        );
        _requestWithdraw(buyer, amount);
    }

    /// `handle_request_withdraw` (`request_withdraw.rs:27-44`), line for line.
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
    /// `WITHDRAW_DELAY_SECONDS (3,600) > MAX_VOUCHER_REDEEMABLE_LIFE_SECONDS (2,220)` guarantees
    /// that a voucher signed **before** this call cannot outlive the delay. It says nothing about
    /// one signed after: a voucher signed at `T + 1381` or later is still redeemable past
    /// `T + 3600`, [`withdraw`] reads no outstanding-voucher state and pays `min(requested,
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

    /// `events.rs::EscrowWithdrawn` (`withdraw.rs:145-150`) minus one field. The Anchor event
    /// carries `destination` because on Solana the buyer names a token account; here the
    /// recipient is `msg.sender`, which is also the indexed `buyer`, so a `destination` field
    /// would be a second copy of one address and an indexer could not tell them apart anyway.
    ///
    /// Both `requested` and `amount` are carried, and they differ whenever a redemption landed
    /// during the hour. An indexer that saw only `amount` could not tell a partly-filled exit
    /// from a smaller one.
    event EscrowWithdrawn(address indexed buyer, uint64 requested, uint64 amount);

    /// The buyer takes their own money out of their own escrow — `handle_withdraw`
    /// (`withdraw.rs:113-152`), and the second half of the two-step exit [`requestWithdraw`]
    /// opens. It is the door this whole PR exists to keep open: a full compromise of every key
    /// held in an environment variable must be unable to stop a buyer taking their own money out,
    /// and unable to take it for them.
    ///
    /// # It takes no destination and pays `msg.sender`
    ///
    /// `withdraw.rs:83-101` takes a `destination` token account and argues the program should not
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
    /// The design gives relayed twins to [`setLimitsBySig`] and [`requestWithdrawBySig`] and stops
    /// there. [`requestWithdraw`] already served the one-hour delay, so by the time this function
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
    /// # It is never pause-gated
    ///
    /// `withdraw.rs:22-33` is explicit that its `Config` is loaded for one field and that there is
    /// "no `paused` check anywhere in this file". An admin key that could freeze an owner's exit
    /// is exactly what the pause rule (owner exits are never paused) exists to prevent, and the
    /// party
    /// holding that switch is the party this door protects people from. Nothing here is for a later
    /// reader to "close
    /// the gap" on. This port does not load `Config` at all, because the one field Anchor needs it
    /// for — `stake_mint` — is `ASSET`, an immutable of this contract.
    ///
    /// # What it pays, and what it refuses
    ///
    /// `min(requested, balance)`, exactly as `withdraw.rs:120`: a redemption may have landed
    /// during the wait, which is the intended ordering — the platform collects what the buyer
    /// already signed for, and the buyer takes the rest. The request is then spent whether or not
    /// it was filled (`withdraw.rs:136-138`), because a partly-filled request left standing would
    /// be a claim the buyer never renewed against a balance the platform is still collecting from.
    ///
    /// An **empty** escrow is refused instead (`withdraw.rs:123`, `EscrowInsufficient`) rather
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
    /// message the buyer already agreed to. Each door hashes a DISTINCT typehash
    /// (`Voucher712`'s three), so an authorisation collected at one door cannot be presented at
    /// another; that is the EIP-712 form of `attestation.rs:126`'s
    /// `assert!(ATTESTATION_MESSAGE_LEN != VOUCHER_MESSAGE_LEN)`, and strictly stronger, because
    /// two lengths can be made to collide by a future field and two typehashes cannot.
    ///
    /// **One nonce serves both doors.** `authNonce` is a single counter on the escrow, not one
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
    /// `buyer == address(0)` is belt over brace: [`_recover`] refuses a recovery to the zero
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

        Escrow storage e = escrows[buyer];
        if (nonce != e.authNonce) revert BadNonce();
        if (_recover(_hashTypedDataV4(structHash), sig) != buyer) revert SignerIsNotBuyer();

        e.authNonce = nonce + 1;
    }

    /// The whole rule set, in one internal function so the batch reuses it UNCHANGED — a
    /// batch that re-spelled these checks would be a second place for the replay rule to live.
    ///
    /// # The order, and where each line comes from
    ///
    /// `redeem_voucher.rs:38-43` states the Anchor order as "redeemer, pause, amount, `pay_to`,
    /// window, signature, sequence, spending limits, stake floor, balance". This function is that
    /// list minus `pay_to` (the EVM voucher drops the field: on Solana it makes the *off-chain*
    /// `payTo` a
    /// signed fact against the escrow PDA, and here `escrows[v.payer]` is derived from the signed
    /// payer with no second address to disagree with) and with **one deliberate reordering**:
    ///
    /// **`seq` is checked BEFORE the signature; `redeem_voucher.rs:137-144` checks it after.**
    /// The EVM design specifies it here. It is strictly cheaper — a stale voucher is
    /// refused without paying for `ecrecover` — and it leaks nothing, because `seqHigh` is public
    /// state that `escrowOf` already returns to anybody who asks. Recorded in
    /// `docs/divergences.md`.
    ///
    /// **`ProviderBelowMinimumStake` is reinstated** at the Anchor program's position, after the
    /// window limit and before the balance check (`redeem_voucher.rs:148-153`). The EVM design's
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
    /// paid out. This function pays out: every state change — `seqHigh`, `balance`,
    /// `spentInWindow`, `windowStartedAt`, `totalRedeemed`, `totalEscrowed` — is written before
    /// either transfer, and `nonReentrant` on the entry point is load-bearing here in a way it is
    /// not on the funding doors, where the delta assertion overlaps it. USDG is an upgradeable
    /// Paxos proxy, so "this token has no callbacks" is a statement about today only.
    ///
    /// A refusal rolls all of it back, exactly as an Anchor `require!` does — so a redemption
    /// refused for `EscrowInsufficient` leaves `seqHigh` where it was
    /// (`tests/escrow.rs::an_underfunded_escrow_refuses_without_consuming_the_sequence`).
    function _redeem(Voucher calldata v, bytes calldata sig, ParamSet memory p) internal {
        // Through [`Cast.toUint64`] like every other narrowing in `src/`, and not because
        // anybody expects it to fire: `block.timestamp` reaches `2^64` in the year
        // 584,942,419,325. It is here because a file that checks two of its three
        // narrowings and waives the third teaches the next reader that the waiver is a
        // judgement call. It is not; `Cast`'s NatSpec carries the rule.
        uint64 nowTs = Cast.toUint64(block.timestamp);

        if (v.amount == 0) revert ZeroAmount(); // redeem_voucher.rs:125

        // `attestation.rs:476-491` (`require_valid_voucher_window`), in its order. The Anchor
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
        //   `expiresAt + 1800 <= nowTs + 2220`. Move either of them below this line and a voucher
        //   with a large `expiresAt` (leg one) or a large `issuedAt` (leg two) answers
        //   `Panic(0x11)` instead of its named refusal. Both legs are pinned, at exact and
        //   `type(uint64).max` inputs, by `test_boundary_theVoucherClockWindowIsBoundedAtBothEnds`.
        //
        // Anchor needs neither argument: `attestation.rs:483,487` use `saturating_add`, so there
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

        // `state.rs::admit_seq` (`state.rs:576-580`). Strictly increasing, gaps allowed: exactly
        // one redemption per `(buyer, seq)` as a fact of the chain, with one `uint64` and no
        // bitmap. Moved above the signature by design — see the note above.
        Escrow storage e = escrows[v.payer];
        if (v.seq == 0) revert VoucherSeqZero();
        if (v.seq <= e.seqHigh) revert VoucherSeqNotIncreasing();

        // `redeem_voucher.rs:137-142`. The four recovery guards are [`_recover`]'s; the
        // comparison against the SIGNED `v.payer` is this function's, and it is the whole
        // authority over the money.
        if (_recover(_hashTypedDataV4(Voucher712.hashVoucher(v)), sig) != v.payer) {
            revert SignerIsNotPayer();
        }

        // `state.rs::admit_spend` (`state.rs:591-612`). A limit of `0` refuses everything, so an
        // unarmed escrow needs no separate branch.
        if (v.amount > e.maxVoucherAmount) revert VoucherExceedsPerCallLimit();
        uint64 carried = Window.decay(e.spentInWindow, e.windowStartedAt, nowTs);
        uint256 spent = uint256(carried) + v.amount;
        if (spent > e.maxPerWindow) revert EscrowWindowLimitExceeded();

        // `redeem_voucher.rs:148-153` — being paid is the counterpart of being slashable.
        // `bonded` only: stake already asked back is not backing anybody's traffic
        // (`state.rs:442-447`).
        if (STAKE.bondedOf(v.provider) < p.minimumStake) revert ProviderBelowMinimumStake();

        // `redeem_voucher.rs:155-158`. Its job is the DIAGNOSIS: without it `e.balance -=` still
        // refuses, but as `Panic(0x11)`, which is not what an operator needs to read.
        if (e.balance < v.amount) revert EscrowInsufficient();

        // --- effects -------------------------------------------------------------------------
        e.seqHigh = v.seq;
        e.balance -= v.amount;
        // The truncation is unreachable — `spent <= e.maxPerWindow`, checked four lines above, and
        // `maxPerWindow` is a `uint64`. It goes through [`Cast.toUint64`] anyway, and it is
        // narrowed ONCE into a named local rather than cast at each of the two places it is used:
        // the second of those was twenty-four lines from its guard, inside the event argument list.
        // An earlier version argued for a bare cast on the ground that the bound here is the guard
        // itself rather than a claim about a caller — which is `Window.narrow`'s own losing
        // argument restated, not a new one. `Cast`'s NatSpec carries the rule.
        uint64 spentAfter = Cast.toUint64(spent);
        e.spentInWindow = spentAfter;
        // `state.rs:609-611` — never moved backwards: a clock that stepped back must not hand
        // capacity to whoever noticed.
        e.windowStartedAt = nowTs > e.windowStartedAt ? nowTs : e.windowStartedAt;
        e.totalRedeemed += v.amount; // redeem_voucher.rs:206-209
        totalEscrowed -= v.amount; // the pooled solvency counter; `totalFunded` is NOT touched

        (uint64 fee, uint64 providerAmount) = Fee.splitFee(v.amount, p.takeRateBps);

        // --- interactions --------------------------------------------------------------------
        // Guarded on zero exactly as `redeem_voucher.rs:170`/`:186` are, so a 0% take rate makes
        // no call at all and a blocklisted treasury cannot refuse a payment of nothing.
        if (providerAmount > 0) ASSET.safeTransfer(v.provider, providerAmount);
        if (fee > 0) ASSET.safeTransfer(p.treasury, fee);

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
    }

    /// The append budget the D-7 upgrade-safety gate spends. A new field is added ABOVE this
    /// line and the array shrinks by exactly the slots it consumes — the script refuses
    /// anything else.
    uint256[50] private __gap;
}
