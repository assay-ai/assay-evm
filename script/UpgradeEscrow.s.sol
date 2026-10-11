// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {X402Escrow} from "../src/X402Escrow.sol";
import {IX402Config} from "../src/interfaces/IX402Config.sol";

error NotTheAdmin(address broadcaster, address admin);
error UnexpectedChain(uint256 got, uint256 want);
error DomainSeparatorMoved(bytes32 before, bytes32 afterUpgrade);
error WiringMoved();
error SampledEscrowMoved();
error ImplementationSlotMismatch();
error DelegationSurfaceMissing();

/// Upgrades the X402Escrow PROXY in place to an implementation built from this tree — the
/// agent-delegation upgrade (runbook §7). It deploys the new implementation and calls
/// `upgradeToAndCall(newImpl, 0x)` from the broadcaster, which must be `CONFIG.admin()`.
///
/// It refuses to proceed, before anything is broadcast, when the broadcaster is not the admin
/// or the chain is not `EXPECTED_CHAIN_ID`. After the upgrade it asserts, through the proxy, the
/// runbook's post-checks it can make by itself: the ERC-1967 slot names the new implementation,
/// the EIP-712 domain separator is UNCHANGED (or every outstanding voucher would be dead),
/// `CONFIG`/`STAKE`/`ASSET`/`PERMIT2` are unchanged, a sampled buyer's escrow is unchanged field
/// for field, and the new delegation views answer.
///
/// Env:
///   PROXY_ESCROW       the X402Escrow proxy
///   EXPECTED_CHAIN_ID  refuse any other chain (46630 for Robinhood testnet)
///   SAMPLE_BUYER       a funded buyer whose escrow is compared before and after
///
/// The storage layout gate (`script/check-layout.sh`, `script/check-layout-branch.sh` against
/// the deployed commit) must be green before this runs; this script does not re-derive it.
contract UpgradeEscrow is Script {
    bytes32 internal constant IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function run() external returns (address newImpl) {
        X402Escrow escrow = X402Escrow(vm.envAddress("PROXY_ESCROW"));
        uint256 wantChain = vm.envUint("EXPECTED_CHAIN_ID");
        address sample = vm.envAddress("SAMPLE_BUYER");
        if (block.chainid != wantChain) revert UnexpectedChain(block.chainid, wantChain);

        address admin = IX402Config(address(escrow.CONFIG())).admin();
        (, address broadcaster,) = vm.readCallers();
        if (broadcaster != admin) revert NotTheAdmin(broadcaster, admin);

        bytes32 domainBefore = escrow.DOMAIN_SEPARATOR();
        address configBefore = address(escrow.CONFIG());
        address stakeBefore = address(escrow.STAKE());
        address assetBefore = address(escrow.ASSET());
        address permit2Before = escrow.PERMIT2();
        uint128 totalBefore = escrow.totalEscrowed();
        bytes memory sampleBefore = abi.encode(escrow.escrowOf(sample));
        address implBefore =
            address(uint160(uint256(vm.load(address(escrow), IMPLEMENTATION_SLOT))));

        vm.startBroadcast();
        newImpl = address(new X402Escrow());
        escrow.upgradeToAndCall(newImpl, "");
        vm.stopBroadcast();

        if (address(uint160(uint256(vm.load(address(escrow), IMPLEMENTATION_SLOT)))) != newImpl) {
            revert ImplementationSlotMismatch();
        }
        bytes32 domainAfter = escrow.DOMAIN_SEPARATOR();
        if (domainAfter != domainBefore) revert DomainSeparatorMoved(domainBefore, domainAfter);
        if (
            address(escrow.CONFIG()) != configBefore || address(escrow.STAKE()) != stakeBefore
                || address(escrow.ASSET()) != assetBefore || escrow.PERMIT2() != permit2Before
                || escrow.totalEscrowed() != totalBefore
        ) revert WiringMoved();
        if (keccak256(abi.encode(escrow.escrowOf(sample))) != keccak256(sampleBefore)) {
            revert SampledEscrowMoved();
        }
        // The new surface answers, on the upgraded proxy, for an account with no delegates.
        if (escrow.delegatesOf(sample).length > 16) revert DelegationSurfaceMissing();
        if (escrow.delegationOf(sample, address(0xdead)).validUntil != 0) {
            revert DelegationSurfaceMissing();
        }

        console2.log("chainId                 ", block.chainid);
        console2.log("X402Escrow proxy        ", address(escrow));
        console2.log("implementation before   ", implBefore);
        console2.log("implementation after    ", newImpl);
        console2.log("domain separator (unchanged)");
        console2.logBytes32(domainAfter);
        console2.log("sampled buyer unchanged ", sample);
    }
}
