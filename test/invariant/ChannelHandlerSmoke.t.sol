// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.38;

import {Test, console2} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ChannelHandler} from "./ChannelHandler.sol";

/// The handler's actions land when driven by hand (a guard against a campaign that only
/// exercises refusals).
contract ChannelHandlerSmokeTest is Test {
    function test_handlerActionsLand() public {
        ChannelHandler h = new ChannelHandler();
        vm.recordLogs();
        h.settle(0, 1e6, 2, 0, false);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; ++i) {
            console2.logBytes32(logs[i].topics[0]);
            console2.logBytes(logs[i].data);
        }
        assertEq(h.settles(), 1);
    }
}
