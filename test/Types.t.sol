// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {stdError} from "forge-std/StdError.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {
    VOUCHER_TYPEHASH,
    SLASH_ATTESTATION_TYPEHASH,
    SET_LIMITS_TYPEHASH,
    REQUEST_WITHDRAW_TYPEHASH,
    SlashStatus,
    ResponseClass,
    CancelReason,
    Voucher,
    SlashAttestation,
    SetLimits,
    RequestWithdraw,
    ParamSet
} from "../src/Types.sol";
import {Constants} from "../src/Constants.sol";
import {
    VoucherAbiProbe,
    SlashAttestationAbiProbe,
    SetLimitsAbiProbe,
    RequestWithdrawAbiProbe,
    ParamSetAbiProbe
} from "./TypeAbiProbe.sol";

/// The EIP-712 typehash drift gate (D-7).
///
/// It replaces the Anchor build-time assertion
/// `const _: () = assert!(ATTESTATION_MESSAGE_LEN != VOUCHER_MESSAGE_LEN)`, and it has to answer
/// a strictly harder question than that one did. On Solana the signed bytes are a hand-written
/// byte layout, so a struct field and the layout that serialises it are visibly the same code.
/// Under EIP-712 the signed bytes come from a *type string*, and a type string is a string
/// literal: nothing in the language ties `struct Voucher`'s fields to `"Voucher(address payer,…)"`.
///
/// # Three halves, and none of them is sufficient alone
///
/// Each catches a drift the others cannot see. Naming them, because a gate whose coverage is
/// unstated is a gate someone will later credit with more than it does:
///
///  1. **ABI-derived** (`test_everyRegisteredTypehashMatchesItsCompiledStruct`) — rebuilds the
///     type string from the *compiled struct*, so a field renamed, reordered, retyped, added or
///     removed changes the derived hash and fails. This is the only half that can see the struct
///     at all. It cannot see a rename applied consistently to the struct *and* the type string,
///     because from inside the file that is self-consistent.
///  2. **Canonical string** (`test_everyRegisteredTypehashMatchesItsCanonicalString`) — pins each
///     constant to its type string spelled out a second time. Stops someone silencing half 1 by
///     editing only the constant.
///  3. **Pinned wire digest** (`test_everyRegisteredTypehashMatchesItsPinnedWireValue`) — pins
///     each typehash to a hand-typed 32-byte literal. This is the fidelity half. Halves 1 and 2
///     both prove *self*-consistency and go green on a rename applied everywhere inside this
///     repo; the digest does not, because it is the number the backend's `ChainAdapter` and the
///     frontend's signer must independently reproduce. Changing one of these literals is a
///     wire-breaking change that invalidates every signature already issued, and it should be as
///     hard to do by accident as `test_constantsMatchTheAnchorProgram` makes changing a constant.
///
/// # And the enumeration is itself an assertion
///
/// The first version of this gate named each probe by hand, listed four literal assertions, and
/// used a fixed `bytes32[4]` for distinctness. A review added a fifth signed struct with a
/// deliberately wrong typehash and no probe: **the suite stayed green**, because the gate proved
/// what it was pointed at rather than what exists. That is the same failure shape one level up
/// from the one it was built to fix: a gate that answers a different question than the one it
/// names.
///
/// So `_registry()` is the single list, and `test_everyTypehashDeclaredInTypesSolIsRegistered`
/// reads `src/Types.sol` and fails unless every `bytes32 constant …_TYPEHASH` it declares appears
/// in it. Registering one then forces a probe (the artifact read fails without it), a canonical
/// string, a pinned digest, and a slot in the pairwise-distinctness matrix — all four loops
/// iterate the registry, none of them has a hardcoded arity.
contract TypesTest is Test {
    using stdJson for string;

    /// One EIP-712 type under gate.
    struct GatedType {
        /// The identifier as it is spelled in `src/Types.sol`. Matched against the source text.
        string constantName;
        /// The probe contract in `TypeAbiProbe.sol` whose ABI describes the struct.
        string probeContract;
        /// The constant's compiled value.
        bytes32 typehash;
        /// The canonical EIP-712 type string, written out a second time (half 2).
        string canonical;
        /// The digest, hand-typed (half 3). Not `keccak256(canonical)` — the point is that it is
        /// an independent copy of the number that goes on the wire.
        bytes32 pinnedWire;
    }

    /// One entry of a solc ABI artifact's `inputs[0].components` — a struct field as the
    /// compiler describes it.
    ///
    /// **Field order here is not free.** `vm.parseJson` encodes a JSON object's members sorted
    /// by key, so the decode below is positional against `internalType` < `name` < `type`. The
    /// last is spelled `abiType` because `type` is a Solidity keyword; only the position
    /// matters. A field whose own type were a struct would carry a fourth key (`components`)
    /// and this decode would revert rather than mis-read — which is the right failure for a
    /// change that would also need a nested EIP-712 type string.
    struct AbiComponent {
        string internalType;
        string name;
        string abiType;
    }

    VoucherAbiProbe internal voucherProbe;
    SlashAttestationAbiProbe internal slashAttestationProbe;
    SetLimitsAbiProbe internal setLimitsProbe;
    RequestWithdrawAbiProbe internal requestWithdrawProbe;
    ParamSetAbiProbe internal paramSetProbe;

    /// **Deploying the probes is not decoration — it is what makes the gate run at all.**
    ///
    /// `forge test` writes artifacts sparsely: a contract no test contract references is
    /// compiled but never emitted to `out/`, so the artifact reads below would find no file. A
    /// probe reachable from here is a probe `forge test` always emits, on a clean checkout with
    /// no prior `forge build`. Measured both ways.
    function setUp() public {
        voucherProbe = new VoucherAbiProbe();
        slashAttestationProbe = new SlashAttestationAbiProbe();
        setLimitsProbe = new SetLimitsAbiProbe();
        requestWithdrawProbe = new RequestWithdrawAbiProbe();
        paramSetProbe = new ParamSetAbiProbe();
    }

    /// Every gated type, in one list. Adding a `*_TYPEHASH` to `src/Types.sol` without adding a
    /// row here fails `test_everyTypehashDeclaredInTypesSolIsRegistered`; adding a row without a
    /// probe fails the artifact read; adding one without a correct canonical string or pinned
    /// digest fails halves 2 and 3.
    function _registry() internal pure returns (GatedType[] memory g) {
        g = new GatedType[](4);
        g[0] = GatedType({
            constantName: "VOUCHER_TYPEHASH",
            probeContract: "VoucherAbiProbe",
            typehash: VOUCHER_TYPEHASH,
            canonical: "Voucher(address payer,address provider,uint64 amount,bytes32 resourceHash,"
                "bytes32 requestHash,uint64 seq,uint64 issuedAt,uint64 expiresAt)",
            pinnedWire: 0x397e399cf6e4a1b85e582b06b939251807210d31d2743a9bdfece4c1d8ad9435
        });
        g[1] = GatedType({
            constantName: "SLASH_ATTESTATION_TYPEHASH",
            probeContract: "SlashAttestationAbiProbe",
            typehash: SLASH_ATTESTATION_TYPEHASH,
            canonical: "SlashAttestation(bytes32 requestId,address provider,address beneficiary,"
                "uint8 status,uint64 penalty,bytes32 policy,uint64 issuedAt,uint64 expiresAt)",
            pinnedWire: 0x720add31d977b34e2bd07233549b49e34cea20ffa4e845af7b6bd5cc4f52ddca
        });
        g[2] = GatedType({
            constantName: "SET_LIMITS_TYPEHASH",
            probeContract: "SetLimitsAbiProbe",
            typehash: SET_LIMITS_TYPEHASH,
            canonical: "SetLimits(address buyer,uint64 maxVoucherAmount,uint64 maxPerWindow,"
                "uint64 nonce,uint64 deadline)",
            pinnedWire: 0x6409f2b846e600c202b701219606d813366c1189be8b2aec38c50a5e8136dafc
        });
        g[3] = GatedType({
            constantName: "REQUEST_WITHDRAW_TYPEHASH",
            probeContract: "RequestWithdrawAbiProbe",
            typehash: REQUEST_WITHDRAW_TYPEHASH,
            canonical: "RequestWithdraw(address buyer,uint64 amount,uint64 nonce,uint64 deadline)",
            pinnedWire: 0xc8cc528b1ce6b0f90c78a68b0a6e8bf221eaae4e39d597faa197eb0b950f5504
        });
    }

    // -------------------------------------------------------------------------------------
    // The enumeration is the assertion
    // -------------------------------------------------------------------------------------

    /// **The gate that stops the gate being opt-in.** Reads `src/Types.sol` and requires every
    /// `bytes32 constant …_TYPEHASH` it declares to be in `_registry()`, and vice versa. Without
    /// this, a fifth signed struct with a wrong typehash and no probe passes the whole suite —
    /// measured, that is exactly what happened to the previous version.
    function test_everyTypehashDeclaredInTypesSolIsRegistered() public view {
        string[] memory declared = _declaredBytes32Constants();
        GatedType[] memory g = _registry();

        assertEq(
            declared.length,
            g.length,
            "src/Types.sol declares a different number of bytes32 constants than _registry() gates"
        );

        for (uint256 i = 0; i < declared.length; i++) {
            bool found;
            for (uint256 j = 0; j < g.length; j++) {
                if (_eq(declared[i], g[j].constantName)) {
                    found = true;
                    break;
                }
            }
            assertTrue(found, string.concat("ungated typehash in src/Types.sol: ", declared[i]));
        }
        for (uint256 j = 0; j < g.length; j++) {
            bool found;
            for (uint256 i = 0; i < declared.length; i++) {
                if (_eq(declared[i], g[j].constantName)) {
                    found = true;
                    break;
                }
            }
            assertTrue(
                found,
                string.concat(
                    "_registry() names a constant Types.sol does not declare: ", g[j].constantName
                )
            );
        }
    }

    /// The naming convention the enumeration leans on. `_declaredBytes32Constants` only collects
    /// names ending in `_TYPEHASH`, so a signed type whose constant were called `FOO_HASH` would
    /// slip past it. This closes that: in `src/Types.sol` a `bytes32 constant` **is** a typehash.
    function test_everyBytes32ConstantInTypesSolIsNamedATypehash() public view {
        string[] memory all = _declaredBytes32Constants(false);
        for (uint256 i = 0; i < all.length; i++) {
            assertTrue(
                _endsWith(all[i], "_TYPEHASH"),
                string.concat("bytes32 constant in src/Types.sol not named *_TYPEHASH: ", all[i])
            );
        }
    }

    // -------------------------------------------------------------------------------------
    // Half 1 — derived from the compiled struct
    // -------------------------------------------------------------------------------------

    function test_everyRegisteredTypehashMatchesItsCompiledStruct() public view {
        GatedType[] memory g = _registry();
        for (uint256 i = 0; i < g.length; i++) {
            assertEq(
                keccak256(bytes(_eip712TypeString(g[i].probeContract))),
                g[i].typehash,
                string.concat("struct and constant have drifted: ", g[i].constantName)
            );
        }
    }

    /// The gate's own gate. A *narrowing* bug in the derivation — reading only the first field,
    /// say — could still coincidentally satisfy the loop above one day, so assert the derivation
    /// reproduces one string in full, spelled out here character for character.
    function test_theAbiDerivationReproducesTheFullTypeString() public view {
        assertEq(
            _eip712TypeString("VoucherAbiProbe"),
            "Voucher(address payer,address provider,uint64 amount,bytes32 resourceHash,"
            "bytes32 requestHash,uint64 seq,uint64 issuedAt,uint64 expiresAt)"
        );
    }

    // -------------------------------------------------------------------------------------
    // Half 2 — the canonical string, written a second time
    // -------------------------------------------------------------------------------------

    function test_everyRegisteredTypehashMatchesItsCanonicalString() public pure {
        GatedType[] memory g = _registry();
        for (uint256 i = 0; i < g.length; i++) {
            assertEq(
                keccak256(bytes(g[i].canonical)),
                g[i].typehash,
                string.concat("constant does not hash its canonical string: ", g[i].constantName)
            );
        }
    }

    // -------------------------------------------------------------------------------------
    // Half 3 — the wire digest, pinned
    // -------------------------------------------------------------------------------------

    /// **These 32-byte literals are the interface.** Every EIP-712 digest the backend signs and
    /// every one the frontend's wallet is asked to sign begins with one of them, so a change here
    /// invalidates in-flight signatures across three repositories at once. Halves 1 and 2 cannot
    /// see such a change if it is applied consistently inside `evm/`; this one can, because it is
    /// a copy of the number rather than a copy of the source.
    function test_everyRegisteredTypehashMatchesItsPinnedWireValue() public pure {
        GatedType[] memory g = _registry();
        for (uint256 i = 0; i < g.length; i++) {
            assertEq(
                g[i].typehash,
                g[i].pinnedWire,
                string.concat("wire-breaking change to ", g[i].constantName)
            );
        }
    }

    // -------------------------------------------------------------------------------------
    // Cross-kind replay
    // -------------------------------------------------------------------------------------

    /// A signature collected for one struct must not satisfy another door. The loop is over
    /// `_registry()` and has no fixed arity, so a fifth type joins the matrix by being
    /// registered — the previous `bytes32[4]` silently stopped covering anything added after it.
    function test_registeredTypehashesArePairwiseDistinct() public pure {
        GatedType[] memory g = _registry();
        assertTrue(g.length >= 2, "distinctness needs at least two types");
        for (uint256 i = 0; i < g.length; i++) {
            for (uint256 j = i + 1; j < g.length; j++) {
                assertTrue(
                    g[i].typehash != g[j].typehash,
                    string.concat(
                        "typehash collision: ", g[i].constantName, " / ", g[j].constantName
                    )
                );
            }
        }
    }

    // -------------------------------------------------------------------------------------
    // Struct encoding
    // -------------------------------------------------------------------------------------

    /// Declaration order, asserted positionally.
    ///
    /// The previous version of this test built named struct literals and asserted each probe
    /// returned the field it was handed. Named literals are keyed rather than positional, so it
    /// passed under *every* field reordering — including the `amount` ↔ `seq` swap, which on EVM
    /// silently makes every voucher's price its sequence number. It was credited with proving
    /// field order and proved nothing about it.
    ///
    /// This decodes `abi.encode(v)` as a flat positional tuple instead. Every value is distinct,
    /// so a swap of two same-width fields is caught by value; a retype is caught because
    /// `abi.decode` of a dirty word into a narrower type reverts.
    function test_structsAbiEncodeInDeclarationOrder() public pure {
        Voucher memory v = Voucher({
            payer: address(0x1111),
            provider: address(0x2222),
            amount: 3,
            resourceHash: bytes32(uint256(4)),
            requestHash: bytes32(uint256(5)),
            seq: 6,
            issuedAt: 7,
            expiresAt: 8
        });
        (
            address payer,
            address provider,
            uint64 amount,
            bytes32 resourceHash,
            bytes32 requestHash,
            uint64 seq,
            uint64 issuedAt,
            uint64 expiresAt
        ) = abi.decode(
            abi.encode(v), (address, address, uint64, bytes32, bytes32, uint64, uint64, uint64)
        );
        assertEq(payer, address(0x1111), "Voucher field 0");
        assertEq(provider, address(0x2222), "Voucher field 1");
        assertEq(amount, 3, "Voucher field 2");
        assertEq(resourceHash, bytes32(uint256(4)), "Voucher field 3");
        assertEq(requestHash, bytes32(uint256(5)), "Voucher field 4");
        assertEq(seq, 6, "Voucher field 5");
        assertEq(issuedAt, 7, "Voucher field 6");
        assertEq(expiresAt, 8, "Voucher field 7");

        SlashAttestation memory a = SlashAttestation({
            requestId: bytes32(uint256(1)),
            provider: address(0x2222),
            beneficiary: address(0x3333),
            status: uint8(ResponseClass.DataFail),
            penalty: 5,
            policy: bytes32(uint256(6)),
            issuedAt: 7,
            expiresAt: 8
        });
        (
            bytes32 requestId,
            address aProvider,
            address beneficiary,
            uint8 status,
            uint64 penalty,
            bytes32 policy,
            uint64 aIssuedAt,
            uint64 aExpiresAt
        ) = abi.decode(
            abi.encode(a), (bytes32, address, address, uint8, uint64, bytes32, uint64, uint64)
        );
        assertEq(requestId, bytes32(uint256(1)), "SlashAttestation field 0");
        assertEq(aProvider, address(0x2222), "SlashAttestation field 1");
        assertEq(beneficiary, address(0x3333), "SlashAttestation field 2");
        assertEq(status, 3, "SlashAttestation field 3");
        assertEq(penalty, 5, "SlashAttestation field 4");
        assertEq(policy, bytes32(uint256(6)), "SlashAttestation field 5");
        assertEq(aIssuedAt, 7, "SlashAttestation field 6");
        assertEq(aExpiresAt, 8, "SlashAttestation field 7");

        SetLimits memory s = SetLimits({
            buyer: address(0x1111),
            maxVoucherAmount: 2,
            maxPerWindow: 3,
            nonce: 4,
            deadline: 5
        });
        (
            address sBuyer,
            uint64 maxVoucherAmount,
            uint64 maxPerWindow,
            uint64 sNonce,
            uint64 sDeadline
        ) = abi.decode(abi.encode(s), (address, uint64, uint64, uint64, uint64));
        assertEq(sBuyer, address(0x1111), "SetLimits field 0");
        assertEq(maxVoucherAmount, 2, "SetLimits field 1");
        assertEq(maxPerWindow, 3, "SetLimits field 2");
        assertEq(sNonce, 4, "SetLimits field 3");
        assertEq(sDeadline, 5, "SetLimits field 4");

        RequestWithdraw memory r =
            RequestWithdraw({buyer: address(0x1111), amount: 2, nonce: 3, deadline: 4});
        (address rBuyer, uint64 rAmount, uint64 rNonce, uint64 rDeadline) =
            abi.decode(abi.encode(r), (address, uint64, uint64, uint64));
        assertEq(rBuyer, address(0x1111), "RequestWithdraw field 0");
        assertEq(rAmount, 2, "RequestWithdraw field 1");
        assertEq(rNonce, 3, "RequestWithdraw field 2");
        assertEq(rDeadline, 4, "RequestWithdraw field 3");

        // `ParamSet` is the odd one out here: it is not an EIP-712 struct and no signature binds
        // its order. It is in this test because it is `X402Config._params`, a
        // **storage** struct occupying slots 1-3 behind a UUPS proxy — so a reorder does not
        // change a message, it silently changes the layout the next implementation reads, and
        // `admin`/`treasury`/`redeemer` come back as each other. It also wastes 12 bytes in slot
        // 1 (`treasury` is followed by a second `address` that cannot fit beside it), which makes
        // "pack it better" a plausible edit. The storage-layout gate (`script/check-layout.sh`)
        // also catches that edit; this test is the earlier, cheaper red in front of it. Every value
        // below is distinct, including across the four `uint16`s, so any transposition is caught by
        // value.
        ParamSet memory ps = ParamSet({
            treasury: address(0x1111),
            redeemer: address(0x2222),
            unbondingPeriodSeconds: 3,
            minimumStake: 4,
            penaltyAmount: 5,
            verifierDailyCap: 6,
            takeRateBps: 7,
            slashAgentBps: 8,
            slashPlatformBps: 9,
            slashCapBps: 10
        });
        (
            address pTreasury,
            address pRedeemer,
            uint64 pUnbonding,
            uint64 pMinimumStake,
            uint64 pPenaltyAmount,
            uint64 pVerifierDailyCap,
            uint16 pTakeRateBps,
            uint16 pSlashAgentBps,
            uint16 pSlashPlatformBps,
            uint16 pSlashCapBps
        ) = abi.decode(
            abi.encode(ps),
            (address, address, uint64, uint64, uint64, uint64, uint16, uint16, uint16, uint16)
        );
        assertEq(pTreasury, address(0x1111), "ParamSet field 0");
        assertEq(pRedeemer, address(0x2222), "ParamSet field 1");
        assertEq(pUnbonding, 3, "ParamSet field 2");
        assertEq(pMinimumStake, 4, "ParamSet field 3");
        assertEq(pPenaltyAmount, 5, "ParamSet field 4");
        assertEq(pVerifierDailyCap, 6, "ParamSet field 5");
        assertEq(pTakeRateBps, 7, "ParamSet field 6");
        assertEq(pSlashAgentBps, 8, "ParamSet field 7");
        assertEq(pSlashPlatformBps, 9, "ParamSet field 8");
        assertEq(pSlashCapBps, 10, "ParamSet field 9");
    }

    /// `ParamSet`'s **width and order**, read back out of solc rather than out of the source text.
    ///
    /// The positional `abi.encode` assertions above see order and **nothing about width**:
    /// `abi.encode` pads every field to a 32-byte word, so widening `uint64 minimumStake` to
    /// `uint128` decodes identically and leaves the whole suite green — while moving `_params`
    /// from 3 storage slots to 4 and `__gap` from slot 4 to slot 5. Behind a live UUPS proxy that
    /// is the exact layout break the order pin was added to prevent, arriving through the one
    /// property the pin could not see. Measured: 56 of 56 green under that widen.
    ///
    /// The compiled ABI carries the width. This asserts two strings built entirely from
    /// `ParamSetAbiProbe`'s artifact — the canonical tuple (`(address,address,uint64,…)`), which
    /// is order plus width and nothing else, and the named form, which adds the field names. Both
    /// are derived by solc; neither is a re-reading of `src/Types.sol`.
    ///
    /// What it still cannot see: `__gap`'s size, and a field inserted into `X402Config` *before*
    /// `_params`. Those move the layout without touching this struct at all, and only a layout
    /// snapshot catches them (`script/check-layout.sh`).
    function test_paramSetCarriesItsDeclaredWidthsAndOrder() public view {
        assertEq(
            _abiTupleTypeString("ParamSetAbiProbe"),
            "(address,address,uint64,uint64,uint64,uint64,uint16,uint16,uint16,uint16)",
            "ParamSet canonical ABI tuple: order AND width"
        );
        assertEq(
            _eip712TypeString("ParamSetAbiProbe"),
            "ParamSet(address treasury,address redeemer,uint64 unbondingPeriodSeconds,"
            "uint64 minimumStake,uint64 penaltyAmount,uint64 verifierDailyCap,uint16 takeRateBps,"
            "uint16 slashAgentBps,uint16 slashPlatformBps,uint16 slashCapBps)",
            "ParamSet's fields, named and in order"
        );
        assertTrue(
            bytes(vm.readFile(_artifactPath("ParamSetAbiProbe"))).length > 0,
            "no artifact emitted for probe ParamSetAbiProbe"
        );
    }

    /// Its only job is to keep the four probe contracts referenced from a test contract, which is
    /// what makes `forge test` emit their artifacts (see `setUp`). It asserts each probe returns
    /// the one field it was handed, which proves nothing beyond "the call went through" —
    /// `test_structsAbiEncodeInDeclarationOrder` is where field order is actually pinned. Named
    /// for what it does.
    function test_probeArtifactsAreEmittedBecauseTheProbesAreReferenced() public view {
        Voucher memory v = Voucher({
            payer: address(0xA11CE),
            provider: address(0xB0B),
            amount: 7,
            resourceHash: keccak256("resource"),
            requestHash: keccak256("request"),
            seq: 1,
            issuedAt: 100,
            expiresAt: 400
        });
        assertEq(voucherProbe.probe(v), 7);

        SlashAttestation memory a = SlashAttestation({
            requestId: keccak256("request-id"),
            provider: address(0xB0B),
            beneficiary: address(0xA11CE),
            status: uint8(ResponseClass.DataFail),
            penalty: 11,
            policy: keccak256("policy"),
            issuedAt: 100,
            expiresAt: 400
        });
        assertEq(slashAttestationProbe.probe(a), 11);

        SetLimits memory s = SetLimits({
            buyer: address(0xA11CE),
            maxVoucherAmount: 5,
            maxPerWindow: 50,
            nonce: 3,
            deadline: 400
        });
        assertEq(setLimitsProbe.probe(s), 3);

        RequestWithdraw memory r =
            RequestWithdraw({buyer: address(0xA11CE), amount: 9, nonce: 4, deadline: 400});
        assertEq(requestWithdrawProbe.probe(r), 4);

        // The artifacts the three typehash halves read must actually be on disk by now.
        GatedType[] memory g = _registry();
        for (uint256 i = 0; i < g.length; i++) {
            assertTrue(
                bytes(vm.readFile(_artifactPath(g[i].probeContract))).length > 0,
                string.concat("no artifact emitted for probe ", g[i].probeContract)
            );
        }
    }

    // -------------------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------------------

    /// The Anchor invariant WITHDRAW_DELAY > CLOCK_SKEW + VOUCHER_MAX_LIFETIME + REDEEM_GRACE,
    /// derived rather than typed, exactly as constants.rs derives it.
    ///
    /// This is half of what `constants.rs:285`'s `const _: () = assert!(…)` was. The other half —
    /// a `require` inside `X402Escrow.initialize` — lives there, and `Constants.sol` says so at
    /// the constant. Nothing in this test stops a proxy being initialised into a violating state.
    function test_withdrawDelayOutlivesTheLongestRedeemableVoucher() public pure {
        uint64 life = Constants.CLOCK_SKEW_TOLERANCE_SECONDS
            + Constants.VOUCHER_MAX_LIFETIME_SECONDS + Constants.REDEEM_GRACE_SECONDS;
        assertEq(life, 2220);
        assertEq(Constants.MAX_VOUCHER_REDEEMABLE_LIFE_SECONDS, life);
        assertGt(Constants.WITHDRAW_DELAY_SECONDS, life);
    }

    /// The numbers copied out of constants.rs, pinned one by one. A ported constant that drifts
    /// from its Anchor source is a divergence between the two chains' behaviour, and the whole
    /// point of copying rather than re-deriving them is that one test matrix covers both.
    function test_constantsMatchTheAnchorProgram() public pure {
        assertEq(Constants.SLASH_DELAY_SECONDS, 259_200); // 72 * 3_600
        assertEq(Constants.WITHDRAW_DELAY_SECONDS, 3_600);
        assertEq(Constants.REDEEM_GRACE_SECONDS, 1_800); // 30 * 60
        assertEq(Constants.VOUCHER_MAX_LIFETIME_SECONDS, 300); // 5 * 60
        assertEq(Constants.CLOCK_SKEW_TOLERANCE_SECONDS, 120);
        assertEq(Constants.SLASH_WINDOW_SECONDS, 86_400);
        assertEq(Constants.SLASH_EXECUTION_GRACE_SECONDS, 604_800); // 7 * 86_400
        assertEq(Constants.MAX_ATTESTATION_LIFETIME_SECONDS, 604_800); // 7 * 86_400
        assertEq(Constants.MAX_VERIFIER_KEY_LIFETIME_SECONDS, 31_536_000); // 365 * 86_400
        assertEq(Constants.MIN_UNBONDING_PERIOD_SECONDS, 950_400); // 11 * 86_400
        assertEq(Constants.MAX_UNBONDING_PERIOD_SECONDS, 2_592_000); // 30 * 24 * 3_600
        assertEq(Constants.MAX_TAKE_RATE_BPS, 3_000);
        assertEq(Constants.MAX_SLASH_CAP_BPS, 5_000);
        assertEq(Constants.BPS_DENOMINATOR, 10_000);
        assertEq(Constants.MAX_REDEEM_BATCH, 64);
    }

    /// The bounds compose: an admin can only pick an unbonding period inside [MIN, MAX], and a
    /// cap that MAX_SLASH_CAP_BPS admits still leaves the provider at least half their stake.
    function test_boundsAreCoherent() public pure {
        assertLt(Constants.MIN_UNBONDING_PERIOD_SECONDS, Constants.MAX_UNBONDING_PERIOD_SECONDS);
        assertLt(Constants.MAX_TAKE_RATE_BPS, Constants.BPS_DENOMINATOR);
        assertLe(Constants.MAX_SLASH_CAP_BPS, Constants.BPS_DENOMINATOR / 2);
    }

    /// EIP-2's low-s ceiling is exactly floor(n/2), so `s` and `n - s` cannot both be admitted.
    function test_halfNIsHalfTheCurveOrder() public pure {
        uint256 n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        assertEq(Constants.SECP256K1_HALF_N, n / 2);
    }

    /// `BPS_DENOMINATOR` is `u64` in `constants.rs` and `uint16` here (a deliberate choice), and
    /// the narrowing carries a real trap: `uint16 * uint16` evaluates in `uint16`. Demonstrated
    /// rather than described, so the fee and config code meets it here rather than in a debugger.
    function test_bpsDenominatorOverflowsIfMultipliedAsUint16() public {
        uint16 bps = 7;
        vm.expectRevert(stdError.arithmeticError);
        this.multiplyBpsNarrow(bps);

        // The rule: promote to uint256 first. Same inputs, no revert.
        assertEq(uint256(bps) * uint256(Constants.BPS_DENOMINATOR), 70_000);
        // And the intended shape is a division whose numerator is already wide.
        uint64 amount = 1_000_000;
        assertEq(uint256(amount) * bps / Constants.BPS_DENOMINATOR, 700);
    }

    /// External so `vm.expectRevert` has a call boundary to observe the panic at.
    function multiplyBpsNarrow(uint16 bps) external pure returns (uint16) {
        return bps * Constants.BPS_DENOMINATOR;
    }

    // -------------------------------------------------------------------------------------
    // Enums
    // -------------------------------------------------------------------------------------

    /// `ResponseClass`'s discriminants are *signed* — they travel inside `SlashAttestation` as
    /// `uint8 status`, and the protocol design makes DataFail the only class that may touch
    /// stake. attestation.rs writes them out explicitly for that reason; pin them here for the
    /// same one. Reordering this enum silently changes what an existing signature means.
    function test_responseClassDiscriminantsMatchTheAnchorProgram() public pure {
        assertEq(uint8(ResponseClass.Pass), 0);
        assertEq(uint8(ResponseClass.SystemError), 1);
        assertEq(uint8(ResponseClass.RequestError), 2);
        assertEq(uint8(ResponseClass.DataFail), 3);
    }

    /// `SlashStatus` carries one variant Anchor's does not: `None == 0`. On Solana "no record"
    /// is the absence of the PDA; in a Solidity mapping every unwritten slot reads as zero, so
    /// the zero value has to *be* "no record" or an unproposed request id would read as Pending.
    /// Anchor's three states keep their relative order after it, which means **every shared state
    /// is EVM = Solana + 1**. Anything comparing the two chains must map, not cast.
    function test_slashStatusReservesZeroForNoRecord() public pure {
        assertEq(uint8(SlashStatus.None), 0);
        assertEq(uint8(SlashStatus.Pending), 1);
        assertEq(uint8(SlashStatus.Executed), 2);
        assertEq(uint8(SlashStatus.Cancelled), 3);
    }

    /// events.rs's CancelReason, in its order — it is emitted, so consumers index on it.
    function test_cancelReasonDiscriminantsMatchTheAnchorProgram() public pure {
        assertEq(uint8(CancelReason.Withdrawn), 0);
        assertEq(uint8(CancelReason.Expired), 1);
        assertEq(uint8(CancelReason.VerifierUnavailable), 2);
    }

    // -------------------------------------------------------------------------------------
    // Artifact reading
    // -------------------------------------------------------------------------------------

    function _artifactPath(string memory probe) internal view returns (string memory) {
        return string.concat(vm.projectRoot(), "/out/TypeAbiProbe.sol/", probe, ".json");
    }

    /// Rebuild `Name(type field,type field,…)` from a probe contract's compiled ABI.
    ///
    /// Every part of the result comes from solc: the struct name from `internalType`, the field
    /// names and canonical types from `components`, and the order from the array itself. Nothing
    /// here is a copy of the source text, which is the whole point.
    function _eip712TypeString(string memory probe) internal view returns (string memory) {
        string memory json = vm.readFile(_artifactPath(probe));

        // `.abi[0]` is `probe(...)`: the probe contracts declare exactly one external function.
        string memory internalType = json.readString(".abi[0].inputs[0].internalType");
        AbiComponent[] memory fields =
            abi.decode(vm.parseJson(json, ".abi[0].inputs[0].components"), (AbiComponent[]));

        assertTrue(fields.length > 0, "abi: no struct components read");

        string memory out = string.concat(_structName(internalType), "(");
        for (uint256 i = 0; i < fields.length; i++) {
            if (i > 0) out = string.concat(out, ",");
            out = string.concat(out, fields[i].abiType, " ", fields[i].name);
        }
        return string.concat(out, ")");
    }

    /// The canonical ABI tuple of a probe's struct parameter — `(address,uint64,…)`, types only.
    ///
    /// Deliberately **not** derived from `_eip712TypeString` by string surgery: this reads the
    /// same `components` array and emits only `abiType`, so a field whose name changed does not
    /// move this string and a field whose *width* changed cannot fail to.
    function _abiTupleTypeString(string memory probe) internal view returns (string memory) {
        string memory json = vm.readFile(_artifactPath(probe));
        AbiComponent[] memory fields =
            abi.decode(vm.parseJson(json, ".abi[0].inputs[0].components"), (AbiComponent[]));

        assertTrue(fields.length > 0, "abi: no struct components read");

        string memory out = "(";
        for (uint256 i = 0; i < fields.length; i++) {
            if (i > 0) out = string.concat(out, ",");
            out = string.concat(out, fields[i].abiType);
        }
        return string.concat(out, ")");
    }

    /// `"struct Voucher"` -> `"Voucher"`. Fails loudly rather than returning the input, so a
    /// changed artifact shape cannot degrade this into a no-op.
    function _structName(string memory internalType) internal pure returns (string memory) {
        bytes memory b = bytes(internalType);
        assertTrue(b.length > 7, "abi: internalType too short");
        assertTrue(
            b[0] == "s" && b[1] == "t" && b[2] == "r" && b[3] == "u" && b[4] == "c" && b[5] == "t"
                && b[6] == " ",
            "abi: internalType is not a struct"
        );
        bytes memory out = new bytes(b.length - 7);
        for (uint256 i = 7; i < b.length; i++) {
            out[i - 7] = b[i];
        }
        return string(out);
    }

    // -------------------------------------------------------------------------------------
    // Source scanning
    // -------------------------------------------------------------------------------------

    function _declaredBytes32Constants() internal view returns (string[] memory) {
        return _declaredBytes32Constants(true);
    }

    /// Every `bytes32 constant <NAME>` declared at file level in `src/Types.sol`.
    ///
    /// Scans the source text, because Solidity has no way to enumerate its own file-level
    /// constants and they do not appear in any ABI. Line-based, skipping comment lines, so a
    /// declaration quoted inside a doc comment cannot register as a real one — and so writing
    /// about this scanner in `Types.sol` cannot break it.
    ///
    /// @param typehashesOnly keep only names ending in `_TYPEHASH`.
    function _declaredBytes32Constants(bool typehashesOnly)
        internal
        view
        returns (string[] memory)
    {
        bytes memory src = bytes(vm.readFile(string.concat(vm.projectRoot(), "/src/Types.sol")));
        bytes memory needle = bytes("bytes32 constant ");

        string[] memory buf = new string[](64);
        uint256 n;

        uint256 lineStart;
        for (uint256 i = 0; i <= src.length; i++) {
            if (i != src.length && src[i] != "\n") continue;

            uint256 s = lineStart;
            while (s < i && (src[s] == " " || src[s] == "\t")) s++;
            bool isComment = s + 1 < i && src[s] == "/" && src[s + 1] == "/";
            lineStart = i + 1;
            if (isComment || s >= i) continue;

            // Only a declaration starting the line counts; that is how they are written.
            if (i - s < needle.length) continue;
            bool hit = true;
            for (uint256 k = 0; k < needle.length; k++) {
                if (src[s + k] != needle[k]) {
                    hit = false;
                    break;
                }
            }
            if (!hit) continue;

            uint256 p = s + needle.length;
            uint256 q = p;
            while (q < i && _isIdentChar(src[q])) q++;
            if (q == p) continue;

            bytes memory name = new bytes(q - p);
            for (uint256 k = p; k < q; k++) {
                name[k - p] = src[k];
            }
            assertTrue(n < buf.length, "source scan: more constants than the buffer holds");
            buf[n++] = string(name);
        }

        assertTrue(n > 0, "source scan: found no bytes32 constant in src/Types.sol");

        uint256 kept;
        for (uint256 i = 0; i < n; i++) {
            if (!typehashesOnly || _endsWith(buf[i], "_TYPEHASH")) kept++;
        }
        string[] memory out = new string[](kept);
        uint256 w;
        for (uint256 i = 0; i < n; i++) {
            if (!typehashesOnly || _endsWith(buf[i], "_TYPEHASH")) out[w++] = buf[i];
        }
        return out;
    }

    function _isIdentChar(bytes1 c) internal pure returns (bool) {
        return (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || (c >= "0" && c <= "9")
            || c == "_" || c == "$";
    }

    function _endsWith(string memory s, string memory suffix) internal pure returns (bool) {
        bytes memory a = bytes(s);
        bytes memory b = bytes(suffix);
        if (b.length > a.length) return false;
        for (uint256 i = 0; i < b.length; i++) {
            if (a[a.length - b.length + i] != b[i]) return false;
        }
        return true;
    }

    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
