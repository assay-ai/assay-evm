// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {X402Config} from "../src/X402Config.sol";
import {X402Escrow} from "../src/X402Escrow.sol";
import {X402Stake} from "../src/X402Stake.sol";
import {ParamSet} from "../src/Types.sol";

error UnexpectedChain(uint256 got, uint256 want);
error NotTheAdmin(address broadcaster, address admin);
error AlreadyMigrated(address owner);
error WiringMismatch();
error ImplementationSlotMismatch(address proxy);
error OwnerNotSet(address owner, address wanted);
error PendingOwnerNotSet(address pending, address wanted);
error DomainSeparatorMoved(address proxy);
error SampleMoved(address proxy);
error StateMoved(string what);

/// **The D-17 / D-18 upgrade of all three proxies, in the one order that works** (runbook §7.4).
///
/// While the deployed implementations are live, the upgrade authority of all three is
/// `CONFIG.admin()`. So this script is signed by the CURRENT ADMIN, and it:
///
///   1. deploys the three new implementations (from `DEPLOYER_ADDRESS` when set — the deployer
///      key then holds no role at all — else from the admin);
///   2. upgrades `X402Config` FIRST, with `initializeV2()` inside the same `upgradeToAndCall`, so
///      `owner()` exists and equals the admin in that transaction (no window where it is unset);
///   3. upgrades `X402Stake` and `X402Escrow` — their OLD implementations still check
///      `CONFIG.admin()`, which is still this broadcaster; the NEW ones check `CONFIG.owner()`;
///   4. when `NEW_OWNER` is set, PROPOSES the ownership to it (`transferOwnership`). Nothing
///      moves until the new owner itself calls `acceptOwnership()` — a separate transaction
///      signed by the cold key (runbook §7.4, step 5).
///
/// It refuses before broadcasting anything when the chain is wrong, the broadcaster is not the
/// admin, or the config is already migrated. Afterwards it asserts what an upgrade must never
/// change: both EIP-712 domain separators, the wiring, the totals, the parameter set, the pause
/// flag, a sampled buyer's escrow and a sampled provider's stake (byte for byte), and that the
/// three implementation slots name the new code.
///
/// Env:
///   PROXY_CONFIG, PROXY_STAKE, PROXY_ESCROW   the three proxies
///   EXPECTED_CHAIN_ID                          refuse any other chain (46630 for the testnet)
///   SAMPLE_BUYER, SAMPLE_PROVIDER              compared byte for byte before and after
///   DEPLOYER_ADDRESS   (optional)              the key that deploys the implementations
///   NEW_OWNER          (optional)              propose the ownership to this key at the end
///
/// The storage-layout gate (`script/check-layout-branch.sh` against each deployed commit) and an
/// anvil-fork rehearsal (`testnet/rehearse-owner-split.sh`) must be green before this broadcasts.
contract UpgradeOwnerSplit is Script {
    bytes32 internal constant IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    struct Snapshot {
        bytes32 escrowDomain;
        bytes32 stakeDomain;
        bytes sampleEscrow;
        bytes sampleStake;
        uint128 totalEscrowed;
        uint128 totalStaked;
        bytes params;
        bool paused;
        address admin;
    }

    function run() external returns (address configImpl, address stakeImpl, address escrowImpl) {
        X402Config config = X402Config(vm.envAddress("PROXY_CONFIG"));
        X402Stake stake = X402Stake(vm.envAddress("PROXY_STAKE"));
        X402Escrow escrow = X402Escrow(vm.envAddress("PROXY_ESCROW"));
        uint256 wantChain = vm.envUint("EXPECTED_CHAIN_ID");
        address sampleBuyer = vm.envAddress("SAMPLE_BUYER");
        address sampleProvider = vm.envAddress("SAMPLE_PROVIDER");
        address newOwner = vm.envOr("NEW_OWNER", address(0));

        if (block.chainid != wantChain) revert UnexpectedChain(block.chainid, wantChain);
        address admin = config.admin();
        (, address broadcaster,) = vm.readCallers();
        if (broadcaster != admin) revert NotTheAdmin(broadcaster, admin);
        address deployer = vm.envOr("DEPLOYER_ADDRESS", admin);
        // `owner()` does not exist on the version-1 implementation, so a call that SUCCEEDS
        // means this proxy was already migrated.
        (bool hasOwner, bytes memory ret) =
            address(config).staticcall(abi.encodeWithSignature("owner()"));
        if (hasOwner && ret.length == 32) revert AlreadyMigrated(abi.decode(ret, (address)));
        if (
            address(stake.CONFIG()) != address(config)
                || address(escrow.CONFIG()) != address(config)
                || address(escrow.STAKE()) != address(stake)
                || address(escrow.ASSET()) != address(stake.ASSET())
        ) revert WiringMismatch();

        Snapshot memory before = _snapshot(config, stake, escrow, sampleBuyer, sampleProvider);

        vm.startBroadcast(deployer);
        configImpl = address(new X402Config());
        stakeImpl = address(new X402Stake());
        escrowImpl = address(new X402Escrow());
        vm.stopBroadcast();

        vm.startBroadcast(admin);
        config.upgradeToAndCall(configImpl, abi.encodeCall(X402Config.initializeV2, ()));
        stake.upgradeToAndCall(stakeImpl, "");
        escrow.upgradeToAndCall(escrowImpl, "");
        if (newOwner != address(0)) config.transferOwnership(newOwner);
        vm.stopBroadcast();

        // --- post-checks ------------------------------------------------------------------
        _assertImpl(address(config), configImpl);
        _assertImpl(address(stake), stakeImpl);
        _assertImpl(address(escrow), escrowImpl);
        if (config.owner() != admin) revert OwnerNotSet(config.owner(), admin);
        if (config.pendingOwner() != newOwner) {
            revert PendingOwnerNotSet(config.pendingOwner(), newOwner);
        }

        Snapshot memory afterUpgrade = _snapshot(config, stake, escrow, sampleBuyer, sampleProvider);
        if (afterUpgrade.escrowDomain != before.escrowDomain) {
            revert DomainSeparatorMoved(address(escrow));
        }
        if (afterUpgrade.stakeDomain != before.stakeDomain) {
            revert DomainSeparatorMoved(address(stake));
        }
        if (keccak256(afterUpgrade.sampleEscrow) != keccak256(before.sampleEscrow)) {
            revert SampleMoved(address(escrow));
        }
        if (keccak256(afterUpgrade.sampleStake) != keccak256(before.sampleStake)) {
            revert SampleMoved(address(stake));
        }
        if (afterUpgrade.totalEscrowed != before.totalEscrowed) revert StateMoved("totalEscrowed");
        if (afterUpgrade.totalStaked != before.totalStaked) revert StateMoved("totalStaked");
        if (keccak256(afterUpgrade.params) != keccak256(before.params)) revert StateMoved("params");
        if (afterUpgrade.paused != before.paused) revert StateMoved("paused");
        if (afterUpgrade.admin != before.admin) revert StateMoved("admin");

        console2.log("chainId                  ", block.chainid);
        console2.log("deployer (no role)       ", deployer);
        console2.log("admin = owner (migrated) ", admin);
        console2.log("pending owner            ", newOwner);
        console2.log("X402Config  implementation", configImpl);
        console2.log("X402Stake   implementation", stakeImpl);
        console2.log("X402Escrow  implementation", escrowImpl);
        console2.log("escrow domain separator (unchanged)");
        console2.logBytes32(afterUpgrade.escrowDomain);
        console2.log("stake domain separator (unchanged)");
        console2.logBytes32(afterUpgrade.stakeDomain);
    }

    function _snapshot(
        X402Config config,
        X402Stake stake,
        X402Escrow escrow,
        address sampleBuyer,
        address sampleProvider
    ) internal view returns (Snapshot memory s) {
        s.escrowDomain = escrow.DOMAIN_SEPARATOR();
        s.stakeDomain = stake.DOMAIN_SEPARATOR();
        s.sampleEscrow = abi.encode(escrow.escrowOf(sampleBuyer));
        s.sampleStake = abi.encode(stake.stakeOf(sampleProvider));
        s.totalEscrowed = escrow.totalEscrowed();
        s.totalStaked = stake.totalStaked();
        ParamSet memory p = config.params();
        s.params = abi.encode(p);
        s.paused = config.paused();
        s.admin = config.admin();
    }

    function _assertImpl(address proxy, address impl) internal view {
        if (address(uint160(uint256(vm.load(proxy, IMPLEMENTATION_SLOT)))) != impl) {
            revert ImplementationSlotMismatch(proxy);
        }
    }
}
