// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

/// The base for every test under `test/fork/`.
///
/// # Why the env var, and not a `[profile.fork]`
///
/// A bare `forge test` — gate 7 — must be OFFLINE and DETERMINISTIC. A profile would keep the
/// fork tests out of the default run, but only for someone who remembered to set the profile;
/// this fixture keeps them out for everyone, because without `RH_TESTNET_RPC` every contract
/// under `test/fork/` SKIPS ITSELF and says so in the output. A skip that is printed is a
/// different thing from a test that silently was not collected — a check passing while
/// answering something other than what was asked is a failure shape this suite has met before.
///
/// `script/check-fork-isolation.sh` is what proves the skip actually happens, in both
/// directions, rather than trusting this comment.
///
/// # Why the fork is not pinned to a block
///
/// Measured 2026-09-10: the public 46630 RPC serves state about 6,250 blocks deep and refuses by
/// ~7,812, at 0.1448 s per block — roughly FIFTEEN MINUTES. The window itself moves: the same
/// binary search on 2026-09-09 returned 4,687 / 6,250, so even the depth is not a constant.
/// `--fork-block-number` names a block that will be gone before the next run. So these tests run
/// against `latest` and are non-deterministic on purpose, which is exactly why they may never
/// contribute a row to `.gas-snapshot`.
///
/// # Why funding is `deal` and never a transfer from a whale
///
/// A whale's balance is chain state a stranger can move. `deal` writes the balance slot
/// directly and adjusts `totalSupply`, so the test's premise cannot be taken away from it
/// between two runs.
abstract contract ForkFixture is Test {
    address internal constant RH_TESTNET_USDG = 0x915Ef7c9F9f80a69e3BE47A38EE0Bb47607103ec;
    address internal constant CANONICAL_PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    uint256 internal constant RH_TESTNET_CHAIN_ID = 46630;

    /// The Permit2 domain separator measured on 46630 on 2026-09-09, re-measured 2026-09-10. It
    /// is a CONSTANT of the deployment, so a fork test can assert it and a change is a real
    /// event, not churn.
    bytes32 internal constant PERMIT2_DOMAIN_SEPARATOR_46630 =
        0x385ef69ffea4b42e91eff23e95ef22db58d3ad382de54eedf9bf9ff2ed24173f;

    /// keccak256 of the 5,652-byte runtime code at `RH_TESTNET_USDG`, measured 2026-09-10.
    /// The token is NOT behind a proxy (EIP-1967 slot is zero), so this cannot change without
    /// the address changing — which makes it a stronger identity pin than any getter.
    bytes32 internal constant TESTNET_USDG_RUNTIME_KECCAK =
        0xf37549bb5a61edd116fc93067c60c1c091577250252e36e4eb08188f3525f1b1;

    bool internal forkLive;

    function _selectForkOrSkip() internal returns (bool) {
        string memory rpc = vm.envOr("RH_TESTNET_RPC", string(""));
        if (bytes(rpc).length == 0) {
            // Skips every test in the contract, and PRINTS that it did.
            vm.skip(true);
            return false;
        }
        vm.createSelectFork(rpc);
        // If the RPC is pointed somewhere else, fail loudly here rather than let a suite report
        // green about a chain nobody meant to test.
        assertEq(block.chainid, RH_TESTNET_CHAIN_ID, "RH_TESTNET_RPC is not chain 46630");
        forkLive = true;
        return true;
    }

    /// ADDS to the current balance. `deal`'s three-argument form SETS, which silently erases a
    /// previous funding when a fixture funds the same address twice — and the second funding is
    /// usually the one a test is reasoning about.
    function _dealMore(address token, address to, uint256 amount) internal {
        (bool ok, bytes memory ret) =
            token.staticcall(abi.encodeWithSignature("balanceOf(address)", to));
        require(ok, "balanceOf failed");
        deal(token, to, abi.decode(ret, (uint256)) + amount, true);
    }
}
