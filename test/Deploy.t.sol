// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {X402Config} from "../src/X402Config.sol";
import {ParamSet} from "../src/Types.sol";
import "../src/Errors.sol";

/// **Why `Deploy.s.sol` must use the atomic `new ERC1967Proxy(impl, encodeCall(initialize, …))`
/// form, measured rather than asserted.**
///
/// A split deploy-then-initialise script leaves a live, uninitialised proxy in the mempool's view
/// for one transaction. `initialize` cannot defend itself against that: whoever lands first
/// becomes the admin of `X402Config`, and through it — because the two money contracts read
/// `CONFIG.admin()` live (D-1) — the upgrade authority of all three. A half-guard in the contract
/// (an `onlyDeployer` check, a stored expected caller) would be worse than none, because it would
/// read as if the window were closed while a reordered pair of transactions still walked through
/// it.
///
/// The atomic form removes the window instead of policing it, and `test_theDeployScriptUsesTheAtomicForm`
/// is what stops a future edit reintroducing the split.
contract DeployTest is Test {
    address internal constant ADMIN = address(0xADAA);
    address internal constant ATTACKER = address(0xBAD1);

    function _params() internal pure returns (ParamSet memory) {
        return ParamSet({
            treasury: address(0x7EA5),
            redeemer: address(0x4EED),
            unbondingPeriodSeconds: 14 * 86_400,
            minimumStake: 100_000_000,
            penaltyAmount: 1_000_000,
            verifierDailyCap: 500_000_000,
            takeRateBps: 1_000,
            slashAgentBps: 6_000,
            slashPlatformBps: 3_000,
            slashCapBps: 1_000
        });
    }

    /// The shipped form: initialised inside the creating transaction, and a second `initialize`
    /// from anybody — attacker or deployer — is already refused.
    function test_theAtomicFormLeavesNoWindow() public {
        X402Config config = X402Config(
            address(
                new ERC1967Proxy(
                    address(new X402Config()),
                    abi.encodeCall(X402Config.initialize, (_params(), ADMIN))
                )
            )
        );

        assertEq(config.admin(), ADMIN, "initialised in the creating transaction");

        vm.prank(ATTACKER);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        config.initialize(_params(), ATTACKER);
        assertEq(config.admin(), ADMIN, "and still the deployer's admin");
    }

    /// **The forbidden form, and what it costs.** The proxy is created with empty constructor
    /// data, so `initialize` is a separate transaction — and any address may land it first.
    ///
    /// The attacker here is not exotic: it is one address, one call, no value, no reordering
    /// trick beyond paying more gas. It ends holding `Config.admin`, which under D-1 is the
    /// upgrade authority of `X402Escrow` and `X402Stake` as well, so the whole system is theirs
    /// before the deployer's second transaction is mined.
    function test_wrongState_theSplitFormIsFrontRunnable() public {
        address impl = address(new X402Config());

        // Transaction 1 — the deployer creates the proxy, uninitialised.
        X402Config config = X402Config(address(new ERC1967Proxy(impl, "")));
        assertEq(config.admin(), address(0), "live, and nobody's");

        // Transaction 1.5 — the attacker's, in between.
        vm.prank(ATTACKER);
        config.initialize(_params(), ATTACKER);
        assertEq(config.admin(), ATTACKER, "the system belongs to whoever landed first");

        // Transaction 2 — the deployer's, now too late, and it fails with an error that names the
        // initializer rather than the theft.
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        config.initialize(_params(), ADMIN);

        // And the consequence, spelled out: the attacker upgrades the parameter contract.
        address next = address(new X402Config());
        vm.prank(ATTACKER);
        config.upgradeToAndCall(next, "");
        assertEq(
            address(uint160(uint256(vm.load(address(config), _IMPL_SLOT())))),
            next,
            "and can replace its logic"
        );
    }

    /// The source-text guard on the above. `Deploy.s.sol` must construct every proxy with its
    /// initializer calldata inline, and must never contain a bare `new ERC1967Proxy(impl, "")`.
    ///
    /// A text scan, with the limit `docs/ci-gates.md` states for every text scan in this repo: it
    /// catches every spelling a human would write and cannot see a proxy created through an
    /// assembly `create2`. It is the whole enforcement of a rule that has no on-chain half.
    function test_theDeployScriptUsesTheAtomicForm() public view {
        string memory src = vm.readFile(string.concat(vm.projectRoot(), "/script/Deploy.s.sol"));
        // Comment lines are stripped first, exactly as
        // `test_recoveryHappensAtExactlyOneCallSiteInSrc` strips them: this file's own header
        // names every pattern below in prose, so a whole-file scan would be counting its own
        // documentation. Measured — without the strip, `X402Escrow.initialize` counts 2.
        bytes memory b = _codeOnly(bytes(src));

        assertEq(_count(b, "new ERC1967Proxy"), 3, "one proxy per contract, and no more");
        // One `abi.encodeCall(<Contract>.initialize` per contract. Counted by the three
        // qualified names rather than by `abi.encodeCall`, for two measured reasons: the header
        // names the pattern in prose (so the bare spelling counts 4, and the test would be a
        // comment-length check), and `forge fmt` wraps two of the three onto a following line at
        // this file's 100-column width (so `abi.encodeCall(X402` counts 1).
        assertEq(_count(b, "X402Config.initialize"), 1, "Config's initializer calldata");
        assertEq(_count(b, "X402Stake.initialize"), 1, "Stake's initializer calldata");
        assertEq(_count(b, "X402Escrow.initialize"), 1, "Escrow's initializer calldata");
        assertEq(_count(b, 'ERC1967Proxy{salt: _salt("'), 3, "and the salt is on the PROXY (D-7)");

        // The two spellings of the forbidden split, on any line.
        assertEq(_count(b, 'ERC1967Proxy(configImpl, "")'), 0);
        assertEq(_count(b, "Proxy(impl,"), 0);
        assertEq(_count(b, ".initialize("), 0, "initialize is never called as a separate step");
    }

    /// **The degenerate `verify-deployment.sh` would be if it stopped at "the proxy exists".**
    ///
    /// The script cannot be run here — there is no deployment and no agent may make one — so the
    /// three checks it makes are modelled instead, against real proxies in memory, and then the
    /// weak version is run beside the strong one on the same state. The source-text assertions at
    /// the end pin that the shipped script really contains the strong check.
    ///
    /// The state is the one that matters: a proxy that was upgraded and whose deployment record
    /// was **not** updated. That is not a hypothetical — it is what happens whenever an upgrade is
    /// applied and step 7's last checklist item is skipped, and it is the only condition under
    /// which the live code and the recorded code differ.
    function test_theWeakVerifierCannotSeeAnUnrecordedUpgrade() public {
        address recordedImpl = address(new X402Config());
        X402Config config = X402Config(
            address(
                new ERC1967Proxy(
                    recordedImpl, abi.encodeCall(X402Config.initialize, (_params(), ADMIN))
                )
            )
        );

        // Both verifiers agree while the record is current.
        assertTrue(_strongCheck(address(config), recordedImpl), "strong: green before");
        assertTrue(_weakCheck(address(config)), "weak: green before");

        // An upgrade nobody wrote down.
        address newImpl = address(new X402Config());
        vm.prank(ADMIN);
        config.upgradeToAndCall(newImpl, "");

        assertFalse(
            _strongCheck(address(config), recordedImpl),
            "the shipped check reads the ERC-1967 slot and sees it"
        );
        assertTrue(
            _weakCheck(address(config)),
            "the degenerate check only asks whether the proxy has code, and it still does"
        );

        // And the shipped script does contain the strong check, spelled the one way it can be.
        string memory sh =
            vm.readFile(string.concat(vm.projectRoot(), "/script/verify-deployment.sh"));
        bytes memory b = bytes(sh);
        assertGt(
            _count(b, "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc"),
            0,
            "verify-deployment.sh must name the ERC-1967 implementation slot"
        );
        assertGt(_count(b, "cast storage"), 0, "and must actually read it");
        assertGt(_count(b, "implementation slot"), 0, "and must fail by that name");
    }

    /// What `verify-deployment.sh` check 1 does: the proxy points at the implementation the record
    /// names.
    function _strongCheck(address proxy, address recordedImpl) internal view returns (bool) {
        return address(uint160(uint256(vm.load(proxy, _IMPL_SLOT())))) == recordedImpl;
    }

    /// What it would do if somebody "simplified" it to check 3 alone.
    function _weakCheck(address proxy) internal view returns (bool) {
        return proxy.code.length > 0;
    }

    /// Lines that are not comments, rejoined. `//`, `///`, `/*` and a continuation `*` all start
    /// a comment line here — the same four cases the `ecrecover` gate handles, and the same limit:
    /// a pattern hidden inside a trailing comment on a code line is still counted.
    function _codeOnly(bytes memory src) internal pure returns (bytes memory out) {
        uint256 lineStart;
        for (uint256 i = 0; i <= src.length; i++) {
            if (i != src.length && src[i] != "\n") continue;
            uint256 s = lineStart;
            lineStart = i + 1;
            while (s < i && (src[s] == " " || src[s] == "\t")) s++;
            if (s >= i) continue;
            if (src[s] == "*") continue;
            if (s + 1 < i && src[s] == "/" && (src[s + 1] == "/" || src[s + 1] == "*")) continue;
            bytes memory line = new bytes(i - s);
            for (uint256 k = 0; k < i - s; k++) {
                line[k] = src[s + k];
            }
            out = abi.encodePacked(out, line, "\n");
        }
    }

    /// **The salt formula, pinned against the shell.** `Deploy._salt` is
    /// `keccak256(abi.encodePacked("x402:", name, ":v2:", block.chainid))`, and `block.chainid` is
    /// a `uint256` — so it contributes thirty-two big-endian bytes, **not** the decimal string.
    /// `script/new-deployment-record.sh` has to reproduce that exactly or the `salt` field in a
    /// deployment record names an address nobody deployed, and the CREATE2 derivation an operator
    /// checks against it fails for a reason no error message would explain.
    ///
    /// The literals below came out of the shell spelling
    /// (`cast keccak $(cast concat-hex $(cast from-utf8 "x402:Config:v2:") $(cast to-uint256 46630))`).
    /// This test recomputes them in Solidity, which is the only way the two spellings can be shown
    /// to agree.
    function test_theSaltFormulaMatchesTheOneTheShellScriptComputes() public pure {
        assertEq(
            keccak256(abi.encodePacked("x402:", "Config", ":v2:", uint256(46630))),
            0xdd28db2fe87459f4b5e57a59948960ae1c0b67a86c815311aa5482da72bb2531,
            "Config @ 46630"
        );
        assertEq(
            keccak256(abi.encodePacked("x402:", "Stake", ":v2:", uint256(46630))),
            0xd6642378f60892659ba6d8f33e6d55ca6621e2fdb3d6f6bde1b48ae5a6d50e32,
            "Stake @ 46630"
        );
        assertEq(
            keccak256(abi.encodePacked("x402:", "Escrow", ":v2:", uint256(46630))),
            0xc091d2b479e3b306fdf03a61f83fd34a914799011dad1b3ebcfba613125c43ae,
            "Escrow @ 46630"
        );

        // And the property the whole scheme exists for: the two networks do NOT collide, so a
        // backend pointed at the wrong RPC gets "no code at address" rather than a live contract
        // that answers plausibly.
        assertTrue(
            keccak256(abi.encodePacked("x402:", "Escrow", ":v2:", uint256(4663)))
                != keccak256(abi.encodePacked("x402:", "Escrow", ":v2:", uint256(46630))),
            "mainnet and testnet must land on different addresses"
        );
    }

    function _IMPL_SLOT() internal pure returns (bytes32) {
        return 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    }

    function _count(bytes memory haystack, string memory needleStr)
        internal
        pure
        returns (uint256 n)
    {
        bytes memory needle = bytes(needleStr);
        if (needle.length == 0 || haystack.length < needle.length) return 0;
        for (uint256 i = 0; i + needle.length <= haystack.length; i++) {
            bool hit = true;
            for (uint256 j = 0; j < needle.length; j++) {
                if (haystack[i + j] != needle[j]) {
                    hit = false;
                    break;
                }
            }
            if (hit) n++;
        }
    }
}
