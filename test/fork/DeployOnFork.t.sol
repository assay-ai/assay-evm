// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.24;

import {ForkFixture} from "./ForkFixture.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {X402Config} from "../../src/X402Config.sol";
import {X402Stake} from "../../src/X402Stake.sol";
import {X402Escrow} from "../../src/X402Escrow.sol";
import {IX402Config} from "../../src/interfaces/IX402Config.sol";
import {IX402StakeView} from "../../src/interfaces/IX402StakeView.sol";
import {ParamSet} from "../../src/Types.sol";

/// `Deploy.s.sol`'s sequence, executed against real 46630 state, with the runbook's own
/// post-deploy checklist as assertions.
///
/// `test/Deploy.t.sol` already proves the SHAPE of the script — that it uses the atomic
/// deploy-and-initialise form, that the split form is front-runnable, that the salt formula
/// matches the shell's. What it cannot prove is that the sequence works against the token that
/// is actually there, because it runs against `MockUSDG`. This does.
///
/// **Nothing here is broadcast.** `vm.createSelectFork` + `new` writes to the local fork's
/// journal and never leaves the process.
///
/// **What it deliberately does NOT reproduce: the CREATE2 salt.** `Deploy.s.sol` creates each
/// proxy with `new ERC1967Proxy{salt: _salt(name)}(…)` inside `vm.startBroadcast()`, so on chain
/// the deployer is the broadcasting EOA. In a test there is no broadcaster; the deployer is this
/// test contract, so a salted `new` here would produce an address that predicts nothing about the
/// deploy. The addresses are therefore not asserted — the WIRING is, which is the half a dry run
/// cannot give you. The address half is arithmetic and lives in `verify-deployment.sh` check 5.
contract DeployOnForkTest is ForkFixture {
    address internal constant ADMIN = address(0xADAA);
    address internal constant TREASURY = address(0x7EA5);
    address internal constant REDEEMER = address(0x4EED);

    // keccak256("eip1967.proxy.implementation") - 1
    bytes32 internal constant IMPL_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    X402Config internal config;
    X402Stake internal stake;
    X402Escrow internal escrow;
    address internal configImpl;
    address internal stakeImpl;
    address internal escrowImpl;

    function setUp() public {
        if (!_selectForkOrSkip()) return;

        ParamSet memory p = ParamSet({
            treasury: TREASURY,
            redeemer: REDEEMER,
            unbondingPeriodSeconds: 950_400,
            minimumStake: 50_000_000,
            penaltyAmount: 1_000_000,
            verifierDailyCap: 100_000_000,
            takeRateBps: 2_000,
            slashAgentBps: 8_000,
            slashPlatformBps: 1_000,
            slashCapBps: 5_000
        });

        configImpl = address(new X402Config());
        config = X402Config(
            address(new ERC1967Proxy(configImpl, abi.encodeCall(X402Config.initialize, (p, ADMIN))))
        );
        stakeImpl = address(new X402Stake());
        stake = X402Stake(
            address(
                new ERC1967Proxy(
                    stakeImpl,
                    abi.encodeCall(
                        X402Stake.initialize,
                        (IX402Config(address(config)), IERC20(RH_TESTNET_USDG))
                    )
                )
            )
        );
        escrowImpl = address(new X402Escrow());
        escrow = X402Escrow(
            address(
                new ERC1967Proxy(
                    escrowImpl,
                    abi.encodeCall(
                        X402Escrow.initialize,
                        (
                            IX402Config(address(config)),
                            IX402StakeView(address(stake)),
                            IERC20(RH_TESTNET_USDG),
                            CANONICAL_PERMIT2
                        )
                    )
                )
            )
        );
    }

    /// Runbook §5's wiring block, and `verify-deployment.sh`'s `cast call` comparisons.
    function test_theWiringMatchesWhatVerifyDeploymentWillCheck() public view {
        assertEq(address(escrow.CONFIG()), address(config), "escrow.CONFIG");
        assertEq(address(stake.CONFIG()), address(config), "stake.CONFIG");
        assertEq(address(escrow.STAKE()), address(stake), "escrow.STAKE");
        assertEq(address(escrow.ASSET()), RH_TESTNET_USDG, "escrow.ASSET");
        assertEq(address(stake.ASSET()), RH_TESTNET_USDG, "stake.ASSET");
        assertEq(escrow.PERMIT2(), CANONICAL_PERMIT2, "escrow.PERMIT2");
        assertEq(config.admin(), ADMIN, "config.admin");
        assertFalse(config.paused(), "a fresh deployment must not be paused");
    }

    /// Runbook §7's post-check 1, and the reason `verify-deployment.sh` reads the slot at all.
    function test_eachProxyPointsAtTheImplementationTheRecordWouldName() public view {
        assertEq(address(uint160(uint256(vm.load(address(config), IMPL_SLOT)))), configImpl);
        assertEq(address(uint160(uint256(vm.load(address(stake), IMPL_SLOT)))), stakeImpl);
        assertEq(address(uint160(uint256(vm.load(address(escrow), IMPL_SLOT)))), escrowImpl);
    }

    /// The domain separators go in the record, and they are read FROM THE PROXIES — the only
    /// reading that means anything, because the proxy is the `verifyingContract` a voucher names.
    function test_theDomainSeparatorsAreReadFromTheProxiesAndDiffer() public view {
        bytes32 e = escrow.DOMAIN_SEPARATOR();
        bytes32 s = stake.DOMAIN_SEPARATOR();
        assertTrue(e != bytes32(0) && s != bytes32(0));
        assertTrue(
            e != s, "the two contracts share a domain; only verifyingContract separates them"
        );
    }

    /// The implementations must be unusable on their own. `initialize` on a bare implementation
    /// is how a proxy-based system gets taken over, and OZ's `_disableInitializers` is what stops
    /// it — asserted here rather than assumed from the base class.
    ///
    /// The revert is expected **by selector**, not with a bare `vm.expectRevert()`. A bare one is
    /// satisfied by any revert at all — including one from a mis-encoded `ParamSet` — so it would
    /// pass for a reason that has nothing to do with the guard it names.
    function test_theImplementationsCannotBeInitialised() public {
        ParamSet memory p = config.params();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        X402Config(configImpl).initialize(p, address(0xB0B));
    }

    /// The money path, end to end, against the real token: deposit, then the buyer's own exit.
    /// This is what a dry run cannot tell you and what `MockUSDG` cannot tell you either.
    function test_aRealDepositAndTheBuyersOwnExitBothWork() public {
        address b = address(0xB0FFE1);
        _dealMore(RH_TESTNET_USDG, b, 50_000_000);
        vm.startPrank(b);
        IERC20(RH_TESTNET_USDG).approve(address(escrow), type(uint256).max);
        uint256 g = gasleft();
        escrow.deposit(10_000_000);
        emit log_named_uint("real USDG deposit gas", g - gasleft());
        escrow.requestWithdraw(10_000_000);
        vm.warp(block.timestamp + 3_601); // WITHDRAW_DELAY_SECONDS = 3600
        escrow.withdraw();
        vm.stopPrank();
        assertEq(IERC20(RH_TESTNET_USDG).balanceOf(address(escrow)), 0);
        assertEq(IERC20(RH_TESTNET_USDG).balanceOf(b), 50_000_000);
    }
}
