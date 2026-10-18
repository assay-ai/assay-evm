// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.24;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Ownable2StepUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";

import {Fixture} from "./helpers/Fixture.sol";
import {X402Config} from "../src/X402Config.sol";
import {X402Escrow} from "../src/X402Escrow.sol";
import {X402Stake} from "../src/X402Stake.sol";
import {ParamSet} from "../src/Types.sol";
import "../src/Errors.sol";

/// D-17: the OWNER / ADMIN split.
///
/// - the owner (cold) is the upgrade authority of all three contracts and appoints the admin;
///   it moves in two steps and can never be renounced or become `address(0)`;
/// - the admin (operational) holds every config door and nothing else.
contract X402ConfigOwnerTest is Fixture {
    bytes32 internal constant IMPL_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    address internal stranger = address(0x57A2);
    address internal cold = address(0xC01D);

    function _unauthorized(address who) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, who);
    }

    function _impl(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, IMPL_SLOT))));
    }

    // === the access matrix ===================================================================

    /// Every ADMIN door refuses the owner (who is not the admin here) and a stranger, and admits
    /// the admin. The owner's power is the upgrade and the appointment; it is not a super-admin.
    function test_everyAdminDoorRefusesTheOwnerAndAStranger() public {
        ParamSet memory p = config.params();
        address[2] memory refused = [owner, stranger];
        for (uint256 i = 0; i < refused.length; i++) {
            vm.startPrank(refused[i]);
            vm.expectRevert(NotAdmin.selector);
            config.updateConfig(p);
            vm.expectRevert(NotAdmin.selector);
            config.setPaused(true);
            vm.expectRevert(NotAdmin.selector);
            config.registerVerifier(address(0xF1), bytes32("k"), uint64(block.timestamp + 1));
            vm.expectRevert(NotAdmin.selector);
            config.revokeVerifier(address(0xF1));
            vm.expectRevert(NotAdmin.selector);
            stake.cancelSlash(bytes32(uint256(1)));
            vm.stopPrank();
        }

        vm.startPrank(admin);
        config.updateConfig(p);
        config.setPaused(true);
        config.setPaused(false);
        config.registerVerifier(address(0xF1), bytes32("k"), uint64(block.timestamp + 1));
        config.revokeVerifier(address(0xF1));
        vm.stopPrank();
    }

    /// Every OWNER door refuses the admin, the redeemer and a stranger, and admits the owner.
    function test_everyOwnerDoorRefusesTheAdminTheRedeemerAndAStranger() public {
        address cfgNext = address(new X402Config());
        address stakeNext = address(new X402Stake());
        address escrowNext = address(new X402Escrow());
        address[3] memory refused = [admin, redeemer, stranger];
        for (uint256 i = 0; i < refused.length; i++) {
            vm.startPrank(refused[i]);
            vm.expectRevert(_unauthorized(refused[i]));
            config.setAdmin(stranger);
            vm.expectRevert(_unauthorized(refused[i]));
            config.transferOwnership(refused[i]);
            vm.expectRevert(_unauthorized(refused[i]));
            config.upgradeToAndCall(cfgNext, "");
            vm.expectRevert(NotOwner.selector);
            stake.upgradeToAndCall(stakeNext, "");
            vm.expectRevert(NotOwner.selector);
            escrow.upgradeToAndCall(escrowNext, "");
            vm.stopPrank();
        }
        assertEq(config.admin(), admin, "nobody appointed an admin");
        assertEq(config.pendingOwner(), address(0), "nobody proposed an owner");

        vm.startPrank(owner);
        config.setAdmin(admin);
        config.upgradeToAndCall(cfgNext, "");
        stake.upgradeToAndCall(stakeNext, "");
        escrow.upgradeToAndCall(escrowNext, "");
        vm.stopPrank();
        assertEq(_impl(address(config)), cfgNext);
        assertEq(_impl(address(stake)), stakeNext);
        assertEq(_impl(address(escrow)), escrowNext);
    }

    /// `renounceOwnership` is disabled for EVERY caller, the owner included.
    function test_wrongState_ownershipCanNeverBeRenounced() public {
        address[3] memory callers = [owner, admin, stranger];
        for (uint256 i = 0; i < callers.length; i++) {
            vm.prank(callers[i]);
            vm.expectRevert(OwnershipCannotBeRenounced.selector);
            config.renounceOwnership();
        }
        assertEq(config.owner(), owner);
    }

    // === the two-step transfer ===============================================================

    function test_happyPath_ownershipMovesInTwoSteps() public {
        vm.expectEmit(true, true, false, false, address(config));
        emit Ownable2StepUpgradeable.OwnershipTransferStarted(owner, cold);
        vm.prank(owner);
        config.transferOwnership(cold);
        assertEq(config.owner(), owner, "a proposal moves nothing");
        assertEq(config.pendingOwner(), cold);

        // The proposed key holds NOTHING until it accepts.
        address next = address(new X402Stake());
        vm.startPrank(cold);
        vm.expectRevert(NotOwner.selector);
        stake.upgradeToAndCall(next, "");
        vm.expectRevert(_unauthorized(cold));
        config.setAdmin(cold);
        vm.stopPrank();

        // Only the proposed key may accept.
        address[3] memory wrong = [owner, admin, stranger];
        for (uint256 i = 0; i < wrong.length; i++) {
            vm.prank(wrong[i]);
            vm.expectRevert(_unauthorized(wrong[i]));
            config.acceptOwnership();
        }

        vm.expectEmit(true, true, false, false, address(config));
        emit OwnableUpgradeable.OwnershipTransferred(owner, cold);
        vm.prank(cold);
        config.acceptOwnership();
        assertEq(config.owner(), cold);
        assertEq(config.pendingOwner(), address(0));

        // The old owner is out of every owner door; the new one is in.
        vm.startPrank(owner);
        vm.expectRevert(NotOwner.selector);
        stake.upgradeToAndCall(next, "");
        vm.expectRevert(_unauthorized(owner));
        config.setAdmin(owner);
        vm.stopPrank();
        vm.prank(cold);
        stake.upgradeToAndCall(next, "");
        assertEq(_impl(address(stake)), next);
    }

    /// A mistyped proposal is recoverable: a new proposal replaces it, and proposing
    /// `address(0)` cancels it. Neither moves the owner, and nobody can accept for `address(0)`.
    function test_aWrongProposalIsReplacedOrCancelledAndNeverMovesTheOwner() public {
        address typo = address(0x7790);
        vm.prank(owner);
        config.transferOwnership(typo);
        vm.prank(owner);
        config.transferOwnership(cold);
        assertEq(config.pendingOwner(), cold, "the second proposal replaced the first");
        vm.prank(typo);
        vm.expectRevert(_unauthorized(typo));
        config.acceptOwnership();

        vm.prank(owner);
        config.transferOwnership(address(0));
        assertEq(config.pendingOwner(), address(0), "proposing address(0) cancels");
        assertEq(config.owner(), owner, "and the owner never moved");
        vm.prank(cold);
        vm.expectRevert(_unauthorized(cold));
        config.acceptOwnership();
    }

    /// Fuzzed: whatever single proposal the owner makes, the owner is never `address(0)` and
    /// only the proposed key can complete it.
    function testFuzz_theOwnerIsNeverTheZeroAddress(address proposed, address acceptor) public {
        vm.prank(owner);
        config.transferOwnership(proposed);
        vm.prank(acceptor);
        if (acceptor == proposed && proposed != address(0)) {
            config.acceptOwnership();
            assertEq(config.owner(), proposed);
        } else {
            vm.expectRevert(_unauthorized(acceptor));
            config.acceptOwnership();
            assertEq(config.owner(), owner);
        }
        assertTrue(config.owner() != address(0));
    }

    // === initialisation ======================================================================

    function test_wrongState_aFreshDeploymentNeedsBothRoles() public {
        ParamSet memory p = config.params();
        vm.expectRevert(
            abi.encodeWithSelector(OwnableUpgradeable.OwnableInvalidOwner.selector, address(0))
        );
        new ERC1967Proxy(
            address(configImpl), abi.encodeCall(X402Config.initialize, (p, admin, address(0)))
        );
        vm.expectRevert(InvalidAdmin.selector);
        new ERC1967Proxy(
            address(configImpl), abi.encodeCall(X402Config.initialize, (p, address(0), owner))
        );
    }

    /// `initialize` runs once, on the proxy, and never on the implementation.
    function test_wrongState_noInitialiserRunsTwiceOrOnTheImplementation() public {
        ParamSet memory p = config.params();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        config.initialize(p, stranger, stranger);

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        configImpl.initialize(p, stranger, stranger);
    }

    // === the deployer keeps nothing ==========================================================

    /// `script/Deploy.s.sol` refuses to run when the broadcasting key would hold the owner, the
    /// admin or the redeemer role, and asserts the owner it set before it logs success.
    function test_theDeployScriptLeavesTheDeployerNoRole() public view {
        string memory src = vm.readFile(string.concat(vm.projectRoot(), "/script/Deploy.s.sol"));
        assertTrue(
            _has(
                src,
                "if (owner == deployer || admin == deployer || p.redeemer == deployer) {\n            revert DeployerWouldKeepARole(deployer);"
            ),
            "Deploy.s.sol no longer refuses a deployer that keeps a role"
        );
        assertTrue(
            _has(src, "if (config.owner() != owner || config.pendingOwner() != address(0))"),
            "Deploy.s.sol no longer checks the owner it set"
        );
    }

    function _has(string memory h, string memory n) internal pure returns (bool) {
        bytes memory a = bytes(h);
        bytes memory b = bytes(n);
        for (uint256 i = 0; i + b.length <= a.length; i++) {
            uint256 j = 0;
            while (j < b.length && a[i + j] == b[j]) j++;
            if (j == b.length) return true;
        }
        return false;
    }
}
