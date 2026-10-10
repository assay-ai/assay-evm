// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {MockUSDG} from "../../test/helpers/MockUSDG.sol";

/// Testnet only: deploys the 6-decimal `MockUSDG` used as the settlement token on 46630.
/// Anyone can mint it; never point a mainnet deployment at it.
contract DeployMockUSDG is Script {
    error NotATestnet();

    function run() external returns (MockUSDG token) {
        if (block.chainid == 4663) revert NotATestnet();
        vm.startBroadcast();
        token = new MockUSDG();
        vm.stopBroadcast();
        console2.log("MockUSDG", address(token));
    }
}
