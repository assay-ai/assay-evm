// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {X402Config} from "../../src/X402Config.sol";
import {X402Escrow} from "../../src/X402Escrow.sol";
import {X402Stake} from "../../src/X402Stake.sol";
import {IX402Config} from "../../src/interfaces/IX402Config.sol";
import {IX402StakeView} from "../../src/interfaces/IX402StakeView.sol";
import {Voucher, ParamSet} from "../../src/Types.sol";
import {MockUSDG} from "../helpers/MockUSDG.sol";
import {VoucherSigner} from "../helpers/VoucherSigner.sol";

/// The escrow's bounded actor set for the stateful invariant run.
///
/// **Four actors with KNOWN private keys**, because a voucher has to be signed inside the fuzz
/// loop and a random `address` cannot sign anything. Everything is deployed here rather than
/// inherited from `Fixture`: an invariant handler is the fuzzer's whole world, and a fixture that
/// pre-funded or pre-armed anything would make the identities below assertions about the fixture.
///
/// Every action is bounded with `bound()` and every one increments a landed counter, checked by
/// `InvariantsTest.test_theHandlerActuallyReachedEveryAction`. `fail_on_revert = false` is set in
/// `foundry.toml`, so without that check a run in which **every** call reverted would report six
/// green invariants over an empty state — which is the failure mode `tests/fuzz.rs` guards with
/// "assert every op landed >= 1", and it ports.
contract EscrowHandler is Test {
    MockUSDG public usdg;
    X402Config public config;
    X402Escrow public escrow;
    X402Stake public stake;

    address internal constant ADMIN = address(0xADAA);
    address internal constant TREASURY = address(0x7EA5);
    address internal constant REDEEMER = address(0x4EED);
    address internal constant PROVIDER = address(0x9309);
    uint64 internal constant MINIMUM_STAKE = 100_000_000;

    address[4] public actors;
    uint256[4] internal keys;

    /// The high-water mark this handler last observed per actor, and the flag that records
    /// whether it ever moved backwards. Read by `invariant_seqHighIsMonotonic`.
    uint64[4] internal observedSeqHigh;
    bool public seqHighNeverWentBackwards = true;

    /// Landed-call counters, one per action, indexed by the action's own name.
    mapping(bytes32 => uint256) public landed;

    constructor() {
        keys = [uint256(0xA1), uint256(0xA2), uint256(0xA3), uint256(0xA4)];
        for (uint256 i = 0; i < 4; i++) {
            actors[i] = vm.addr(keys[i]);
        }

        usdg = new MockUSDG();

        ParamSet memory p = ParamSet({
            treasury: TREASURY,
            redeemer: REDEEMER,
            unbondingPeriodSeconds: 14 * 86_400,
            minimumStake: MINIMUM_STAKE,
            penaltyAmount: 1_000_000,
            verifierDailyCap: 500_000_000,
            takeRateBps: 1_000,
            slashAgentBps: 6_000,
            slashPlatformBps: 3_000,
            slashCapBps: 1_000
        });

        config = X402Config(
            address(
                new ERC1967Proxy(
                    address(new X402Config()), abi.encodeCall(X402Config.initialize, (p, ADMIN))
                )
            )
        );
        stake = X402Stake(
            address(
                new ERC1967Proxy(
                    address(new X402Stake()),
                    abi.encodeCall(
                        X402Stake.initialize, (IX402Config(address(config)), IERC20(address(usdg)))
                    )
                )
            )
        );
        escrow = X402Escrow(
            address(
                new ERC1967Proxy(
                    address(new X402Escrow()),
                    abi.encodeCall(
                        X402Escrow.initialize,
                        (
                            IX402Config(address(config)),
                            IX402StakeView(address(stake)),
                            IERC20(address(usdg)),
                            address(0)
                        )
                    )
                )
            )
        );

        // One provider, bonded well clear of the floor, so `ProviderBelowMinimumStake` is not
        // what every redeem in the run fails on.
        usdg.mint(address(this), 10 * MINIMUM_STAKE);
        usdg.approve(address(stake), 10 * MINIMUM_STAKE);
        stake.depositStakeFor(PROVIDER, 10 * MINIMUM_STAKE);
    }

    // --- the tracked sums --------------------------------------------------------------------

    /// The left-hand side of D-14's first identity, computed OUTSIDE the contract. Summing the
    /// mapping in the contract itself would be reading `totalEscrowed` twice.
    function sumOfBalances() external view returns (uint128 total) {
        for (uint256 i = 0; i < 4; i++) {
            total += escrow.escrowOf(actors[i]).balance;
        }
    }

    function _recordSeq(uint256 idx) internal {
        uint64 seen = escrow.escrowOf(actors[idx]).seqHigh;
        if (seen < observedSeqHigh[idx]) seqHighNeverWentBackwards = false;
        observedSeqHigh[idx] = seen;
    }

    function _actor(uint256 seed) internal view returns (uint256 idx) {
        return bound(seed, 0, 3);
    }

    // --- the actions -------------------------------------------------------------------------

    function deposit(uint256 actorSeed, uint64 amount) external {
        uint256 i = _actor(actorSeed);
        amount = uint64(bound(amount, 1, 1_000_000_000));
        address a = actors[i];
        usdg.mint(a, amount);
        vm.startPrank(a);
        usdg.approve(address(escrow), amount);
        escrow.deposit(amount);
        vm.stopPrank();
        landed["deposit"] += 1;
        _recordSeq(i);
    }

    /// Anyone may fund anyone — so the identity has to survive a third party crediting an actor
    /// who never called anything.
    function depositFor(uint256 funderSeed, uint256 beneficiarySeed, uint64 amount) external {
        uint256 f = _actor(funderSeed);
        uint256 b = _actor(beneficiarySeed);
        amount = uint64(bound(amount, 1, 1_000_000_000));
        usdg.mint(actors[f], amount);
        vm.startPrank(actors[f]);
        usdg.approve(address(escrow), amount);
        escrow.depositFor(actors[b], amount);
        vm.stopPrank();
        landed["depositFor"] += 1;
        _recordSeq(b);
    }

    function setLimits(uint256 actorSeed, uint64 maxVoucher, uint64 maxWindow) external {
        uint256 i = _actor(actorSeed);
        maxVoucher = uint64(bound(maxVoucher, 0, 2_000_000_000));
        maxWindow = uint64(bound(maxWindow, 0, 4_000_000_000));
        vm.prank(actors[i]);
        escrow.setLimits(maxVoucher, maxWindow);
        landed["setLimits"] += 1;
    }

    /// The one action that moves money OUT through the platform. `seq` is derived from the live
    /// high-water mark rather than fuzzed flat: a uniformly random `uint64` `seq` is above
    /// `seqHigh` on essentially every draw, so the fuzzer would never exercise the refusal and —
    /// worse — a redeem that could not land would make the two escrow invariants vacuous.
    /// (Uniform fuzzing essentially never finds structured small values, so the handler steers.)
    function redeem(uint256 actorSeed, uint64 seqDelta, uint64 amount) external {
        uint256 i = _actor(actorSeed);
        address a = actors[i];
        X402Escrow.Escrow memory e = escrow.escrowOf(a);

        // Bias hard toward a redeem that CAN land: at or below the balance, at or below both
        // ceilings. The fuzzer still reaches the refusals through `seqDelta == 0` and through
        // states where a ceiling is zero.
        uint64 ceiling = e.balance > type(uint64).max ? type(uint64).max : uint64(e.balance);
        if (e.maxVoucherAmount < ceiling) ceiling = e.maxVoucherAmount;
        if (ceiling == 0) return;
        amount = uint64(bound(amount, 1, ceiling));
        uint64 seq = e.seqHigh + uint64(bound(seqDelta, 0, 2));

        Voucher memory v = Voucher({
            payer: a,
            provider: PROVIDER,
            amount: amount,
            resourceHash: keccak256("invariant"),
            requestHash: keccak256(abi.encode(a, seq, amount, block.timestamp)),
            seq: seq,
            issuedAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp) + 60
        });
        bytes memory sig = VoucherSigner.signVoucher(keys[i], escrow.DOMAIN_SEPARATOR(), v);

        vm.prank(REDEEMER);
        escrow.redeemVoucher(v, sig);
        landed["redeem"] += 1;
        _recordSeq(i);
    }

    function requestWithdraw(uint256 actorSeed, uint64 amount) external {
        uint256 i = _actor(actorSeed);
        amount = uint64(bound(amount, 0, 2_000_000_000));
        vm.prank(actors[i]);
        escrow.requestWithdraw(amount);
        landed["requestWithdraw"] += 1;
    }

    function withdraw(uint256 actorSeed) external {
        uint256 i = _actor(actorSeed);
        vm.prank(actors[i]);
        escrow.withdraw();
        landed["withdraw"] += 1;
    }

    /// Time is an actor too: the rolling window, the withdraw delay and the voucher clock all
    /// depend on it, and a run that never warped would leave `Window.decay` at `elapsed == 0`
    /// for the whole run.
    function warp(uint32 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 1, 3 * 3600));
        landed["warp"] += 1;
    }

    /// A donation straight to the contract address, crediting nobody. It exists so
    /// `invariant_theContractHoldsAtLeastWhatItOwes` is asserted against a state where the
    /// inequality is STRICT — without it the token balance and `totalEscrowed` are always equal
    /// and the `assertGe` would be an `assertEq` in disguise.
    function donate(uint64 amount) external {
        amount = uint64(bound(amount, 1, 1_000_000));
        usdg.mint(address(escrow), amount);
        landed["donate"] += 1;
    }
}
