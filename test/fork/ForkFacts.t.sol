// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.24;

import {ForkFixture} from "./ForkFixture.sol";

interface IProbe {
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
    function totalSupply() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function owner() external view returns (address);
    function transfer(address, uint256) external returns (bool);
}

/// What the chain actually holds, asserted against the chain.
///
/// Every claim here was a sentence in a document before it was a test, and two of them were
/// WRONG in the document: `docs/gas.md`, `docs/risk-register.md` and `MockUSDG.sol`'s header all
/// describe the 46630 token as "a Paxos proxy with a blocklist". It is neither.
contract ForkFactsTest is ForkFixture {
    function setUp() public {
        _selectForkOrSkip();
    }

    /// Identity, asserted with everything that is reachable under the repo's PINNED
    /// `evm_version = "shanghai"`.
    ///
    /// `symbol()` is deliberately NOT called here. It is unreachable on this fork — see
    /// `test_theTokensStringGettersAreUnreachableUnderTheShanghaiPin` below, which is where that
    /// finding lives. What is left is stronger than a string anyway: the token is not proxied
    /// (next test), so its runtime code cannot change, and a code hash pins the whole contract
    /// rather than one getter.
    function test_theTokenIsUsdgWithSixDecimals() public view {
        assertEq(IProbe(RH_TESTNET_USDG).decimals(), 6, "decimals");
        assertEq(RH_TESTNET_USDG.code.length, 5652, "runtime size");
        assertEq(keccak256(RH_TESTNET_USDG.code), TESTNET_USDG_RUNTIME_KECCAK, "runtime keccak");
    }

    /// **A finding, asserted so it cannot be forgotten.**
    ///
    /// The token deployed at 46630 carries exactly ONE post-Shanghai opcode — `MCOPY` (0x5E,
    /// EIP-5656, Cancun) at pc 4325, on the shared string-return helper that `name()` and
    /// `symbol()` both tail into. This repo pins `evm_version = "shanghai"` (foundry.toml), so
    /// the fork VM executes the real token under Shanghai rules and that one instruction is not
    /// activated: the call dies with `EvmError: NotActivated`, which surfaces to Solidity as a
    /// bare revert.
    ///
    /// **On chain both getters work.** `cast call … "symbol()(string)"` returns `"USDG"`, and
    /// the chain is ArbOS 116. The gap is between our compile target and the chain's, not in the
    /// token. See `docs/chain-facts.md` §1a.
    ///
    /// **The pin stays.** Shanghai is a subset of Cancun, so a Shanghai-compiled contract runs
    /// correctly on a Cancun chain; raising `evm_version` would change the bytecode of all three
    /// production contracts and is a decision no test may make on its own. The cost is that two
    /// VIEW functions of the settlement token cannot be read on a fork. `X402Escrow` and
    /// `X402Stake` touch only `decimals`, `balanceOf`, `approve`, `transfer` and `transferFrom`,
    /// none of which reach the MCOPY, so no money path is affected.
    ///
    /// This test goes RED the day the pin moves — which is the point. Delete it in the same
    /// change that raises `evm_version`, and re-assert `symbol() == "USDG"` there.
    function test_theTokensStringGettersAreUnreachableUnderTheShanghaiPin() public {
        (bool okSymbol,) = RH_TESTNET_USDG.staticcall(abi.encodeWithSignature("symbol()"));
        assertFalse(okSymbol, "symbol() executed: evm_version was raised, read this test's docs");
        (bool okName,) = RH_TESTNET_USDG.staticcall(abi.encodeWithSignature("name()"));
        assertFalse(okName, "name() executed: evm_version was raised, read this test's docs");
    }

    /// D-A.3's 1:1 USD peg mapping and the `uint64` amount width BOTH rest on this number. If it
    /// is ever not 6, the correct response is to re-open the spec, not to widen a type.
    function test_theTokenIsNotBehindAnEip1967Proxy() public view {
        bytes32 slot = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
        assertEq(vm.load(RH_TESTNET_USDG, slot), bytes32(0));
    }

    /// The claim this test exists to refute. Five spellings, all of which must be ABSENT.
    /// A `staticcall` to a selector the contract does not export hits the dispatcher's fallback
    /// and reverts, so `ok == false` IS the assertion.
    function test_theTokenHasNoBlocklistUnderAnySpellingWeKnow() public view {
        string[5] memory sigs = [
            "isBlocked(address)",
            "isFrozen(address)",
            "blocklist(address)",
            "isBlacklisted(address)",
            "frozen(address)"
        ];
        for (uint256 i = 0; i < sigs.length; i++) {
            (bool ok,) = RH_TESTNET_USDG.staticcall(abi.encodeWithSignature(sigs[i], address(0x1)));
            assertFalse(ok, sigs[i]);
        }
    }

    /// The positive control for the test above. Without it, a typo in every signature string
    /// would make that test pass while proving nothing — the exact shape this project keeps
    /// hitting.
    function test_thePositiveControlProvesTheProbeItselfWorks() public view {
        (bool ok, bytes memory ret) =
            RH_TESTNET_USDG.staticcall(abi.encodeWithSignature("decimals()"));
        assertTrue(ok);
        assertEq(abi.decode(ret, (uint8)), 6);
    }

    function test_permit2IsTheCanonicalSingletonWithItsRealDomain() public view {
        assertEq(CANONICAL_PERMIT2.code.length, 9152);
        (bool ok, bytes memory ret) =
            CANONICAL_PERMIT2.staticcall(abi.encodeWithSignature("DOMAIN_SEPARATOR()"));
        assertTrue(ok);
        assertEq(abi.decode(ret, (bytes32)), PERMIT2_DOMAIN_SEPARATOR_46630);
    }

    /// The number every "real USDG is more expensive" sentence in this repo assumed the sign of.
    /// It is recorded, not asserted against a threshold: a fork run has no pinned block, so a
    /// hard bound here would be a gate that goes red for a reason that is not a defect.
    function test_measure_realTransferGas() public {
        address a = address(0xA11CE);
        address b = address(0xB0B2);
        _dealMore(RH_TESTNET_USDG, a, 1_000_000);
        vm.prank(a);
        uint256 before = gasleft();
        IProbe(RH_TESTNET_USDG).transfer(b, 500_000);
        emit log_named_uint("real USDG transfer gas", before - gasleft());
        emit log_named_uint("fork block", block.number);
        assertEq(IProbe(RH_TESTNET_USDG).balanceOf(b), 500_000);
    }
}
