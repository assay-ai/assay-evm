// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {X402Config} from "../src/X402Config.sol";
import {X402Stake} from "../src/X402Stake.sol";
import {X402Escrow} from "../src/X402Escrow.sol";
import {IERC20Decimals} from "../src/interfaces/IERC20Decimals.sol";
import {ParamSet} from "../src/Types.sol";

/// Script-local errors — see `Deploy.s.sol`'s note. No revert strings anywhere, `require`
/// included.
error StakeConfigMismatch();
error EscrowConfigMismatch();
error EscrowStakeMismatch();
error TheTwoVaultsDisagreeOnTheAsset();
error AssetDecimalsAreNotSix();

/// The same assertions `script/verify-deployment.sh` makes, from inside the EVM.
///
/// **Both exist, and neither replaces the other.** The shell version is the one CI and an operator
/// run: it needs nothing but `cast` and `jq`, it works against a chain this repo has never
/// compiled for, and its failures name a field. This one is a `forge script --rpc-url` and adds
/// what a shell cannot cheaply do: it decodes `params()` into the actual `ParamSet` struct and
/// prints every field, so the post-deploy step of the runbook (§6) that says "confirm `params()`
/// matches the record" is a reading rather than ten `cast call`s and a squint.
///
/// Run WITHOUT `--broadcast`. It sends nothing and it is not gated on anything.
///
/// ```sh
/// PROXY_CONFIG=0x… PROXY_STAKE=0x… PROXY_ESCROW=0x… \
///   forge script script/VerifyDeployment.s.sol --rpc-url <rpc>
/// ```
contract VerifyDeployment is Script {
    /// keccak256("eip1967.proxy.implementation") - 1. The same constant as in `Deploy.s.sol`,
    /// `verify-deployment.sh` and the runbook — four places, one value.
    bytes32 internal constant IMPL_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function run() external view {
        X402Config config = X402Config(vm.envAddress("PROXY_CONFIG"));
        X402Stake stake = X402Stake(vm.envAddress("PROXY_STAKE"));
        X402Escrow escrow = X402Escrow(vm.envAddress("PROXY_ESCROW"));

        console2.log("chainId               ", block.chainid);

        // The wiring, read back through the proxies.
        if (address(stake.CONFIG()) != address(config)) revert StakeConfigMismatch();
        if (address(escrow.CONFIG()) != address(config)) revert EscrowConfigMismatch();
        if (address(escrow.STAKE()) != address(stake)) revert EscrowStakeMismatch();
        if (address(escrow.ASSET()) != address(stake.ASSET())) {
            revert TheTwoVaultsDisagreeOnTheAsset();
        }
        if (IERC20Decimals(address(escrow.ASSET())).decimals() != 6) {
            revert AssetDecimalsAreNotSix();
        }

        // The implementation each proxy currently points at. This is the field an UPGRADE changes,
        // and the only one that tells an operator whether an upgrade they did not perform has
        // happened. `verify-deployment.sh` compares it to the record; here it is printed.
        console2.log("X402Config  impl (live)", _implOf(address(config)));
        console2.log("X402Stake   impl (live)", _implOf(address(stake)));
        console2.log("X402Escrow  impl (live)", _implOf(address(escrow)));

        console2.log("admin                 ", config.admin());
        console2.log("paused                ", config.paused());

        ParamSet memory p = config.params();
        console2.log("treasury              ", p.treasury);
        console2.log("redeemer              ", p.redeemer);
        console2.log("unbondingPeriodSeconds", p.unbondingPeriodSeconds);
        console2.log("minimumStake          ", p.minimumStake);
        console2.log("penaltyAmount         ", p.penaltyAmount);
        console2.log("verifierDailyCap      ", p.verifierDailyCap);
        console2.log("takeRateBps           ", p.takeRateBps);
        console2.log("slashAgentBps         ", p.slashAgentBps);
        console2.log("slashPlatformBps      ", p.slashPlatformBps);
        console2.log("slashCapBps           ", p.slashCapBps);

        console2.log("escrow domainSep (proxy)");
        console2.logBytes32(escrow.DOMAIN_SEPARATOR());
        console2.log("stake domainSep  (proxy)");
        console2.logBytes32(stake.DOMAIN_SEPARATOR());
        console2.log("totalEscrowed         ", escrow.totalEscrowed());
        console2.log("totalStaked           ", stake.totalStaked());
    }

    function _implOf(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, IMPL_SLOT))));
    }
}
