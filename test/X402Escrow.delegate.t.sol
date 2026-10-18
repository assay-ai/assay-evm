// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.24;

import {Fixture} from "./helpers/Fixture.sol";
import {VoucherSigner} from "./helpers/VoucherSigner.sol";
import {X402Escrow} from "../src/X402Escrow.sol";
import {Voucher} from "../src/Types.sol";
import {Constants} from "../src/Constants.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../src/Errors.sol";

/// Agent payment delegation, x402-aligned: a voucher is authorised by (a) the payer's own key,
/// (b) a DELEGATE key the payer authorised on chain, within the delegate's own caps and the
/// escrow's, until `validUntil` and unless revoked. Nothing else: there is no EIP-1271 branch
/// (D-18). The delegate signs vouchers and nothing else.
contract X402EscrowDelegateTest is Fixture {
    uint256 internal constant DELEGATE_KEY = 0xDE1E6A7E;
    uint256 internal constant OTHER_KEY = 0x07E4;
    uint256 internal constant WALLET_OWNER_KEY = 0x0A11E7;

    address internal delegate;
    address internal stranger = address(0xDEAD);
    bytes32 internal ds;

    uint64 internal constant ESCROW_PER_CALL = 1_000_000;
    uint64 internal constant ESCROW_PER_WINDOW = 5_000_000;
    uint64 internal constant D_PER_CALL = 400_000;
    uint64 internal constant D_PER_WINDOW = 1_000_000;

    event DelegateAuthorized(
        address indexed payer,
        address indexed delegate,
        uint64 maxVoucherAmount,
        uint64 maxPerWindow,
        uint64 validUntil
    );
    event DelegateRevoked(address indexed payer, address indexed delegate);
    event DelegateVoucherRedeemed(
        address indexed payer,
        address indexed delegate,
        uint64 seq,
        uint64 amount,
        uint64 spentInWindow
    );
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

    function setUp() public virtual override {
        super.setUp();
        ds = escrow.DOMAIN_SEPARATOR();
        delegate = vm.addr(DELEGATE_KEY);
        _arm(buyer, 10_000_000);
    }

    // --- helpers ---------------------------------------------------------------------------

    function _arm(address who, uint64 amount) internal {
        _fund(who, amount);
        vm.startPrank(who);
        usdg.approve(address(escrow), amount);
        escrow.deposit(amount);
        escrow.setLimits(ESCROW_PER_CALL, ESCROW_PER_WINDOW);
        vm.stopPrank();
    }

    function _until() internal view returns (uint64) {
        return uint64(block.timestamp) + 30 days;
    }

    function _authorize(address payer_, address delegate_) internal {
        vm.prank(payer_);
        escrow.authorizeDelegate(delegate_, D_PER_CALL, D_PER_WINDOW, _until());
    }

    function _v(address payer_, uint64 amount, uint64 seq) internal view returns (Voucher memory) {
        return Voucher({
            payer: payer_,
            provider: provider,
            amount: amount,
            resourceHash: keccak256("resource"),
            requestHash: keccak256(abi.encode("request", payer_, seq)),
            seq: seq,
            issuedAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp) + 300
        });
    }

    function _signed(uint256 key, Voucher memory v) internal view returns (bytes memory) {
        return VoucherSigner.signVoucher(key, ds, v);
    }

    /// Redeem, then collect as the redeemer (redeem into hold), so a payout assertion here still
    /// reads the money the voucher moved.
    function _redeem(Voucher memory v, bytes memory sig) internal {
        vm.prank(redeemer);
        escrow.redeemVoucher(v, sig);
        _collect(v.payer, v.seq);
    }

    function _expect(Voucher memory v, bytes memory sig, bytes4 err) internal {
        vm.prank(redeemer);
        vm.expectRevert(err);
        escrow.redeemVoucher(v, sig);
    }

    function _nonce(address who) internal view returns (uint64) {
        return escrow.escrowOf(who).authNonce;
    }

    function _authSig(
        uint256 key,
        address payer_,
        address delegate_,
        uint64 mva,
        uint64 mpw,
        uint64 validUntil,
        uint64 nonce,
        uint64 deadline
    ) internal view returns (bytes memory) {
        return VoucherSigner.signAuthorizeDelegate(
            key, ds, payer_, delegate_, mva, mpw, validUntil, nonce, deadline
        );
    }

    // --- authorisation: the direct door -----------------------------------------------------

    function test_happyPath_authorizeDelegateWritesTheRecordListsItAndConsumesTheNonce() public {
        uint64 until = _until();
        uint64 n = _nonce(buyer);
        vm.expectEmit(true, true, false, true, address(escrow));
        emit DelegateAuthorized(buyer, delegate, D_PER_CALL, D_PER_WINDOW, until);
        vm.prank(buyer);
        escrow.authorizeDelegate(delegate, D_PER_CALL, D_PER_WINDOW, until);

        X402Escrow.Delegation memory d = escrow.delegationOf(buyer, delegate);
        assertEq(d.maxVoucherAmount, D_PER_CALL);
        assertEq(d.maxPerWindow, D_PER_WINDOW);
        assertEq(d.validUntil, until);
        assertEq(d.spentInWindow, 0);
        assertFalse(d.revoked);
        assertEq(d.listPosition, 1);
        address[] memory list = escrow.delegatesOf(buyer);
        assertEq(list.length, 1);
        assertEq(list[0], delegate);
        assertEq(_nonce(buyer), n + 1, "a direct delegation write must consume authNonce");
    }

    function test_wrongArgs_theAuthorisationIsValidatedField_byField() public {
        uint64 until = _until();
        vm.startPrank(buyer);

        vm.expectRevert(ZeroAddress.selector);
        escrow.authorizeDelegate(address(0), D_PER_CALL, D_PER_WINDOW, until);

        vm.expectRevert(DelegateIsPayer.selector);
        escrow.authorizeDelegate(buyer, D_PER_CALL, D_PER_WINDOW, until);

        vm.expectRevert(DelegateCapsInvalid.selector);
        escrow.authorizeDelegate(delegate, 0, D_PER_WINDOW, until);
        vm.expectRevert(DelegateCapsInvalid.selector);
        escrow.authorizeDelegate(delegate, D_PER_CALL, 0, until);
        vm.expectRevert(DelegateCapsInvalid.selector);
        escrow.authorizeDelegate(delegate, D_PER_WINDOW + 1, D_PER_WINDOW, until);

        vm.expectRevert(DelegateCapsExceedEscrowLimits.selector);
        escrow.authorizeDelegate(delegate, ESCROW_PER_CALL + 1, ESCROW_PER_WINDOW, until);
        vm.expectRevert(DelegateCapsExceedEscrowLimits.selector);
        escrow.authorizeDelegate(delegate, D_PER_CALL, ESCROW_PER_WINDOW + 1, until);

        vm.expectRevert(DelegateValidUntilInvalid.selector);
        escrow.authorizeDelegate(delegate, D_PER_CALL, D_PER_WINDOW, uint64(block.timestamp));
        // A grant must outlive the tighten delay: one second short is refused.
        vm.expectRevert(DelegateValidUntilInvalid.selector);
        escrow.authorizeDelegate(
            delegate,
            D_PER_CALL,
            D_PER_WINDOW,
            uint64(block.timestamp) + Constants.TIGHTEN_DELAY_SECONDS - 1
        );
        vm.expectRevert(DelegateValidUntilInvalid.selector);
        escrow.authorizeDelegate(
            delegate,
            D_PER_CALL,
            D_PER_WINDOW,
            uint64(block.timestamp) + Constants.MAX_DELEGATION_LIFETIME_SECONDS + 1
        );
        vm.stopPrank();

        assertEq(escrow.delegatesOf(buyer).length, 0, "a refused authorisation listed somebody");
    }

    function test_boundary_theCapsMayEqualTheEscrowLimitsAndTheHorizonItsMaximum() public {
        vm.prank(buyer);
        escrow.authorizeDelegate(
            delegate,
            ESCROW_PER_CALL,
            ESCROW_PER_WINDOW,
            uint64(block.timestamp) + Constants.MAX_DELEGATION_LIFETIME_SECONDS
        );
        assertEq(escrow.delegationOf(buyer, delegate).maxPerWindow, ESCROW_PER_WINDOW);
    }

    function test_wrongState_anUnarmedEscrowCannotAuthoriseADelegate() public {
        address fresh = vm.addr(0xF2E54);
        vm.prank(fresh);
        vm.expectRevert(DelegateCapsExceedEscrowLimits.selector);
        escrow.authorizeDelegate(delegate, 1, 1, _until());
    }

    function test_wrongState_anIdenticalAuthorisationIsRefusedAndAChangeIsAccepted() public {
        uint64 until = _until();
        vm.startPrank(buyer);
        escrow.authorizeDelegate(delegate, D_PER_CALL, D_PER_WINDOW, until);
        vm.expectRevert(DelegationUnchanged.selector);
        escrow.authorizeDelegate(delegate, D_PER_CALL, D_PER_WINDOW, until);
        escrow.authorizeDelegate(delegate, D_PER_CALL - 1, D_PER_WINDOW, until);
        vm.stopPrank();
        assertEq(escrow.delegationOf(buyer, delegate).maxVoucherAmount, D_PER_CALL - 1);
        assertEq(escrow.delegatesOf(buyer).length, 1, "an update must not list the delegate twice");
    }

    // --- authorisation: the relayed door ----------------------------------------------------

    function test_happyPath_anyoneMayRelayThePayersSignedAuthorisationOnce() public {
        uint64 until = _until();
        uint64 n = _nonce(buyer);
        uint64 deadline = uint64(block.timestamp) + 300;
        bytes memory sig =
            _authSig(buyerKey, buyer, delegate, D_PER_CALL, D_PER_WINDOW, until, n, deadline);

        vm.prank(stranger);
        escrow.authorizeDelegateBySig(
            buyer, delegate, D_PER_CALL, D_PER_WINDOW, until, n, deadline, sig
        );
        assertEq(escrow.delegationOf(buyer, delegate).validUntil, until);
        assertEq(_nonce(buyer), n + 1);

        vm.prank(stranger);
        vm.expectRevert(BadNonce.selector);
        escrow.authorizeDelegateBySig(
            buyer, delegate, D_PER_CALL, D_PER_WINDOW, until, n, deadline, sig
        );
    }

    function test_wrongSigner_onlyThePayersKeyAuthorisesARelayedDelegation() public {
        uint64 until = _until();
        uint64 n = _nonce(buyer);
        uint64 deadline = uint64(block.timestamp) + 300;

        // The delegate cannot authorise itself, and nobody else can either.
        uint256[2] memory keys = [DELEGATE_KEY, OTHER_KEY];
        for (uint256 i = 0; i < keys.length; i++) {
            bytes memory sig =
                _authSig(keys[i], buyer, delegate, D_PER_CALL, D_PER_WINDOW, until, n, deadline);
            vm.expectRevert(SignerIsNotBuyer.selector);
            escrow.authorizeDelegateBySig(
                buyer, delegate, D_PER_CALL, D_PER_WINDOW, until, n, deadline, sig
            );
        }

        // Every signed field is bound: the relayer cannot raise a cap or move the delegate.
        bytes memory good =
            _authSig(buyerKey, buyer, delegate, D_PER_CALL, D_PER_WINDOW, until, n, deadline);
        vm.expectRevert(SignerIsNotBuyer.selector);
        escrow.authorizeDelegateBySig(
            buyer, delegate, D_PER_CALL + 1, D_PER_WINDOW, until, n, deadline, good
        );
        vm.expectRevert(SignerIsNotBuyer.selector);
        escrow.authorizeDelegateBySig(
            buyer, delegate, D_PER_CALL, D_PER_WINDOW + 1, until, n, deadline, good
        );
        vm.expectRevert(SignerIsNotBuyer.selector);
        escrow.authorizeDelegateBySig(
            buyer, delegate, D_PER_CALL, D_PER_WINDOW, until + 1, n, deadline, good
        );
        vm.expectRevert(SignerIsNotBuyer.selector);
        escrow.authorizeDelegateBySig(
            buyer, stranger, D_PER_CALL, D_PER_WINDOW, until, n, deadline, good
        );

        vm.warp(deadline + 1);
        vm.expectRevert(SignatureExpired.selector);
        escrow.authorizeDelegateBySig(
            buyer, delegate, D_PER_CALL, D_PER_WINDOW, until, n, deadline, good
        );
        assertEq(escrow.delegatesOf(buyer).length, 0);
    }

    /// A delegation signature cannot be presented at the SetLimits door, nor the reverse — the
    /// typehashes differ.
    function test_crossKind_aDelegationSignatureIsNotASetLimitsSignature() public {
        uint64 n = _nonce(buyer);
        uint64 deadline = uint64(block.timestamp) + 300;
        bytes memory sig =
            _authSig(buyerKey, buyer, delegate, D_PER_CALL, D_PER_WINDOW, _until(), n, deadline);
        vm.expectRevert(SignerIsNotBuyer.selector);
        escrow.setLimitsBySig(buyer, D_PER_CALL, D_PER_WINDOW, n, deadline, sig);
    }

    // --- the nonce is shared -----------------------------------------------------------------

    function test_nonce_aSetLimitsAndADelegationAtOneNonceAreAlternatives() public {
        uint64 n = _nonce(buyer);
        uint64 deadline = uint64(block.timestamp) + 300;
        uint64 until = _until();
        bytes memory auth =
            _authSig(buyerKey, buyer, delegate, D_PER_CALL, D_PER_WINDOW, until, n, deadline);
        bytes memory limits = VoucherSigner.signSetLimits(
            buyerKey, ds, buyer, ESCROW_PER_CALL, ESCROW_PER_WINDOW + 1, n, deadline
        );

        escrow.setLimitsBySig(buyer, ESCROW_PER_CALL, ESCROW_PER_WINDOW + 1, n, deadline, limits);
        vm.expectRevert(BadNonce.selector);
        escrow.authorizeDelegateBySig(
            buyer, delegate, D_PER_CALL, D_PER_WINDOW, until, n, deadline, auth
        );
    }

    /// The reason the direct doors consume the nonce: a relayed authorisation the relayer
    /// withheld must not be landable after the payer revoked the delegate directly.
    function test_nonce_aWithheldRelayedAuthorisationDiesWithADirectRevocation() public {
        _authorize(buyer, delegate);
        uint64 n = _nonce(buyer);
        uint64 deadline = uint64(block.timestamp) + 300;
        uint64 until = _until() + 1;
        bytes memory withheld =
            _authSig(buyerKey, buyer, delegate, D_PER_CALL, D_PER_WINDOW, until, n, deadline);

        vm.prank(buyer);
        escrow.revokeDelegate(delegate);

        vm.expectRevert(BadNonce.selector);
        escrow.authorizeDelegateBySig(
            buyer, delegate, D_PER_CALL, D_PER_WINDOW, until, n, deadline, withheld
        );
        assertTrue(escrow.delegationOf(buyer, delegate).revoked);
    }

    // --- revocation ----------------------------------------------------------------------------

    /// The revocation unlists the delegate and marks it at once, and ends its authority after
    /// the tighten delay: a voucher it signed before stays collectable until then.
    function test_revoke_directRevocationEndsTheAuthorityAfterTheTightenDelay() public {
        _authorize(buyer, delegate);
        Voucher memory v = _v(buyer, 100_000, 1);
        bytes memory sig = _signed(DELEGATE_KEY, v);
        uint64 n = _nonce(buyer);
        uint64 revokedAt = uint64(block.timestamp);

        vm.expectEmit(true, true, false, true, address(escrow));
        emit DelegateRevoked(buyer, delegate);
        vm.prank(buyer);
        escrow.revokeDelegate(delegate);

        assertEq(_nonce(buyer), n + 1);
        assertEq(escrow.delegatesOf(buyer).length, 0);
        assertTrue(escrow.delegationOf(buyer, delegate).revoked);
        (,, uint64 dCapV,) = escrow.effectiveCapsOf(buyer, delegate);
        assertEq(dCapV, D_PER_CALL, "the revoked grant still signs during its grace");

        _redeem(v, sig);
        assertEq(escrow.escrowOf(buyer).balance, 10_000_000 - 100_000);

        vm.warp(revokedAt + Constants.TIGHTEN_DELAY_SECONDS + 1);
        Voucher memory late = _v(buyer, 100_000, 2);
        _expect(late, _signed(DELEGATE_KEY, late), DelegateIsRevoked.selector);
    }

    function test_revoke_theRelayedRevocationWorksAndIsBoundToThePayersKey() public {
        _authorize(buyer, delegate);
        uint64 n = _nonce(buyer);
        uint64 deadline = uint64(block.timestamp) + 300;

        bytes memory byDelegate =
            VoucherSigner.signRevokeDelegate(DELEGATE_KEY, ds, buyer, delegate, n, deadline);
        vm.expectRevert(SignerIsNotBuyer.selector);
        escrow.revokeDelegateBySig(buyer, delegate, n, deadline, byDelegate);

        bytes memory sig =
            VoucherSigner.signRevokeDelegate(buyerKey, ds, buyer, delegate, n, deadline);
        vm.prank(stranger);
        escrow.revokeDelegateBySig(buyer, delegate, n, deadline, sig);
        assertTrue(escrow.delegationOf(buyer, delegate).revoked);
        assertEq(_nonce(buyer), n + 1);
    }

    function test_revoke_aDelegateThatIsNotActiveCannotBeRevoked() public {
        vm.prank(buyer);
        vm.expectRevert(DelegateNotActive.selector);
        escrow.revokeDelegate(delegate);

        _authorize(buyer, delegate);
        vm.startPrank(buyer);
        escrow.revokeDelegate(delegate);
        vm.expectRevert(DelegateNotActive.selector);
        escrow.revokeDelegate(delegate);
        vm.stopPrank();
    }

    function test_revoke_reAuthorisingARevokedDelegateCarriesItsWindowOver() public {
        _authorize(buyer, delegate);
        Voucher memory v = _v(buyer, D_PER_CALL, 1);
        _redeem(v, _signed(DELEGATE_KEY, v));

        vm.startPrank(buyer);
        escrow.revokeDelegate(delegate);
        escrow.authorizeDelegate(delegate, D_PER_CALL, D_PER_WINDOW, _until());
        vm.stopPrank();

        X402Escrow.Delegation memory d = escrow.delegationOf(buyer, delegate);
        assertFalse(d.revoked);
        assertEq(d.spentInWindow, D_PER_CALL, "re-authorising handed out fresh capacity");

        Voucher memory w = _v(buyer, D_PER_CALL, 2);
        _redeem(w, _signed(DELEGATE_KEY, w));
        Voucher memory x = _v(buyer, D_PER_CALL, 3); // 3 x 400k > 1M
        _expect(x, _signed(DELEGATE_KEY, x), DelegateWindowLimitExceeded.selector);
    }

    // --- the list ------------------------------------------------------------------------------

    function test_list_revocationSwapsAndPopsAndKeepsEveryPositionTrue() public {
        address a = vm.addr(0xA1);
        address b = vm.addr(0xB1);
        address c = vm.addr(0xC1);
        _authorize(buyer, a);
        _authorize(buyer, b);
        _authorize(buyer, c);

        vm.prank(buyer);
        escrow.revokeDelegate(a);

        address[] memory list = escrow.delegatesOf(buyer);
        assertEq(list.length, 2);
        assertEq(list[0], c);
        assertEq(list[1], b);
        assertEq(escrow.delegationOf(buyer, c).listPosition, 1);
        assertEq(escrow.delegationOf(buyer, b).listPosition, 2);
        assertEq(escrow.delegationOf(buyer, a).listPosition, 0);

        vm.startPrank(buyer);
        escrow.revokeDelegate(b); // the last entry: a plain pop
        escrow.revokeDelegate(c);
        vm.stopPrank();
        assertEq(escrow.delegatesOf(buyer).length, 0);
    }

    function test_list_aPayerHoldsAtMostTheBoundAndARevocationFreesAPlace() public {
        for (uint256 i = 0; i < Constants.MAX_DELEGATES_PER_PAYER; i++) {
            _authorize(buyer, vm.addr(0x1000 + i));
        }
        address extra = vm.addr(0x9999);
        vm.prank(buyer);
        vm.expectRevert(TooManyDelegates.selector);
        escrow.authorizeDelegate(extra, D_PER_CALL, D_PER_WINDOW, _until());

        // Updating one that is already listed is not adding one.
        vm.prank(buyer);
        escrow.authorizeDelegate(vm.addr(0x1000), D_PER_CALL - 1, D_PER_WINDOW, _until());

        vm.startPrank(buyer);
        escrow.revokeDelegate(vm.addr(0x1003));
        escrow.authorizeDelegate(extra, D_PER_CALL, D_PER_WINDOW, _until());
        vm.stopPrank();
        assertEq(escrow.delegatesOf(buyer).length, Constants.MAX_DELEGATES_PER_PAYER);
    }

    // --- redemption through a delegate --------------------------------------------------------

    function test_happyPath_aDelegateSignedVoucherWithinItsCapsIsRedeemed() public {
        _authorize(buyer, delegate);
        Voucher memory v = _v(buyer, 250_000, 1);

        vm.expectEmit(true, true, false, true, address(escrow));
        emit VoucherRedeemed(
            buyer, provider, v.requestHash, v.resourceHash, 250_000, 25_000, 1, 1_000, 250_000
        );
        vm.expectEmit(true, true, false, true, address(escrow));
        emit DelegateVoucherRedeemed(buyer, delegate, 1, 250_000, 250_000);
        _redeem(v, _signed(DELEGATE_KEY, v));

        X402Escrow.Escrow memory e = escrow.escrowOf(buyer);
        assertEq(e.balance, 10_000_000 - 250_000);
        assertEq(e.seqHigh, 1);
        assertEq(e.spentInWindow, 250_000);
        assertEq(usdg.balanceOf(provider), 225_000);
        assertEq(usdg.balanceOf(treasury), 25_000);
        X402Escrow.Delegation memory d = escrow.delegationOf(buyer, delegate);
        assertEq(d.spentInWindow, 250_000);
        assertEq(d.windowStartedAt, block.timestamp);
    }

    function test_happyPath_thePayersOwnVoucherTouchesNoDelegateCounter() public {
        _authorize(buyer, delegate);
        Voucher memory v = _v(buyer, 900_000, 1);
        _redeem(v, _signed(buyerKey, v));
        assertEq(escrow.delegationOf(buyer, delegate).spentInWindow, 0);
    }

    function test_caps_theDelegatesPerCallCapAdmitsItsOwnValueAndNoMore() public {
        _authorize(buyer, delegate);
        Voucher memory over = _v(buyer, D_PER_CALL + 1, 1);
        _expect(over, _signed(DELEGATE_KEY, over), DelegateVoucherExceedsPerCallLimit.selector);
        Voucher memory exact = _v(buyer, D_PER_CALL, 1);
        _redeem(exact, _signed(DELEGATE_KEY, exact));
    }

    function test_caps_theDelegatesWindowAdmitsItsOwnValueThenDrainsThenDecays() public {
        vm.prank(buyer);
        escrow.authorizeDelegate(delegate, 500_000, D_PER_WINDOW, _until());
        Voucher memory a = _v(buyer, 500_000, 1);
        _redeem(a, _signed(DELEGATE_KEY, a));
        Voucher memory b = _v(buyer, 500_000, 2);
        _redeem(b, _signed(DELEGATE_KEY, b));
        Voucher memory c = _v(buyer, 1, 3);
        _expect(c, _signed(DELEGATE_KEY, c), DelegateWindowLimitExceeded.selector);

        // The payer's own key still has the escrow's remaining capacity.
        _redeem(c, _signed(buyerKey, c));

        vm.warp(block.timestamp + Constants.SLASH_WINDOW_SECONDS);
        Voucher memory d = _v(buyer, 500_000, 4);
        _redeem(d, _signed(DELEGATE_KEY, d));
    }

    /// The escrow's own ceilings still bind a delegate: lowering them after the authorisation
    /// narrows what the delegate can spend.
    function test_caps_theEscrowLimitsStillApplyToADelegate() public {
        _authorize(buyer, delegate);
        vm.prank(buyer);
        escrow.setLimits(100_000, 150_000);
        // The lowering binds once the tighten delay has passed (test/X402Escrow.tighten.t.sol).
        vm.warp(block.timestamp + Constants.TIGHTEN_DELAY_SECONDS + 1);

        Voucher memory v = _v(buyer, 200_000, 1);
        _expect(v, _signed(DELEGATE_KEY, v), VoucherExceedsPerCallLimit.selector);

        Voucher memory a = _v(buyer, 100_000, 1);
        _redeem(a, _signed(DELEGATE_KEY, a));
        Voucher memory b = _v(buyer, 100_000, 2);
        _expect(b, _signed(DELEGATE_KEY, b), EscrowWindowLimitExceeded.selector);
    }

    function test_expiry_aDelegateIsValidThroughItsInstantAndRefusedAfter() public {
        uint64 until = uint64(block.timestamp) + 1 hours;
        vm.prank(buyer);
        escrow.authorizeDelegate(delegate, D_PER_CALL, D_PER_WINDOW, until);

        vm.warp(until);
        Voucher memory a = _v(buyer, 1_000, 1);
        _redeem(a, _signed(DELEGATE_KEY, a));

        vm.warp(until + 1);
        Voucher memory b = _v(buyer, 1_000, 2);
        _expect(b, _signed(DELEGATE_KEY, b), DelegateIsExpired.selector);

        // An expired delegate can be revoked, which frees its place.
        vm.prank(buyer);
        escrow.revokeDelegate(delegate);
        assertEq(escrow.delegatesOf(buyer).length, 0);
    }

    function test_foreignPayer_aDelegateOfOnePayerCannotSpendAnother() public {
        address other = vm.addr(OTHER_KEY);
        _arm(other, 5_000_000);
        _authorize(buyer, delegate);

        Voucher memory v = _v(other, 1_000, 1);
        _expect(v, _signed(DELEGATE_KEY, v), SignerIsNotPayer.selector);
        assertEq(escrow.escrowOf(other).balance, 5_000_000);
    }

    function test_unknownKey_aKeyNobodyAuthorisedIsSignerIsNotPayer() public {
        Voucher memory v = _v(buyer, 1_000, 1);
        _expect(v, _signed(DELEGATE_KEY, v), SignerIsNotPayer.selector);
    }

    function test_replay_theSequenceRuleIsSharedByThePayerAndTheDelegate() public {
        _authorize(buyer, delegate);
        Voucher memory a = _v(buyer, 1_000, 5);
        _redeem(a, _signed(DELEGATE_KEY, a));

        // The same voucher again, and a lower seq by the payer's own key.
        _expect(a, _signed(DELEGATE_KEY, a), VoucherSeqNotIncreasing.selector);
        Voucher memory b = _v(buyer, 1_000, 4);
        _expect(b, _signed(buyerKey, b), VoucherSeqNotIncreasing.selector);
        Voucher memory z = _v(buyer, 1_000, 0);
        _expect(z, _signed(DELEGATE_KEY, z), VoucherSeqZero.selector);

        Voucher memory c = _v(buyer, 1_000, 6);
        _redeem(c, _signed(buyerKey, c));
        assertEq(escrow.escrowOf(buyer).seqHigh, 6);
    }

    /// The four recovery guards still apply to a delegate's signature on an EOA payer, with
    /// their own names.
    function test_eoaPath_malformedDelegateSignaturesKeepTheirNames() public {
        _authorize(buyer, delegate);
        Voucher memory v = _v(buyer, 1_000, 1);
        bytes memory sig = _signed(DELEGATE_KEY, v);

        _expect(v, VoucherSigner.malleate(sig), MalleableSignature.selector);
        _expect(v, new bytes(65), BadSignatureV.selector);
        _expect(v, new bytes(64), InvalidSignature.selector);
        bytes memory longer = bytes.concat(sig, hex"00");
        _expect(v, longer, InvalidSignature.selector);
        assertEq(escrow.escrowOf(buyer).seqHigh, 0);
    }

    function test_refusal_aRefusedDelegateVoucherConsumesNothing() public {
        _authorize(buyer, delegate);
        Voucher memory v = _v(buyer, D_PER_CALL + 1, 1);
        _expect(v, _signed(DELEGATE_KEY, v), DelegateVoucherExceedsPerCallLimit.selector);
        assertEq(escrow.escrowOf(buyer).seqHigh, 0);
        assertEq(escrow.escrowOf(buyer).spentInWindow, 0);
        assertEq(escrow.delegationOf(buyer, delegate).spentInWindow, 0);
    }

    function test_pause_aDelegateVoucherIsClosedWhilePaused() public {
        _authorize(buyer, delegate);
        Voucher memory v = _v(buyer, 1_000, 1);
        bytes memory sig = _signed(DELEGATE_KEY, v);
        vm.prank(admin);
        config.setPaused(true);
        _expect(v, sig, ProgramPaused.selector);
    }

    // --- the batch is the same path -----------------------------------------------------------

    function test_batch_mixesPayerAndDelegateVouchersThroughTheSameRules() public {
        _authorize(buyer, delegate);
        Voucher[] memory vs = new Voucher[](3);
        bytes[] memory sigs = new bytes[](3);
        vs[0] = _v(buyer, 300_000, 1);
        sigs[0] = _signed(DELEGATE_KEY, vs[0]);
        vs[1] = _v(buyer, 300_000, 2);
        sigs[1] = _signed(buyerKey, vs[1]);
        vs[2] = _v(buyer, 300_000, 3);
        sigs[2] = _signed(DELEGATE_KEY, vs[2]);

        vm.prank(redeemer);
        escrow.redeemVoucherBatch(vs, sigs);
        assertEq(escrow.escrowOf(buyer).seqHigh, 3);
        assertEq(escrow.delegationOf(buyer, delegate).spentInWindow, 600_000);
        assertEq(escrow.escrowOf(buyer).spentInWindow, 900_000);
    }

    function test_batch_oneOverCapDelegateVoucherRevertsTheWholeBatch() public {
        _authorize(buyer, delegate);
        Voucher[] memory vs = new Voucher[](3);
        bytes[] memory sigs = new bytes[](3);
        for (uint256 i = 0; i < 3; i++) {
            vs[i] = _v(buyer, 400_000, uint64(i + 1)); // 1.2M > the delegate's 1M window
            sigs[i] = _signed(DELEGATE_KEY, vs[i]);
        }
        vm.prank(redeemer);
        vm.expectRevert(DelegateWindowLimitExceeded.selector);
        escrow.redeemVoucherBatch(vs, sigs);
        assertEq(escrow.escrowOf(buyer).seqHigh, 0);
    }

    // --- what a delegate can never do ---------------------------------------------------------

    function test_powerless_aDelegateCannotMoveLimitsWithdrawOrAuthorise() public {
        _authorize(buyer, delegate);
        uint64 n = _nonce(buyer);
        uint64 deadline = uint64(block.timestamp) + 300;

        bytes memory limits = VoucherSigner.signSetLimits(
            DELEGATE_KEY, ds, buyer, ESCROW_PER_CALL, ESCROW_PER_WINDOW * 2, n, deadline
        );
        vm.expectRevert(SignerIsNotBuyer.selector);
        escrow.setLimitsBySig(buyer, ESCROW_PER_CALL, ESCROW_PER_WINDOW * 2, n, deadline, limits);

        bytes memory wd =
            VoucherSigner.signRequestWithdraw(DELEGATE_KEY, ds, buyer, 1_000, n, deadline);
        vm.expectRevert(SignerIsNotBuyer.selector);
        escrow.requestWithdrawBySig(buyer, 1_000, n, deadline, wd);

        address accomplice = vm.addr(0xACC);
        bytes memory auth = _authSig(
            DELEGATE_KEY, buyer, accomplice, D_PER_CALL, D_PER_WINDOW, _until(), n, deadline
        );
        vm.expectRevert(SignerIsNotBuyer.selector);
        escrow.authorizeDelegateBySig(
            buyer, accomplice, D_PER_CALL, D_PER_WINDOW, _until(), n, deadline, auth
        );

        bytes memory revoke =
            VoucherSigner.signRevokeDelegate(DELEGATE_KEY, ds, buyer, delegate, n, deadline);
        vm.expectRevert(SignerIsNotBuyer.selector);
        escrow.revokeDelegateBySig(buyer, delegate, n, deadline, revoke);

        // The direct doors read msg.sender: a delegate calling them acts on ITS OWN escrow.
        vm.startPrank(delegate);
        vm.expectRevert(NoWithdrawRequested.selector);
        escrow.withdraw();
        escrow.requestWithdraw(1_000);
        vm.expectRevert(DelegateCapsExceedEscrowLimits.selector);
        escrow.authorizeDelegate(accomplice, 1, 1, _until());
        vm.stopPrank();

        X402Escrow.Escrow memory e = escrow.escrowOf(buyer);
        assertEq(e.balance, 10_000_000);
        assertEq(e.maxPerWindow, ESCROW_PER_WINDOW);
        assertEq(e.withdrawRequested, 0);
        assertEq(e.authNonce, n);
        assertEq(escrow.delegationOf(buyer, accomplice).validUntil, 0);
    }

    // --- a payer with code: no EIP-1271 (D-18) -----------------------------------------------

    function _wallet() internal returns (ExecWallet w) {
        w = new ExecWallet();
        _fund(address(w), 5_000_000);
        w.exec(address(usdg), abi.encodeCall(IERC20.approve, (address(escrow), 5_000_000)));
        w.exec(address(escrow), abi.encodeCall(X402Escrow.deposit, (5_000_000)));
        w.exec(
            address(escrow),
            abi.encodeCall(X402Escrow.setLimits, (ESCROW_PER_CALL, ESCROW_PER_WINDOW))
        );
    }

    /// The wallet answers the EIP-1271 magic value for EVERY digest and signature, and is still
    /// never paid for on its own say-so: the escrow no longer asks it.
    function test_aContractWalletIsNeverAskedToAuthoriseAVoucher() public {
        ExecWallet w = _wallet();
        Voucher memory v = _v(address(w), 1_000, 1);
        _expect(v, _signed(WALLET_OWNER_KEY, v), SignerIsNotPayer.selector);
        _expect(v, _signed(buyerKey, v), SignerIsNotPayer.selector);
        // A non-ECDSA blob is refused by the strict recovery under its own name.
        _expect(v, hex"01020304", InvalidSignature.selector);
        assertEq(escrow.escrowOf(address(w)).seqHigh, 0);
        assertEq(escrow.escrowOf(address(w)).balance, 5_000_000);
    }

    /// The supported route for a contract-wallet payer: it authorises a delegate DIRECTLY (that
    /// door reads `msg.sender`), and the delegate signs.
    function test_aContractWalletPayerPaysThroughADelegate() public {
        ExecWallet w = _wallet();
        w.exec(
            address(escrow),
            abi.encodeCall(
                X402Escrow.authorizeDelegate, (delegate, D_PER_CALL, D_PER_WINDOW, _until())
            )
        );
        Voucher memory v = _v(address(w), 1_000, 1);
        _redeem(v, _signed(DELEGATE_KEY, v));
        assertEq(escrow.delegationOf(address(w), delegate).spentInWindow, 1_000);

        w.exec(address(escrow), abi.encodeCall(X402Escrow.revokeDelegate, (delegate)));
        vm.warp(block.timestamp + Constants.TIGHTEN_DELAY_SECONDS + 1);
        Voucher memory x = _v(address(w), 1_000, 2);
        _expect(x, _signed(DELEGATE_KEY, x), DelegateIsRevoked.selector);
    }

    // --- fuzz ----------------------------------------------------------------------------------

    function testFuzz_aDelegateWithinItsCapsIsAlwaysPaidAndOverThemNever(
        uint64 perCall,
        uint64 perWindow,
        uint64 amount
    ) public {
        perWindow = uint64(bound(perWindow, 1, ESCROW_PER_WINDOW));
        perCall =
            uint64(bound(perCall, 1, perWindow < ESCROW_PER_CALL ? perWindow : ESCROW_PER_CALL));
        amount = uint64(bound(amount, 1, ESCROW_PER_CALL * 2));

        vm.prank(buyer);
        escrow.authorizeDelegate(delegate, perCall, perWindow, _until());
        Voucher memory v = _v(buyer, amount, 1);
        bytes memory sig = _signed(DELEGATE_KEY, v);

        if (amount > ESCROW_PER_CALL) {
            _expect(v, sig, VoucherExceedsPerCallLimit.selector);
        } else if (amount > perCall) {
            _expect(v, sig, DelegateVoucherExceedsPerCallLimit.selector);
        } else {
            _redeem(v, sig);
            assertEq(escrow.escrowOf(buyer).balance, 10_000_000 - amount);
            assertEq(escrow.delegationOf(buyer, delegate).spentInWindow, amount);
        }
    }

    function testFuzz_noUnauthorisedKeyEverSpendsThroughTheDelegatePath(uint256 key, uint64 amount)
        public
    {
        key = bound(key, 1, VoucherSigner.N - 1);
        vm.assume(key != buyerKey && key != DELEGATE_KEY);
        amount = uint64(bound(amount, 1, D_PER_CALL));
        _authorize(buyer, delegate);

        Voucher memory v = _v(buyer, amount, 1);
        _expect(v, _signed(key, v), SignerIsNotPayer.selector);
        assertEq(escrow.escrowOf(buyer).balance, 10_000_000);
    }

    function testFuzz_aDelegateIsAcceptedExactlyWhileItsHorizonHolds(uint64 life, uint64 later)
        public
    {
        life = uint64(
            bound(life, Constants.TIGHTEN_DELAY_SECONDS, Constants.MAX_DELEGATION_LIFETIME_SECONDS)
        );
        later = uint64(bound(later, 0, uint64(Constants.MAX_DELEGATION_LIFETIME_SECONDS) * 2));
        uint64 until = uint64(block.timestamp) + life;
        vm.prank(buyer);
        escrow.authorizeDelegate(delegate, D_PER_CALL, D_PER_WINDOW, until);

        vm.warp(block.timestamp + later);
        Voucher memory v = _v(buyer, 1_000, 1);
        bytes memory sig = _signed(DELEGATE_KEY, v);
        if (block.timestamp <= until) {
            _redeem(v, sig);
        } else {
            _expect(v, sig, DelegateIsExpired.selector);
        }
    }

    function testFuzz_aDelegateNeverOutspendsItsWindow(uint64[6] memory amounts) public {
        _authorize(buyer, delegate);
        uint256 total;
        for (uint256 i = 0; i < amounts.length; i++) {
            uint64 a = uint64(bound(amounts[i], 1, D_PER_CALL));
            Voucher memory v = _v(buyer, a, uint64(i + 1));
            bytes memory sig = _signed(DELEGATE_KEY, v);
            if (total + a > D_PER_WINDOW) {
                _expect(v, sig, DelegateWindowLimitExceeded.selector);
            } else {
                _redeem(v, sig);
                total += a;
            }
        }
        assertEq(escrow.delegationOf(buyer, delegate).spentInWindow, total);
        assertLe(total, D_PER_WINDOW);
    }
}

/// A contract-wallet payer: forwards calls, and would accept every EIP-1271 question.
contract ExecWallet {
    function exec(address target, bytes calldata data) external returns (bytes memory) {
        (bool ok, bytes memory ret) = target.call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        return ret;
    }

    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        return 0x1626ba7e;
    }
}
