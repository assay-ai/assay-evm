// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.24;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Fixture} from "./helpers/Fixture.sol";
import {VoucherSigner} from "./helpers/VoucherSigner.sol";
import {X402ConfigPreHold} from "./helpers/legacy/X402ConfigPreHold.sol";
import {X402EscrowPreHold} from "./helpers/legacy/X402EscrowPreHold.sol";
import {X402Config} from "../src/X402Config.sol";
import {X402Escrow} from "../src/X402Escrow.sol";
import {IX402Config} from "../src/interfaces/IX402Config.sol";
import {Voucher, ParamSet} from "../src/Types.sol";
import {Constants} from "../src/Constants.sol";
import "../src/Errors.sol";

/// The redeem-into-hold upgrade of Config and Escrow, run against the REAL pre-upgrade code
/// (verbatim copies of `src/X402Config.sol` and `src/X402Escrow.sol` at the pre-upgrade commit,
/// in `test/helpers/legacy/`): every escrow, grant, setting and the EIP-712 domain survive, the
/// appended state reads empty (`totalHeld == 0`, the collect hold at its default), a voucher
/// signed before the upgrade redeems into hold after it, and the order is Config first.
contract UpgradeHoldTest is Fixture {
    uint256 internal constant DELEGATE_KEY = 0xDE1E6A80;
    address internal delegateAddr;
    X402ConfigPreHold internal oldConfig;
    X402EscrowPreHold internal oldEscrow;

    function setUp() public virtual override {
        super.setUp();
        delegateAddr = vm.addr(DELEGATE_KEY);
        ParamSet memory p = config.params();
        oldConfig = X402ConfigPreHold(
            address(
                new ERC1967Proxy(
                    address(new X402ConfigPreHold()),
                    abi.encodeCall(X402ConfigPreHold.initialize, (p, admin, owner))
                )
            )
        );
        oldEscrow = X402EscrowPreHold(
            address(
                new ERC1967Proxy(
                    address(new X402EscrowPreHold()),
                    abi.encodeCall(
                        X402EscrowPreHold.initialize,
                        (
                            IX402Config(address(oldConfig)),
                            stakeView,
                            IERC20(address(usdg)),
                            address(0)
                        )
                    )
                )
            )
        );
        vm.startPrank(admin);
        oldConfig.setSlashDelay(2 * 86_400);
        oldConfig.setArbiter(address(0xA4B1));
        vm.stopPrank();

        _fund(buyer, 10_000_000);
        vm.startPrank(buyer);
        usdg.approve(address(oldEscrow), 10_000_000);
        oldEscrow.deposit(10_000_000);
        oldEscrow.setLimits(1_000_000, 5_000_000);
        oldEscrow.authorizeDelegate(
            delegateAddr, 400_000, 1_000_000, uint64(vm.getBlockTimestamp()) + 30 days
        );
        oldEscrow.requestWithdraw(1_000);
        vm.stopPrank();

        // One pre-upgrade redemption, paid at once by the old code.
        Voucher memory v = _v(100_000, 1);
        bytes memory sig = VoucherSigner.signVoucher(DELEGATE_KEY, oldEscrow.DOMAIN_SEPARATOR(), v);
        vm.prank(redeemer);
        oldEscrow.redeemVoucher(v, sig);
        assertEq(usdg.balanceOf(provider), 90_000);
    }

    function _v(uint64 amount, uint64 seq) internal view returns (Voucher memory) {
        return Voucher({
            payer: buyer,
            provider: provider,
            amount: amount,
            resourceHash: keccak256("resource"),
            requestHash: keccak256(abi.encode("upgrade-hold", seq)),
            seq: seq,
            issuedAt: uint64(vm.getBlockTimestamp()),
            expiresAt: uint64(vm.getBlockTimestamp()) + 300
        });
    }

    function _upgradeBoth() internal returns (X402Config c, X402Escrow e) {
        address cImpl = address(new X402Config());
        address eImpl = address(new X402Escrow());
        // Config FIRST: the new Escrow reads `collectHoldSeconds` on every redemption.
        vm.startPrank(owner);
        oldConfig.upgradeToAndCall(cImpl, "");
        oldEscrow.upgradeToAndCall(eImpl, "");
        vm.stopPrank();
        c = X402Config(address(oldConfig));
        e = X402Escrow(address(oldEscrow));
    }

    function test_theHoldUpgradePreservesEveryEscrowSettingAndTheDomain() public {
        bytes memory escrowBefore = abi.encode(oldEscrow.escrowOf(buyer));
        bytes memory grantBefore = abi.encode(oldEscrow.delegationOf(buyer, delegateAddr));
        bytes memory listBefore = abi.encode(oldEscrow.delegatesOf(buyer));
        (uint64 a0, uint64 a1, uint64 a2, uint64 a3) =
            oldEscrow.effectiveCapsOf(buyer, delegateAddr);
        uint128 totalBefore = oldEscrow.totalEscrowed();
        bytes32 sep = oldEscrow.DOMAIN_SEPARATOR();
        bytes memory paramsBefore = abi.encode(oldConfig.params());
        uint256 vault = usdg.balanceOf(address(oldEscrow));

        (X402Config c, X402Escrow e) = _upgradeBoth();

        assertEq(abi.encode(e.escrowOf(buyer)), escrowBefore, "escrow");
        assertEq(abi.encode(e.delegationOf(buyer, delegateAddr)), grantBefore, "grant");
        assertEq(abi.encode(e.delegatesOf(buyer)), listBefore, "delegate list");
        (uint64 b0, uint64 b1, uint64 b2, uint64 b3) = e.effectiveCapsOf(buyer, delegateAddr);
        assertEq(abi.encode(b0, b1, b2, b3), abi.encode(a0, a1, a2, a3), "caps");
        assertEq(e.totalEscrowed(), totalBefore);
        assertEq(e.DOMAIN_SEPARATOR(), sep, "the EIP-712 domain must not move");
        assertEq(address(e.CONFIG()), address(c));
        assertEq(address(e.STAKE()), address(stakeView));
        assertEq(address(e.ASSET()), address(usdg));
        assertEq(usdg.balanceOf(address(e)), vault);

        assertEq(abi.encode(c.params()), paramsBefore, "params");
        assertEq(c.admin(), admin);
        assertEq(c.owner(), owner);
        assertEq(c.paused(), false);
        assertEq(c.arbiter(), address(0xA4B1));
        assertEq(c.slashDelaySeconds(), 2 * 86_400, "the dispute upgrade's setting survives");

        // The appended state reads empty.
        assertEq(e.totalHeld(), 0);
        assertEq(c.collectHoldSeconds(), Constants.DEFAULT_COLLECT_HOLD_SECONDS);
        assertEq(uint8(e.held(buyer, 1).status), uint8(X402Escrow.HeldStatus.None));
    }

    /// A voucher signed before the upgrade lands after it — into hold — and is collected.
    function test_aPreUpgradeVoucherRedeemsIntoHoldAfterTheUpgrade() public {
        Voucher memory v = _v(200_000, 2);
        bytes memory sig = VoucherSigner.signVoucher(buyerKey, oldEscrow.DOMAIN_SEPARATOR(), v);
        (, X402Escrow e) = _upgradeBoth();

        vm.prank(redeemer);
        e.redeemVoucher(v, sig);
        assertEq(usdg.balanceOf(provider), 90_000, "not paid at redemption any more");
        assertEq(e.totalHeld(), 200_000);
        assertEq(e.held(buyer, 2).collectableAt, uint64(vm.getBlockTimestamp()) + 3_600);

        _collect(e, buyer, 2);
        assertEq(usdg.balanceOf(provider), 90_000 + 180_000);
        assertGe(usdg.balanceOf(address(e)), uint256(e.totalEscrowed()) + e.totalHeld());
    }

    /// Escrow before Config bricks redemption (the new Escrow calls `collectHoldSeconds`, which
    /// the old Config lacks) — and nothing else: the money stays, and upgrading Config afterwards
    /// repairs it. `UpgradeByOwner` refuses this order (`ConfigMustBeUpgradedFirst`).
    function test_theOrderMatters_configBeforeEscrow() public {
        Voucher memory v = _v(200_000, 2);
        bytes memory sig = VoucherSigner.signVoucher(buyerKey, oldEscrow.DOMAIN_SEPARATOR(), v);
        address eImpl = address(new X402Escrow());
        vm.prank(owner);
        oldEscrow.upgradeToAndCall(eImpl, "");
        X402Escrow e = X402Escrow(address(oldEscrow));

        vm.prank(redeemer);
        vm.expectRevert();
        e.redeemVoucher(v, sig);

        address cImpl = address(new X402Config());
        vm.prank(owner);
        oldConfig.upgradeToAndCall(cImpl, "");
        vm.prank(redeemer);
        e.redeemVoucher(v, sig);
        assertEq(e.totalHeld(), 200_000);
    }
}
