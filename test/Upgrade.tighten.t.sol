// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.24;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Fixture} from "./helpers/Fixture.sol";
import {VoucherSigner} from "./helpers/VoucherSigner.sol";
import {X402EscrowPreTighten} from "./helpers/legacy/X402EscrowPreTighten.sol";
import {X402Escrow} from "../src/X402Escrow.sol";
import {IX402Config} from "../src/interfaces/IX402Config.sol";
import {Voucher} from "../src/Types.sol";
import {Constants} from "../src/Constants.sol";
import "../src/Errors.sol";

/// The "signed means collectable" upgrade, run against the REAL deployed escrow (a verbatim copy
/// of `src/X402Escrow.sol` at 6985ef0 in `test/helpers/legacy/`): every escrow, every grant,
/// the delegate lists, the solvency counter and the EIP-712 domain survive; the two appended
/// mappings read as empty, so the effective caps are the stored ones; a voucher signed before
/// the upgrade redeems after it; and a delegate revoked BEFORE the upgrade stays dead (it has no
/// grace, because its hold reads `until == 0`).
contract UpgradeTightenTest is Fixture {
    uint256 internal constant LIVE_KEY = 0xDE1E6A7E;
    uint256 internal constant REVOKED_KEY = 0xDE1E6A7F;
    address internal live;
    address internal revoked;
    X402EscrowPreTighten internal old;

    function setUp() public virtual override {
        super.setUp();
        live = vm.addr(LIVE_KEY);
        revoked = vm.addr(REVOKED_KEY);
        old = X402EscrowPreTighten(
            address(
                new ERC1967Proxy(
                    address(new X402EscrowPreTighten()),
                    abi.encodeCall(
                        X402EscrowPreTighten.initialize,
                        (IX402Config(address(config)), stakeView, IERC20(address(usdg)), address(0))
                    )
                )
            )
        );

        _fund(buyer, 10_000_000);
        vm.startPrank(buyer);
        usdg.approve(address(old), 10_000_000);
        old.deposit(10_000_000);
        old.setLimits(1_000_000, 5_000_000);
        old.authorizeDelegate(live, 400_000, 1_000_000, uint64(block.timestamp) + 30 days);
        old.authorizeDelegate(revoked, 400_000, 1_000_000, uint64(block.timestamp) + 30 days);
        old.revokeDelegate(revoked);
        old.requestWithdraw(1_000);
        vm.stopPrank();

        // One redemption, so the window counters and seqHigh are non-zero.
        Voucher memory v = _v(100_000, 1);
        bytes memory sig = VoucherSigner.signVoucher(LIVE_KEY, old.DOMAIN_SEPARATOR(), v);
        vm.prank(redeemer);
        old.redeemVoucher(v, sig);
    }

    function _v(uint64 amount, uint64 seq) internal view returns (Voucher memory) {
        return Voucher({
            payer: buyer,
            provider: provider,
            amount: amount,
            resourceHash: keccak256("resource"),
            requestHash: keccak256(abi.encode("upgrade", seq)),
            seq: seq,
            issuedAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp) + 300
        });
    }

    function _upgrade() internal returns (X402Escrow e) {
        address impl = address(new X402Escrow());
        vm.prank(owner);
        old.upgradeToAndCall(impl, "");
        e = X402Escrow(address(old));
    }

    function test_theUpgradePreservesEveryEscrowGrantAndTheDomain() public {
        bytes memory escrowBefore = abi.encode(old.escrowOf(buyer));
        bytes memory liveBefore = abi.encode(old.delegationOf(buyer, live));
        bytes memory revokedBefore = abi.encode(old.delegationOf(buyer, revoked));
        bytes memory listBefore = abi.encode(old.delegatesOf(buyer));
        uint128 totalBefore = old.totalEscrowed();
        bytes32 sep = old.DOMAIN_SEPARATOR();
        address cfg = address(old.CONFIG());
        address stk = address(old.STAKE());
        address asset = address(old.ASSET());
        uint256 vault = usdg.balanceOf(address(old));

        X402Escrow e = _upgrade();

        assertEq(abi.encode(e.escrowOf(buyer)), escrowBefore, "escrow");
        assertEq(abi.encode(e.delegationOf(buyer, live)), liveBefore, "live grant");
        assertEq(abi.encode(e.delegationOf(buyer, revoked)), revokedBefore, "revoked grant");
        assertEq(abi.encode(e.delegatesOf(buyer)), listBefore, "delegate list");
        assertEq(e.totalEscrowed(), totalBefore);
        assertEq(e.DOMAIN_SEPARATOR(), sep, "the EIP-712 domain must not move");
        assertEq(address(e.CONFIG()), cfg);
        assertEq(address(e.STAKE()), stk);
        assertEq(address(e.ASSET()), asset);
        assertEq(usdg.balanceOf(address(e)), vault);

        // The appended mappings start empty: the effective caps are the stored ones, and the
        // grant revoked before the upgrade reports none.
        (uint64 capV, uint64 capW, uint64 dCapV, uint64 dCapW) = e.effectiveCapsOf(buyer, live);
        assertEq(capV, 1_000_000);
        assertEq(capW, 5_000_000);
        assertEq(dCapV, 400_000);
        assertEq(dCapW, 1_000_000);
        (,, dCapV, dCapW) = e.effectiveCapsOf(buyer, revoked);
        assertEq(dCapV, 0, "a pre-upgrade revocation has no grace");
        assertEq(dCapW, 0);
    }

    /// A voucher signed before the upgrade redeems after it; one signed by the delegate revoked
    /// before the upgrade stays refused (its old `validUntil` is 30 days out, so a rule reading
    /// only `validUntil` would have brought it back).
    function test_aPreUpgradeVoucherRedeemsAndAPreUpgradeRevocationStaysFinal() public {
        bytes32 sep = old.DOMAIN_SEPARATOR();
        Voucher memory a = _v(200_000, 2);
        bytes memory sigA = VoucherSigner.signVoucher(LIVE_KEY, sep, a);
        Voucher memory b = _v(1_000, 3);
        bytes memory sigB = VoucherSigner.signVoucher(REVOKED_KEY, sep, b);

        X402Escrow e = _upgrade();

        vm.prank(redeemer);
        e.redeemVoucher(a, sigA);
        assertEq(e.escrowOf(buyer).seqHigh, 2);
        vm.prank(redeemer);
        vm.expectRevert(DelegateIsRevoked.selector);
        e.redeemVoucher(b, sigB);
    }

    /// After the upgrade the new rule applies to the old grants: revoking the pre-upgrade live
    /// delegate leaves its signed voucher collectable.
    function test_aPreUpgradeGrantRevokedAfterTheUpgradeGetsItsGrace() public {
        Voucher memory a = _v(200_000, 2);
        bytes memory sigA = VoucherSigner.signVoucher(LIVE_KEY, old.DOMAIN_SEPARATOR(), a);
        X402Escrow e = _upgrade();
        vm.prank(buyer);
        e.revokeDelegate(live);
        vm.warp(a.expiresAt + Constants.REDEEM_GRACE_SECONDS);
        vm.prank(redeemer);
        e.redeemVoucher(a, sigA);
    }
}
