// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {AssayEscrow} from "../src/AssayEscrow.sol";
import {AssayStake} from "../src/AssayStake.sol";
import {UpgradeByOwner, LibraryCodehashMismatch} from "../script/UpgradeByOwner.s.sol";
import {
    LinkedLibraryMismatch,
    NotThisBuild,
    ExtensionMismatch,
    ExtensionCodehashMismatch
} from "../script/ChannelDoorLink.sol";
import {AssayEscrowSilentDomainV2} from "./helpers/AssayEscrowSilentDomainV2.sol";
import {AssayConfig} from "../src/AssayConfig.sol";

contract UpgradeByOwnerProbe is UpgradeByOwner {
    function linked(address impl) external view returns (address) {
        return _linkedChannelDoor(impl);
    }

    function assertChannelDoor(address impl, address door, bytes32 want) external view {
        _assertChannelDoor(impl, door, want);
    }

    function assertBuilt(address at, string calldata artifact, address lib) external view {
        _assertBuilt(at, artifact, lib);
    }

    function assertExtension(address impl, bytes32 want) external view returns (address) {
        return _assertExtension(impl, want);
    }
}

/// D-29: the owner's upgrade script pins the extension the escrow's `fallback` DELEGATECALLs,
/// by address (the implementation's first CREATE) and by code (exactly this build, its one
/// immutable checked by value).
contract UpgradeByOwnerExtensionTest is Test {
    struct Span {
        uint256 length;
        uint256 start;
    }

    UpgradeByOwnerProbe internal probe;
    address internal impl;
    address internal ext;

    function setUp() public {
        probe = new UpgradeByOwnerProbe();
        impl = address(new AssayEscrow());
        ext = AssayEscrow(impl).EXTENSION();
    }

    function test_acceptsTheExtensionTheImplementationCreated() public view {
        assertEq(probe.assertExtension(impl, ext.codehash), ext);
    }

    function test_refusesAnotherPinnedHash() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                ExtensionCodehashMismatch.selector, ext, ext.codehash, bytes32(uint256(1))
            )
        );
        probe.assertExtension(impl, bytes32(uint256(1)));
    }

    /// The reviewer's case: an implementation whose OWN code is the build but whose extension
    /// enforces another EIP-712 domain. Its hash pinned from that very code changes nothing.
    function test_refusesAnExtensionThatIsNotThisBuild_evenWithItsHashPinned() public {
        address silent = address(new AssayEscrowSilentDomainV2());
        address bad = AssayEscrow(silent).EXTENSION();
        vm.expectRevert(
            abi.encodeWithSelector(
                NotThisBuild.selector, bad, "out/AssayEscrowExtension.sol/AssayEscrowExtension.json"
            )
        );
        probe.assertExtension(silent, bad.codehash);
    }

    /// Build code at the right address, but its direct-call guard names another address: not
    /// this extension deployed here.
    function test_refusesAnExtensionWhoseGuardNamesAnotherAddress() public {
        bytes memory code = ext.code;
        // the guard's 32-byte word holds `ext`; flip its last byte wherever it appears
        bytes32 word = bytes32(uint256(uint160(ext)));
        uint256 hits;
        for (uint256 i = 0; i + 32 <= code.length; i++) {
            bytes32 w;
            assembly ("memory-safe") {
                w := mload(add(add(code, 32), i))
            }
            if (w == word) {
                code[i + 31] = code[i + 31] ^ 0x01;
                hits++;
            }
        }
        assertGt(hits, 0);
        vm.etch(ext, code);
        vm.expectRevert(
            abi.encodeWithSelector(
                NotThisBuild.selector, ext, "out/AssayEscrowExtension.sol/AssayEscrowExtension.json"
            )
        );
        probe.assertExtension(impl, keccak256(code));
    }

    /// Review H-1: `EXTENSION` has two spans, the getter's and the `fallback`'s DELEGATECALL
    /// target. Implementation code with ONLY the fallback's span pointing elsewhere, and its
    /// hash pinned from that very code, is refused: the getter still reports the genuine
    /// extension, so only the every-span-holds-one-value rule can see it.
    function test_refusesAFallbackTargetThatDiffersFromTheGetter() public {
        string memory art = vm.readFile("out/AssayEscrow.sol/AssayEscrow.json");
        string[] memory ids = vm.parseJsonKeys(art, ".deployedBytecode.immutableReferences");
        bytes memory code = impl.code;
        uint256 patched;
        for (uint256 k = 0; k < ids.length; k++) {
            Span[] memory spans = abi.decode(
                vm.parseJson(
                    art, string.concat(".deployedBytecode.immutableReferences.['", ids[k], "']")
                ),
                (Span[])
            );
            uint256[] memory starts = new uint256[](spans.length);
            for (uint256 i = 0; i < spans.length; i++) {
                starts[i] = spans[i].start;
            }
            if (starts.length < 2) continue;
            bytes32 w;
            uint256 at = starts[0];
            assembly ("memory-safe") {
                w := mload(add(add(code, 32), at))
            }
            if (w != bytes32(uint256(uint160(ext)))) continue;
            // the lowest offset is the fallback's PUSH32 (it is the first code after dispatch)
            uint256 lowest = starts[0] < starts[1] ? starts[0] : starts[1];
            bytes32 evil = bytes32(uint256(uint160(address(0xBAD))));
            assembly ("memory-safe") {
                mstore(add(add(code, 32), lowest), evil)
            }
            patched++;
        }
        assertEq(patched, 1, "EXTENSION has exactly two spans");
        address lib = probe.linked(impl);
        vm.etch(impl, code);
        assertEq(AssayEscrow(impl).EXTENSION(), ext, "the getter still reports the real one");
        vm.expectRevert(
            abi.encodeWithSelector(
                NotThisBuild.selector, impl, "out/AssayEscrow.sol/AssayEscrow.json"
            )
        );
        probe.assertBuilt(impl, "out/AssayEscrow.sol/AssayEscrow.json", lib);
    }

    /// An implementation that reports an extension other than its first CREATE.
    function test_refusesAnExtensionThatIsNotTheImplementationsFirstCreate() public {
        address stranger = address(new AssayEscrow());
        vm.mockCall(impl, abi.encodeWithSignature("EXTENSION()"), abi.encode(stranger));
        vm.expectRevert(abi.encodeWithSelector(ExtensionMismatch.selector, impl, stranger, ext));
        probe.assertExtension(impl, stranger.codehash);
    }

    function test_refusesAnImplementationWithoutAnExtension() public {
        address stake = address(new AssayStake());
        vm.expectRevert(
            abi.encodeWithSelector(ExtensionMismatch.selector, stake, address(0), address(0))
        );
        probe.assertExtension(stake, bytes32(0));
    }
}

/// The owner's upgrade script pins the code of the library the escrow DELEGATECALLs into, not
/// only the escrow's own code: the escrow codehash fixes the library's address, this fixes what
/// runs there.
contract UpgradeByOwnerChannelDoorTest is Test {
    UpgradeByOwnerProbe internal probe;
    address internal impl;
    address internal door;
    bytes32 internal pinned;

    function setUp() public {
        probe = new UpgradeByOwnerProbe();
        impl = address(new AssayEscrow());
        door = probe.linked(impl);
        pinned = door.codehash;
    }

    function test_readsTheLinkedLibrary_andAcceptsTheVerifiedOne() public view {
        assertTrue(door.code.length > 0, "the linked address holds the library");
        probe.assertChannelDoor(impl, door, pinned);
    }

    function test_refusesAnotherLibraryAddress() public {
        address other = address(0xD00D);
        vm.etch(other, door.code);
        vm.expectRevert(abi.encodeWithSelector(LinkedLibraryMismatch.selector, impl, door, other));
        probe.assertChannelDoor(impl, other, pinned);
    }

    function test_refusesOtherCodeAtTheLinkedAddress() public {
        bytes memory code = door.code;
        code[code.length - 1] = code[code.length - 1] ^ 0x01;
        vm.etch(door, code);
        vm.expectRevert(
            abi.encodeWithSelector(LibraryCodehashMismatch.selector, door, keccak256(code), pinned)
        );
        probe.assertChannelDoor(impl, door, pinned);
    }

    function test_refusesALibraryWithoutItsOwnCallGuard() public {
        // Code whose hash the operator pinned, but that is not a library deployed at this
        // address: the call guard names another address.
        bytes memory code = door.code;
        code[38] = code[38] ^ 0x01; // the last byte of the self-address word at offset 7
        vm.etch(door, code);
        vm.expectRevert(abi.encodeWithSelector(LinkedLibraryMismatch.selector, impl, door, door));
        probe.assertChannelDoor(impl, door, keccak256(code));
    }

    function test_refusesAnImplementationThatIsNotThisBuild() public {
        address stake = address(new AssayStake());
        vm.expectRevert();
        probe.assertChannelDoor(stake, door, pinned);
    }

    /// The review's probe: library code that differs from the build in one byte, deployed with
    /// its own address in the call guard, and a hash pinned from that very code. Every
    /// chain-read check passes; the comparison with the build refuses it.
    function test_refusesALibraryThatIsNotThisBuild_evenWithItsHashPinned() public {
        bytes memory code = door.code;
        code[code.length - 60] = code[code.length - 60] ^ 0x01;
        vm.etch(door, code);
        vm.expectRevert(
            abi.encodeWithSelector(
                NotThisBuild.selector, door, "out/ChannelDoor.sol/ChannelDoor.json"
            )
        );
        probe.assertChannelDoor(impl, door, keccak256(code));
    }

    function test_refusesAnEscrowImplementationThatIsNotThisBuild() public {
        bytes memory code = impl.code;
        code[code.length - 60] = code[code.length - 60] ^ 0x01;
        vm.etch(impl, code);
        vm.expectRevert(
            abi.encodeWithSelector(
                NotThisBuild.selector, impl, "out/AssayEscrow.sol/AssayEscrow.json"
            )
        );
        probe.assertChannelDoor(impl, door, pinned);
    }

    function test_plainImplementations_matchTheirOwnBuildOnly() public {
        address cfg = address(new AssayConfig());
        address stk = address(new AssayStake());
        probe.assertBuilt(cfg, "out/AssayConfig.sol/AssayConfig.json", address(0));
        probe.assertBuilt(stk, "out/AssayStake.sol/AssayStake.json", address(0));
        vm.expectRevert(
            abi.encodeWithSelector(
                NotThisBuild.selector, stk, "out/AssayConfig.sol/AssayConfig.json"
            )
        );
        probe.assertBuilt(stk, "out/AssayConfig.sol/AssayConfig.json", address(0));
    }

    /// An escrow build checked without its library address keeps its placeholders: refused.
    function test_anUnlinkedComparisonIsRefused() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                NotThisBuild.selector, impl, "out/AssayEscrow.sol/AssayEscrow.json"
            )
        );
        probe.assertBuilt(impl, "out/AssayEscrow.sol/AssayEscrow.json", address(0));
    }
}
