// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

/// Documents under `docs/` that an operator relies on must not silently lose the entries they
/// exist for. These tests read the runbook and fail when one of those entries disappears.
contract DocPinsTest is Test {
    /// The six human-only preconditions, by the marker each one is written under.
    ///
    /// A checklist an operator relies on is exactly the kind of document that loses an entry in a
    /// tidy-up, and the entry it loses is the one nobody has needed yet — which on this list is
    /// the one that is unrecoverable. Marker strings, not prose, so an edit to the wording does
    /// not fail the gate and a deletion does.
    function test_theRunbookNamesEveryHumanOnlyPrecondition() public {
        string memory rb = vm.readFile("docs/deploy-runbook.md");
        string[6] memory markers = [
            "**0.1**", // the mainnet USDG address
            "**0.2**", // the admin Ledger
            "**0.3**", // the treasury Ledger
            "**0.4**", // the EVM secp256k1 verifier key
            "**0.5**", // the environment configuration, same window
            "**0.6**" // the audit
        ];
        for (uint256 i = 0; i < markers.length; i++) {
            assertTrue(
                vm.contains(rb, markers[i]),
                string.concat("deploy-runbook.md lost precondition ", markers[i])
            );
        }
        // And the three sections those preconditions are cashed out in.
        assertTrue(vm.contains(rb, "### 6.4 Enrolling the EVM verifier key"), "6.4 is gone");
        assertTrue(vm.contains(rb, "## 10. The relayer float"), "10 is gone");
        assertTrue(
            vm.contains(
                rb, "## 11. The environment configuration and the code deploy in ONE window"
            ),
            "11 is gone"
        );
    }

    /// The one number that must never appear in this repository until an operator supplies it.
    /// `0x915Ef7…03ec` is the TESTNET token and there is no code at it on 4663; a runbook that
    /// offered it as a mainnet value would be read as an answer.
    function test_theRunbookNeverOffersAMainnetUsdgAddress() public {
        string memory rb = vm.readFile("docs/deploy-runbook.md");
        assertTrue(
            vm.contains(rb, "operator-supplied. Not derivable. Not the testnet address."),
            "the 4663 USDG cell stopped refusing"
        );
    }
}
