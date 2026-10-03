// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.24;

import {Vm} from "forge-std/Vm.sol";

import {Fixture} from "./helpers/Fixture.sol";
import {VoucherSigner} from "./helpers/VoucherSigner.sol";
import {X402Escrow} from "../src/X402Escrow.sol";
import {Voucher712} from "../src/libraries/Voucher712.sol";
import {
    Voucher,
    VOUCHER_TYPEHASH,
    SET_LIMITS_TYPEHASH,
    REQUEST_WITHDRAW_TYPEHASH
} from "../src/Types.sol";
import {Constants} from "../src/Constants.sol";
import "../src/Errors.sol";

/// A calldata door onto [`Voucher712`], whose three functions are `internal` and whose first
/// takes `calldata`. Without it `hashSetLimits` and `hashRequestWithdraw` would have no caller
/// at all outside the relayed doors, and a library nothing calls is a library nothing tests: the
/// two of them could have their arguments transposed and every other test would still be
/// green.
contract Voucher712Harness {
    function hashVoucher(Voucher calldata v) external pure returns (bytes32) {
        return Voucher712.hashVoucher(v);
    }

    function hashSetLimits(
        address buyer,
        uint64 maxVoucherAmount,
        uint64 maxPerWindow,
        uint64 nonce,
        uint64 deadline
    ) external pure returns (bytes32) {
        return Voucher712.hashSetLimits(buyer, maxVoucherAmount, maxPerWindow, nonce, deadline);
    }

    function hashRequestWithdraw(address buyer, uint64 amount, uint64 nonce, uint64 deadline)
        external
        pure
        returns (bytes32)
    {
        return Voucher712.hashRequestWithdraw(buyer, amount, nonce, deadline);
    }
}

/// The EIP-712 domain and the four recovery guards.
///
/// # What this file is defending
///
/// A signature is an authorisation, and an authorisation that is valid in a context its signer
/// did not mean is the whole failure mode. Three separate things narrow the context, and each
/// has a test here that fails if it is removed:
///
///   - `chainId` — the same buyer key controls the same address on every EVM chain, so without
///     it a voucher signed against the testnet escrow is a valid voucher against the mainnet
///     escrow of the same buyer (`test_aVoucherSignedForOneChainDoesNotVerifyOnAnother`);
///   - `verifyingContract` — `address(this)`, which behind a proxy is the PROXY, so an UPGRADE
///     keeps every outstanding voucher and only a REDEPLOY kills them
///     (`test_aVoucherSignedForOneDeploymentDoesNotVerifyOnAnother`; `Upgrade.t.sol` owns the
///     upgrade half);
///   - the struct hash — every one of the eight fields is in the preimage, proved by moving each
///     one on its own (`test_flippingAnySingleSignedFieldChangesTheRecoveredSigner`).
///
/// The Anchor program narrows the same three: `attestation.rs:425` writes `b"x402:voucher:v2"`
/// at offset 0 and `crate::ID` at 15, and the type doc at `attestation.rs:441-453` records that
/// the cluster half of that is carried by "mainnet must be deployed under a different program
/// id than devnet" — an operational rule. `chainId` makes the EVM half of it arithmetic.
///
/// # And the malleability half
///
/// `seq` is what stops a double-spend, not the signature bytes; but the backend keys idempotency
/// on the signature today, so a second valid 65-byte encoding of one authorisation is a
/// correctness bug rather than a formality. Four guards, four named errors, four tests, plus the
/// two boundary tests that pin `>` and `∈ {27, 28}` rather than merely exercising them.
contract X402EscrowDomainTest is Fixture {
    Voucher712Harness internal hasher;

    /// Robinhood Chain: 46630 is the testnet, 4663 is mainnet (`docs/chain-facts.md`). The pair
    /// is named
    /// concretely because the replay this file refuses is exactly "testnet voucher, mainnet
    /// escrow", and a test that only proves `31337 != 1` proves it for nobody's deployment.
    uint256 internal constant TESTNET = 46630;
    uint256 internal constant MAINNET = 4663;

    function setUp() public virtual override {
        super.setUp();
        hasher = new Voucher712Harness();
    }

    function _voucher() internal view returns (Voucher memory v) {
        v = Voucher({
            payer: buyer,
            provider: provider,
            amount: 250_000,
            resourceHash: keccak256("https://example.test/search"),
            requestHash: keccak256("canonical request"),
            seq: 1,
            issuedAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp) + 300
        });
    }

    /// `vm.expectRevert` can assert that one selector came back; it cannot assert that a
    /// *different* one did. The boundary tests need the second statement — "at `s == HALF_N` the
    /// malleability guard does NOT fire" — so they read the selector directly. Returns
    /// `bytes4(0)` when the call succeeded.
    function _selectorOf(Voucher memory v, bytes memory sig) internal view returns (bytes4) {
        (bool ok, bytes memory ret) =
            address(escrow).staticcall(abi.encodeCall(X402Escrow.recoverVoucherSigner, (v, sig)));
        if (ok) return bytes4(0);
        return bytes4(ret);
    }

    /// The same call, keeping BOTH outcomes. [`_assertNoForgery`] needs the returned address as
    /// well as the selector, because the property it states is a disjunction over the two.
    function _outcomeOf(Voucher memory v, bytes memory sig)
        internal
        view
        returns (bool ok, bytes4 selector, address signer)
    {
        bytes memory ret;
        (ok, ret) =
            address(escrow).staticcall(abi.encodeCall(X402Escrow.recoverVoucherSigner, (v, sig)));
        if (ok) return (true, bytes4(0), abi.decode(ret, (address)));
        return (false, bytes4(ret), address(0));
    }

    /// **THE ANTI-FORGERY PROPERTY.** For a 65-byte string nobody's key produced:
    /// `recoverVoucherSigner` either reverts with one of the guards' own named errors, or returns
    /// an address that is **not** the voucher's `payer`.
    ///
    /// Both halves matter. "It reverts" alone would be satisfied by a function that reverts on
    /// everything; "it does not return the payer" alone would be satisfied by a revert with an
    /// unnamed panic. Together they say: the only way to be recognised as the payer is to hold the
    /// payer's key.
    ///
    /// Three selectors, not four: `InvalidSignature` covers guards 1 and 4, and
    /// [`SignerIsNotPayer`] belongs to `redeemVoucher`, not to recovery.
    function _assertNoForgery(Voucher memory v, bytes memory sig, string memory ctx)
        internal
        view
    {
        (bool ok, bytes4 selector, address signer) = _outcomeOf(v, sig);
        if (ok) {
            assertTrue(signer != v.payer, ctx);
        } else {
            assertTrue(
                selector == InvalidSignature.selector || selector == MalleableSignature.selector
                    || selector == BadSignatureV.selector,
                ctx
            );
        }
    }

    // --- the happy path ---------------------------------------------------------------------

    function test_happyPath_recoversThePayer() public view {
        Voucher memory v = _voucher();
        bytes memory sig = VoucherSigner.signVoucher(buyerKey, escrow.DOMAIN_SEPARATOR(), v);
        assertEq(escrow.recoverVoucherSigner(v, sig), buyer);
    }

    /// Recovery is the exact inverse of signing for *any* key and *any* voucher, not only the
    /// one the fixture holds. `vm.sign` always produces a low-s signature, so this also asserts
    /// that the malleability guard never fires on an honestly produced one.
    function testFuzz_recoverIsTheInverseOfSignForAnyKeyAndAnyVoucher(
        uint256 pk,
        address provider_,
        uint64 amount,
        bytes32 resourceHash,
        bytes32 requestHash,
        uint64 seq,
        uint64 issuedAt,
        uint64 expiresAt
    ) public view {
        pk = bound(pk, 1, VoucherSigner.N - 1);
        address signer = vm.addr(pk);
        Voucher memory v = Voucher({
            payer: signer,
            provider: provider_,
            amount: amount,
            resourceHash: resourceHash,
            requestHash: requestHash,
            seq: seq,
            issuedAt: issuedAt,
            expiresAt: expiresAt
        });
        bytes memory sig = VoucherSigner.signVoucher(pk, escrow.DOMAIN_SEPARATOR(), v);
        assertEq(escrow.recoverVoucherSigner(v, sig), signer);
    }

    // --- the four guards --------------------------------------------------------------------

    /// A malleated twin is a DIFFERENT 65-byte string that verifies the same voucher.
    /// `seq` already stops the double-spend; low-s is enforced because the backend keys
    /// idempotency on the signature today and must move to (payer, chainId, seq).
    function test_wrongSigner_aMalleatedSignatureIsRefused() public {
        Voucher memory v = _voucher();
        bytes memory sig = VoucherSigner.signVoucher(buyerKey, escrow.DOMAIN_SEPARATOR(), v);
        bytes memory twin = VoucherSigner.malleate(sig);
        assertTrue(keccak256(twin) != keccak256(sig), "the twin must be different bytes");
        vm.expectRevert(MalleableSignature.selector);
        escrow.recoverVoucherSigner(v, twin);
    }

    /// The twin really is a twin — `ecrecover` accepts it and yields the same address. Without
    /// this, `test_wrongSigner_aMalleatedSignatureIsRefused` would also pass against a
    /// `malleate` that produced nonsense, and would then be proving nothing about malleability.
    function test_theMalleatedTwinIsAcceptedByTheBarePrecompile() public view {
        Voucher memory v = _voucher();
        bytes32 domainSeparator = escrow.DOMAIN_SEPARATOR();
        bytes memory twin =
            VoucherSigner.malleate(VoucherSigner.signVoucher(buyerKey, domainSeparator, v));
        bytes32 r;
        bytes32 s;
        uint8 vv;
        assembly ("memory-safe") {
            r := mload(add(twin, 0x20))
            s := mload(add(twin, 0x40))
            vv := byte(0, mload(add(twin, 0x60)))
        }
        bytes32 digest = VoucherSigner.digest(domainSeparator, VoucherSigner.voucherStructHash(v));
        assertEq(ecrecover(digest, vv, r, s), buyer, "the twin must verify the same voucher");
        assertTrue(uint256(s) > Constants.SECP256K1_HALF_N, "and it must be the high-s half");
    }

    function test_wrongSigner_vOutsideTwentySevenAndTwentyEightIsRefused() public {
        Voucher memory v = _voucher();
        bytes memory sig = VoucherSigner.signVoucher(buyerKey, escrow.DOMAIN_SEPARATOR(), v);
        sig[64] = bytes1(uint8(29));
        vm.expectRevert(BadSignatureV.selector);
        escrow.recoverVoucherSigner(v, sig);
    }

    /// ecrecover returns address(0) for garbage. Forget the check and any garbage
    /// "recovers" to a zero address — the EVM counterpart of the pointer-chasing trap the
    /// Solana precompile parser defends against (`attestation.rs:504-507`).
    ///
    /// `r = 0` is the deterministic garbage: `r` is a curve point's x-coordinate and must lie in
    /// `[1, n-1]`, so `ecrecover` returns `address(0)` for it on every input, every time. A
    /// pattern-filled `r` recovers to a *real* address roughly half the time, which is a flaky
    /// test rather than a strong one; `s = 1` keeps the low-s and `v` guards from firing first,
    /// so this test is about the fourth guard and nothing else.
    function test_wrongSigner_pureGarbageDoesNotRecoverToTheZeroAddress() public {
        Voucher memory v = _voucher();
        bytes memory garbage = abi.encodePacked(bytes32(0), bytes32(uint256(1)), uint8(27));
        assertEq(garbage.length, 65, "the length guard must not be what refuses this");
        vm.expectRevert(InvalidSignature.selector);
        escrow.recoverVoucherSigner(v, garbage);
    }

    /// Exactly ONE acceptable encoding. The 64-byte EIP-2098 compact form is refused on
    /// purpose: admitting two encodings of one signature is the same idempotency hazard
    /// low-s exists to close.
    function test_wrongSigner_theCompactSixtyFourByteFormIsRefused() public {
        Voucher memory v = _voucher();
        bytes memory sig = VoucherSigner.signVoucher(buyerKey, escrow.DOMAIN_SEPARATOR(), v);
        bytes memory compact = new bytes(64);
        for (uint256 i = 0; i < 64; i++) {
            compact[i] = sig[i];
        }
        vm.expectRevert(InvalidSignature.selector);
        escrow.recoverVoucherSigner(v, compact);
    }

    /// The other side of the length guard, and the one that actually proves it.
    ///
    /// A 64-byte signature is refused even with the guard deleted, because `calldataload` then
    /// reads the zero word past the end of calldata and `v == 0` trips the *`v`* guard instead —
    /// so the compact test above would go on passing (with the wrong selector) against a
    /// mutant. A 65-byte signature with one junk byte appended has a perfectly good `v` at
    /// offset 64, so with the guard deleted it recovers to `buyer` and nothing reverts at all.
    function test_wrongSigner_aSixtySixByteSignatureIsRefused() public {
        Voucher memory v = _voucher();
        bytes memory sig = VoucherSigner.signVoucher(buyerKey, escrow.DOMAIN_SEPARATOR(), v);
        bytes memory tooLong = abi.encodePacked(sig, bytes1(0xFF));
        assertEq(tooLong.length, 66);
        vm.expectRevert(InvalidSignature.selector);
        escrow.recoverVoucherSigner(v, tooLong);
    }

    // --- the two boundaries -----------------------------------------------------------------

    /// The operator is `>`, so `SECP256K1_HALF_N` itself is the last ACCEPTED value, not the
    /// first refused one. −1, exactly, +1, read off the comparison rather than guessed.
    ///
    /// The two accepted values are asserted as "not `MalleableSignature`" rather than "no
    /// revert": a hand-built `(r, s)` is not a signature, so what happens after the guard is
    /// `InvalidSignature` or an arbitrary address, and neither is the statement being made here.
    function test_theLowSCeilingIsHalfNItselfAndTheGuardIsStrictlyAboveIt() public view {
        Voucher memory v = _voucher();
        bytes32 r = keccak256("some r");

        bytes memory below = abi.encodePacked(r, bytes32(Constants.SECP256K1_HALF_N - 1), uint8(27));
        bytes memory at = abi.encodePacked(r, bytes32(Constants.SECP256K1_HALF_N), uint8(27));
        bytes memory above = abi.encodePacked(r, bytes32(Constants.SECP256K1_HALF_N + 1), uint8(27));

        assertTrue(_selectorOf(v, below) != MalleableSignature.selector, "half n - 1 is legal");
        assertTrue(_selectorOf(v, at) != MalleableSignature.selector, "half n itself is legal");
        assertEq(_selectorOf(v, above), MalleableSignature.selector, "half n + 1 is not");
    }

    /// `v ∈ {27, 28}`, refused on both sides. 26 matters as much as 29: a guard spelled
    /// `v > 28` admits the 0/1 form some libraries emit, which `ecrecover` then turns into
    /// `address(0)` — a diagnosis-free failure in place of a named one.
    function test_vIsAcceptedAtTwentySevenAndTwentyEightAndRefusedEitherSideOfThem() public view {
        Voucher memory v = _voucher();
        bytes memory sig = VoucherSigner.signVoucher(buyerKey, escrow.DOMAIN_SEPARATOR(), v);

        sig[64] = bytes1(uint8(26));
        assertEq(_selectorOf(v, sig), BadSignatureV.selector, "26 is outside the set");
        sig[64] = bytes1(uint8(27));
        assertTrue(_selectorOf(v, sig) != BadSignatureV.selector, "27 is inside it");
        sig[64] = bytes1(uint8(28));
        assertTrue(_selectorOf(v, sig) != BadSignatureV.selector, "28 is inside it");
        sig[64] = bytes1(uint8(29));
        assertEq(_selectorOf(v, sig), BadSignatureV.selector, "29 is outside the set");
        sig[64] = bytes1(uint8(0));
        assertEq(_selectorOf(v, sig), BadSignatureV.selector, "and so is the 0/1 form");
    }

    // --- who signed it ----------------------------------------------------------------------

    function test_wrongSigner_anotherKeysSignatureRecoversToThatOtherKey() public view {
        Voucher memory v = _voucher();
        uint256 attacker = 0xBADBAD;
        bytes memory sig = VoucherSigner.signVoucher(attacker, escrow.DOMAIN_SEPARATOR(), v);
        assertEq(escrow.recoverVoucherSigner(v, sig), vm.addr(attacker));
        assertTrue(escrow.recoverVoucherSigner(v, sig) != buyer);
    }

    // --- forgery ----------------------------------------------------------------------------

    /// **The hole this closes, found in review.** Every other test in this file hands
    /// `_recover` either a signature a key really produced or a signature that is malformed.
    /// **None hands it an adversarially chosen WELL-FORMED one**, so a hardcoded backdoor keyed on
    /// an `(r, s)` pair no honest signature can carry —
    ///
    /// ```solidity
    /// if (r == bytes32(0) && uint256(s) == 2) return v.payer;   // every escrow, spendable
    /// ```
    ///
    /// — passed all 157 tests. `r` is a curve point's x-coordinate and must lie in `[1, n-1]`, so
    /// no real signature ever has `r == 0`, and the one test that did present `r == 0` used
    /// `s == 1`. A backdoor is only ever one line, and it only ever needs one uninhabited corner.
    ///
    /// The structured sweep below is the deterministic half: 0, 1, 2, 3 and the two malleability
    /// boundaries for each of `r` and `s`, against `v` on both sides of {27, 28}. It exists
    /// because a fuzzer draws `bytes32` uniformly and will essentially never produce a *small*
    /// value, which is exactly where a hand-written backdoor lives.
    function test_noSmallStructuredSignatureEverRecoversToThePayer() public view {
        Voucher memory v = _voucher();

        bytes32[6] memory rs = [
            bytes32(0),
            bytes32(uint256(1)),
            bytes32(uint256(2)),
            bytes32(uint256(3)),
            bytes32(Constants.SECP256K1_HALF_N),
            bytes32(Constants.SECP256K1_HALF_N + 1)
        ];
        uint8[4] memory vs = [26, 27, 28, 29];

        for (uint256 i = 0; i < rs.length; i++) {
            for (uint256 j = 0; j < rs.length; j++) {
                for (uint256 k = 0; k < vs.length; k++) {
                    _assertNoForgery(
                        v,
                        abi.encodePacked(rs[i], rs[j], vs[k]),
                        "a hand-built (r, s, v) was accepted as the payer"
                    );
                }
            }
        }
    }

    /// The same property over the fuzzer, and over the VOUCHER as well as the signature — a
    /// backdoor keyed on `payer`, `seq` or `amount` is as cheap to write as one keyed on `r`.
    ///
    /// Recovering to `payer_` by chance is a 2^-160 event, so an assertion failure here is a
    /// backdoor and not bad luck.
    function testFuzz_noHandBuiltSignatureEverRecoversToThePayer(
        address payer_,
        uint64 amount,
        uint64 seq,
        bytes32 r,
        bytes32 s,
        uint8 vv
    ) public view {
        Voucher memory v = _voucher();
        v.payer = payer_;
        v.amount = amount;
        v.seq = seq;
        _assertNoForgery(
            v, abi.encodePacked(r, s, vv), "a fuzzed (r, s, v) was accepted as the payer"
        );
    }

    /// The guards are only guards if EVERY recovery goes through `_recover`. That rule is stated
    /// in `X402Escrow`'s natspec and, before this test, enforced by nothing — a second recovery
    /// call anywhere in `src/` would be a path with no length check, no low-s check, no `v` check
    /// and no zero-signer check.
    ///
    /// **A recovery call site is `ecrecover(`, `ECDSA.tryRecover(` or `ECDSA.recover(`**, and it
    /// has to be all three: writing this gate against `ecrecover(` alone finds **zero** today,
    /// because the precompile is reached through the vendored OZ library under `lib/` and the
    /// only thing `src/` contains is the `ECDSA.tryRecover(` that calls it. (That is how this
    /// test first failed — `0 != 1` — and it is the more useful shape of the rule: what must be
    /// unique is the *call site*, not the spelling.)
    ///
    /// It **counts** those sites rather than grepping for absence. `script/check-vendor.sh`'s
    /// header records why: enumerating what is present can never answer "is anything missing", and
    /// the trap runs in reverse here — asserting "no recovery outside `X402Escrow.sol`" would pass
    /// a tree in which `X402Escrow.sol` itself had grown a second one.
    ///
    /// Comment lines are skipped, so the prose in `_recover`'s own natspec — which names all
    /// three spellings — does not count as a call site. `test/Types.t.sol`'s source scanner skips
    /// them the same way and for the same reason.
    ///
    /// **The body now lives in `src/libraries/Sig.sol`**, with a forwarder in
    /// `X402Escrow._recover` behind it, so the owning file is now that library and the count is
    /// still exactly 1. The list below is a list rather than a single name because a future change
    /// may legitimately add a second owner; what it must never do is let a recovery appear in a
    /// file that moves money.
    function test_recoveryHappensAtExactlyOneCallSiteInSrc() public view {
        Vm.DirEntry[] memory entries = vm.readDir(string.concat(vm.projectRoot(), "/src"), 3);

        uint256 total;
        uint256 solidityFiles;
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].isDir) continue;
            if (!_endsWith(entries[i].path, ".sol")) continue;
            solidityFiles++;
            uint256 n = _countRecoveryCallSites(vm.readFile(entries[i].path));
            if (n != 0) {
                assertTrue(
                    _endsWith(entries[i].path, "/libraries/Sig.sol"),
                    string.concat("recovery outside the file that owns it: ", entries[i].path)
                );
            }
            total += n;
        }

        assertTrue(solidityFiles >= 8, "the scan found too few files to be scanning src/ at all");
        assertEq(total, 1, "there must be exactly one recovery call site in src/");
    }

    /// Occurrences of the three recovery spellings on lines that are not comments. Line-based
    /// rather than whole-file so that natspec naming them stays free.
    function _countRecoveryCallSites(string memory source) internal pure returns (uint256 n) {
        bytes memory src = bytes(source);
        uint256 lineStart;
        for (uint256 i = 0; i <= src.length; i++) {
            if (i != src.length && src[i] != "\n") continue;

            uint256 s = lineStart;
            lineStart = i + 1;
            while (s < i && (src[s] == " " || src[s] == "\t")) s++;
            if (s >= i) continue;
            // `//`, `///`, `/*` and a continuation `*` all start a comment line here.
            if (src[s] == "*") continue;
            if (s + 1 < i && src[s] == "/" && (src[s + 1] == "/" || src[s + 1] == "*")) continue;

            string memory line = _slice(src, s, i);
            n += _countOccurrences(line, "ecrecover(");
            n += _countOccurrences(line, "ECDSA.tryRecover(");
            n += _countOccurrences(line, "ECDSA.recover(");
        }
    }

    function _slice(bytes memory src, uint256 from, uint256 to)
        internal
        pure
        returns (string memory)
    {
        bytes memory out = new bytes(to - from);
        for (uint256 i = from; i < to; i++) {
            out[i - from] = src[i];
        }
        return string(out);
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

    function _countOccurrences(string memory haystack, string memory needle)
        internal
        pure
        returns (uint256 n)
    {
        bytes memory h = bytes(haystack);
        bytes memory k = bytes(needle);
        if (k.length == 0 || h.length < k.length) return 0;
        for (uint256 i = 0; i + k.length <= h.length; i++) {
            bool hit = true;
            for (uint256 j = 0; j < k.length; j++) {
                if (h[i + j] != k[j]) {
                    hit = false;
                    break;
                }
            }
            if (hit) n++;
        }
    }

    // --- replay -----------------------------------------------------------------------------

    /// CROSS-CHAIN REPLAY. Same key, same address, same voucher, different chain id.
    function test_aVoucherSignedForOneChainDoesNotVerifyOnAnother() public {
        vm.chainId(TESTNET);
        Voucher memory v = _voucher();
        bytes32 sepOnTestnet = escrow.DOMAIN_SEPARATOR();
        bytes memory sig = VoucherSigner.signVoucher(buyerKey, sepOnTestnet, v);
        assertEq(escrow.recoverVoucherSigner(v, sig), buyer);

        vm.chainId(MAINNET);
        assertTrue(escrow.DOMAIN_SEPARATOR() != sepOnTestnet, "the separator must follow chainId");
        assertTrue(escrow.recoverVoucherSigner(v, sig) != buyer, "cross-chain replay");
    }

    /// CROSS-CONTRACT REPLAY. Two deployments, one chain. A second PROXY — which is what a
    /// redeploy is (D-7); an upgrade would reuse this one and is proved in `Upgrade.t.sol`.
    function test_aVoucherSignedForOneDeploymentDoesNotVerifyOnAnother() public {
        X402Escrow other = _deployEscrow(address(0));
        assertTrue(other.DOMAIN_SEPARATOR() != escrow.DOMAIN_SEPARATOR());

        Voucher memory v = _voucher();
        bytes memory sig = VoucherSigner.signVoucher(buyerKey, escrow.DOMAIN_SEPARATOR(), v);
        assertEq(escrow.recoverVoucherSigner(v, sig), buyer);
        assertTrue(other.recoverVoucherSigner(v, sig) != buyer, "cross-contract replay");
    }

    /// THE ENCODER MUTATION TEST. Flip exactly one signed field and the recovery must move.
    /// This is the Anchor suite's field-binding assertion, generalised to the EIP-712 struct, and
    /// the counterpart of `attestation.rs`'s `no_field_of_a_voucher_is_outside_the_signed_bytes`.
    ///
    /// **`mutated[i] = _voucher()`, and NOT `mutated[i] = base`.** A `Voucher memory` is a
    /// POINTER, so `mutated[i] = base` stores eight copies of one reference: `mutated[0].payer =
    /// …` then writes through to `base` itself, the next seven writes land on the same object,
    /// and by the assertion loop every entry is one voucher with all eight fields changed. The
    /// test still passes — it just stops being eight single-field flips and becomes the same
    /// eight-field flip eight times, which is satisfied by an encoder that reads only ONE field.
    /// Measured: with `= base`, replacing any single member of `Voucher712.hashVoucher` with a
    /// constant survived this test (rows V1-V8 of `test/MUTATION-LOG.md`, first run). Calling
    /// `_voucher()` again allocates a fresh struct each time, and the four assertions below fail
    /// loudly if that ever stops being true.
    function test_flippingAnySingleSignedFieldChangesTheRecoveredSigner() public view {
        Voucher memory base = _voucher();
        Voucher memory pristine = _voucher(); // a THIRD allocation, never written to
        bytes memory sig = VoucherSigner.signVoucher(buyerKey, escrow.DOMAIN_SEPARATOR(), base);

        Voucher[8] memory mutated;
        for (uint256 i = 0; i < 8; i++) {
            mutated[i] = _voucher();
        }
        mutated[0].payer = address(0xDEAD);
        mutated[1].provider = address(0xDEAD);
        mutated[2].amount = base.amount + 1;
        mutated[3].resourceHash = keccak256("other resource");
        mutated[4].requestHash = keccak256("other request");
        mutated[5].seq = base.seq + 1;
        mutated[6].issuedAt = base.issuedAt + 1;
        mutated[7].expiresAt = base.expiresAt + 1;

        // Eight distinct structs, each differing from `base` in exactly one field. If these four
        // ever fail, the array has aliased and the loop below has stopped proving anything.
        //
        // The fourth compares against `pristine`, NOT against `base`: under the aliasing
        // regression `base` IS `mutated[7]`, so `mutated[7].seq == base.seq` is true by identity
        // and the assertion is inert. `pristine` is a separate allocation, so it still holds the
        // seq `_voucher()` builds and the comparison has something to say. (The review found this
        // one inert, and found its message naming voucher 5 while reading voucher 7.)
        assertEq(base.payer, buyer, "base must be untouched by the writes above");
        assertEq(mutated[0].payer, address(0xDEAD), "voucher 0 carries its own flip");
        assertEq(mutated[1].payer, buyer, "and voucher 1 does not carry voucher 0's");
        assertEq(mutated[7].seq, pristine.seq, "and voucher 7 does not carry voucher 5's");

        for (uint256 i = 0; i < 8; i++) {
            assertTrue(
                escrow.recoverVoucherSigner(mutated[i], sig) != buyer,
                "a signed field was not actually signed"
            );
        }
    }

    // --- the three struct hashes ------------------------------------------------------------

    /// The preimage, spelled out independently of `VoucherSigner`: the typehash, then the eight
    /// fields in declaration order, each in its own word. Every value is distinct, so a
    /// transposition of any two same-typed fields — `resourceHash`/`requestHash`,
    /// `issuedAt`/`expiresAt`, `payer`/`provider` — moves the hash. `Types.sol`'s header records
    /// that the struct's field order IS the type string's field order; this is the assertion
    /// that the *encoder* agrees with both.
    function test_theVoucherStructHashIsTheTypehashAndTheEightFieldsInDeclarationOrder()
        public
        view
    {
        Voucher memory v = Voucher({
            payer: address(0xA11CE),
            provider: address(0xB0B),
            amount: 987_654,
            resourceHash: keccak256("resource"),
            requestHash: keccak256("request"),
            seq: 4_242,
            issuedAt: 1_760_000_111,
            expiresAt: 1_760_000_222
        });
        assertEq(
            hasher.hashVoucher(v),
            keccak256(
                abi.encode(
                    VOUCHER_TYPEHASH,
                    address(0xA11CE),
                    address(0xB0B),
                    uint64(987_654),
                    keccak256("resource"),
                    keccak256("request"),
                    uint64(4_242),
                    uint64(1_760_000_111),
                    uint64(1_760_000_222)
                )
            )
        );
    }

    /// The two messages with no Anchor counterpart at all — on Solana the buyer signs the
    /// instruction, so `set_escrow_limits.rs` and `request_withdraw.rs` have nothing to type.
    /// Neither has a direct caller outside the relayed doors, so without this their four and three
    /// `uint64` arguments could be transposed today and every other test would stay green.
    function test_theSetLimitsAndRequestWithdrawHashesEncodeTheirArgumentsInOrder() public view {
        assertEq(
            hasher.hashSetLimits(address(0xA11CE), 111, 222, 333, 444),
            keccak256(
                abi.encode(
                    SET_LIMITS_TYPEHASH,
                    address(0xA11CE),
                    uint64(111),
                    uint64(222),
                    uint64(333),
                    uint64(444)
                )
            )
        );
        assertEq(
            hasher.hashRequestWithdraw(address(0xA11CE), 555, 666, 777),
            keccak256(
                abi.encode(
                    REQUEST_WITHDRAW_TYPEHASH,
                    address(0xA11CE),
                    uint64(555),
                    uint64(666),
                    uint64(777)
                )
            )
        );
    }

    /// **ONE vector proves transposition, never substitution — and this file made exactly the
    /// mistake it had just diagnosed elsewhere.** The test above pins each function with a
    /// single argument vector, so replacing every `uint64` parameter with *that vector's literal*
    /// — a function that reads nothing but `buyer` — passes it. The review's degenerate did
    /// precisely that to both. It is the same distinction row E9's correction draws about
    /// `hashVoucher`: substituting a constant and transposing two arguments are different
    /// mutations and one test does not answer both.
    ///
    /// A fuzz closes it rather than a second vector, because a second vector only moves the
    /// literal a degenerate has to hardcode. What it CANNOT do is stand in for
    /// `Types.t.sol`'s typehash-vs-struct gate: both sides here are `abi.encode` of the same
    /// arguments, so a *shared* misconception about EIP-712 encoding would satisfy both. It kills
    /// substitution, transposition and a wrong typehash constant, which is what it is for.
    function testFuzz_theSetLimitsHashReadsAllFiveOfItsArguments(
        address buyer_,
        uint64 maxVoucherAmount,
        uint64 maxPerWindow,
        uint64 nonce,
        uint64 deadline
    ) public view {
        assertEq(
            hasher.hashSetLimits(buyer_, maxVoucherAmount, maxPerWindow, nonce, deadline),
            keccak256(
                abi.encode(
                    SET_LIMITS_TYPEHASH, buyer_, maxVoucherAmount, maxPerWindow, nonce, deadline
                )
            )
        );
    }

    function testFuzz_theRequestWithdrawHashReadsAllFourOfItsArguments(
        address buyer_,
        uint64 amount,
        uint64 nonce,
        uint64 deadline
    ) public view {
        assertEq(
            hasher.hashRequestWithdraw(buyer_, amount, nonce, deadline),
            keccak256(abi.encode(REQUEST_WITHDRAW_TYPEHASH, buyer_, amount, nonce, deadline))
        );
    }

    /// CROSS-KIND REPLAY. A distinct typehash per kind puts the guard inside the hashed
    /// preimage, which is strictly stronger than the Solana design's "the message lengths
    /// differ" check (`attestation.rs:126`'s `const _: () = assert!(ATTESTATION_MESSAGE_LEN !=
    /// VOUCHER_MESSAGE_LEN)`): lengths can be made to collide by a future field, typehashes
    /// cannot.
    function test_aSetLimitsSignatureIsNotAVoucherSignature() public view {
        bytes32 sep = escrow.DOMAIN_SEPARATOR();
        bytes memory sig = VoucherSigner.signSetLimits(buyerKey, sep, buyer, 250_000, 1, 1, 0);
        assertTrue(
            escrow.recoverVoucherSigner(_voucher(), sig) != buyer,
            "a SetLimits signature was presented at the redeem door"
        );
    }
}
