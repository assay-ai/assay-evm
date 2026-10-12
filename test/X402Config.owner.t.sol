// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.24;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Ownable2StepUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";

import {Fixture} from "./helpers/Fixture.sol";
import {X402ConfigV1} from "./helpers/legacy/X402ConfigV1.sol";
import {X402Config} from "../src/X402Config.sol";
import {X402Escrow} from "../src/X402Escrow.sol";
import {X402Stake} from "../src/X402Stake.sol";
import {ParamSet} from "../src/Types.sol";
import "../src/Errors.sol";

/// D-17: the OWNER / ADMIN split.
///
/// - the owner (cold) is the upgrade authority of all three contracts and appoints the admin;
///   it moves in two steps and can never be renounced or become `address(0)`;
/// - the admin (operational) holds every config door and nothing else;
/// - the version-1 proxy on the testnet migrates through `initializeV2`, inside the upgrade's
///   own `upgradeToAndCall`, with owner = the current admin.
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
            config.updateConfig(p, address(0));
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
        config.updateConfig(p, address(0));
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

    /// `initialize` and `initializeV2` are alternatives at version 2: on a fresh proxy the first
    /// closes the second, and neither runs on the implementation.
    function test_wrongState_noInitialiserRunsTwiceOrOnTheImplementation() public {
        ParamSet memory p = config.params();
        vm.prank(admin);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        config.initializeV2();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        config.initialize(p, stranger, stranger);

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        configImpl.initializeV2();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        configImpl.initialize(p, stranger, stranger);
    }

    // === the D-17 migration of the deployed version-1 proxy ==================================

    function _v1() internal returns (X402ConfigV1 v1) {
        v1 = X402ConfigV1(
            address(
                new ERC1967Proxy(
                    address(new X402ConfigV1()),
                    abi.encodeCall(X402ConfigV1.initialize, (config.params(), admin))
                )
            )
        );
        vm.startPrank(admin);
        v1.registerVerifier(address(0xF1), bytes32("k"), uint64(block.timestamp + 1000));
        v1.setPaused(true);
        vm.stopPrank();
    }

    /// The upgrade the testnet runs: the CURRENT admin calls
    /// `upgradeToAndCall(new, initializeV2())`. Afterwards the owner is that admin, the admin is
    /// unchanged, every pre-existing slot reads back identically, and version 2 is closed.
    function test_theMigrationMakesTheCurrentAdminTheOwnerAndMovesNoSlot() public {
        X402ConfigV1 v1 = _v1();
        bytes32[60] memory before;
        for (uint256 i = 0; i < 60; i++) {
            before[i] = vm.load(address(v1), bytes32(i));
        }
        bytes memory paramsBefore = abi.encode(v1.params());

        // A stranger cannot run the V1 upgrade door.
        vm.prank(stranger);
        vm.expectRevert(NotAdmin.selector);
        v1.upgradeToAndCall(address(configImpl), abi.encodeCall(X402Config.initializeV2, ()));

        vm.expectEmit(true, true, false, false, address(v1));
        emit OwnableUpgradeable.OwnershipTransferred(address(0), admin);
        vm.prank(admin);
        v1.upgradeToAndCall(address(configImpl), abi.encodeCall(X402Config.initializeV2, ()));

        X402Config v2 = X402Config(address(v1));
        assertEq(v2.owner(), admin, "owner = the admin that was the upgrade authority");
        assertEq(v2.admin(), admin, "the admin is unchanged");
        assertEq(v2.pendingOwner(), address(0));
        assertEq(abi.encode(v2.params()), paramsBefore, "params unchanged");
        assertTrue(v2.paused(), "pause unchanged");
        assertTrue(v2.verifierKey(address(0xF1)).registered, "registry unchanged");
        for (uint256 i = 0; i < 60; i++) {
            assertEq(vm.load(address(v1), bytes32(i)), before[i], "a sequential slot moved");
        }

        vm.prank(admin);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        v2.initializeV2();
        ParamSet memory p = v2.params(); // read first: expectRevert arms the NEXT call
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        v2.initialize(p, stranger, stranger);

        // …then the two-step move to the cold key, after which the admin cannot upgrade.
        vm.prank(admin);
        v2.transferOwnership(cold);
        vm.prank(cold);
        v2.acceptOwnership();
        address next = address(new X402Config());
        vm.prank(admin);
        vm.expectRevert(_unauthorized(admin));
        v2.upgradeToAndCall(next, "");
        vm.prank(cold);
        v2.upgradeToAndCall(next, "");
        assertEq(_impl(address(v2)), next);
        assertEq(v2.admin(), admin, "the admin stays the operational key");
    }

    /// If an operator upgrades WITHOUT the `initializeV2` call, version 2 stays open — and it
    /// still cannot be captured: `initialize` refuses an already-initialised admin, and
    /// `initializeV2` admits only the current admin, who lands exactly the owner it would have.
    function test_wrongState_anUpgradeWithoutItsInitialiserCannotBeCaptured() public {
        X402ConfigV1 v1 = _v1();
        vm.prank(admin);
        v1.upgradeToAndCall(address(configImpl), "");
        X402Config v2 = X402Config(address(v1));
        assertEq(v2.owner(), address(0), "no owner yet");

        ParamSet memory p = v2.params();
        vm.startPrank(stranger);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        v2.initialize(p, stranger, stranger);
        vm.expectRevert(NotAdmin.selector);
        v2.initializeV2();
        vm.stopPrank();

        vm.prank(admin);
        v2.initializeV2();
        assertEq(v2.owner(), admin);
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
