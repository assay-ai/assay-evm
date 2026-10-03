// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {X402Config} from "../src/X402Config.sol";
import {X402Stake} from "../src/X402Stake.sol";
import {X402Escrow} from "../src/X402Escrow.sol";
import {IX402Config} from "../src/interfaces/IX402Config.sol";
import {IX402StakeView} from "../src/interfaces/IX402StakeView.sol";
import {IERC20Decimals} from "../src/interfaces/IERC20Decimals.sol";
import {ParamSet} from "../src/Types.sol";

/// Script-local errors. **The repo rule is that there are no revert strings anywhere, `require`
/// included, and it applies here too** — an earlier draft spelled these as
/// `require(cond, "stake config mismatch")` and the global constraint wins. Nothing below is ever
/// deployed, so the usual bytecode argument does not apply; the argument that does is that a rule
/// enforceable by `grep` stops being enforceable the moment one file is exempt, and a reader who
/// meets a revert string in `script/` learns the wrong default.
///
/// They are declared HERE rather than in `src/Errors.sol` on purpose: `script/check-errors.sh`
/// accounts `src/Errors.sol` against the Anchor `error.rs`, and a deploy-script condition has no
/// Anchor counterpart and would show up for ever as an unexplained EVM-only entry.
error AssetIsTheZeroAddress();
error AssetHasNoCodeOnThisChain();
error AssetDecimalsAreNotSix();
error AssetIsTheTestnetUsdgAddress();
error StakeConfigMismatch();
error EscrowConfigMismatch();
error EscrowStakeMismatch();
error AssetMismatch();
error AdminMismatch();
error DeployedPaused();
error ImplementationSlotMismatch();

/// The deployment, and nothing else. **No agent runs this.** `--broadcast` against 4663 or 46630
/// is a human action, gated on the audit for mainnet, and `docs/deploy-runbook.md` is the
/// procedure.
///
/// # The shape, and why each part of it is not negotiable
///
/// **Each contract is deployed twice over — the implementation plainly, then an `ERC1967Proxy` in
/// front of it whose constructor data is `abi.encodeCall(X.initialize, (…))`.** The proxy is
/// therefore initialised in the transaction that creates it, and there is no block in which a
/// live, uninitialised proxy sits waiting for somebody's `initialize`. **A split
/// deploy-then-initialise script is forbidden here.** `initialize` cannot defend itself against
/// front-running — whoever lands first becomes the admin of `X402Config`, and through it the
/// upgrade authority of all three — and a half-guard in the contract (an `onlyDeployer` check, a
/// stored expected caller) would read as if it could. The atomic form removes the window instead
/// of policing it.
///
/// **The CREATE2 salt is on the PROXY** (D-7). The proxy is the address everything names — the
/// backend's config, a voucher's `verifyingContract`, the explorer link — and it is the address
/// that must survive every upgrade, so it is the one that has to be derivable. Implementation
/// addresses are recorded, never derived; an upgrade changes them by design.
///
/// **The salt is a pure function of the chain id**, so mainnet and testnet land on DIFFERENT
/// addresses. A backend pointed at the wrong RPC then gets "no code at address" instead of a live
/// contract that answers plausibly — which is the failure that costs a day.
contract Deploy is Script {
    /// Robinhood Chain mainnet. Named because the mainnet-only refusal below turns on it.
    uint256 internal constant MAINNET_CHAIN_ID = 4663;

    function _salt(string memory name) internal view returns (bytes32) {
        return keccak256(abi.encodePacked("x402:", name, ":v2:", block.chainid));
    }

    function run() external {
        address asset = vm.envAddress("USDG_ADDRESS");
        address permit2 = vm.envAddress("PERMIT2_ADDRESS");
        address admin = vm.envAddress("ADMIN_ADDRESS");

        _assertTheAssetIsReal(asset);

        ParamSet memory p = ParamSet({
            treasury: vm.envAddress("TREASURY_ADDRESS"),
            redeemer: vm.envAddress("REDEEMER_ADDRESS"),
            unbondingPeriodSeconds: uint64(vm.envUint("UNBONDING_PERIOD_SECONDS")),
            minimumStake: uint64(vm.envUint("MINIMUM_STAKE")),
            penaltyAmount: uint64(vm.envUint("PENALTY_AMOUNT")),
            verifierDailyCap: uint64(vm.envUint("VERIFIER_DAILY_CAP")),
            takeRateBps: uint16(vm.envUint("TAKE_RATE_BPS")),
            slashAgentBps: uint16(vm.envUint("SLASH_AGENT_BPS")),
            slashPlatformBps: uint16(vm.envUint("SLASH_PLATFORM_BPS")),
            slashCapBps: uint16(vm.envUint("SLASH_CAP_BPS"))
        });

        vm.startBroadcast();

        address configImpl = address(new X402Config());
        X402Config config = X402Config(
            address(
                new ERC1967Proxy{salt: _salt("Config")}(
                    configImpl, abi.encodeCall(X402Config.initialize, (p, admin))
                )
            )
        );

        address stakeImpl = address(new X402Stake());
        X402Stake stake = X402Stake(
            address(
                new ERC1967Proxy{salt: _salt("Stake")}(
                    stakeImpl,
                    abi.encodeCall(
                        X402Stake.initialize, (IX402Config(address(config)), IERC20(asset))
                    )
                )
            )
        );

        address escrowImpl = address(new X402Escrow());
        X402Escrow escrow = X402Escrow(
            address(
                new ERC1967Proxy{salt: _salt("Escrow")}(
                    escrowImpl,
                    abi.encodeCall(
                        X402Escrow.initialize,
                        (
                            IX402Config(address(config)),
                            IX402StakeView(address(stake)),
                            IERC20(asset),
                            permit2
                        )
                    )
                )
            )
        );
        vm.stopBroadcast();

        // Post-checks, read back THROUGH THE PROXIES — the only way the backend will ever read
        // them, so the only reading worth asserting.
        if (address(stake.CONFIG()) != address(config)) revert StakeConfigMismatch();
        if (address(escrow.CONFIG()) != address(config)) revert EscrowConfigMismatch();
        if (address(escrow.STAKE()) != address(stake)) revert EscrowStakeMismatch();
        if (address(escrow.ASSET()) != asset || address(stake.ASSET()) != asset) {
            revert AssetMismatch();
        }
        if (config.admin() != admin) revert AdminMismatch();
        if (config.paused()) revert DeployedPaused();

        // And the ERC-1967 implementation slot of each proxy names the implementation this script
        // just deployed. `deployments/<chainId>.json` records all six addresses.
        bytes32 SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
        if (address(uint160(uint256(vm.load(address(config), SLOT)))) != configImpl) {
            revert ImplementationSlotMismatch();
        }
        if (address(uint160(uint256(vm.load(address(stake), SLOT)))) != stakeImpl) {
            revert ImplementationSlotMismatch();
        }
        if (address(uint160(uint256(vm.load(address(escrow), SLOT)))) != escrowImpl) {
            revert ImplementationSlotMismatch();
        }

        console2.log("chainId               ", block.chainid);
        console2.log("X402Config  proxy     ", address(config));
        console2.log("X402Config  impl      ", configImpl);
        console2.log("X402Stake   proxy     ", address(stake));
        console2.log("X402Stake   impl      ", stakeImpl);
        console2.log("X402Escrow  proxy     ", address(escrow));
        console2.log("X402Escrow  impl      ", escrowImpl);
        console2.log("asset                 ", asset);
        console2.log("permit2               ", permit2);
        console2.log("escrow domainSep (proxy)");
        console2.logBytes32(escrow.DOMAIN_SEPARATOR());
        console2.log("stake domainSep  (proxy)");
        console2.logBytes32(stake.DOMAIN_SEPARATOR());
        console2.log("Config salt");
        console2.logBytes32(_salt("Config"));
        console2.log("Stake salt");
        console2.logBytes32(_salt("Stake"));
        console2.log("Escrow salt");
        console2.logBytes32(_salt("Escrow"));
    }

    /// **The mainnet USDG refusal, in the one place that cannot be skipped.**
    ///
    /// `docs/chain-facts.md` §1 measured that mainnet USDG is **not** at the testnet address:
    /// `cast code 0x915Ef7…03ec` on 4663 returns `0x`, while the same call on 46630 returns
    /// 11,306 characters of code — so the probe works and the answer is a real absence. The
    /// mainnet address is an **operator-supplied input**, not something this repo can derive, and
    /// the failure it guards against is an operator pasting the testnet address into a mainnet
    /// deploy.
    ///
    /// `X402Escrow.initialize` already refuses an asset whose `decimals()` is not 6, but a call to
    /// an address with no code does not revert on EVM — it returns empty, and the ABI decoder is
    /// what fails, with a message about decoding rather than about the address. The explicit
    /// `code.length` check is here so the refusal names what is actually wrong.
    function _assertTheAssetIsReal(address asset) internal view {
        if (asset == address(0)) revert AssetIsTheZeroAddress();
        // Wrong network, almost always. `code.length` before `decimals()` so the refusal names
        // what is actually wrong.
        if (asset.code.length == 0) revert AssetHasNoCodeOnThisChain();
        if (IERC20Decimals(asset).decimals() != 6) revert AssetDecimalsAreNotSix();
        // The testnet USDG address, refused by value on mainnet. There is no code at it on 4663,
        // so the check above would already catch it — this one exists so the diagnosis is
        // "you pasted the testnet address" rather than "wrong network", which is a different fix.
        if (
            block.chainid == MAINNET_CHAIN_ID && asset == 0x915Ef7c9F9f80a69e3BE47A38EE0Bb47607103ec
        ) {
            revert AssetIsTheTestnetUsdgAddress();
        }
    }
}
