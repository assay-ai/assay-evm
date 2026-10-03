// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {X402Config} from "../../src/X402Config.sol";
import {X402Escrow} from "../../src/X402Escrow.sol";
import {X402Stake} from "../../src/X402Stake.sol";
import {IX402Config} from "../../src/interfaces/IX402Config.sol";
import {IX402StakeView} from "../../src/interfaces/IX402StakeView.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ParamSet} from "../../src/Types.sol";
import {MockUSDG} from "./MockUSDG.sol";

/// Everything here is deployed BEHIND A PROXY (D-1), so every test in this suite runs
/// through the same delegatecall path production runs through. `config` and `escrow` stay
/// typed as the contracts — they are the proxy address cast to the implementation's type,
/// which is how a UUPS deployment is always called.
abstract contract Fixture is Test {
    /// The settlement token, ALWAYS reached through this handle. Off the fork it is a real
    /// `MockUSDG`; on the fork it is the address of the token deployed at 46630, cast to the
    /// same type. The cast is safe for `balanceOf`, `approve`, `transfer` and `transferFrom`,
    /// which both tokens export with identical signatures — and unsafe for `mint`, `blocked`,
    /// `transferFeeBps`, `setBlocked` and `setTransferFeeBps`, which only the mock has. `_fund`
    /// covers the first of those; `mockTokenOnly` covers the rest.
    ///
    /// It is unsafe for `name()` and `symbol()` too, for a reason that has nothing to do with
    /// the cast: the real token's string getters use `MCOPY`, which this repo's pinned
    /// `evm_version = "shanghai"` does not activate. Nothing in `src/` calls them. See
    /// `docs/chain-facts.md` §1b.
    MockUSDG internal usdg;

    /// Set by a subclass in `test/fork/` BEFORE `super.setUp()`. Nothing else may write it.
    bool internal forkMode;

    address internal constant RH_TESTNET_USDG = 0x915Ef7c9F9f80a69e3BE47A38EE0Bb47607103ec;
    uint256 internal constant RH_TESTNET_CHAIN_ID = 46630;
    X402Config internal config;
    X402Escrow internal escrow;
    X402Stake internal stake;
    IX402StakeView internal stakeView;

    /// The implementations, kept so a test can name one (`Upgrade.t.sol` upgrades against them).
    X402Config internal configImpl;
    X402Escrow internal escrowImpl;
    X402Stake internal stakeImpl;

    address internal admin = address(0xADAA);
    address internal treasury = address(0x7EA5);
    address internal redeemer = address(0x4EED);
    address internal provider = address(0x9309);

    uint256 internal buyerKey = 0xB0FFE;
    address internal buyer;

    uint16 internal constant TAKE_RATE_BPS = 1_000; // 10%
    uint64 internal constant MINIMUM_STAKE = 100_000_000; // 100 USDG

    function setUp() public virtual {
        if (forkMode) {
            string memory rpc = vm.envOr("RH_TESTNET_RPC", string(""));
            if (bytes(rpc).length == 0) {
                vm.skip(true);
                return;
            }
            vm.createSelectFork(rpc);
            assertEq(block.chainid, RH_TESTNET_CHAIN_ID, "RH_TESTNET_RPC is not chain 46630");
        }

        // BEFORE the token, and on the fork too. Every voucher-window assertion in this suite is
        // written against this instant; warping BACKWARDS from the fork's real timestamp
        // (~1_788_986_951 on 2026-09-10) is legal and changes nothing on chain, and it is what
        // lets the same assertions run in both modes. Verified on a live fork.
        vm.warp(1_760_000_000);
        buyer = vm.addr(buyerKey);

        usdg = forkMode ? MockUSDG(RH_TESTNET_USDG) : new MockUSDG();

        ParamSet memory p = ParamSet({
            treasury: treasury,
            redeemer: redeemer,
            unbondingPeriodSeconds: 14 * 86_400,
            minimumStake: MINIMUM_STAKE,
            penaltyAmount: 1_000_000,
            verifierDailyCap: 500_000_000,
            takeRateBps: TAKE_RATE_BPS,
            slashAgentBps: 6_000,
            slashPlatformBps: 3_000,
            slashCapBps: 1_000
        });

        configImpl = new X402Config();
        config = X402Config(
            address(
                new ERC1967Proxy(
                    address(configImpl), abi.encodeCall(X402Config.initialize, (p, admin))
                )
            )
        );

        stakeImpl = new X402Stake();
        stake = _deployStake(address(usdg));

        // `_deployEscrow` reads this, and so do the Permit2 deposit tests.
        stakeView = IX402StakeView(address(stake));

        escrowImpl = new X402Escrow();
        escrow = _deployEscrow(address(0));

        // Every escrow test needs a provider that clears the minimum. It arrives through the
        // real deposit path now, so nothing in the suite is proved against a stub any more.
        _setBonded(provider, MINIMUM_STAKE);
    }

    /// A stake contract behind its OWN proxy (D-1). The stake suites take one each rather than
    /// sharing this fixture's instance, because that one is pre-funded for the escrow tests and
    /// the accounting totals are contract-wide — a shared instance would make
    /// `totalStaked == DEPOSIT` an assertion about the fixture rather than about the deposit.
    function _deployStake(address asset_) internal returns (X402Stake) {
        return X402Stake(
            address(
                new ERC1967Proxy(
                    address(stakeImpl),
                    abi.encodeCall(
                        X402Stake.initialize, (IX402Config(address(config)), IERC20(asset_))
                    )
                )
            )
        );
    }

    /// `StakeStub.setBonded` as the real contract does it: deposit to raise, and `requestUnstake`
    /// to lower — which is the actual path a provider takes to fall under the minimum, and
    /// therefore a better fixture than a setter that wrote the field directly.
    ///
    /// The lowered amount lands in `unbonding`, where it is still slashable and no longer counts
    /// toward the floor (`state.rs:446`: `meets_minimum` reads `bonded` only). That is exactly
    /// what the stub's `setBonded` was standing in for.
    function _setBonded(address provider_, uint64 target) internal {
        uint64 current = stake.bondedOf(provider_);
        if (target > current) {
            uint64 delta = target - current;
            _fund(address(this), delta);
            usdg.approve(address(stake), delta);
            stake.depositStakeFor(provider_, delta);
        } else if (target < current) {
            vm.prank(provider_);
            stake.requestUnstake(current - target);
        }
    }

    /// A second escrow behind its OWN proxy — which is what a redeploy is (D-7). Every test
    /// variant goes through this, so nothing in the suite ever calls an implementation
    /// directly and accidentally proves something about a contract nobody deploys.
    function _deployEscrow(address permit2_) internal returns (X402Escrow) {
        return _deployEscrow(address(usdg), permit2_);
    }

    /// The same, with the settlement asset named. Two tests need an asset that is not `usdg` —
    /// the re-entrancy prover and the decimals check — and neither may reach for a bare
    /// implementation to get one.
    function _deployEscrow(address asset_, address permit2_) internal returns (X402Escrow) {
        return X402Escrow(
            address(
                new ERC1967Proxy(
                    address(escrowImpl),
                    abi.encodeCall(
                        X402Escrow.initialize,
                        (IX402Config(address(config)), stakeView, IERC20(asset_), permit2_)
                    )
                )
            )
        );
    }
    /// Give `to` `amount` MORE of the settlement token.
    ///
    /// **Adds, never sets.** `deal`'s three-argument form SETS a balance, which silently erases
    /// an earlier funding when a fixture funds one address twice — and the second funding is
    /// usually the one the test is reasoning about. `MockUSDG.mint` adds, so the two modes must
    /// agree on that or the suites diverge for a reason that has nothing to do with the token.
    ///
    /// The fourth argument to `deal` adjusts `totalSupply`, so the real token's own accounting
    /// identity is not broken by the funding.

    function _fund(address to, uint256 amount) internal virtual {
        if (forkMode) {
            deal(address(usdg), to, usdg.balanceOf(to) + amount, true);
        } else {
            usdg.mint(to, amount);
        }
    }

    /// For the assertions that need a lever only the mock has.
    ///
    /// It SKIPS rather than silently passing, so the fork run's output names each one. A test
    /// that quietly does nothing on the fork is indistinguishable from a test that ran — which
    /// is the failure mode of a gate that answers a different question than the one it names.
    modifier mockTokenOnly() {
        if (forkMode) {
            vm.skip(true);
        }
        _;
    }
}
