// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {X402Config} from "../src/X402Config.sol";
import {X402Escrow} from "../src/X402Escrow.sol";
import {X402Stake} from "../src/X402Stake.sol";

error UnexpectedChain(uint256 got, uint256 want);
error NotTheOwner(address broadcaster, address owner);
error NotAUupsImplementation(address impl);
error ImplementationCodehashMismatch(address impl, bytes32 got, bytes32 want);
error ImplementationSlotMismatch(address proxy);
error DomainSeparatorMoved(address proxy);
error SampleMoved(address proxy);
error StateMoved(string what);
error ConfigMustBeUpgradedFirst(address config);

/// **Every upgrade after D-17, signed by the OWNER** (runbook §7). Two phases, two keys:
///
///   `deploy()`  — broadcast by the DEPLOYER (a hot key with no role). Deploys a fresh
///                 implementation of each contract flagged `UPGRADE_<NAME>` and prints the addresses.
///                 Verify them (layout gate, `check-bytecode.sh`, an anvil rehearsal) BEFORE
///                 phase two; a deployed implementation is inert until a proxy points at it.
///   `run()`     — broadcast by the OWNER, `--ledger --sender $OWNER` (or any signer forge
///                 accepts). Upgrades each flagged proxy to `IMPL_<NAME>`, with optional
///                 initialiser calldata `CALL_<NAME>`, then re-asserts the invariants.
///   `safeCalldata()` — no broadcast. Prints `(to, data)` for each upgrade, for a Safe
///                 Transaction Builder proposal when the owner is a Safe.
///
/// Env:
///   PROXY_CONFIG, PROXY_STAKE, PROXY_ESCROW, EXPECTED_CHAIN_ID, SAMPLE_BUYER, SAMPLE_PROVIDER
///   UPGRADE_CONFIG / UPGRADE_STAKE / UPGRADE_ESCROW   `true` for each proxy to upgrade
///   IMPL_CONFIG / IMPL_STAKE / IMPL_ESCROW        (run, safeCalldata) the implementations
///   CALL_CONFIG / CALL_STAKE / CALL_ESCROW        (optional) `upgradeToAndCall` data, default 0x
///   EXPECTED_CODEHASH_CONFIG / _STAKE / _ESCROW   (run, safeCalldata; REQUIRED for each flagged
///                 proxy) the `extcodehash` of `IMPL_<NAME>`. Take it from the implementation
///                 that `check-bytecode.sh` / `verify-deployment.sh` matched against the local
///                 build (`cast keccak $(cast code $IMPL_<NAME>)`), so the owner signs for exactly
///                 the code that was verified and not for whatever address ended up in the env.
///
/// **Order (the dispute upgrade, runbook §7.5).** The proxies are always upgraded Config, Stake,
/// Escrow, in that order. The Stake and Escrow built since the dispute upgrade call
/// `CONFIG.assertActive`, `CONFIG.slashDelaySeconds` and `CONFIG.arbiter`; upgrading either
/// behind a Config that lacks them would brick their deposit, exit and slash doors. Both entry
/// points refuse (`ConfigMustBeUpgradedFirst`) a Stake or Escrow upgrade unless Config is
/// flagged too or the live Config already answers `slashDelaySeconds()`.
contract UpgradeByOwner is Script {
    bytes32 internal constant IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function deploy() external {
        _chain();
        vm.startBroadcast();
        if (vm.envOr("UPGRADE_CONFIG", false)) {
            console2.log("IMPL_CONFIG=", address(new X402Config()));
        }
        if (vm.envOr("UPGRADE_STAKE", false)) console2.log("IMPL_STAKE=", address(new X402Stake()));
        if (vm.envOr("UPGRADE_ESCROW", false)) {
            console2.log("IMPL_ESCROW=", address(new X402Escrow()));
        }
        vm.stopBroadcast();
    }

    function safeCalldata() external view {
        _chain();
        (
            address[3] memory proxies,
            address[3] memory impls,
            bytes[3] memory calls,
            bool[3] memory on,
            bytes32[3] memory hashes
        ) = _plan();
        _assertOrder(proxies[0], on);
        for (uint256 i = 0; i < 3; i++) {
            if (!on[i]) continue;
            _assertImplementation(impls[i], hashes[i]);
            console2.log("to  ", proxies[i]);
            console2.logBytes(
                abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (impls[i], calls[i]))
            );
        }
    }

    function run() external {
        _chain();
        X402Config config = X402Config(vm.envAddress("PROXY_CONFIG"));
        X402Stake stake = X402Stake(vm.envAddress("PROXY_STAKE"));
        X402Escrow escrow = X402Escrow(vm.envAddress("PROXY_ESCROW"));
        address owner = config.owner();
        (, address broadcaster,) = vm.readCallers();
        if (broadcaster != owner) revert NotTheOwner(broadcaster, owner);

        (
            address[3] memory proxies,
            address[3] memory impls,
            bytes[3] memory calls,
            bool[3] memory on,
            bytes32[3] memory hashes
        ) = _plan();
        _assertOrder(proxies[0], on);
        for (uint256 i = 0; i < 3; i++) {
            if (on[i]) _assertImplementation(impls[i], hashes[i]);
        }

        address sampleBuyer = vm.envAddress("SAMPLE_BUYER");
        address sampleProvider = vm.envAddress("SAMPLE_PROVIDER");
        bytes32 escrowDomain = escrow.DOMAIN_SEPARATOR();
        bytes32 stakeDomain = stake.DOMAIN_SEPARATOR();
        bytes32 buyerBefore = keccak256(abi.encode(escrow.escrowOf(sampleBuyer)));
        bytes32 providerBefore = keccak256(abi.encode(stake.stakeOf(sampleProvider)));
        uint128 escrowedBefore = escrow.totalEscrowed();
        uint128 stakedBefore = stake.totalStaked();
        address adminBefore = config.admin();
        bytes32 paramsBefore = keccak256(abi.encode(config.params()));
        bool pausedBefore = config.paused();

        vm.startBroadcast(owner);
        for (uint256 i = 0; i < 3; i++) {
            if (on[i]) UUPSUpgradeable(proxies[i]).upgradeToAndCall(impls[i], calls[i]);
        }
        vm.stopBroadcast();

        for (uint256 i = 0; i < 3; i++) {
            if (!on[i]) continue;
            if (address(uint160(uint256(vm.load(proxies[i], IMPLEMENTATION_SLOT)))) != impls[i]) {
                revert ImplementationSlotMismatch(proxies[i]);
            }
            console2.log("upgraded", proxies[i], "->", impls[i]);
        }
        if (escrow.DOMAIN_SEPARATOR() != escrowDomain) revert DomainSeparatorMoved(address(escrow));
        if (stake.DOMAIN_SEPARATOR() != stakeDomain) revert DomainSeparatorMoved(address(stake));
        if (keccak256(abi.encode(escrow.escrowOf(sampleBuyer))) != buyerBefore) {
            revert SampleMoved(address(escrow));
        }
        if (keccak256(abi.encode(stake.stakeOf(sampleProvider))) != providerBefore) {
            revert SampleMoved(address(stake));
        }
        if (escrow.totalEscrowed() != escrowedBefore) revert StateMoved("totalEscrowed");
        if (stake.totalStaked() != stakedBefore) revert StateMoved("totalStaked");
        if (config.admin() != adminBefore) revert StateMoved("admin");
        if (config.owner() != owner) revert StateMoved("owner");
        if (keccak256(abi.encode(config.params())) != paramsBefore) revert StateMoved("params");
        if (config.paused() != pausedBefore) revert StateMoved("paused");
        // The dispute upgrade's appended Config state, printed for the record: on the first
        // upgrade past it these read 72 hours and address(0).
        console2.log("slashDelaySeconds", config.slashDelaySeconds());
        console2.log("arbiter", config.arbiter());
    }

    /// See the contract note. `slashDelaySeconds()` is the probe: it exists from the dispute
    /// upgrade on, and a Config without it lacks `assertActive` and `arbiter` too.
    function _assertOrder(address config, bool[3] memory on) internal view {
        if (on[0] || (!on[1] && !on[2])) return;
        (bool ok, bytes memory ret) =
            config.staticcall(abi.encodeWithSignature("slashDelaySeconds()"));
        if (!ok || ret.length != 32) revert ConfigMustBeUpgradedFirst(config);
    }

    function _plan()
        internal
        view
        returns (
            address[3] memory proxies,
            address[3] memory impls,
            bytes[3] memory calls,
            bool[3] memory on,
            bytes32[3] memory hashes
        )
    {
        string[3] memory names = ["CONFIG", "STAKE", "ESCROW"];
        for (uint256 i = 0; i < 3; i++) {
            proxies[i] = vm.envAddress(string.concat("PROXY_", names[i]));
            on[i] = vm.envOr(string.concat("UPGRADE_", names[i]), false);
            if (!on[i]) continue;
            impls[i] = vm.envAddress(string.concat("IMPL_", names[i]));
            calls[i] = vm.envOr(string.concat("CALL_", names[i]), bytes(""));
            hashes[i] = vm.envBytes32(string.concat("EXPECTED_CODEHASH_", names[i]));
        }
    }

    /// The implementation's runtime code is exactly the one the operator verified
    /// (`EXPECTED_CODEHASH_<NAME>`), and it is a UUPS implementation.
    function _assertImplementation(address impl, bytes32 want) internal view {
        if (impl.codehash != want) revert ImplementationCodehashMismatch(impl, impl.codehash, want);
        _assertUups(impl);
    }

    /// The implementation has code and answers `proxiableUUID()` with the ERC-1967 slot, which
    /// is exactly what `upgradeToAndCall` will check — refused here, before the owner signs.
    function _assertUups(address impl) internal view {
        if (impl.code.length == 0) revert NotAUupsImplementation(impl);
        (bool ok, bytes memory ret) = impl.staticcall(abi.encodeWithSignature("proxiableUUID()"));
        if (!ok || ret.length != 32 || abi.decode(ret, (bytes32)) != IMPLEMENTATION_SLOT) {
            revert NotAUupsImplementation(impl);
        }
    }

    function _chain() internal view {
        uint256 want = vm.envUint("EXPECTED_CHAIN_ID");
        if (block.chainid != want) revert UnexpectedChain(block.chainid, want);
    }
}
