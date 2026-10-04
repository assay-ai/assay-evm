// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.24;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {Fixture} from "./helpers/Fixture.sol";
import {MockPermit2, ReentrantPermit2} from "./helpers/MockPermit2.sol";
import {ReentrantUSDG, FalseReturningUSDG, NoReturnUSDG} from "./helpers/MockUSDG.sol";
import {X402Escrow} from "../src/X402Escrow.sol";
import {IX402Config} from "../src/interfaces/IX402Config.sol";
import {IX402StakeView} from "../src/interfaces/IX402StakeView.sol";
import {ParamSet} from "../src/Types.sol";
import "../src/Errors.sol";

/// An asset with the wrong decimals, and nothing else. `initialize` reads exactly one function
/// off the asset, so this is the whole surface it needs.
contract EighteenDecimals {
    function decimals() external pure returns (uint8) {
        return 18;
    }
}

/// `X402Escrow`'s storage and its two funding doors.
///
/// Every assertion pins a *value* rather than relating two numbers the implementation produces,
/// because the recurring defect in this suite is a test a degenerate satisfies: a credit that
/// assigns instead of adding, a single global balance every buyer reads, a `totalEscrowed`
/// derived from the one balance just written. The amounts here are therefore all distinct and
/// non-round, two deposits are made wherever one would do, and two buyers and two proxies are
/// funded wherever one would do.
contract X402EscrowDepositTest is Fixture {
    /// ERC-1967 implementation slot — `bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1)`.
    bytes32 internal constant IMPL_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    address internal relayer = address(0x2E14);
    address internal stranger = address(0xDEAD);

    event Deposited(address indexed buyer, address indexed funder, uint64 amount, uint128 balance);

    // --- storage and the four addresses -----------------------------------------------------

    function test_happyPath_initializeStoresTheFourAddresses() public view {
        assertEq(address(escrow.CONFIG()), address(config));
        assertEq(address(escrow.STAKE()), address(stakeView));
        assertEq(address(escrow.ASSET()), address(usdg));
        assertEq(escrow.PERMIT2(), address(0));

        // Called THROUGH the declared types, so the getters' return types are pinned by the
        // compiler and not only by `address(...)`, which accepts a plain `address` just as well.
        // A getter retyped to `address` — the shape a reviewer's degenerate used — stops this
        // file compiling, which is the loudest failure available.
        assertEq(escrow.STAKE().bondedOf(provider), MINIMUM_STAKE, "STAKE is IX402StakeView");
        assertEq(escrow.CONFIG().admin(), admin, "CONFIG is IX402Config");
        assertEq(escrow.ASSET().balanceOf(address(escrow)), 0, "ASSET is IERC20");
    }

    /// A second proxy with a DIFFERENT permit2 and a different asset, so a hard-coded getter
    /// cannot satisfy both instances.
    function test_theStoredAddressesAreThisProxysOwn() public {
        MockPermit2 permit2 = new MockPermit2();
        X402Escrow a = _deployEscrow(address(permit2));
        assertEq(a.PERMIT2(), address(permit2));
        assertEq(escrow.PERMIT2(), address(0), "the fixture's escrow is unchanged");
        assertEq(address(a.ASSET()), address(usdg));
        assertEq(address(a.CONFIG()), address(config));
    }

    function test_wrongState_initializeRefusesAZeroConfigOrStakeOrAsset() public {
        vm.expectRevert(ZeroAddress.selector);
        new ERC1967Proxy(
            address(escrowImpl),
            abi.encodeCall(
                X402Escrow.initialize,
                (IX402Config(address(0)), stakeView, IERC20(address(usdg)), address(0))
            )
        );

        vm.expectRevert(ZeroAddress.selector);
        new ERC1967Proxy(
            address(escrowImpl),
            abi.encodeCall(
                X402Escrow.initialize,
                (
                    IX402Config(address(config)),
                    IX402StakeView(address(0)),
                    IERC20(address(usdg)),
                    address(0)
                )
            )
        );

        vm.expectRevert(ZeroAddress.selector);
        new ERC1967Proxy(
            address(escrowImpl),
            abi.encodeCall(
                X402Escrow.initialize,
                (IX402Config(address(config)), stakeView, IERC20(address(0)), address(0))
            )
        );
    }

    /// `initialize_config.rs:24-32` refuses a mint whose token program is not the one the
    /// program can account for; the EVM question about the settlement asset is its decimals.
    function test_wrongState_initializeRefusesAnAssetThatIsNotSixDecimals() public {
        EighteenDecimals wrong = new EighteenDecimals();
        vm.expectRevert(AssetDecimalsNotSix.selector);
        _deployEscrow(address(wrong), address(0));
    }

    function test_wrongState_initializeRunsOnce() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        escrow.initialize(
            IX402Config(address(config)), stakeView, IERC20(address(usdg)), address(0)
        );
    }

    /// Without `_disableInitializers()` anybody may initialize the implementation, become the
    /// admin it reads and upgrade it out from under every proxy pointing at it.
    function test_wrongState_theImplementationCannotBeInitialised() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        escrowImpl.initialize(
            IX402Config(address(config)), stakeView, IERC20(address(usdg)), address(0)
        );
    }

    /// The layout, asserted from inside the suite and not only by `script/check-layout.sh`.
    ///
    /// The gate compares against a committed snapshot, so it is only as good as somebody
    /// running it; this reads the live proxy's slots and fails in the ordinary test run. It is
    /// what makes the twelve-field struct load-bearing today: ten of those fields have no
    /// writer on the deposit path, and without this an implementation that stored nothing but a
    /// `mapping(address => uint128)` would satisfy every other assertion in this file.
    ///
    /// The constants come from `snapshots/X402Escrow.storage.json`: `escrows` at slot 7,
    /// `totalEscrowed` at slot 8, and the four addresses at 3, 4, 5, 6.
    function test_theStorageLayoutIsTheOneTheSnapshotCommitsTo() public {
        _fund(buyer, 1_000_000);
        vm.startPrank(buyer);
        usdg.approve(address(escrow), 1_000_000);
        escrow.deposit(1_000_000);
        vm.stopPrank();

        assertEq(_addrAt(3), address(config), "CONFIG at slot 3");
        assertEq(_addrAt(4), address(stakeView), "STAKE at slot 4");
        assertEq(_addrAt(5), address(usdg), "ASSET at slot 5");
        assertEq(_addrAt(6), address(0), "PERMIT2 at slot 6");
        assertEq(uint256(vm.load(address(escrow), bytes32(uint256(8)))), 1_000_000, "totalEscrowed");

        // `escrows[buyer]` starts at keccak256(abi.encode(key, slot)) and occupies four slots.
        uint256 base = uint256(keccak256(abi.encode(buyer, uint256(7))));
        uint256 s0 = uint256(vm.load(address(escrow), bytes32(base)));
        assertEq(uint128(s0), 1_000_000, "balance is the low 16 bytes of the struct's slot 0");
        assertEq(uint64(s0 >> 128), 0, "seqHigh sits above it");
        assertEq(uint64(s0 >> 192), 0, "authNonce above that");

        uint256 s3 = uint256(vm.load(address(escrow), bytes32(base + 3)));
        assertEq(uint128(s3), 0, "totalWithdrawn is the low half of slot 3");
        assertEq(
            uint128(s3 >> 128),
            1_000_000,
            "totalFunded is the HIGH half - its own storage, not a second name for balance"
        );

        // …and the struct really is four slots: the fifth is the next mapping entry's, untouched.
        assertEq(uint256(vm.load(address(escrow), bytes32(base + 1))), 0, "slots 1 and 2 are the");
        assertEq(uint256(vm.load(address(escrow), bytes32(base + 2))), 0, "limits and the withdraw");
    }

    /// All TWELVE fields, each pinned to its slot AND its bit offset.
    ///
    /// The test above pins two of them, because the other ten have no writer on the deposit path
    /// and an assertion that reads zero is satisfied by any permutation of unwritten fields — a
    /// reviewer's degenerate permuted all ten, kept the struct at 128 bytes, and passed. This
    /// test writes the four slots RAW, with twelve distinct recognisable values in the documented
    /// packing, and then reads them back through `escrowOf`. Any permutation, any changed offset
    /// and any changed width decodes at least one field to the wrong number.
    // Twelve distinct recognisable values. At contract level rather than as locals only because
    // the function reads better that way; both spellings compile and run identically.
    //
    // (An earlier version of this comment blamed `via_ir`'s stack scheduler for a cold build that
    // went from ~85s to 677s when these were locals. That was wrong and is recorded here rather
    // than deleted: hoisting them changed nothing — the next cold build took 823s — and
    // `/usr/bin/time -p` showed `real 829.59 / user 58.38`, i.e. ~58s of CPU. The machine was
    // contended, not the code. Do not attribute a wall-clock number on this box to a source
    // change without the CPU number beside it.)
    uint128 internal constant BAL_ = 111_000_000_000_001;
    uint64 internal constant SEQ_ = 222_000_000_000_002;
    uint64 internal constant NONCE_ = 333_000_000_000_003;
    uint64 internal constant MAXV_ = 444_000_000_000_004;
    uint64 internal constant MAXW_ = 555_000_000_000_005;
    uint64 internal constant SPENT_ = 666_000_000_000_006;
    uint64 internal constant WSTART_ = 777_000_000_000_007;
    uint64 internal constant WREQ_ = 888_000_000_000_008;
    uint64 internal constant WAVAIL_ = 999_000_000_000_009;
    uint128 internal constant TRED_ = 121_000_000_000_010;
    uint128 internal constant TWDR_ = 131_000_000_000_011;
    uint128 internal constant TFUND_ = 141_000_000_000_012;

    function test_theTwelveEscrowFieldsDecodeFromTheFourSlotsTheSnapshotCommitsTo() public {
        uint256 base = uint256(keccak256(abi.encode(buyer, uint256(7))));
        vm.store(
            address(escrow),
            bytes32(base),
            bytes32(uint256(BAL_) | (uint256(SEQ_) << 128) | (uint256(NONCE_) << 192))
        );
        vm.store(
            address(escrow),
            bytes32(base + 1),
            bytes32(
                uint256(MAXV_) | (uint256(MAXW_) << 64) | (uint256(SPENT_) << 128)
                    | (uint256(WSTART_) << 192)
            )
        );
        vm.store(
            address(escrow),
            bytes32(base + 2),
            bytes32(uint256(WREQ_) | (uint256(WAVAIL_) << 64) | (uint256(TRED_) << 128))
        );
        vm.store(
            address(escrow), bytes32(base + 3), bytes32(uint256(TWDR_) | (uint256(TFUND_) << 128))
        );

        X402Escrow.Escrow memory e = escrow.escrowOf(buyer);
        assertEq(e.balance, BAL_, "balance: slot 0, offset 0");
        assertEq(e.seqHigh, SEQ_, "seqHigh: slot 0, offset 16");
        assertEq(e.authNonce, NONCE_, "authNonce: slot 0, offset 24");
        assertEq(e.maxVoucherAmount, MAXV_, "maxVoucherAmount: slot 1, offset 0");
        assertEq(e.maxPerWindow, MAXW_, "maxPerWindow: slot 1, offset 8");
        assertEq(e.spentInWindow, SPENT_, "spentInWindow: slot 1, offset 16");
        assertEq(e.windowStartedAt, WSTART_, "windowStartedAt: slot 1, offset 24");
        assertEq(e.withdrawRequested, WREQ_, "withdrawRequested: slot 2, offset 0");
        assertEq(e.withdrawAvailableAt, WAVAIL_, "withdrawAvailableAt: slot 2, offset 8");
        assertEq(e.totalRedeemed, TRED_, "totalRedeemed: slot 2, offset 16");
        assertEq(e.totalWithdrawn, TWDR_, "totalWithdrawn: slot 3, offset 0");
        assertEq(e.totalFunded, TFUND_, "totalFunded: slot 3, offset 16");

        // Four slots, not five: the neighbour is still zero and the entry stops here.
        assertEq(uint256(vm.load(address(escrow), bytes32(base + 4))), 0, "the struct is 4 slots");
    }

    function _addrAt(uint256 slot) internal view returns (address) {
        return address(uint160(uint256(vm.load(address(escrow), bytes32(slot)))));
    }

    // --- the domain separator ---------------------------------------------------------------

    /// The separator is the PROXY's, and its name and version are the two strings that may never
    /// change. Recomputed here from the literals rather than read back from the contract, so an
    /// implementation that renamed either fails this test instead of agreeing with itself.
    function test_theDomainSeparatorIsTheProxysAndNamesX402Settlement() public view {
        bytes32 expected = keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256(bytes("x402 Settlement")),
                keccak256(bytes("2")),
                block.chainid,
                address(escrow)
            )
        );
        assertEq(escrow.DOMAIN_SEPARATOR(), expected);
        assertTrue(
            escrow.DOMAIN_SEPARATOR() != escrowImpl.DOMAIN_SEPARATOR(),
            "the implementation's separator is a different contract's"
        );
    }

    // --- deposit ----------------------------------------------------------------------------

    function test_happyPath_depositCreditsTheBuyerAndThePool() public {
        _fund(buyer, 1_000_000);
        vm.startPrank(buyer);
        usdg.approve(address(escrow), 1_000_000);
        escrow.deposit(1_000_000);
        vm.stopPrank();

        assertEq(escrow.escrowOf(buyer).balance, 1_000_000);
        assertEq(escrow.escrowOf(buyer).totalFunded, 1_000_000);
        assertEq(escrow.totalEscrowed(), 1_000_000);
    }

    /// The tokens actually move, and they move to this contract. Without this, an escrow whose
    /// `_pullExact` did nothing but assert would still pass the credit assertions above.
    function test_happyPath_depositMovesTheTokensToTheEscrow() public {
        _fund(buyer, 7_654_321);
        vm.startPrank(buyer);
        usdg.approve(address(escrow), 7_654_321);
        escrow.deposit(4_321_000);
        vm.stopPrank();

        assertEq(usdg.balanceOf(buyer), 3_333_321);
        assertEq(usdg.balanceOf(address(escrow)), 4_321_000);
        assertEq(escrow.escrowOf(buyer).balance, 4_321_000);
    }

    /// `deposit_stake.rs:75` — "Deposits accumulate: a second deposit adds to the first, it does
    /// not replace it." Three different amounts, so an implementation that assigns, or that
    /// doubles, or that keeps only the last, disagrees with all three totals.
    function test_happyPath_depositsAccumulate() public {
        _fund(buyer, 9_000_000);
        vm.startPrank(buyer);
        usdg.approve(address(escrow), type(uint256).max);
        escrow.deposit(1_000_003);
        assertEq(escrow.escrowOf(buyer).balance, 1_000_003);
        escrow.deposit(2_000_005);
        assertEq(escrow.escrowOf(buyer).balance, 3_000_008);
        escrow.deposit(11);
        vm.stopPrank();

        assertEq(escrow.escrowOf(buyer).balance, 3_000_019);
        assertEq(escrow.escrowOf(buyer).totalFunded, 3_000_019);
        assertEq(escrow.totalEscrowed(), 3_000_019);
        assertEq(usdg.balanceOf(address(escrow)), 3_000_019);
    }

    /// One pooled contract, per-buyer accounting. A single global balance passes every
    /// single-buyer test in this file and fails this one.
    function test_twoBuyersDoNotShareABalance() public {
        address second = address(0xB0B);
        _fund(buyer, 1_111_111);
        _fund(second, 2_222_222);

        vm.startPrank(buyer);
        usdg.approve(address(escrow), type(uint256).max);
        escrow.deposit(1_111_111);
        vm.stopPrank();

        vm.startPrank(second);
        usdg.approve(address(escrow), type(uint256).max);
        escrow.deposit(2_222_222);
        vm.stopPrank();

        assertEq(escrow.escrowOf(buyer).balance, 1_111_111);
        assertEq(escrow.escrowOf(second).balance, 2_222_222);
        assertEq(escrow.totalEscrowed(), 3_333_333);
    }

    /// `totalEscrowed` is a contract-wide sum, not a copy of the balance last written.
    function testFuzz_totalEscrowedIsTheSumOfEveryBalance(uint64 a, uint64 b, uint64 c) public {
        a = uint64(bound(a, 1, 1e15));
        b = uint64(bound(b, 1, 1e15));
        c = uint64(bound(c, 1, 1e15));
        address[3] memory who = [buyer, address(0xB0B), address(0xCAFE)];
        uint64[3] memory amt = [a, b, c];

        for (uint256 i = 0; i < 3; i++) {
            _fund(who[i], amt[i]);
            vm.startPrank(who[i]);
            usdg.approve(address(escrow), amt[i]);
            escrow.deposit(amt[i]);
            vm.stopPrank();
        }

        uint256 sum;
        for (uint256 i = 0; i < 3; i++) {
            assertEq(escrow.escrowOf(who[i]).balance, amt[i]);
            sum += amt[i];
        }
        assertEq(escrow.totalEscrowed(), sum);
        assertEq(usdg.balanceOf(address(escrow)), sum);
    }

    /// Two proxies over one implementation share no storage. A degenerate holding its accounting
    /// anywhere but in the proxy's own slots fails here.
    function test_theBalancesAreThisProxysOwn() public {
        X402Escrow other = _deployEscrow(address(0));
        _fund(buyer, 5_000_000);
        vm.startPrank(buyer);
        usdg.approve(address(escrow), 5_000_000);
        escrow.deposit(5_000_000);
        vm.stopPrank();

        assertEq(escrow.escrowOf(buyer).balance, 5_000_000);
        assertEq(other.escrowOf(buyer).balance, 0);
        assertEq(other.totalEscrowed(), 0);
    }

    /// `events.rs::StakeDeposited` carries the running total, not just the delta, so a reader
    /// never has to fold the log to know where the account stands.
    function test_happyPath_theDepositedEventCarriesTheFunderAndTheRunningBalance() public {
        _fund(buyer, 3_000_000);
        vm.startPrank(buyer);
        usdg.approve(address(escrow), type(uint256).max);

        vm.expectEmit(true, true, false, true, address(escrow));
        emit Deposited(buyer, buyer, 1_200_000, 1_200_000);
        escrow.deposit(1_200_000);

        vm.expectEmit(true, true, false, true, address(escrow));
        emit Deposited(buyer, buyer, 800_000, 2_000_000);
        escrow.deposit(800_000);
        vm.stopPrank();
    }

    /// A fresh escrow is zero-valued, and zero limits mean REFUSE, not "unlimited".
    /// This is what replaces open_escrow: the EVM's default storage gives fail-closed free.
    function test_happyPath_aFreshEscrowHasZeroLimits() public view {
        X402Escrow.Escrow memory e = escrow.escrowOf(address(0xFEED));
        assertEq(e.maxVoucherAmount, 0);
        assertEq(e.maxPerWindow, 0);
        assertEq(e.seqHigh, 0);
        assertEq(e.balance, 0);
    }

    /// Every one of the twelve fields, so a later task cannot quietly change what "unopened"
    /// means. `open_escrow.rs:99-111` writes exactly these zeroes by hand on Solana.
    function test_happyPath_everyFieldOfAFreshEscrowIsZero() public view {
        X402Escrow.Escrow memory e = escrow.escrowOf(address(0xFEED));
        assertEq(e.balance, 0);
        assertEq(e.seqHigh, 0);
        assertEq(e.authNonce, 0);
        assertEq(e.maxVoucherAmount, 0);
        assertEq(e.maxPerWindow, 0);
        assertEq(e.spentInWindow, 0);
        assertEq(e.windowStartedAt, 0);
        assertEq(e.withdrawRequested, 0);
        assertEq(e.withdrawAvailableAt, 0);
        assertEq(e.totalRedeemed, 0);
        assertEq(e.totalWithdrawn, 0);
        assertEq(e.totalFunded, 0);
    }

    function test_happyPath_anybodyMayFundAnybody() public {
        _fund(provider, 500_000);
        vm.startPrank(provider);
        usdg.approve(address(escrow), 500_000);
        escrow.depositFor(buyer, 500_000);
        vm.stopPrank();
        assertEq(escrow.escrowOf(buyer).balance, 500_000);
        assertEq(escrow.escrowOf(provider).balance, 0);
        assertEq(usdg.balanceOf(provider), 0, "the funder paid");
        assertEq(escrow.totalEscrowed(), 500_000);
    }

    /// The funder is in the event, the buyer is what is credited.
    function test_happyPath_theEventNamesTheFunderNotTheBuyer() public {
        _fund(provider, 500_000);
        vm.startPrank(provider);
        usdg.approve(address(escrow), 500_000);
        vm.expectEmit(true, true, false, true, address(escrow));
        emit Deposited(buyer, provider, 500_000, 500_000);
        escrow.depositFor(buyer, 500_000);
        vm.stopPrank();
    }

    function test_wrongState_zeroIsRefused() public {
        vm.prank(buyer);
        vm.expectRevert(ZeroAmount.selector);
        escrow.deposit(0);
    }

    function test_wrongState_theZeroAddressCannotBeFunded() public {
        _fund(buyer, 1_000_000);
        vm.startPrank(buyer);
        usdg.approve(address(escrow), 1_000_000);
        vm.expectRevert(ZeroAddress.selector);
        escrow.depositFor(address(0), 1_000_000);
        vm.stopPrank();
    }

    function test_wrongState_depositIsClosedWhilePaused() public {
        _fund(buyer, 1_000_000);
        vm.prank(buyer);
        usdg.approve(address(escrow), 1_000_000);

        vm.prank(admin);
        config.setPaused(true);

        vm.prank(buyer);
        vm.expectRevert(ProgramPaused.selector);
        escrow.deposit(1_000_000);
    }

    /// The pause is read live from Config, so lifting it re-opens the door without touching
    /// this contract. A cached copy would pass the test above and fail this one.
    function test_happyPath_unpausingReopensTheDoor() public {
        _fund(buyer, 1_000_000);
        vm.prank(buyer);
        usdg.approve(address(escrow), 1_000_000);

        vm.prank(admin);
        config.setPaused(true);
        vm.prank(admin);
        config.setPaused(false);

        vm.prank(buyer);
        escrow.deposit(1_000_000);
        assertEq(escrow.escrowOf(buyer).balance, 1_000_000);
    }

    /// A fee-on-transfer surprise must fail loudly, never under-credit silently.
    /// `mockTokenOnly`: needs `MockUSDG.setTransferFeeBps`. A fee-on-transfer USDG is a
    /// hypothetical this delta assertion defends against; no deployed USDG has it, and the 46630
    /// token cannot be made to.
    function test_wrongState_aShortTransferReverts() public mockTokenOnly {
        usdg.setTransferFeeBps(100); // 1% eaten in transit
        _fund(buyer, 1_000_000);
        vm.startPrank(buyer);
        usdg.approve(address(escrow), 1_000_000);
        vm.expectRevert(TransferAmountMismatch.selector);
        escrow.deposit(1_000_000);
        vm.stopPrank();
    }

    /// And nothing is credited by the reverted call.
    /// `mockTokenOnly`: needs `MockUSDG.setTransferFeeBps` — see above.
    function test_wrongState_aShortTransferCreditsNothing() public mockTokenOnly {
        usdg.setTransferFeeBps(1); // one basis point, the smallest loss the mock can inflict
        _fund(buyer, 10_000_000);
        vm.startPrank(buyer);
        usdg.approve(address(escrow), type(uint256).max);
        vm.expectRevert(TransferAmountMismatch.selector);
        escrow.deposit(10_000_000);
        vm.stopPrank();

        assertEq(escrow.escrowOf(buyer).balance, 0);
        assertEq(escrow.totalEscrowed(), 0);
        assertEq(usdg.balanceOf(buyer), 10_000_000, "nothing moved");
    }

    /// Solvency is internal accounting. A donation to the contract address changes
    /// balanceOf and must change nothing the contract believes.
    function test_donationsDoNotBecomeAnybodysBalance() public {
        _fund(address(escrow), 9_999_999);
        assertEq(escrow.totalEscrowed(), 0);
        assertEq(escrow.escrowOf(buyer).balance, 0);
    }

    /// …and a donation made BETWEEN the two `balanceOf` reads does not make a short transfer
    /// look exact either, because the delta is measured across the transfer and nothing else
    /// runs in between. Here the donation lands before the deposit and the deposit still
    /// credits exactly what it pulled.
    function test_aDonationDoesNotInflateALaterDeposit() public {
        _fund(address(escrow), 4_000_000);
        _fund(buyer, 1_500_000);
        vm.startPrank(buyer);
        usdg.approve(address(escrow), 1_500_000);
        escrow.deposit(1_500_000);
        vm.stopPrank();

        assertEq(escrow.escrowOf(buyer).balance, 1_500_000);
        assertEq(escrow.totalEscrowed(), 1_500_000);
        assertEq(usdg.balanceOf(address(escrow)), 5_500_000, "the donation is still there");
    }

    /// A token that calls back into the escrow mid-transfer gets the door shut on it. This is
    /// the only test that can distinguish `nonReentrant` from its absence.
    function test_wrongState_aReentrantAssetCannotRecurseIntoDepositFor() public {
        ReentrantUSDG bad = new ReentrantUSDG();
        X402Escrow re = _deployEscrow(address(bad), address(0));
        bad.setEscrow(address(re), 1);
        bad.mint(buyer, 1_000_000);

        vm.startPrank(buyer);
        bad.approve(address(re), type(uint256).max);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        re.deposit(1_000_000);
        vm.stopPrank();

        assertEq(re.escrowOf(buyer).balance, 0);
        assertEq(re.totalEscrowed(), 0);
    }

    /// `SafeERC20`, proved rather than reviewed — part one. A token that refuses the way the
    /// standard allows (`false`, no revert, no move) must stop the deposit *by name*. Against
    /// `MockUSDG`, which can only ever return `true`, a bare `ASSET.transferFrom(...)` with the
    /// boolean thrown away is indistinguishable from `safeTransferFrom` — measured, it survived
    /// the whole suite.
    function test_wrongState_aTokenThatReturnsFalseStopsTheDeposit() public {
        FalseReturningUSDG liar = new FalseReturningUSDG();
        X402Escrow onLiar = _deployEscrow(address(liar), address(0));
        liar.mint(buyer, 1_000_000);

        vm.startPrank(buyer);
        liar.approve(address(onLiar), type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(liar))
        );
        onLiar.deposit(1_000_000);
        vm.stopPrank();

        assertEq(onLiar.escrowOf(buyer).balance, 0);
        assertEq(onLiar.totalEscrowed(), 0);
    }

    /// `SafeERC20`, proved rather than reviewed — part two, and this is the half that kills the
    /// substitution outright. USDT's shape: `transferFrom` moves the balances and returns NO
    /// data. `SafeERC20` accepts that from an address with code; a bare `IERC20.transferFrom`
    /// tries to ABI-decode a `bool` out of zero bytes and reverts. So the correct implementation
    /// must SUCCEED here, and only the correct one does.
    function test_happyPath_aTokenThatReturnsNoDataIsAccepted() public {
        NoReturnUSDG usdt = new NoReturnUSDG();
        X402Escrow onUsdt = _deployEscrow(address(usdt), address(0));
        usdt.mint(buyer, 2_500_000);

        vm.startPrank(buyer);
        usdt.approve(address(onUsdt), type(uint256).max);
        onUsdt.deposit(2_500_000);
        vm.stopPrank();

        assertEq(onUsdt.escrowOf(buyer).balance, 2_500_000);
        assertEq(onUsdt.escrowOf(buyer).totalFunded, 2_500_000);
        assertEq(onUsdt.totalEscrowed(), 2_500_000);
        assertEq(usdt.balanceOf(address(onUsdt)), 2_500_000);
        assertEq(usdt.balanceOf(buyer), 0);
    }

    // --- the Permit2 door -------------------------------------------------------------------

    function test_wrongState_permit2PathRefusesWhenUnconfigured() public {
        X402Escrow noPermit = _deployEscrow(address(0));
        vm.expectRevert(Permit2NotConfigured.selector);
        noPermit.depositWithPermit2(buyer, 1, 0, block.timestamp + 1, hex"00");
    }

    /// The only signature-based fund-in on this chain, exercised end to end against a
    /// MockPermit2 that enforces the two things the real one enforces for this call: the
    /// signature recovers to `owner`, and the `spender` bound into it is msg.sender (the
    /// escrow). A relayer submits; the buyer paid gas exactly once, for the approve (D-11).
    function test_happyPath_permit2DepositCreditsTheSigner() public {
        MockPermit2 permit2 = new MockPermit2();
        X402Escrow withPermit = _deployEscrow(address(permit2));
        _fund(buyer, 1_000_000);
        vm.prank(buyer);
        usdg.approve(address(permit2), type(uint256).max); // the one-time approve

        uint256 deadline = block.timestamp + 600;
        bytes memory sig =
            permit2.signFor(buyerKey, address(usdg), 1_000_000, 7, deadline, address(withPermit));

        vm.prank(relayer); // a relayer, holding nothing but the signature
        withPermit.depositWithPermit2(buyer, 1_000_000, 7, deadline, sig);

        assertEq(withPermit.escrowOf(buyer).balance, 1_000_000);
        assertEq(withPermit.totalEscrowed(), 1_000_000);
        assertEq(usdg.balanceOf(buyer), 0);
        assertEq(withPermit.escrowOf(relayer).balance, 0, "the relayer got nothing");
        assertEq(usdg.balanceOf(address(withPermit)), 1_000_000);
    }

    /// `owner` is both the account Permit2 checks the signature against and the account the
    /// escrow credits, so a relayer cannot point the buyer's signature at another escrow.
    function test_wrongSigner_aPermit2SignatureCannotCreditSomebodyElse() public {
        MockPermit2 permit2 = new MockPermit2();
        X402Escrow withPermit = _deployEscrow(address(permit2));
        _fund(buyer, 1_000_000);
        vm.prank(buyer);
        usdg.approve(address(permit2), type(uint256).max);

        uint256 deadline = block.timestamp + 600;
        bytes memory sig =
            permit2.signFor(buyerKey, address(usdg), 1_000_000, 7, deadline, address(withPermit));

        vm.prank(relayer);
        vm.expectRevert(MockPermit2.InvalidSigner.selector);
        withPermit.depositWithPermit2(stranger, 1_000_000, 7, deadline, sig);

        assertEq(withPermit.escrowOf(stranger).balance, 0);
        assertEq(usdg.balanceOf(buyer), 1_000_000, "nothing moved");
    }

    /// The other half of the same rule: the digest binds `msg.sender` as the spender, so a
    /// signature made for one escrow is not a signature for a second escrow the relayer
    /// controls — even though both are legitimate deployments of this implementation.
    function test_wrongSigner_aPermit2SignatureIsBoundToOneEscrow() public {
        MockPermit2 permit2 = new MockPermit2();
        X402Escrow first = _deployEscrow(address(permit2));
        X402Escrow second = _deployEscrow(address(permit2));
        _fund(buyer, 1_000_000);
        vm.prank(buyer);
        usdg.approve(address(permit2), type(uint256).max);

        uint256 deadline = block.timestamp + 600;
        bytes memory sig =
            permit2.signFor(buyerKey, address(usdg), 1_000_000, 7, deadline, address(first));

        vm.prank(relayer);
        vm.expectRevert(MockPermit2.InvalidSigner.selector);
        second.depositWithPermit2(buyer, 1_000_000, 7, deadline, sig);

        assertEq(second.escrowOf(buyer).balance, 0);
        assertEq(usdg.balanceOf(buyer), 1_000_000, "nothing moved");
    }

    /// One signature, one deposit. The nonce is Permit2's, not this contract's, which is why
    /// the second attempt fails inside the double rather than here.
    function test_wrongState_aPermit2SignatureCannotBeReplayed() public {
        MockPermit2 permit2 = new MockPermit2();
        X402Escrow withPermit = _deployEscrow(address(permit2));
        _fund(buyer, 4_000_000);
        vm.prank(buyer);
        usdg.approve(address(permit2), type(uint256).max);

        uint256 deadline = block.timestamp + 600;
        bytes memory sig =
            permit2.signFor(buyerKey, address(usdg), 1_000_000, 7, deadline, address(withPermit));

        vm.prank(relayer);
        withPermit.depositWithPermit2(buyer, 1_000_000, 7, deadline, sig);

        vm.prank(relayer);
        vm.expectRevert(MockPermit2.NonceUsed.selector);
        withPermit.depositWithPermit2(buyer, 1_000_000, 7, deadline, sig);

        assertEq(withPermit.escrowOf(buyer).balance, 1_000_000, "credited once");
        assertEq(withPermit.totalEscrowed(), 1_000_000);
    }

    /// The delta assertion guards the Permit2 door too — it is a second call site, so it is a
    /// second guard, and deleting it has to fail a test of its own.
    /// `mockTokenOnly`: needs `MockUSDG.setTransferFeeBps` — see above.
    function test_wrongState_aShortTransferRevertsThroughPermit2() public mockTokenOnly {
        MockPermit2 permit2 = new MockPermit2();
        X402Escrow withPermit = _deployEscrow(address(permit2));
        usdg.setTransferFeeBps(100);
        _fund(buyer, 1_000_000);
        vm.prank(buyer);
        usdg.approve(address(permit2), type(uint256).max);

        uint256 deadline = block.timestamp + 600;
        bytes memory sig =
            permit2.signFor(buyerKey, address(usdg), 1_000_000, 7, deadline, address(withPermit));

        vm.prank(relayer);
        vm.expectRevert(TransferAmountMismatch.selector);
        withPermit.depositWithPermit2(buyer, 1_000_000, 7, deadline, sig);

        assertEq(withPermit.escrowOf(buyer).balance, 0);
        assertEq(withPermit.totalEscrowed(), 0);
    }

    function test_wrongState_permit2DepositIsClosedWhilePaused() public {
        MockPermit2 permit2 = new MockPermit2();
        X402Escrow withPermit = _deployEscrow(address(permit2));
        _fund(buyer, 1_000_000);
        vm.prank(buyer);
        usdg.approve(address(permit2), type(uint256).max);

        uint256 deadline = block.timestamp + 600;
        bytes memory sig =
            permit2.signFor(buyerKey, address(usdg), 1_000_000, 7, deadline, address(withPermit));

        vm.prank(admin);
        config.setPaused(true);

        vm.prank(relayer);
        vm.expectRevert(ProgramPaused.selector);
        withPermit.depositWithPermit2(buyer, 1_000_000, 7, deadline, sig);
    }

    function test_wrongState_permit2RefusesZeroAmountAndTheZeroBuyer() public {
        MockPermit2 permit2 = new MockPermit2();
        X402Escrow withPermit = _deployEscrow(address(permit2));

        vm.prank(relayer);
        vm.expectRevert(ZeroAmount.selector);
        withPermit.depositWithPermit2(buyer, 0, 7, block.timestamp + 600, hex"00");

        vm.prank(relayer);
        vm.expectRevert(ZeroAddress.selector);
        withPermit.depositWithPermit2(address(0), 1, 7, block.timestamp + 600, hex"00");
    }

    /// `PERMIT2` is an arbitrary address this contract calls out to, so the Permit2 door needs
    /// its own re-entrancy proof: E4 mutates `depositFor` only, and deleting `nonReentrant` from
    /// this door failed nothing at all until this test existed.
    function test_wrongState_aReentrantPermit2CannotRecurseIntoDepositWithPermit2() public {
        ReentrantPermit2 evil = new ReentrantPermit2();
        X402Escrow re = _deployEscrow(address(evil));
        evil.setEscrow(address(re), 250_000);
        _fund(buyer, 4_000_000);
        vm.prank(buyer);
        usdg.approve(address(evil), type(uint256).max);

        vm.prank(relayer);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        re.depositWithPermit2(buyer, 1_000_000, 7, block.timestamp + 600, hex"");

        assertEq(re.escrowOf(buyer).balance, 0);
        assertEq(re.totalEscrowed(), 0);
        assertEq(usdg.balanceOf(buyer), 4_000_000, "nothing moved");
    }

    // --- the upgrade door -------------------------------------------------------------------

    /// The authority is `CONFIG.admin()`, read live. Nobody else may move the implementation.
    function test_wrongSigner_onlyTheAdminUpgradesEscrow() public {
        X402Escrow next = new X402Escrow();

        vm.prank(stranger);
        vm.expectRevert(NotAdmin.selector);
        escrow.upgradeToAndCall(address(next), "");

        vm.prank(admin);
        escrow.upgradeToAndCall(address(next), "");
        assertEq(
            address(uint160(uint256(vm.load(address(escrow), IMPL_SLOT)))),
            address(next),
            "the admin moved it"
        );
    }

    /// Read LIVE, never cached: handing Config to a new admin hands this contract's upgrade
    /// authority over in the same transaction.
    function test_theUpgradeAuthorityFollowsConfigsAdmin() public {
        address nextAdmin = address(0xA11CE);
        X402Escrow next = new X402Escrow();

        // Read the params BEFORE the prank: `vm.prank` arms the next call, and an argument
        // that is itself a call would consume it.
        ParamSet memory unchangedParams = config.params();
        vm.prank(admin);
        config.updateConfig(unchangedParams, nextAdmin);

        vm.prank(admin);
        vm.expectRevert(NotAdmin.selector);
        escrow.upgradeToAndCall(address(next), "");

        vm.prank(nextAdmin);
        escrow.upgradeToAndCall(address(next), "");
        assertEq(address(uint160(uint256(vm.load(address(escrow), IMPL_SLOT)))), address(next));
    }
}
