// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.24;

import {console2} from "forge-std/console2.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {Fixture} from "./helpers/Fixture.sol";
import {VoucherSigner} from "./helpers/VoucherSigner.sol";
import {RedeemReentrantUSDG} from "./helpers/MockUSDG.sol";
import {X402Escrow} from "../src/X402Escrow.sol";
import {X402Config} from "../src/X402Config.sol";
import {Voucher, ParamSet} from "../src/Types.sol";
import {Constants} from "../src/Constants.sol";
import "../src/Errors.sol";

/// The two calls every mock in this file has to answer so a buyer can be funded and armed
/// against an escrow that settles in it. Declared once rather than typed at each call site,
/// because three different tokens in this suite have to be armed identically.
interface IMintableToken {
    function mint(address to, uint256 amount) external;
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}

/// The **batch** half of the effects-before-interactions proof, and it is a different property
/// from the one `RedeemObserverUSDG` proves in `X402Escrow.redeem.t.sol`.
///
/// That mock observes the FIRST external call and nothing else. Against a batch, "every effect is
/// written before the first transfer" would be satisfied by an implementation that writes item
/// 0's effects, pays item 0, and then does anything it likes for items 1..n — the observation
/// point has already gone by. So this mock records at **every** transfer, and at each one it
/// reads the escrow of **every** watched payer, not only the one whose voucher is being paid.
///
/// That makes two opposite claims assertable from one run:
///
///   - at item `n`'s first transfer, item `n`'s own effects are ALREADY written; and
///   - at item `n`'s first transfer, item `n+1`'s effects are NOT YET written.
///
/// The second is what pins the shape: the loop is `n` complete redemptions in sequence, not a
/// pass of effects followed by a pass of payouts. An implementation that batched the transfers to
/// the end would satisfy the first claim at every item and fail the second at every item.
///
/// It re-enters a **view** (`escrowOf`, `totalEscrowed`), which carries no `nonReentrant`, so the
/// outer call succeeds and this contract's storage survives to be asserted.
contract BatchObserverUSDG {
    uint8 public constant decimals = 6;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    struct Seen {
        uint128 balance;
        uint64 seqHigh;
        uint64 spentInWindow;
        uint128 totalRedeemed;
    }

    address public escrow;
    address[] public watched;
    bool private armed;

    uint256 public transferCount;
    mapping(uint256 => address) public seenTo;
    mapping(uint256 => uint256) public seenAmount;
    mapping(uint256 => uint128) public seenTotalEscrowed;
    /// transfer index => index into `watched` => that payer's escrow at that instant.
    mapping(uint256 => mapping(uint256 => Seen)) internal seen;

    function arm(address escrow_, address[] memory payers) external {
        escrow = escrow_;
        watched = payers;
        armed = true;
    }

    function seenAt(uint256 t, uint256 payerIdx) external view returns (Seen memory) {
        return seen[t][payerIdx];
    }

    function watchedCount() external view returns (uint256) {
        return watched.length;
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

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        if (armed) {
            uint256 t = transferCount;
            seenTo[t] = to;
            seenAmount[t] = amount;
            seenTotalEscrowed[t] = X402Escrow(escrow).totalEscrowed();
            for (uint256 i = 0; i < watched.length; i++) {
                X402Escrow.Escrow memory e = X402Escrow(escrow).escrowOf(watched[i]);
                seen[t][i] = Seen({
                    balance: e.balance,
                    seqHigh: e.seqHigh,
                    spentInWindow: e.spentInWindow,
                    totalRedeemed: e.totalRedeemed
                });
            }
            transferCount = t + 1;
        }
        return true;
    }
}

/// A settlement asset that **moves a Config parameter from inside a payout**, and the only
/// adversary in this suite that can tell "the parameter set is read once for the batch" from
/// "the parameter set is read per item".
///
/// The distinction is not academic: `redeemVoucherBatch` reads `CONFIG.params()` once, into
/// memory, and the NatSpec says out loud that this is so a Config upgrade landing mid-transaction
/// cannot hand two items of one batch different treasuries. Nothing else in the suite can see the
/// difference — a per-item read is byte-for-byte equivalent on every fixture where the parameters
/// hold still — so a degenerate that moved the read inside the loop survived everything until this
/// mock existed.
///
/// It has to be made the Config admin to do it, which is exactly the compromise the property
/// defends against.
contract ConfigShiftingUSDG {
    uint8 public constant decimals = 6;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    address public cfg;
    ParamSet private next;
    bool private armed;
    bool public shifted;

    function arm(address cfg_, ParamSet memory p) external {
        cfg = cfg_;
        next = p;
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

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        if (armed) {
            armed = false;
            shifted = true;
            X402Config(cfg).updateConfig(next, address(0));
        }
        return true;
    }
}

/// `redeemVoucherBatch` — the money-out path, batched.
///
/// **Every assertion in this file is per recipient.** The single-redeem suite measured why: `fee +
/// providerAmount == amount` is structurally true whenever the fee is zero, so a 7-unit voucher at
/// 1 000 bps passes the split assertion while the provider is paid the GROSS. An aggregate over a
/// batch is blind to that at every item at once, and blind on top of it to a batch that pays one
/// item's recipients `n` times. So the fixtures below vary the payer, the provider, the amount and
/// the seq across the items, and every payout is pinned against the address that earned it.
///
/// The original `_batch` helper — one payer, one provider, one amount — is kept, because it is
/// the right shape for the SIZE and GAS assertions, where uniform items are what makes a
/// per-voucher figure meaningful. It is never the shape a correctness assertion is made against.
contract X402EscrowBatchTest is Fixture {
    /// Wide enough that no test in this file is ever refused for funds, and it fits `uint64`.
    uint64 internal constant FUND = 1_000_000_000;

    /// Enough distinct payers and providers for the largest batch this contract admits, armed in
    /// `setUp` rather than in a test body **because warm/cold storage is per transaction**: forge
    /// runs `setUp` as its own call, so a slot written there is COLD when the measurement runs.
    /// Arming inside the measured test would warm every slot and understate the real cost.
    uint256 internal constant POOL = 64;

    bytes32 internal ds;
    uint256[POOL] internal payerKeys;
    address[POOL] internal payers;
    address[POOL] internal providers;

    function setUp() public virtual override {
        super.setUp();
        ds = escrow.DOMAIN_SEPARATOR();

        _fund(buyer, FUND);
        vm.startPrank(buyer);
        usdg.approve(address(escrow), FUND);
        escrow.deposit(FUND);
        escrow.setLimits(type(uint64).max, type(uint64).max);
        vm.stopPrank();

        for (uint256 i = 0; i < POOL; i++) {
            payerKeys[i] = 0xBA7C0000 + i + 1;
            payers[i] = _arm(escrow, IMintableToken(address(usdg)), payerKeys[i], FUND);
            providers[i] = address(uint160(0x93090000 + i + 1));
            _setBonded(providers[i], MINIMUM_STAKE);
        }
    }

    /// Fund a key's address and open its ceilings, against whichever escrow and settlement token
    /// the caller names. FOUR tokens in this file reach it: the fixture's own `usdg`, plus the
    /// three hostile doubles this suite deploys a second escrow in front of.
    ///
    /// The `usdg` case must go through `_fund`, not `mint`. On the fork `usdg` IS the real token
    /// at 46630, whose 19 selectors do not include `mint(address,uint256)` — the call lands in
    /// the dispatcher's fallback and reverts, taking `setUp` with it. The other three are local
    /// doubles that do have `mint` and must keep using it: they are the point of those tests.
    function _arm(X402Escrow e, IMintableToken token, uint256 key, uint64 amount)
        internal
        returns (address b)
    {
        b = vm.addr(key);
        if (address(token) == address(usdg)) {
            _fund(b, amount);
        } else {
            token.mint(b, amount);
        }
        vm.startPrank(b);
        token.approve(address(e), amount);
        e.deposit(amount);
        e.setLimits(type(uint64).max, type(uint64).max);
        vm.stopPrank();
    }

    // --- the fixtures ------------------------------------------------------------------------

    /// The original helper: `n` identical vouchers from ONE payer to ONE provider. Uniform on
    /// purpose — it is the shape the size guards and the gas measurement want, and it is never
    /// the shape a payout assertion is made against.
    function _batch(uint256 n) internal view returns (Voucher[] memory vs, bytes[] memory sigs) {
        vs = new Voucher[](n);
        sigs = new bytes[](n);
        for (uint256 i = 0; i < n; i++) {
            vs[i] = Voucher({
                payer: buyer,
                provider: provider,
                amount: 1_000,
                resourceHash: keccak256("resource"),
                requestHash: keccak256(abi.encode("request", i)),
                seq: uint64(i + 1),
                issuedAt: uint64(block.timestamp),
                expiresAt: uint64(block.timestamp) + 300
            });
            sigs[i] = VoucherSigner.signVoucher(buyerKey, ds, vs[i]);
        }
    }

    /// The correctness shape. Four payers, `n` distinct providers, `n` distinct amounts, and a
    /// seq that advances per payer rather than per item — so one batch exercises the
    /// strictly-increasing rule WITHIN a payer and the independence of two payers' sequences at
    /// the same time.
    ///
    /// Every amount is `>= 10`, which at 1 000 bps is the point where `0 < fee < amount`. Below
    /// it the fee floors to zero and paying the gross is indistinguishable from paying the net —
    /// the exact hole the first single-redeem fixture had.
    function _varied(uint256 n) internal view returns (Voucher[] memory vs, bytes[] memory sigs) {
        vs = new Voucher[](n);
        sigs = new bytes[](n);
        for (uint256 i = 0; i < n; i++) {
            uint256 pIdx = i % 4;
            vs[i] = Voucher({
                payer: payers[pIdx],
                provider: providers[i],
                amount: uint64(1_000 + i * 137),
                resourceHash: keccak256(abi.encode("resource", i)),
                requestHash: keccak256(abi.encode("request", i)),
                seq: uint64(i / 4 + 1),
                issuedAt: uint64(block.timestamp),
                expiresAt: uint64(block.timestamp) + 300
            });
            sigs[i] = VoucherSigner.signVoucher(payerKeys[pIdx], ds, vs[i]);
        }
    }

    /// `n` vouchers from `n` DISTINCT payers, one each. The gas shape the backend's batching rule
    /// turns on: every item here pays a cold `SSTORE` on a buyer nobody in this transaction has
    /// touched, where `_batch` keeps one buyer's three slots warm from item 2 onwards.
    function _distinctPayers(uint256 n)
        internal
        view
        returns (Voucher[] memory vs, bytes[] memory sigs)
    {
        vs = new Voucher[](n);
        sigs = new bytes[](n);
        for (uint256 i = 0; i < n; i++) {
            vs[i] = Voucher({
                payer: payers[i],
                provider: providers[i],
                amount: 1_000,
                resourceHash: keccak256("resource"),
                requestHash: keccak256(abi.encode("request", i)),
                seq: 1,
                issuedAt: uint64(block.timestamp),
                expiresAt: uint64(block.timestamp) + 300
            });
            sigs[i] = VoucherSigner.signVoucher(payerKeys[i], ds, vs[i]);
        }
    }

    /// Distinct payers, ONE provider. The payer variable on its own — because
    /// [`_distinctPayers`] moves two things at once (a cold buyer escrow AND a cold recipient
    /// token balance) and a figure that conflates them answers a question nobody asked.
    function _distinctPayersOneProvider(uint256 n)
        internal
        view
        returns (Voucher[] memory vs, bytes[] memory sigs)
    {
        vs = new Voucher[](n);
        sigs = new bytes[](n);
        for (uint256 i = 0; i < n; i++) {
            vs[i] = Voucher({
                payer: payers[i],
                provider: provider,
                amount: 1_000,
                resourceHash: keccak256("resource"),
                requestHash: keccak256(abi.encode("request", i)),
                seq: 1,
                issuedAt: uint64(block.timestamp),
                expiresAt: uint64(block.timestamp) + 300
            });
            sigs[i] = VoucherSigner.signVoucher(payerKeys[i], ds, vs[i]);
        }
    }

    /// One payer, distinct providers — the other half of the same decomposition.
    function _onePayerDistinctProviders(uint256 n)
        internal
        view
        returns (Voucher[] memory vs, bytes[] memory sigs)
    {
        vs = new Voucher[](n);
        sigs = new bytes[](n);
        for (uint256 i = 0; i < n; i++) {
            vs[i] = Voucher({
                payer: buyer,
                provider: providers[i],
                amount: 1_000,
                resourceHash: keccak256("resource"),
                requestHash: keccak256(abi.encode("request", i)),
                seq: uint64(i + 1),
                issuedAt: uint64(block.timestamp),
                expiresAt: uint64(block.timestamp) + 300
            });
            sigs[i] = VoucherSigner.signVoucher(buyerKey, ds, vs[i]);
        }
    }

    function _fee(uint64 amount) internal pure returns (uint64) {
        return uint64((uint256(amount) * TAKE_RATE_BPS) / 10_000);
    }

    // --- the happy paths ---------------------------------------------------------------------

    function test_happyPath_aBatchOfEightSettlesAllEight() public {
        (Voucher[] memory vs, bytes[] memory sigs) = _batch(8);
        vm.prank(redeemer);
        escrow.redeemVoucherBatch(vs, sigs);

        assertEq(escrow.escrowOf(buyer).seqHigh, 8);
        assertEq(usdg.balanceOf(provider), 8 * 900);
        assertEq(usdg.balanceOf(treasury), 8 * 100);
    }

    /// **The test the uniform happy path above cannot be.** Eight items, eight providers, eight
    /// amounts, four payers — and every payout asserted against the address that earned it.
    ///
    /// A batch that redeems only the first item, or that redeems all eight but pays every
    /// provider out of the first voucher's amounts, satisfies `test_happyPath_…` above and dies
    /// here.
    function test_happyPath_eachItemPaysItsOwnRecipientsItsOwnSplit() public {
        (Voucher[] memory vs, bytes[] memory sigs) = _varied(8);

        vm.prank(redeemer);
        escrow.redeemVoucherBatch(vs, sigs);

        uint256 expectedTreasury;
        for (uint256 i = 0; i < 8; i++) {
            uint64 fee = _fee(vs[i].amount);
            // The fixture is only able to tell gross from net while this holds.
            assertTrue(fee > 0 && fee < vs[i].amount, "fixture cannot distinguish gross from net");
            assertEq(
                usdg.balanceOf(vs[i].provider),
                vs[i].amount - fee,
                "a provider was paid something other than its own voucher's net"
            );
            expectedTreasury += fee;
        }
        assertEq(usdg.balanceOf(treasury), expectedTreasury, "the treasury got the summed fees");

        for (uint256 j = 0; j < 4; j++) {
            uint64 spent = vs[j].amount + vs[j + 4].amount;
            X402Escrow.Escrow memory e = escrow.escrowOf(payers[j]);
            assertEq(e.seqHigh, 2, "each payer advanced by its own two vouchers");
            assertEq(e.balance, FUND - spent, "each payer paid for its own two vouchers");
            assertEq(e.spentInWindow, spent);
            assertEq(e.totalRedeemed, spent);
            assertEq(e.totalFunded, FUND, "a spend is not an unfunding");
        }
    }

    /// **Beside the fuzz, not instead of it.** A uniform draw never lands on 1, 9, 10 or 10_001 —
    /// the amounts where the floor division changes character — and 1..9 are precisely where the
    /// fee is zero and the gross-payment degenerate hides. Every one of them is in ONE batch here,
    /// each with its own provider, so the sweep is per-recipient rather than cumulative.
    function test_theSplitIsExactAcrossAStructuredSweepInsideOneBatch() public {
        uint64[16] memory amounts = [
            uint64(1),
            2,
            3,
            7,
            9,
            10,
            11,
            99,
            100,
            101,
            9_999,
            10_000,
            10_001,
            123_457,
            999_999,
            1_000_000
        ];

        Voucher[] memory vs = new Voucher[](16);
        bytes[] memory sigs = new bytes[](16);
        for (uint256 i = 0; i < 16; i++) {
            uint256 pIdx = i % 4;
            vs[i] = Voucher({
                payer: payers[pIdx],
                provider: providers[i],
                amount: amounts[i],
                resourceHash: keccak256(abi.encode("resource", i)),
                requestHash: keccak256(abi.encode("request", i)),
                seq: uint64(i / 4 + 1),
                issuedAt: uint64(block.timestamp),
                expiresAt: uint64(block.timestamp) + 300
            });
            sigs[i] = VoucherSigner.signVoucher(payerKeys[pIdx], ds, vs[i]);
        }

        vm.prank(redeemer);
        escrow.redeemVoucherBatch(vs, sigs);

        uint256 fees;
        uint256 total;
        for (uint256 i = 0; i < 16; i++) {
            uint64 fee = _fee(amounts[i]);
            assertEq(usdg.balanceOf(providers[i]), amounts[i] - fee, "provider i, its own net");
            fees += fee;
            total += amounts[i];
        }
        assertEq(usdg.balanceOf(treasury), fees, "treasury, the summed floor");
        // 65 funded escrows — the fixture buyer and the pool of 64 — minus what this batch spent.
        assertEq(escrow.totalEscrowed(), uint128(65 * uint256(FUND) - total));
    }

    /// The fuzz that sits beside the sweep. Four items, four payers, four providers, four drawn
    /// amounts — and each provider's payout pinned against a closed form spelled here rather than
    /// read back out of `Fee`.
    function testFuzz_everyItemInABatchPaysItsOwnRecipientsExactly(
        uint64 a0,
        uint64 a1,
        uint64 a2,
        uint64 a3
    ) public {
        uint64[4] memory amounts = [
            uint64(bound(a0, 1, 1_000_000)),
            uint64(bound(a1, 1, 1_000_000)),
            uint64(bound(a2, 1, 1_000_000)),
            uint64(bound(a3, 1, 1_000_000))
        ];

        Voucher[] memory vs = new Voucher[](4);
        bytes[] memory sigs = new bytes[](4);
        for (uint256 i = 0; i < 4; i++) {
            vs[i] = Voucher({
                payer: payers[i],
                provider: providers[i],
                amount: amounts[i],
                resourceHash: keccak256(abi.encode("resource", i)),
                requestHash: keccak256(abi.encode("request", i)),
                seq: 1,
                issuedAt: uint64(block.timestamp),
                expiresAt: uint64(block.timestamp) + 300
            });
            sigs[i] = VoucherSigner.signVoucher(payerKeys[i], ds, vs[i]);
        }

        vm.prank(redeemer);
        escrow.redeemVoucherBatch(vs, sigs);

        uint256 fees;
        for (uint256 i = 0; i < 4; i++) {
            uint64 fee = _fee(amounts[i]);
            assertEq(usdg.balanceOf(providers[i]), amounts[i] - fee, "provider i, its own net");
            assertEq(
                escrow.escrowOf(payers[i]).balance, FUND - amounts[i], "payer i, its own debit"
            );
            assertEq(escrow.escrowOf(payers[i]).seqHigh, 1);
            fees += fee;
        }
        assertEq(usdg.balanceOf(treasury), fees);
    }

    // --- the batch's own guards --------------------------------------------------------------

    /// Vouchers for one payer must arrive in strictly increasing seq order. The rule is not
    /// a batch rule — it is `seq > seqHigh`, applied item by item.
    function test_wrongState_anOutOfOrderBatchReverts() public {
        (Voucher[] memory vs, bytes[] memory sigs) = _batch(3);
        (vs[0], vs[2]) = (vs[2], vs[0]);
        (sigs[0], sigs[2]) = (sigs[2], sigs[0]);

        vm.prank(redeemer);
        vm.expectRevert(VoucherSeqNotIncreasing.selector);
        escrow.redeemVoucherBatch(vs, sigs);
    }

    /// Two payers' sequences are independent, so an ordering that would be "out of order" read as
    /// one list is admitted when the seqs belong to different escrows. Without this, the test
    /// above is satisfied by an implementation that enforces a batch-wide ascending `seq`.
    function test_happyPath_twoPayersSequencesDoNotConstrainEachOther() public {
        Voucher[] memory vs = new Voucher[](4);
        bytes[] memory sigs = new bytes[](4);
        uint8[4] memory who = [0, 1, 0, 1];
        uint64[4] memory seqs = [uint64(1), 1, 2, 2];
        // read as one list this is 1, 1, 2, 2 — non-decreasing and repeating, which no batch-wide
        // "strictly increasing" rule admits, and which the per-escrow rule admits exactly.
        for (uint256 i = 0; i < 4; i++) {
            uint256 pIdx = who[i];
            vs[i] = Voucher({
                payer: payers[pIdx],
                provider: providers[i],
                amount: 1_000,
                resourceHash: keccak256("resource"),
                requestHash: keccak256(abi.encode("request", i)),
                seq: seqs[i],
                issuedAt: uint64(block.timestamp),
                expiresAt: uint64(block.timestamp) + 300
            });
            sigs[i] = VoucherSigner.signVoucher(payerKeys[pIdx], ds, vs[i]);
        }

        vm.prank(redeemer);
        escrow.redeemVoucherBatch(vs, sigs);

        assertEq(escrow.escrowOf(payers[0]).seqHigh, 2);
        assertEq(escrow.escrowOf(payers[1]).seqHigh, 2);
        for (uint256 i = 0; i < 4; i++) {
            assertEq(usdg.balanceOf(providers[i]), 900, "each of the four was paid once");
        }
    }

    /// Atomic: one bad item and nothing settles.
    function test_wrongState_oneBadVoucherRevertsTheWholeBatch() public {
        (Voucher[] memory vs, bytes[] memory sigs) = _batch(4);
        vs[2].amount = vs[2].amount + 1; // no longer the signed struct

        vm.prank(redeemer);
        vm.expectRevert(SignerIsNotPayer.selector);
        escrow.redeemVoucherBatch(vs, sigs);

        assertEq(escrow.escrowOf(buyer).seqHigh, 0, "nothing settled");
        assertEq(usdg.balanceOf(provider), 0);
    }

    /// The same atomicity, on the shape a skip-and-continue implementation would survive: the bad
    /// item is the LAST one, so three good items have already been paid when it fails, and every
    /// one of those three payments must be rolled back.
    ///
    /// `test_wrongState_oneBadVoucherRevertsTheWholeBatch` above uses one payer and one provider;
    /// this one uses four of each, so "nothing settled" is asserted per recipient.
    function test_wrongState_aBadLastItemUnwindsEveryItemBeforeIt() public {
        (Voucher[] memory vs, bytes[] memory sigs) = _varied(4);
        vs[3].amount = vs[3].amount + 1;

        vm.prank(redeemer);
        vm.expectRevert(SignerIsNotPayer.selector);
        escrow.redeemVoucherBatch(vs, sigs);

        for (uint256 i = 0; i < 4; i++) {
            assertEq(usdg.balanceOf(providers[i]), 0, "provider i was paid by a reverted batch");
            assertEq(escrow.escrowOf(payers[i]).balance, FUND, "payer i was debited");
            assertEq(escrow.escrowOf(payers[i]).seqHigh, 0, "payer i's sequence advanced");
        }
        assertEq(usdg.balanceOf(treasury), 0);
    }

    function test_boundary_batchSizeLimits() public {
        (Voucher[] memory none, bytes[] memory noneSigs) = _batch(0);
        vm.prank(redeemer);
        vm.expectRevert(EmptyBatch.selector);
        escrow.redeemVoucherBatch(none, noneSigs);

        (Voucher[] memory ok, bytes[] memory okSigs) = _batch(64);
        vm.prank(redeemer);
        escrow.redeemVoucherBatch(ok, okSigs); // exactly MAX_REDEEM_BATCH, admitted
        assertEq(escrow.escrowOf(buyer).seqHigh, 64, "all 64 of the admitted batch settled");

        (Voucher[] memory over, bytes[] memory overSigs) = _batch(65);
        vm.prank(redeemer);
        vm.expectRevert(BatchTooLarge.selector);
        escrow.redeemVoucherBatch(over, overSigs);
    }

    /// The bound is the named constant, not a literal that happens to agree with it today.
    function test_boundary_theCapIsTheDeclaredConstant() public pure {
        assertEq(Constants.MAX_REDEEM_BATCH, 64);
    }

    function test_wrongState_mismatchedArrayLengthsAreRefused() public {
        (Voucher[] memory vs,) = _batch(3);
        bytes[] memory sigs = new bytes[](2);
        vm.prank(redeemer);
        vm.expectRevert(BatchLengthMismatch.selector);
        escrow.redeemVoucherBatch(vs, sigs);
    }

    /// The other direction of the same guard: more signatures than vouchers. Without it, an
    /// implementation that only checked `sigs.length < n` passes the test above.
    function test_wrongState_moreSignaturesThanVouchersAreRefused() public {
        (Voucher[] memory vs,) = _batch(2);
        bytes[] memory sigs = new bytes[](3);
        vm.prank(redeemer);
        vm.expectRevert(BatchLengthMismatch.selector);
        escrow.redeemVoucherBatch(vs, sigs);
    }

    function test_wrongSigner_onlyTheRedeemerMaySubmitABatch() public {
        (Voucher[] memory vs, bytes[] memory sigs) = _batch(2);
        vm.expectRevert(NotRedeemer.selector);
        escrow.redeemVoucherBatch(vs, sigs);
    }

    /// Not even a payer whose own vouchers these are. The pin is about `seq`, not about consent.
    function test_wrongSigner_notEvenThePayerMaySubmitTheirOwnBatch() public {
        (Voucher[] memory vs, bytes[] memory sigs) = _batch(2);
        vm.prank(buyer);
        vm.expectRevert(NotRedeemer.selector);
        escrow.redeemVoucherBatch(vs, sigs);
    }

    /// Order, and it is only visible to a submission that violates BOTH guards at once. A suite of
    /// single-violation tests passes against either order; this one pins the redeemer pin first,
    /// which is `redeemVoucher`'s order and the one `redeem_voucher.rs:38-43` names.
    function test_wrongSigner_theRedeemerPinIsCheckedBeforeThePauseFlag() public {
        (Voucher[] memory vs, bytes[] memory sigs) = _batch(2);
        vm.prank(admin);
        config.setPaused(true);

        // a stranger, while paused: both guards would refuse, and the one that speaks is first.
        vm.expectRevert(NotRedeemer.selector);
        escrow.redeemVoucherBatch(vs, sigs);
    }

    /// **`params()` is read ONCE for the whole batch**, which is what stops a Config upgrade
    /// landing mid-transaction from paying two items of one batch into two different treasuries.
    ///
    /// The only adversary that can see this is a settlement asset that is also the Config admin,
    /// because a parameter that holds still makes a per-item read byte-identical to a single read.
    /// Without this test, moving `CONFIG.params()` inside the loop survives every other test here.
    function test_theParameterSetIsReadOnceForTheWholeBatch() public {
        ConfigShiftingUSDG tok = new ConfigShiftingUSDG();
        X402Escrow e2 = _deployEscrow(address(tok), address(0));
        address b = _arm(e2, IMintableToken(address(tok)), payerKeys[0], FUND);

        // The token becomes the admin — the compromise this property is defending against.
        //
        // Read into memory FIRST: `vm.prank` applies to the next CALL and `config.params()` is
        // one, so `config.updateConfig(config.params(), …)` inside a pranked statement spends the
        // prank on the getter and the update arrives as the test contract — `NotAdmin()`,
        // measured. It is the same trap `ds` is cached in `setUp` for.
        ParamSet memory current = config.params();
        vm.prank(admin);
        config.updateConfig(current, address(tok));

        // A SECOND read, because `ParamSet memory shifted = current` would ALIAS rather than copy
        // — memory structs are reference types — and editing `shifted.treasury` would silently
        // edit `current` as well. Measured: the first draft did exactly that, handed the shifted
        // set to `updateConfig` above, and the test then "passed" its way to a wrong conclusion.
        address altTreasury = address(0xA17E);
        ParamSet memory shifted = config.params();
        shifted.treasury = altTreasury;
        tok.arm(address(config), shifted);

        bytes32 ds2 = e2.DOMAIN_SEPARATOR();
        Voucher[] memory vs = new Voucher[](2);
        bytes[] memory sigs = new bytes[](2);
        for (uint256 i = 0; i < 2; i++) {
            vs[i] = Voucher({
                payer: b,
                provider: providers[i],
                amount: 1_000,
                resourceHash: keccak256("resource"),
                requestHash: keccak256(abi.encode("request", i)),
                seq: uint64(i + 1),
                issuedAt: uint64(block.timestamp),
                expiresAt: uint64(block.timestamp) + 300
            });
            sigs[i] = VoucherSigner.signVoucher(payerKeys[0], ds2, vs[i]);
        }

        vm.prank(redeemer);
        e2.redeemVoucherBatch(vs, sigs);

        assertTrue(tok.shifted(), "the config never moved, so nothing below asserts anything");
        assertEq(config.params().treasury, altTreasury, "and it really did move");
        assertEq(tok.balanceOf(treasury), 200, "both fees go to the treasury the batch STARTED on");
        assertEq(tok.balanceOf(altTreasury), 0, "a mid-batch parameter change reached item 2");
    }

    function test_wrongState_theBatchIsClosedWhilePaused() public {
        (Voucher[] memory vs, bytes[] memory sigs) = _batch(2);
        vm.prank(admin);
        config.setPaused(true);

        vm.prank(redeemer);
        vm.expectRevert(ProgramPaused.selector);
        escrow.redeemVoucherBatch(vs, sigs);
    }

    /// A batch cannot replay a voucher against itself: the same voucher twice in one batch is the
    /// seq rule's problem and it refuses on the second copy. `nonReentrant` does not see this —
    /// there is no second entry into the contract — so the per-item rule is the only thing here.
    function test_wrongState_theSameVoucherTwiceInOneBatchIsRefused() public {
        (Voucher[] memory vs, bytes[] memory sigs) = _batch(2);
        vs[1] = vs[0];
        sigs[1] = sigs[0];

        vm.prank(redeemer);
        vm.expectRevert(VoucherSeqNotIncreasing.selector);
        escrow.redeemVoucherBatch(vs, sigs);

        assertEq(escrow.escrowOf(buyer).seqHigh, 0);
        assertEq(usdg.balanceOf(provider), 0);
    }

    /// The single-redeem re-entrancy prover, aimed at the batch entry point. The asset
    /// re-enters from the FIRST payout, which is inside item 0 and therefore in the middle of the
    /// loop — the place where a missing modifier would let the rest of a batch be re-run.
    ///
    /// The token is also made the configured redeemer, so the nested call clears `onlyRedeemer`
    /// as well and the only thing left refusing it is the guard.
    function test_wrongState_aReentrantAssetCannotRecurseIntoTheBatch() public {
        RedeemReentrantUSDG evil = new RedeemReentrantUSDG();
        X402Escrow e2 = _deployEscrow(address(evil), address(0));
        address b = _arm(e2, IMintableToken(address(evil)), payerKeys[0], FUND);

        ParamSet memory p = config.params();
        p.redeemer = address(evil);
        vm.prank(admin);
        config.updateConfig(p, address(0));

        bytes32 ds2 = e2.DOMAIN_SEPARATOR();
        Voucher[] memory vs = new Voucher[](2);
        bytes[] memory sigs = new bytes[](2);
        for (uint256 i = 0; i < 2; i++) {
            vs[i] = Voucher({
                payer: b,
                provider: providers[i],
                amount: 250_000,
                resourceHash: keccak256("resource"),
                requestHash: keccak256(abi.encode("request", i)),
                seq: uint64(i + 1),
                issuedAt: uint64(block.timestamp),
                expiresAt: uint64(block.timestamp) + 300
            });
            sigs[i] = VoucherSigner.signVoucher(payerKeys[0], ds2, vs[i]);
        }

        bytes memory reentry = abi.encodeCall(X402Escrow.redeemVoucherBatch, (vs, sigs));
        evil.arm(address(e2), reentry);

        // `evil.didReenter()` cannot be read afterwards — the outer call reverts and unwinds the
        // MOCK's storage with the escrow's. `expectCall` is checked as calls happen, so it
        // survives the revert and is the only way to assert the nested call was really attempted.
        vm.expectCall(address(e2), reentry, 2);
        vm.prank(address(evil));
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        e2.redeemVoucherBatch(vs, sigs);

        assertEq(e2.escrowOf(b).balance, FUND, "and nothing moved");
        assertEq(e2.escrowOf(b).seqHigh, 0);
        assertEq(evil.balanceOf(providers[0]), 0);
    }

    // --- effects before interactions, ITEM BY ITEM -------------------------------------------

    /// The batch's version of `test_everyEffectIsWrittenBeforeTheFirstTransfer`, and it proves
    /// something that test cannot: **at item `n`'s first transfer, item `n`'s own effects are
    /// already written and item `n+1`'s are not yet.**
    ///
    /// Four items, four distinct payers, four distinct providers, four distinct amounts. Every
    /// amount is `>= 10`, so every item makes exactly two transfers (provider, then treasury) and
    /// transfer `2n` is item `n`'s first.
    function test_everyItemsEffectsAreWrittenBeforeThatItemsOwnTransfers() public {
        BatchObserverUSDG obs = new BatchObserverUSDG();
        X402Escrow e2 = _deployEscrow(address(obs), address(0));

        address[] memory bs = new address[](4);
        uint64[4] memory amounts = [uint64(250_000), 310_000, 70_007, 1_234_567];
        for (uint256 i = 0; i < 4; i++) {
            bs[i] = _arm(e2, IMintableToken(address(obs)), payerKeys[i], FUND);
        }

        bytes32 ds2 = e2.DOMAIN_SEPARATOR();
        Voucher[] memory vs = new Voucher[](4);
        bytes[] memory sigs = new bytes[](4);
        for (uint256 i = 0; i < 4; i++) {
            vs[i] = Voucher({
                payer: bs[i],
                provider: providers[i],
                amount: amounts[i],
                resourceHash: keccak256(abi.encode("resource", i)),
                requestHash: keccak256(abi.encode("request", i)),
                seq: 1,
                issuedAt: uint64(block.timestamp),
                expiresAt: uint64(block.timestamp) + 300
            });
            sigs[i] = VoucherSigner.signVoucher(payerKeys[i], ds2, vs[i]);
        }

        obs.arm(address(e2), bs);
        vm.prank(redeemer);
        e2.redeemVoucherBatch(vs, sigs);

        assertEq(obs.transferCount(), 8, "two transfers per item, or the indices below are wrong");

        uint256 running;
        for (uint256 n = 0; n < 4; n++) {
            running += amounts[n];
            uint256 t = 2 * n; // item n's FIRST transfer — the provider payout

            assertEq(obs.seenTo(t), providers[n], "transfer 2n is not item n's provider payout");
            assertEq(obs.seenAmount(t), amounts[n] - _fee(amounts[n]));

            // 1. item n's own effects are ALREADY written when item n is paid.
            BatchObserverUSDG.Seen memory own = obs.seenAt(t, n);
            assertEq(own.seqHigh, 1, "item n's seqHigh not yet advanced at item n's payout");
            assertEq(own.balance, FUND - amounts[n], "item n's balance not yet debited");
            assertEq(own.spentInWindow, amounts[n], "item n's window not yet advanced");
            assertEq(own.totalRedeemed, amounts[n], "item n's totalRedeemed not yet advanced");

            // 2. and item n+1's are NOT — the loop is n complete redemptions, not a pass of
            //    effects followed by a pass of payouts.
            if (n + 1 < 4) {
                BatchObserverUSDG.Seen memory next = obs.seenAt(t, n + 1);
                assertEq(next.seqHigh, 0, "item n+1 settled before item n was paid");
                assertEq(next.balance, FUND, "item n+1's balance moved before item n was paid");
                assertEq(next.spentInWindow, 0);
                assertEq(next.totalRedeemed, 0);
            }

            // 3. the pooled counter says the same thing in one number: exactly items 0..n have
            //    been debited at this instant.
            assertEq(
                obs.seenTotalEscrowed(t),
                uint128(4 * uint256(FUND) - running),
                "totalEscrowed at item n's payout is not exactly items 0..n debited"
            );
        }

        // and the batch really completed, so none of the above is vacuous.
        for (uint256 i = 0; i < 4; i++) {
            assertEq(obs.balanceOf(providers[i]), amounts[i] - _fee(amounts[i]));
        }
    }

    // --- the source gate ---------------------------------------------------------------------

    /// The batch **reuses `_redeem` unchanged**; it does not re-spell the rule set. That is not a
    /// stylistic preference — a batch with its own copy of the checks is a second place for the
    /// replay rule to live, and the degenerate that pays every provider out of the first
    /// voucher's amounts is written by copying `_redeem` and editing two lines of the copy.
    ///
    /// The behavioural tests above kill that degenerate on the fixtures they reach. This pins the
    /// shape itself, the way `test_theSignatureComparisonIsUnconditionalInTheSource` pins the
    /// signature comparison: three occurrences of `_redeem(` in `src/` — one declaration and
    /// exactly two call sites — and the loop body is the one-line delegation.
    function test_theBatchDelegatesToTheOneRedeemPathInTheSource() public view {
        string memory src = vm.readFile(string.concat(vm.projectRoot(), "/src/X402Escrow.sol"));

        assertEq(
            _count(
                src,
                "        for (uint256 i = 0; i < n; ++i) {\n            _redeem(vs[i], sigs[i], p);\n        }\n"
            ),
            1,
            "the batch loop is not the exact one-line delegation this test pins"
        );
        assertEq(
            _count(src, "_redeem("),
            3,
            "there is not exactly one _redeem declaration and two call sites in src/"
        );
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

    // --- the measurement ---------------------------------------------------------------------
    //
    // Not assertions about numbers — recordings of them. Gas is deterministic and
    // load-independent, which is exactly why it is measured here and never timed.
    //
    // Each of the three sizes ALSO gets its own test below. `vm.revertToState` restores storage,
    // but the EVM's warm/cold access list is a per-transaction thing and its state across a
    // snapshot revert is not something this suite should have to assume: sizes 8 and 64 measured
    // after size 1 in the same call may see slots the size-1 run already warmed. The one-size-per
    // -test figures are the ones `docs/gas.md` quotes; the loop below is kept because the
    // specification names it and because a disagreement between the two IS the warm/cold effect,
    // quantified.

    /// MEASURE. Not an assertion about a number — a recording of one.
    function test_measure_batchGasAtOneEightAndSixtyFour() public {
        uint256[3] memory sizes = [uint256(1), 8, 64];
        for (uint256 i = 0; i < 3; i++) {
            uint256 snap = vm.snapshotState();
            (Voucher[] memory vs, bytes[] memory sigs) = _batch(sizes[i]);
            vm.prank(redeemer);
            uint256 before = gasleft();
            escrow.redeemVoucherBatch(vs, sigs);
            uint256 used = before - gasleft();
            console2.log("batch size", sizes[i]);
            console2.log("  total gas ", used);
            console2.log("  per voucher", used / sizes[i]);
            vm.revertToState(snap);
        }
    }

    function _measureSamePayer(uint256 n) internal {
        (Voucher[] memory vs, bytes[] memory sigs) = _batch(n);
        vm.prank(redeemer);
        uint256 before = gasleft();
        escrow.redeemVoucherBatch(vs, sigs);
        uint256 used = before - gasleft();
        console2.log("SAME-PAYER batch size", n);
        console2.log("  total gas   ", used);
        console2.log("  per voucher ", used / n);
    }

    function _measureDistinctPayers(uint256 n) internal {
        (Voucher[] memory vs, bytes[] memory sigs) = _distinctPayers(n);
        vm.prank(redeemer);
        uint256 before = gasleft();
        escrow.redeemVoucherBatch(vs, sigs);
        uint256 used = before - gasleft();
        console2.log("DISTINCT-PAYER batch size", n);
        console2.log("  total gas   ", used);
        console2.log("  per voucher ", used / n);
    }

    function test_measure_samePayerBatchOfOne() public {
        _measureSamePayer(1);
    }

    function test_measure_samePayerBatchOfEight() public {
        _measureSamePayer(8);
    }

    function test_measure_samePayerBatchOfSixtyFour() public {
        _measureSamePayer(64);
    }

    function _measureLabelled(string memory label, Voucher[] memory vs, bytes[] memory sigs)
        internal
    {
        vm.prank(redeemer);
        uint256 before = gasleft();
        escrow.redeemVoucherBatch(vs, sigs);
        uint256 used = before - gasleft();
        console2.log(label);
        console2.log("  total gas   ", used);
        console2.log("  per voucher ", used / vs.length);
    }

    function test_measure_distinctPayersOneProviderAtEight() public {
        (Voucher[] memory vs, bytes[] memory sigs) = _distinctPayersOneProvider(8);
        _measureLabelled("DISTINCT-PAYER / ONE-PROVIDER batch size 8", vs, sigs);
    }

    function test_measure_distinctPayersOneProviderAtSixtyFour() public {
        (Voucher[] memory vs, bytes[] memory sigs) = _distinctPayersOneProvider(64);
        _measureLabelled("DISTINCT-PAYER / ONE-PROVIDER batch size 64", vs, sigs);
    }

    function test_measure_onePayerDistinctProvidersAtEight() public {
        (Voucher[] memory vs, bytes[] memory sigs) = _onePayerDistinctProviders(8);
        _measureLabelled("ONE-PAYER / DISTINCT-PROVIDER batch size 8", vs, sigs);
    }

    function test_measure_onePayerDistinctProvidersAtSixtyFour() public {
        (Voucher[] memory vs, bytes[] memory sigs) = _onePayerDistinctProviders(64);
        _measureLabelled("ONE-PAYER / DISTINCT-PROVIDER batch size 64", vs, sigs);
    }

    function test_measure_distinctPayerBatchOfEight() public {
        _measureDistinctPayers(8);
    }

    function test_measure_distinctPayerBatchOfSixtyFour() public {
        _measureDistinctPayers(64);
    }

    /// The comparison the per-voucher figures only mean something against: ONE voucher through
    /// `redeemVoucher`, same shape, same cold slots.
    function test_measure_singleRedeemVoucherForComparison() public {
        (Voucher[] memory vs, bytes[] memory sigs) = _batch(1);
        vm.prank(redeemer);
        uint256 before = gasleft();
        escrow.redeemVoucher(vs[0], sigs[0]);
        uint256 used = before - gasleft();
        console2.log("SINGLE redeemVoucher");
        console2.log("  total gas   ", used);
    }

    /// The calldata figure `docs/gas.md` quotes, measured off the real ABI encoding rather than
    /// counted off the struct by hand. On an Orbit L2 this is the L1 component of the fee and the
    /// reason batching pays at all.
    function test_measure_calldataBytesPerVoucher() public view {
        (Voucher[] memory one, bytes[] memory oneSig) = _batch(1);
        (Voucher[] memory eight, bytes[] memory eightSigs) = _batch(8);
        (Voucher[] memory many, bytes[] memory manySigs) = _batch(64);

        uint256 c1 = abi.encodeCall(X402Escrow.redeemVoucherBatch, (one, oneSig)).length;
        uint256 c8 = abi.encodeCall(X402Escrow.redeemVoucherBatch, (eight, eightSigs)).length;
        uint256 c64 = abi.encodeCall(X402Escrow.redeemVoucherBatch, (many, manySigs)).length;
        uint256 cSingle = abi.encodeCall(X402Escrow.redeemVoucher, (one[0], oneSig[0])).length;

        console2.log("calldata bytes, redeemVoucher (1)   ", cSingle);
        console2.log("calldata bytes, batch of 1          ", c1);
        console2.log("calldata bytes, batch of 8          ", c8);
        console2.log("calldata bytes, batch of 64         ", c64);
        console2.log("marginal bytes per voucher (64 vs 8)", (c64 - c8) / 56);
    }
}
