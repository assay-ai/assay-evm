// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {X402Config} from "../../src/X402Config.sol";
import {X402Stake} from "../../src/X402Stake.sol";
import {IX402Config} from "../../src/interfaces/IX402Config.sol";
import {SlashAttestation, ResponseClass, SlashStatus, ParamSet} from "../../src/Types.sol";
import {Constants} from "../../src/Constants.sol";
import {MockUSDG} from "../helpers/MockUSDG.sol";
import {VoucherSigner} from "../helpers/VoucherSigner.sol";

/// The stake vault's bounded actor set: four providers, one enrolled verifier, and the seven
/// state transitions a `SlashRecord` can take part in.
///
/// **The reservation sum is kept HERE, not read back from the contract.** `sumOfPendingSlash`
/// reads `stakes[p].pendingSlash` off the vault; `sumOfPendingReservations` sums this handler's
/// own record of every proposal it believes is still `Pending`, adding on a landed
/// `proposeSlash` and removing on a landed `executeSlash`, `cancelSlash` or `expireSlash`.
/// Two independent bookkeepings, compared. Reading both from the contract would compare
/// `pendingSlash` with itself.
contract StakeHandler is Test {
    MockUSDG public usdg;
    X402Config public config;
    X402Stake public stake;

    address internal constant ADMIN = address(0xADAA);
    address internal constant TREASURY = address(0x7EA5);
    address internal constant REDEEMER = address(0x4EED);
    address internal constant BENEFICIARY = address(0xA6E7);
    uint256 internal constant VERIFIER_KEY = 0x7E5717;
    address public verifier;

    address[4] public providers;

    /// This handler's own book: every request id it has proposed, and for the ones it still
    /// believes are pending, the amount that was reserved.
    bytes32[] public proposedIds;
    mapping(bytes32 => uint64) public reservedOf;
    mapping(bytes32 => bool) public believedPending;

    mapping(bytes32 => uint256) public landed;

    uint256 internal nextId;

    constructor() {
        verifier = vm.addr(VERIFIER_KEY);
        providers = [address(0x9301), address(0x9302), address(0x9303), address(0x9304)];

        usdg = new MockUSDG();

        ParamSet memory p = ParamSet({
            treasury: TREASURY,
            redeemer: REDEEMER,
            unbondingPeriodSeconds: 14 * 86_400,
            minimumStake: 100_000_000,
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

        vm.prank(ADMIN);
        // The full rotation ceiling, so the run cannot silently become a test of key expiry.
        config.registerVerifier(
            verifier,
            bytes32("verifier-evm-2026-09"),
            uint64(block.timestamp) + Constants.MAX_VERIFIER_KEY_LIFETIME_SECONDS
        );

        // Every provider starts bonded, or nothing can be proposed against them.
        for (uint256 i = 0; i < 4; i++) {
            usdg.mint(address(this), 1_000_000_000);
            usdg.approve(address(stake), 1_000_000_000);
            stake.depositStakeFor(providers[i], 1_000_000_000);
        }
    }

    // --- the two sums the invariant compares -------------------------------------------------

    function sumOfPendingSlash() external view returns (uint256 total) {
        for (uint256 i = 0; i < 4; i++) {
            total += stake.stakeOf(providers[i]).pendingSlash;
        }
    }

    function sumOfPendingReservations() external view returns (uint256 total) {
        for (uint256 i = 0; i < proposedIds.length; i++) {
            if (believedPending[proposedIds[i]]) total += reservedOf[proposedIds[i]];
        }
    }

    /// D-14's fourth identity, per provider, folded into one boolean the suite can assert.
    function everyProviderCoversItsPendingSlash() external view returns (bool) {
        for (uint256 i = 0; i < 4; i++) {
            X402Stake.ProviderStake memory s = stake.stakeOf(providers[i]);
            if (uint256(s.bonded) + s.unbonding < s.pendingSlash) return false;
        }
        return true;
    }

    function _provider(uint256 seed) internal pure returns (uint256) {
        return bound(seed, 0, 3);
    }

    // --- the actions -------------------------------------------------------------------------

    function depositStake(uint256 providerSeed, uint64 amount) external {
        uint256 i = _provider(providerSeed);
        amount = uint64(bound(amount, 1, 1_000_000_000));
        usdg.mint(providers[i], amount);
        vm.startPrank(providers[i]);
        usdg.approve(address(stake), amount);
        stake.depositStake(amount);
        vm.stopPrank();
        landed["depositStake"] += 1;
    }

    function requestUnstake(uint256 providerSeed, uint64 amount) external {
        uint256 i = _provider(providerSeed);
        uint128 bonded = stake.stakeOf(providers[i]).bonded;
        if (bonded == 0) return;
        amount = uint64(bound(amount, 1, uint64(bonded)));
        vm.prank(providers[i]);
        stake.requestUnstake(amount);
        landed["requestUnstake"] += 1;
    }

    function withdrawStake(uint256 providerSeed, uint64 amount) external {
        uint256 i = _provider(providerSeed);
        uint64 free = stake.withdrawableOf(providers[i]);
        if (free == 0) return;
        amount = uint64(bound(amount, 1, free));
        vm.prank(providers[i]);
        stake.withdrawStake(amount);
        landed["withdrawStake"] += 1;
    }

    function proposeSlash(uint256 providerSeed, uint64 penalty) external {
        uint256 i = _provider(providerSeed);
        // `PenaltyExceedsMaximum` is checked against `params().penaltyAmount`, which is
        // 1,000,000 here. Bounding above it made every proposal in the campaign revert and left
        // the whole slash lifecycle unreachable — measured, and exactly the degenerate the
        // reachability test refuses.
        penalty = uint64(bound(penalty, 1, config.params().penaltyAmount));
        bytes32 id = keccak256(abi.encode("req", nextId++));

        SlashAttestation memory a = SlashAttestation({
            requestId: id,
            provider: providers[i],
            beneficiary: BENEFICIARY,
            status: uint8(ResponseClass.DataFail),
            penalty: penalty,
            policy: keccak256("policy v1"),
            issuedAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp) + 3 * 86_400
        });
        bytes memory sig = VoucherSigner.signAttestation(VERIFIER_KEY, stake.DOMAIN_SEPARATOR(), a);

        stake.proposeSlash(a, sig);

        // Only reached when the call landed. `reserved` is read once, here, and never again —
        // from this point the handler's book is its own.
        proposedIds.push(id);
        reservedOf[id] = stake.slashRecordOf(id).reserved;
        believedPending[id] = true;
        landed["proposeSlash"] += 1;
    }

    function executeSlash(uint256 idSeed) external {
        bytes32 id = _pendingId(idSeed);
        if (id == bytes32(0)) return;
        stake.executeSlash(id);
        believedPending[id] = false;
        landed["executeSlash"] += 1;
    }

    function cancelSlash(uint256 idSeed) external {
        bytes32 id = _pendingId(idSeed);
        if (id == bytes32(0)) return;
        vm.prank(ADMIN);
        stake.cancelSlash(id);
        believedPending[id] = false;
        landed["cancelSlash"] += 1;
    }

    function expireSlash(uint256 idSeed) external {
        bytes32 id = _pendingId(idSeed);
        if (id == bytes32(0)) return;
        stake.expireSlash(id);
        believedPending[id] = false;
        landed["expireSlash"] += 1;
    }

    /// Time, in steps big enough to cross the 72-hour delay and the seven-day grace inside a
    /// 64-call run. A window that could never be crossed would leave `executeSlash` and
    /// `expireSlash` at zero landed calls and both slash invariants vacuous — which is exactly
    /// the degenerate `test_theHandlerActuallyReachedEveryAction` refuses.
    function warp(uint32 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 1, 4 * 86_400));
        landed["warp"] += 1;
    }

    function _pendingId(uint256 seed) internal view returns (bytes32) {
        uint256 n = proposedIds.length;
        if (n == 0) return bytes32(0);
        uint256 start = bound(seed, 0, n - 1);
        for (uint256 k = 0; k < n; k++) {
            bytes32 id = proposedIds[(start + k) % n];
            if (believedPending[id]) return id;
        }
        return bytes32(0);
    }
}
