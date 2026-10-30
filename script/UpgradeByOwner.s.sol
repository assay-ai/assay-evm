// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.38;

import {ChannelDoorLink} from "./ChannelDoorLink.sol";
import {console2} from "forge-std/console2.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {AssayConfig} from "../src/AssayConfig.sol";
import {AssayEscrow} from "../src/AssayEscrow.sol";
import {AssayStake} from "../src/AssayStake.sol";
import {UnexpectedLinks, LinkedLibraryMismatch} from "./ChannelDoorLink.sol";

error UnexpectedChain(uint256 got, uint256 want);
error NotTheOwner(address broadcaster, address owner);
error NotAUupsImplementation(address impl);
error ImplementationCodehashMismatch(address impl, bytes32 got, bytes32 want);
error ImplementationSlotMismatch(address proxy);
error DomainSeparatorMoved(address proxy);
error SampleMoved(address proxy);
error StateMoved(string what);
error LibraryCodehashMismatch(address lib, bytes32 got, bytes32 want);

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
///   CHANNEL_DOOR, EXPECTED_CODEHASH_CHANNELDOOR   (run, safeCalldata; REQUIRED with
///                 UPGRADE_ESCROW) the `ChannelDoor` library the escrow implementation is linked
///                 against, and that library's `extcodehash`. The escrow DELEGATECALLs every
///                 channel door into it, so its code moves the escrow's money as much as the
///                 implementation's own; the escrow codehash pins the library ADDRESS (it is
///                 written into the bytecode), this pins the library CODE. Take the hash from the
///                 library `verify-deployment.sh` matched (`cast keccak $(cast code $CHANNEL_DOOR)`).
///
/// **Order.** The proxies are always upgraded Config, Stake, Escrow, in that order (`_plan`), so
/// a Stake or Escrow build that reads a new Config function lands after the Config that has it.
/// An upgrade that introduces such a cross-contract dependency adds its own probe here.
contract UpgradeByOwner is ChannelDoorLink {
    bytes32 internal constant IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function deploy() external {
        _chain();
        vm.startBroadcast();
        if (vm.envOr("UPGRADE_CONFIG", false)) {
            console2.log("IMPL_CONFIG=", address(new AssayConfig()));
        }
        if (vm.envOr("UPGRADE_STAKE", false)) {
            console2.log("IMPL_STAKE=", address(new AssayStake()));
        }
        if (vm.envOr("UPGRADE_ESCROW", false)) {
            address impl = address(new AssayEscrow());
            console2.log("IMPL_ESCROW=", impl);
            // forge deploys and links the library itself; the address is read back from the
            // implementation's code at the link offsets of this build.
            console2.log("CHANNEL_DOOR=", _linkedChannelDoor(impl));
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
        for (uint256 i = 0; i < 3; i++) {
            if (!on[i]) continue;
            _assertImplementation(impls[i], hashes[i]);
            if (i == 2) _assertChannelDoor(impls[i]);
            console2.log("to  ", proxies[i]);
            console2.logBytes(
                abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (impls[i], calls[i]))
            );
        }
    }

    function run() external {
        _chain();
        AssayConfig config = AssayConfig(vm.envAddress("PROXY_CONFIG"));
        AssayStake stake = AssayStake(vm.envAddress("PROXY_STAKE"));
        AssayEscrow escrow = AssayEscrow(vm.envAddress("PROXY_ESCROW"));
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
        for (uint256 i = 0; i < 3; i++) {
            if (on[i]) _assertImplementation(impls[i], hashes[i]);
        }
        if (on[2]) _assertChannelDoor(impls[2]);

        address sampleBuyer = vm.envAddress("SAMPLE_BUYER");
        address sampleProvider = vm.envAddress("SAMPLE_PROVIDER");
        // A deliberate domain rename passes the separators it must land on; otherwise none may move.
        bytes32 escrowDomain = vm.envOr("EXPECTED_ESCROW_DOMAIN", escrow.DOMAIN_SEPARATOR());
        bytes32 stakeDomain = vm.envOr("EXPECTED_STAKE_DOMAIN", stake.DOMAIN_SEPARATOR());
        bytes32 buyerBefore = keccak256(abi.encode(escrow.escrowOf(sampleBuyer)));
        bytes32 providerBefore = keccak256(abi.encode(stake.stakeOf(sampleProvider)));
        uint128 escrowedBefore = escrow.totalEscrowed();
        uint128 stakedBefore = stake.totalStaked();
        address adminBefore = config.admin();
        bytes32 paramsBefore = keccak256(abi.encode(config.params()));
        bool pausedBefore = config.paused();
        bytes32 channelsBefore = _channelTotals(escrow);

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
        if (_channelTotals(escrow) != channelsBefore) revert StateMoved("channel totals");
        // Printed for the record.
        console2.log("slashDelaySeconds", config.slashDelaySeconds());
        console2.log("arbiter", config.arbiter());
        console2.log("collectHoldSeconds", config.collectHoldSeconds());
        console2.log("totalHeld", escrow.totalHeld());
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

    /// The escrow implementation is linked to exactly one library, `ChannelDoor`, at
    /// `CHANNEL_DOOR`, and the code there is exactly the code the operator verified.
    function _assertChannelDoor(address impl) internal view {
        _assertChannelDoor(
            impl, vm.envAddress("CHANNEL_DOOR"), vm.envBytes32("EXPECTED_CODEHASH_CHANNELDOOR")
        );
    }

    function _assertChannelDoor(address impl, address door, bytes32 want) internal view {
        address got = _linkedChannelDoor(impl);
        if (got != door) revert LinkedLibraryMismatch(impl, got, door);
        if (door.codehash != want) revert LibraryCodehashMismatch(door, door.codehash, want);
        // A deployed library holds its own address (the call guard that refuses a direct CALL
        // into a state-changing function) at the compiler's `library_deploy_address` spans;
        // code that names another address there was not deployed as this library here.
        string memory art = vm.readFile("out/ChannelDoor.sol/ChannelDoor.json");
        LinkRef[] memory refs = abi.decode(
            vm.parseJson(art, ".deployedBytecode.immutableReferences.library_deploy_address"),
            (LinkRef[])
        );
        bytes memory code = door.code;
        if (refs.length == 0) revert UnexpectedLinks(0);
        for (uint256 i = 0; i < refs.length; i++) {
            if (
                refs[i].length != 32 || refs[i].start + 32 > code.length
                    || _word(code, refs[i].start) != uint256(uint160(door))
            ) revert LinkedLibraryMismatch(impl, door, door);
        }
    }

    /// The channel door's set-aside and held totals; zero before the first build that has them.
    function _channelTotals(AssayEscrow escrow) internal view returns (bytes32) {
        try escrow.channelBooks(bytes32(0), address(0)) returns (
            uint256, uint128, uint128 totalUnpaid, uint128 held
        ) {
            return keccak256(abi.encode(totalUnpaid, held));
        } catch {
            return keccak256(abi.encode(uint128(0), uint128(0)));
        }
    }

    function _chain() internal view {
        uint256 want = vm.envUint("EXPECTED_CHAIN_ID");
        if (block.chainid != want) revert UnexpectedChain(block.chainid, want);
    }
}
