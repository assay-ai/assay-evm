// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {AssayConfig} from "../src/AssayConfig.sol";
import {AssayStake} from "../src/AssayStake.sol";
import {AssayEscrow} from "../src/AssayEscrow.sol";
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
        AssayConfig config = AssayConfig(vm.envAddress("PROXY_CONFIG"));
        AssayStake stake = AssayStake(vm.envAddress("PROXY_STAKE"));
        AssayEscrow escrow = AssayEscrow(vm.envAddress("PROXY_ESCROW"));

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
        console2.log("AssayConfig  impl (live)", _implOf(address(config)));
        console2.log("AssayStake   impl (live)", _implOf(address(stake)));
        console2.log("AssayEscrow  impl (live)", _implOf(address(escrow)));

        // `owner()` exists only after the D-17 upgrade; a version-1 config logs address(0).
        console2.log("owner                 ", _addrOrZero(address(config), "owner()"));
        console2.log("pending owner         ", _addrOrZero(address(config), "pendingOwner()"));
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

    function _addrOrZero(address target, string memory sig) internal view returns (address) {
        (bool ok, bytes memory ret) = target.staticcall(abi.encodeWithSignature(sig));
        return ok && ret.length == 32 ? abi.decode(ret, (address)) : address(0);
    }
}
