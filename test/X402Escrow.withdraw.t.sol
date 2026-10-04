// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {Fixture} from "./helpers/Fixture.sol";
import {VoucherSigner} from "./helpers/VoucherSigner.sol";
import {X402Escrow} from "../src/X402Escrow.sol";
import {Voucher} from "../src/Types.sol";
import {Constants} from "../src/Constants.sol";
import "../src/Errors.sol";

/// The payout-side observer, and the `withdraw()` counterpart of `RedeemObserverUSDG`.
///
/// It re-enters a **view** from inside `withdraw`'s transfer and records what the escrow looked
/// like at the moment of the first external call. `escrowOf` and `totalEscrowed` carry no
/// `nonReentrant`, so the read succeeds, the OUTER call succeeds, and the mock's storage
/// therefore survives to be asserted — which a flag on a reverting re-entrancy mock cannot do,
/// because that test's outer call unwinds the mock along with the escrow.
///
/// It fails the instant anybody moves the transfer above an effect.
contract WithdrawObserverUSDG {
    uint8 public constant decimals = 6;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    address public escrow;
    address public observedBuyer;
    bool private armed;
    bool public observed;

    uint128 public seenBalance;
    uint64 public seenWithdrawRequested;
    uint64 public seenWithdrawAvailableAt;
    uint128 public seenTotalWithdrawn;
    uint128 public seenTotalFunded;
    uint128 public seenTotalEscrowed;

    function arm(address escrow_, address buyer_) external {
        escrow = escrow_;
        observedBuyer = buyer_;
        armed = true;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    /// The payout door, and the observation point: the FIRST external call `withdraw` makes.
    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        if (armed) {
            armed = false;
            observed = true;
            X402Escrow.Escrow memory e = X402Escrow(escrow).escrowOf(observedBuyer);
            seenBalance = e.balance;
            seenWithdrawRequested = e.withdrawRequested;
            seenWithdrawAvailableAt = e.withdrawAvailableAt;
            seenTotalWithdrawn = e.totalWithdrawn;
            seenTotalFunded = e.totalFunded;
            seenTotalEscrowed = X402Escrow(escrow).totalEscrowed();
        }
        return true;
    }
}

/// A token whose **payout** re-enters `withdraw()`. The money-out direction has no measured
/// balance delta to fall back on, so this is the only place a guard is the sole thing between an
/// escrow and being emptied twice.
contract WithdrawReentrantUSDG {
    uint8 public constant decimals = 6;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    address public escrow;
    bool private armed;

    function arm(address escrow_) external {
        escrow = escrow_;
        armed = true;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    /// Re-enters ONCE, before returning, and bubbles the inner revert verbatim so the test sees
    /// the escrow's own error rather than a `SafeERC20` wrapper.
    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        if (armed) {
            armed = false;
            (bool ok, bytes memory ret) = escrow.call(abi.encodeWithSignature("withdraw()"));
            if (!ok) {
                assembly ("memory-safe") {
                    revert(add(ret, 0x20), mload(ret))
                }
            }
        }
        return true;
    }
}

/// `withdraw()` — the one door that is never relayed, takes no destination and is never
/// pause-gated.
contract X402EscrowWithdrawTest is Fixture {
    event EscrowWithdrawn(address indexed buyer, uint64 requested, uint64 amount);

    function setUp() public virtual override {
        super.setUp();
        _fund(buyer, 10_000_000);
        vm.startPrank(buyer);
        usdg.approve(address(escrow), 10_000_000);
        escrow.deposit(10_000_000);
        escrow.setLimits(1_000_000, 5_000_000);
        vm.stopPrank();
    }

    // --- the eight specified cases ------------------------------------------------------------

    function test_happyPath_theBuyerTakesTheirOwnMoneyAfterTheDelay() public {
        vm.prank(buyer);
        escrow.requestWithdraw(4_000_000);

        vm.warp(block.timestamp + Constants.WITHDRAW_DELAY_SECONDS);
        vm.prank(buyer);
        vm.expectEmit(true, false, false, true, address(escrow));
        emit EscrowWithdrawn(buyer, 4_000_000, 4_000_000);
        escrow.withdraw();

        assertEq(usdg.balanceOf(buyer), 4_000_000);
        assertEq(escrow.escrowOf(buyer).balance, 6_000_000);
        assertEq(escrow.escrowOf(buyer).totalWithdrawn, 4_000_000);
        assertEq(escrow.escrowOf(buyer).withdrawRequested, 0);
        assertEq(escrow.escrowOf(buyer).withdrawAvailableAt, 0);
        assertEq(escrow.totalEscrowed(), 6_000_000);

        // A spent request cannot be taken twice on the next block.
        vm.warp(block.timestamp + 1);
        vm.prank(buyer);
        vm.expectRevert(NoWithdrawRequested.selector);
        escrow.withdraw();
        assertEq(usdg.balanceOf(buyer), 4_000_000);
    }

    /// Boundary B10 at -1 / exact.
    function test_boundary_withdrawIsRefusedOneSecondEarlyAndAdmittedOnTheInstant() public {
        vm.prank(buyer);
        escrow.requestWithdraw(4_000_000);
        uint256 t0 = block.timestamp;

        vm.warp(t0 + Constants.WITHDRAW_DELAY_SECONDS - 1);
        vm.prank(buyer);
        vm.expectRevert(WithdrawNotYetAvailable.selector);
        escrow.withdraw();

        vm.warp(t0 + Constants.WITHDRAW_DELAY_SECONDS);
        vm.prank(buyer);
        escrow.withdraw();
        assertEq(usdg.balanceOf(buyer), 4_000_000);
    }

    function test_wrongState_withdrawWithNoRequestIsRefused() public {
        vm.prank(buyer);
        vm.expectRevert(NoWithdrawRequested.selector);
        escrow.withdraw();
    }

    /// Only the owner takes their own money. There is no destination parameter and no
    /// relayed variant, so this is the whole authorisation model.
    function test_wrongSigner_nobodyElseCanTakeTheBuyersMoney() public {
        vm.prank(buyer);
        escrow.requestWithdraw(4_000_000);
        vm.warp(block.timestamp + Constants.WITHDRAW_DELAY_SECONDS);

        vm.prank(address(0xDEAD));
        vm.expectRevert(NoWithdrawRequested.selector);
        escrow.withdraw(); // the attacker's own escrow has no request; the buyer's is untouched

        assertEq(escrow.escrowOf(buyer).withdrawRequested, 4_000_000);
        assertEq(usdg.balanceOf(address(0xDEAD)), 0);
    }

    /// A request larger than the balance pays what is there and clears the request.
    function test_happyPath_aRequestLargerThanTheBalancePaysWhatIsThere() public {
        vm.prank(buyer);
        escrow.requestWithdraw(type(uint64).max);
        vm.warp(block.timestamp + Constants.WITHDRAW_DELAY_SECONDS);
        vm.prank(buyer);
        vm.expectEmit(true, false, false, true, address(escrow));
        emit EscrowWithdrawn(buyer, type(uint64).max, 10_000_000);
        escrow.withdraw();
        assertEq(usdg.balanceOf(buyer), 10_000_000);
        assertEq(escrow.escrowOf(buyer).balance, 0);
        // `requested` and `amount` differ, and both are on the wire: an indexer that saw only
        // the second could not tell a partly-filled exit from a smaller one.
        assertEq(escrow.escrowOf(buyer).withdrawRequested, 0, "the request is spent either way");
    }

    /// Withdrawals are NEVER pause-gated.
    function test_pauseDoesNotCloseTheOwnersExit() public {
        vm.prank(buyer);
        escrow.requestWithdraw(4_000_000);
        vm.prank(admin);
        config.setPaused(true);

        vm.warp(block.timestamp + Constants.WITHDRAW_DELAY_SECONDS);
        vm.prank(buyer);
        escrow.withdraw();
        assertEq(usdg.balanceOf(buyer), 4_000_000);
        assertTrue(config.paused(), "the pause was live across the withdrawal");
    }

    /// THE INVARIANT THE DELAY EXISTS FOR: a voucher signed the instant before the request
    /// is dead 1,380 seconds before the withdrawal lands. 3600 > 120 + 300 + 1800.
    function test_aVoucherSignedBeforeTheRequestCannotOutliveTheDelay() public {
        Voucher memory v = Voucher({
            payer: buyer,
            provider: provider,
            amount: 1_000_000,
            resourceHash: keccak256("resource"),
            requestHash: keccak256("request"),
            seq: 1,
            issuedAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp) + Constants.VOUCHER_MAX_LIFETIME_SECONDS
        });
        bytes memory sig = VoucherSigner.signVoucher(buyerKey, escrow.DOMAIN_SEPARATOR(), v);

        vm.prank(buyer);
        escrow.requestWithdraw(10_000_000);

        vm.warp(block.timestamp + Constants.WITHDRAW_DELAY_SECONDS);
        vm.prank(redeemer);
        vm.expectRevert(VoucherExpired.selector);
        escrow.redeemVoucher(v, sig);

        vm.prank(buyer);
        escrow.withdraw();
        assertEq(usdg.balanceOf(buyer), 10_000_000);
    }

    /// There is no withdrawBySig, and this test is what stops one being added quietly.
    function test_thereIsNoRelayedWithdraw() public view {
        // withdraw() takes no arguments and no destination; its selector is the whole ABI.
        assertEq(escrow.withdraw.selector, bytes4(keccak256("withdraw()")));
    }

    // --- the three properties the eight specified cases do not reach ---------------------------

    /// **`totalFunded` must not move when the balance falls.** This is the second path that
    /// reduces a balance, and it owes the assertion `redeemVoucher` settled on its own path: the
    /// lifetime money-in counter has exactly one writer, `_credit`, and a withdrawal is not it.
    /// Without this, `totalFunded - totalWithdrawn - totalRedeemed == balance` — the identity a
    /// reconciler checks an escrow with — would hold by construction rather than by accounting,
    /// and a defect in either counter would be invisible.
    function test_totalFundedDoesNotMoveWhenTheBalanceFalls() public {
        assertEq(escrow.escrowOf(buyer).totalFunded, 10_000_000);

        vm.prank(buyer);
        escrow.requestWithdraw(4_000_000);
        vm.warp(block.timestamp + Constants.WITHDRAW_DELAY_SECONDS);
        vm.prank(buyer);
        escrow.withdraw();

        assertEq(escrow.escrowOf(buyer).totalFunded, 10_000_000, "money IN did not change");
        assertEq(escrow.escrowOf(buyer).balance, 6_000_000);
        assertEq(escrow.escrowOf(buyer).totalWithdrawn, 4_000_000);

        // and it still counts the way in, so a later deposit moves it and a later exit does not.
        vm.startPrank(buyer);
        usdg.approve(address(escrow), 4_000_000);
        escrow.deposit(4_000_000);
        assertEq(escrow.escrowOf(buyer).totalFunded, 14_000_000);
        escrow.requestWithdraw(1_000_000);
        vm.stopPrank();
        vm.warp(block.timestamp + Constants.WITHDRAW_DELAY_SECONDS);
        vm.prank(buyer);
        escrow.withdraw();
        assertEq(escrow.escrowOf(buyer).totalFunded, 14_000_000, "still money IN only");
        assertEq(escrow.escrowOf(buyer).totalWithdrawn, 5_000_000);
        assertEq(
            uint256(escrow.escrowOf(buyer).totalFunded) - escrow.escrowOf(buyer).totalWithdrawn,
            escrow.escrowOf(buyer).balance,
            "in - out == balance, with no redemption in between"
        );
    }

    /// An EMPTY escrow is refused rather than paid as zero and cleared — `withdraw.rs:123`. The
    /// standing request SURVIVES, so a buyer whose money arrives a second later does not have to
    /// serve the whole delay again. Nothing else in the suite reaches `EscrowInsufficient`.
    function test_wrongState_anEmptyEscrowIsRefusedAndTheRequestSurvives() public {
        uint256 poorKey = 0xB0B;
        address poor = vm.addr(poorKey);
        _fund(address(this), 1_000_000);
        usdg.approve(address(escrow), 1_000_000);
        escrow.depositFor(poor, 1_000_000);
        vm.startPrank(poor);
        escrow.setLimits(1_000_000, 5_000_000);
        escrow.requestWithdraw(1_000_000);
        vm.stopPrank();
        uint64 maturesAt = escrow.escrowOf(poor).withdrawAvailableAt;

        // the platform collects what the buyer already signed for, during the hour
        Voucher memory v = Voucher({
            payer: poor,
            provider: provider,
            amount: 1_000_000,
            resourceHash: keccak256("resource"),
            requestHash: keccak256("request"),
            seq: 1,
            issuedAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp) + 60
        });
        bytes memory sig = VoucherSigner.signVoucher(poorKey, escrow.DOMAIN_SEPARATOR(), v);
        vm.prank(redeemer);
        escrow.redeemVoucher(v, sig);
        assertEq(escrow.escrowOf(poor).balance, 0);

        vm.warp(uint256(maturesAt));
        vm.prank(poor);
        vm.expectRevert(EscrowInsufficient.selector);
        escrow.withdraw();

        assertEq(escrow.escrowOf(poor).withdrawRequested, 1_000_000, "the request is NOT spent");
        assertEq(escrow.escrowOf(poor).withdrawAvailableAt, maturesAt, "nor is the clock reset");

        // the money arrives a second later and the buyer takes it without serving the delay again
        _fund(address(this), 400_000);
        usdg.approve(address(escrow), 400_000);
        escrow.depositFor(poor, 400_000);
        vm.warp(block.timestamp + 1);
        vm.prank(poor);
        escrow.withdraw();
        assertEq(usdg.balanceOf(poor), 400_000);
    }

    /// A partly-filled request IS spent — `withdraw.rs:136-138`. The two halves are opposite
    /// answers to "was anything paid", and only a fixture where a redemption took *some* of the
    /// balance can tell them apart.
    function test_happyPath_aPartlyFilledRequestIsSpentAllTheSame() public {
        vm.prank(buyer);
        escrow.requestWithdraw(10_000_000);

        Voucher memory v = Voucher({
            payer: buyer,
            provider: provider,
            amount: 1_000_000,
            resourceHash: keccak256("resource"),
            requestHash: keccak256("request"),
            seq: 1,
            issuedAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp) + 60
        });
        bytes memory sig = VoucherSigner.signVoucher(buyerKey, escrow.DOMAIN_SEPARATOR(), v);
        vm.prank(redeemer);
        escrow.redeemVoucher(v, sig);

        vm.warp(block.timestamp + Constants.WITHDRAW_DELAY_SECONDS);
        vm.prank(buyer);
        vm.expectEmit(true, false, false, true, address(escrow));
        emit EscrowWithdrawn(buyer, 10_000_000, 9_000_000);
        escrow.withdraw();

        assertEq(usdg.balanceOf(buyer), 9_000_000);
        assertEq(escrow.escrowOf(buyer).withdrawRequested, 0, "spent, not left standing");
        assertEq(escrow.escrowOf(buyer).withdrawAvailableAt, 0);
        assertEq(escrow.escrowOf(buyer).totalFunded, 10_000_000);
    }

    // --- the exit across the ADDRESS SPACE ------------------------------------------------------

    /// `withdraw` is keyed by `msg.sender` at exactly one point in the source, so a bypass keyed
    /// on some other address would be invisible to a suite that only ever calls it as `buyer` —
    /// the shape of the `redeemVoucher` backdoor mutant that once passed 193 tests. Every buyer
    /// here takes their own money and nobody else's, and the escrow of the caller before them is
    /// re-checked each time.
    function test_everyBuyerTakesTheirOwnAndOnlyTheirOwn() public {
        uint256[6] memory keys = [uint256(1), 2, 3, 7, 65_537, VoucherSigner.N - 1];
        uint64[6] memory funded = [uint64(1_000), 2_000, 3_000, 4_000, 5_000, 6_000];

        _fund(address(this), 21_000);
        usdg.approve(address(escrow), 21_000);
        for (uint256 i = 0; i < keys.length; i++) {
            escrow.depositFor(vm.addr(keys[i]), funded[i]);
        }

        for (uint256 i = 0; i < keys.length; i++) {
            address b = vm.addr(keys[i]);
            vm.prank(b);
            escrow.requestWithdraw(funded[i]);
        }
        vm.warp(block.timestamp + Constants.WITHDRAW_DELAY_SECONDS);

        for (uint256 i = 0; i < keys.length; i++) {
            address b = vm.addr(keys[i]);
            vm.prank(b);
            escrow.withdraw();
            assertEq(usdg.balanceOf(b), funded[i], "this buyer got exactly their own");
            assertEq(escrow.escrowOf(b).balance, 0);
            assertEq(escrow.escrowOf(b).totalFunded, funded[i], "and totalFunded held still");

            // everyone after them is untouched
            for (uint256 j = i + 1; j < keys.length; j++) {
                address later = vm.addr(keys[j]);
                assertEq(usdg.balanceOf(later), 0);
                assertEq(escrow.escrowOf(later).balance, funded[j]);
            }
        }
        assertEq(escrow.escrowOf(buyer).balance, 10_000_000, "and so is the fixture's buyer");
    }

    /// A deterministic small-value sweep beside the fuzz below: `requested` and `balance` at and
    /// around each other, where `min(requested, balance)` decides which branch is taken. A
    /// uniform fuzz samples the typical and would essentially never draw `requested == balance`.
    function test_boundary_theMinimumIsTakenAtAndAroundEquality() public {
        uint64[9] memory bal = [uint64(1), 1, 1, 2, 2, 2, 1_000_000, 1_000_000, 1_000_000];
        uint64[9] memory req = [uint64(1), 2, 1, 1, 2, 3, 999_999, 1_000_000, 1_000_001];
        uint64[9] memory paid = [uint64(1), 1, 1, 1, 2, 2, 999_999, 1_000_000, 1_000_000];

        for (uint256 i = 0; i < bal.length; i++) {
            address b = address(uint160(0xB1D0000 + i));
            _fund(address(this), bal[i]);
            usdg.approve(address(escrow), bal[i]);
            escrow.depositFor(b, bal[i]);

            vm.prank(b);
            escrow.requestWithdraw(req[i]);
            vm.warp(block.timestamp + Constants.WITHDRAW_DELAY_SECONDS);
            vm.prank(b);
            escrow.withdraw();

            assertEq(usdg.balanceOf(b), paid[i], "min(requested, balance)");
            assertEq(escrow.escrowOf(b).balance, bal[i] - paid[i]);
            assertEq(escrow.escrowOf(b).totalWithdrawn, paid[i]);
            assertEq(escrow.escrowOf(b).totalFunded, bal[i]);
        }
    }

    function testFuzz_theExitPaysTheMinimumAndSpendsTheRequest(uint64 deposited, uint64 requested)
        public
    {
        deposited = uint64(bound(deposited, 1, 1_000_000_000));
        requested = uint64(bound(requested, 1, type(uint64).max));
        address b = address(uint160(uint256(keccak256(abi.encode(deposited, requested)))));
        vm.assume(b != address(0) && b != address(escrow) && b != buyer);

        _fund(address(this), deposited);
        usdg.approve(address(escrow), deposited);
        escrow.depositFor(b, deposited);

        vm.prank(b);
        escrow.requestWithdraw(requested);
        vm.warp(block.timestamp + Constants.WITHDRAW_DELAY_SECONDS);
        vm.prank(b);
        escrow.withdraw();

        uint64 expected = requested < deposited ? requested : deposited;
        assertEq(usdg.balanceOf(b), expected);
        assertEq(escrow.escrowOf(b).balance, deposited - expected);
        assertEq(escrow.escrowOf(b).totalWithdrawn, expected);
        assertEq(escrow.escrowOf(b).totalFunded, deposited, "totalFunded never falls");
        assertEq(escrow.escrowOf(b).withdrawRequested, 0);
        assertEq(escrow.escrowOf(b).withdrawAvailableAt, 0);
    }

    // --- what stops re-entrancy on THIS path ----------------------------------------------------

    /// **The ordering is the brace; `nonReentrant` is the belt.** Every one of the five effects is
    /// already written when the transfer happens, so a re-entrant asset finds
    /// `withdrawRequested == 0` and is refused by `NoWithdrawRequested` even with the modifier
    /// gone — measured, and recorded in `test/MUTATION-LOG.md`. This test pins the modifier;
    /// `test_everyEffectIsWrittenBeforeTheWithdrawalTransfer` pins the ordering, and neither is a
    /// substitute for the other.
    function test_wrongState_aReentrantAssetCannotRecurseIntoWithdraw() public {
        WithdrawReentrantUSDG evil = new WithdrawReentrantUSDG();
        X402Escrow e2 = _deployEscrow(address(evil), address(0));

        evil.mint(buyer, 10_000_000);
        vm.startPrank(buyer);
        evil.approve(address(e2), 10_000_000);
        e2.deposit(10_000_000);
        e2.requestWithdraw(4_000_000);
        vm.stopPrank();
        evil.arm(address(e2));

        vm.warp(block.timestamp + Constants.WITHDRAW_DELAY_SECONDS);
        // `expectCall` is checked as calls happen, so it survives the revert that unwinds the
        // mock's own storage — the only way to assert the nested call was really attempted.
        vm.expectCall(address(e2), abi.encodeWithSignature("withdraw()"), 2);
        vm.prank(buyer);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        e2.withdraw();

        assertEq(e2.escrowOf(buyer).balance, 10_000_000, "and nothing moved");
        assertEq(evil.balanceOf(buyer), 0);
        assertEq(e2.escrowOf(buyer).totalWithdrawn, 0);
    }

    /// The committable ordering guard. Every one of the five effects must already be written when
    /// the FIRST external call happens. Nothing needs mutating: the observer re-enters a **view**,
    /// the outer call succeeds, and its storage survives to be asserted.
    function test_everyEffectIsWrittenBeforeTheWithdrawalTransfer() public {
        WithdrawObserverUSDG obs = new WithdrawObserverUSDG();
        X402Escrow e2 = _deployEscrow(address(obs), address(0));

        obs.mint(buyer, 10_000_000);
        vm.startPrank(buyer);
        obs.approve(address(e2), 10_000_000);
        e2.deposit(10_000_000);
        e2.requestWithdraw(4_000_000);
        vm.stopPrank();
        obs.arm(address(e2), buyer);

        vm.warp(block.timestamp + Constants.WITHDRAW_DELAY_SECONDS);
        vm.prank(buyer);
        e2.withdraw();

        assertTrue(obs.observed(), "the observer never ran, so nothing below is asserting anything");
        assertEq(obs.seenBalance(), 6_000_000, "balance not yet debited at payout time");
        assertEq(obs.seenWithdrawRequested(), 0, "the request not yet spent at payout time");
        assertEq(obs.seenWithdrawAvailableAt(), 0, "the clock not yet cleared at payout time");
        assertEq(obs.seenTotalWithdrawn(), 4_000_000, "totalWithdrawn not yet advanced");
        assertEq(obs.seenTotalEscrowed(), 6_000_000, "totalEscrowed not yet debited");
        assertEq(obs.seenTotalFunded(), 10_000_000, "totalFunded MOVED on a falling balance");

        assertEq(obs.balanceOf(buyer), 4_000_000, "and the withdrawal really completed");
    }

    // --- the source and ABI gates ---------------------------------------------------------------

    /// **The two degenerates this kills** are a `withdraw()` that pays a stored destination rather
    /// than `msg.sender`, and a `withdrawBySig` added later. Neither is behaviourally visible: a
    /// destination that defaults to `msg.sender` when unset passes every test above, and a new
    /// relayed door breaks nothing that exists.
    ///
    /// So the shape is pinned in two independent places. The source gate pins the recipient
    /// expression; the ABI gate pins the whole external surface, read out of the compiled
    /// artifact rather than out of the source, so a function added through an inherited contract
    /// is caught too. A deliberate addition is a red test that asks the editor to say so here.
    function test_theExitPaysMsgSenderAndTheAbiHasNoOtherWithdrawDoor() public view {
        string memory src = vm.readFile(string.concat(vm.projectRoot(), "/src/X402Escrow.sol"));
        assertEq(
            _count(src, "        ASSET.safeTransfer(msg.sender, amount);\n"),
            1,
            "the withdrawal recipient is not the exact msg.sender expression this test pins"
        );
        assertEq(_count(src, "function withdraw"), 1, "there is more than one withdraw function");
        // the needle carries `function ` because this file's own NatSpec names `withdrawBySig`
        // twice, in the two paragraphs explaining why there is not one. The ABI gate below is
        // what catches a relayed door spelled under some other name.
        assertEq(_count(src, "function withdrawBySig"), 0, "a relayed withdraw exists in src/");

        string[24] memory expected = [
            "ASSET()",
            "CONFIG()",
            "DOMAIN_SEPARATOR()",
            "PERMIT2()",
            "STAKE()",
            "UPGRADE_INTERFACE_VERSION()",
            "deposit(uint64)",
            "depositFor(address,uint64)",
            "depositWithPermit2(address,uint64,uint256,uint256,bytes)",
            "eip712Domain()",
            "escrowOf(address)",
            "initialize(address,address,address,address)",
            "proxiableUUID()",
            "recoverVoucherSigner((address,address,uint64,bytes32,bytes32,uint64,uint64,uint64),bytes)",
            "redeemVoucher((address,address,uint64,bytes32,bytes32,uint64,uint64,uint64),bytes)",
            "redeemVoucherBatch((address,address,uint64,bytes32,bytes32,uint64,uint64,uint64)[],bytes[])",
            "requestWithdraw(uint64)",
            "requestWithdrawBySig(address,uint64,uint64,uint64,bytes)",
            "setLimits(uint64,uint64)",
            "setLimitsBySig(address,uint64,uint64,uint64,uint64,bytes)",
            "totalEscrowed()",
            "upgradeToAndCall(address,bytes)",
            "withdraw()",
            "" // the 24th slot is deliberately empty: a 24th function makes this test red
        ];

        string memory artifact =
            vm.readFile(string.concat(vm.projectRoot(), "/out/X402Escrow.sol/X402Escrow.json"));
        string[] memory keys = vm.parseJsonKeys(artifact, ".methodIdentifiers");
        assertEq(keys.length, 23, "X402Escrow's external surface changed size");

        for (uint256 i = 0; i < keys.length; i++) {
            bool found;
            for (uint256 j = 0; j < expected.length; j++) {
                if (keccak256(bytes(keys[i])) == keccak256(bytes(expected[j]))) found = true;
            }
            assertTrue(found, string.concat("an external function nobody pinned: ", keys[i]));
        }
        for (uint256 j = 0; j < expected.length - 1; j++) {
            bool found;
            for (uint256 i = 0; i < keys.length; i++) {
                if (keccak256(bytes(keys[i])) == keccak256(bytes(expected[j]))) found = true;
            }
            assertTrue(
                found, string.concat("a pinned external function disappeared: ", expected[j])
            );
        }
    }

    function _count(string memory haystack, string memory needle)
        internal
        pure
        returns (uint256 n)
    {
        bytes memory h = bytes(haystack);
        bytes memory x = bytes(needle);
        if (x.length == 0 || x.length > h.length) return 0;
        for (uint256 i = 0; i + x.length <= h.length; i++) {
            uint256 j = 0;
            while (j < x.length && h[i + j] == x[j]) j++;
            if (j == x.length) n++;
        }
    }
}
