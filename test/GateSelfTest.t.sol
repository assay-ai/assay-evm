// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

/// Properties of the SHELL gates, asserted from inside `forge test` so they run wherever the
/// suite runs. Every one of them was wrong once, and none has a symptom until a deploy exists.
///
/// These are `public`, not `public view`: `vm.contains` is not a `view` cheatcode, and
/// `DocPins.t.sol` — the other document-pinning test in this tree — is spelled the same way for
/// the same reason.
contract GateSelfTest is Test {
    /// EIP-170 bounds RUNTIME bytecode. The first version of `check-sizes.sh` was written from
    /// measured CREATION bytecode, and the two differ by 1,427 bytes on both money contracts here —
    /// so a gate on creation bytecode is 1,427 bytes stricter than the rule it names, on the two
    /// contracts closest to the limit. It measures `deployedBytecode` today; this is what stops it
    /// drifting back.
    ///
    /// **It cannot be spelled `assertFalse(vm.contains(gate, "inspect \"$c\" bytecode"))`.** The
    /// script deliberately prints the creation size BESIDE the runtime one, as information, so
    /// that substring is present in a correct file and the assertion would be red on the tree it
    /// is meant to protect. What matters is not that the word appears but WHICH number the gate
    /// compares, so both halves are pinned by their assignment and the comparison is pinned by
    /// name.
    function test_theSizeGateMeasuresRuntimeBytecodeAndNotCreation() public {
        string memory gate = vm.readFile("script/check-sizes.sh");
        assertTrue(
            vm.contains(gate, "runtime=$($FORGE inspect \"$c\" deployedBytecode"),
            "check-sizes.sh stopped measuring runtime"
        );
        assertFalse(
            vm.contains(gate, "runtime=$($FORGE inspect \"$c\" bytecode"),
            "check-sizes.sh measures CREATION bytecode; EIP-170 bounds RUNTIME"
        );
        assertTrue(
            vm.contains(gate, "if [ \"$runtime\" -gt \"$CEILING\" ]"),
            "check-sizes.sh no longer GATES on the runtime figure it measures"
        );
    }

    /// `got=$(forge inspect X deployedBytecode | cast keccak)` fails with "odd number of digits"
    /// from the trailing newline, and under `set -euo pipefail` that ABORTED gate 6 before it
    /// compared anything — masked for as long as no record had ever reached
    /// `"status": "deployed"`, so the loop containing that line had never executed. It ran for the
    /// first time on 2026-09-10 and was seen to fail on both of its two questions.
    function test_theBytecodeGateDoesNotPipeIntoCastKeccak() public {
        string memory gate = vm.readFile("script/check-bytecode.sh");
        assertFalse(vm.contains(gate, "| cast keccak"), "gate 6 pipes into cast keccak again");
        assertTrue(vm.contains(gate, "tr -d '\\n'"), "gate 6 lost its newline strip");
    }

    /// The branch-level layout gate exists and names the merge base. `ci-gates.md` §3 carried this
    /// recipe as PROSE for three commits and nothing ran it.
    ///
    /// The third assertion is the defect found while proving the gate: `check-layout.py` exits 0
    /// for identical, **2 for a legal append** and 1 for a refusal, and the design this was written
    /// from tested that with `if ! …` / `|| …`, which fire on any non-zero status. So a legal
    /// append — the ordinary case on an upgrade branch — was REFUSED. The gate must read the exit
    /// code, which is what `verdict=$?` pins.
    function test_theBranchLevelLayoutGateExists() public {
        string memory gate = vm.readFile("script/check-layout-branch.sh");
        assertTrue(
            vm.contains(gate, "git merge-base"), "the branch layout gate lost its merge base"
        );
        assertTrue(vm.contains(gate, "check-layout.py"), "it stopped invoking the classifier");
        assertTrue(
            vm.contains(gate, "verdict=$?"),
            "the branch layout gate stopped READING check-layout.py's exit code: `if !` and `||` "
            "fire on exit 2 as well as 1, and exit 2 is a LEGAL APPEND"
        );
        assertFalse(
            vm.contains(gate, "if ! python3 script/check-layout.py"),
            "the branch layout gate is back to truthiness, so it refuses legal appends"
        );
    }
}
