// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.38;

import {Script} from "forge-std/Script.sol";

error UnexpectedLinks(uint256 libraries);
error LinkedLibraryMismatch(address impl, address got, address want);
error NotThisBuild(address at, string artifact);
error ExtensionMismatch(address impl, address got, address want);
error ExtensionCodehashMismatch(address ext, bytes32 got, bytes32 want);

/// Reads back which `ChannelDoor` library an `AssayEscrow` implementation is linked to (D-28),
/// and compares deployed code with THIS tree's build. forge deploys and links the library itself,
/// so the address is taken from the implementation's code at the link offsets the artifact names.
abstract contract ChannelDoorLink is Script {
    struct LinkRef {
        uint256 length;
        uint256 start;
    }

    /// The library address written into `impl` at every link offset of this build's artifact.
    /// Every offset must hold the same address; an artifact that links any other library, or an
    /// implementation that is not this build, fails here instead of passing a wrong address on.
    function _linkedChannelDoor(address impl) internal view returns (address lib) {
        string memory art = vm.readFile("out/AssayEscrow.sol/AssayEscrow.json");
        string[] memory files = vm.parseJsonKeys(art, ".deployedBytecode.linkReferences");
        if (files.length != 1) revert UnexpectedLinks(files.length);
        string[] memory libs = vm.parseJsonKeys(
            art, ".deployedBytecode.linkReferences.['src/libraries/ChannelDoor.sol']"
        );
        if (libs.length != 1) revert UnexpectedLinks(libs.length);
        LinkRef[] memory refs = abi.decode(
            vm.parseJson(
                art,
                ".deployedBytecode.linkReferences.['src/libraries/ChannelDoor.sol'].ChannelDoor"
            ),
            (LinkRef[])
        );
        if (refs.length == 0) revert UnexpectedLinks(0);
        bytes memory code = impl.code;
        for (uint256 i = 0; i < refs.length; i++) {
            if (refs[i].length != 20 || refs[i].start + 20 > code.length) {
                revert LinkedLibraryMismatch(impl, address(0), lib);
            }
            address at = _word20(code, refs[i].start);
            if (i == 0) lib = at;
            else if (at != lib) revert LinkedLibraryMismatch(impl, at, lib);
        }
    }

    function _slice(bytes memory b, uint256 start, uint256 len)
        internal
        pure
        returns (bytes memory out)
    {
        out = new bytes(len);
        for (uint256 i = 0; i < len; i++) {
            out[i] = b[start + i];
        }
    }

    function _word20(bytes memory b, uint256 at) internal pure returns (address) {
        return address(uint160(_word(b, at) >> 96));
    }

    function _word(bytes memory b, uint256 at) internal pure returns (uint256 w) {
        assembly ("memory-safe") {
            w := mload(add(add(b, 32), at))
        }
    }

    /// `at`'s code is this tree's build of `artifact`: the build's link placeholders filled
    /// with `lib` (none when `lib` is zero), and every span the compiler lists as an immutable
    /// zeroed on both sides, since the constructor writes those. A code hash taken from the
    /// chain only says the code did not change since it was read; this says it is the
    /// reviewed source. Run it from a checkout of the commit being deployed, freshly built.
    function _assertBuilt(address at, string memory artifact, address lib) internal view {
        string memory art = vm.readFile(artifact);
        string memory obj = vm.parseJsonString(art, ".deployedBytecode.object");
        if (lib != address(0)) obj = vm.replace(obj, _channelDoorPlaceholder(), _hex40(lib));
        if (vm.indexOf(obj, "__$") != type(uint256).max) revert NotThisBuild(at, artifact);
        bytes memory want = vm.parseBytes(obj);
        bytes memory got = at.code;
        if (got.length != want.length) revert NotThisBuild(at, artifact);
        string[] memory ids = vm.parseJsonKeys(art, ".deployedBytecode.immutableReferences");
        for (uint256 k = 0; k < ids.length; k++) {
            LinkRef[] memory spans = abi.decode(
                vm.parseJson(
                    art, string.concat(".deployedBytecode.immutableReferences.['", ids[k], "']")
                ),
                (LinkRef[])
            );
            for (uint256 i = 0; i < spans.length; i++) {
                if (spans[i].start + spans[i].length > got.length) {
                    revert NotThisBuild(at, artifact);
                }
                // Every span of one immutable must hold the same value: the compiler writes one
                // value to all of them, so a span that differs was written by someone else. This
                // is what ties a getter's value (checked by callers) to every other use of the
                // same immutable, e.g. the DELEGATECALL target in the escrow's `fallback`.
                if (
                    spans[i].length != spans[0].length
                        || keccak256(_slice(got, spans[i].start, spans[i].length))
                            != keccak256(_slice(got, spans[0].start, spans[0].length))
                ) revert NotThisBuild(at, artifact);
            }
            for (uint256 i = 0; i < spans.length; i++) {
                for (uint256 j = spans[i].start; j < spans[i].start + spans[i].length; j++) {
                    got[j] = 0;
                    want[j] = 0;
                }
            }
        }
        if (keccak256(got) != keccak256(want)) revert NotThisBuild(at, artifact);
    }

    /// The escrow implementation's extension (D-29) is the one its constructor created
    /// (first CREATE, nonce 1), its code is exactly the extension's code that the operator
    /// verified (`want`), and it is this tree's build. The extension's one immutable is its own
    /// address (the direct-call guard) and is checked BY VALUE: it has no EIP-712 immutables, so
    /// nothing in it is masked unchecked and a deployer-built extension cannot carry its own
    /// domain past this. `EXTENSION()` is read from the implementation; the implementation's
    /// code is compared with the build separately by `_assertBuilt`, which also requires every
    /// span of an immutable to hold one value, so the getter's value IS the `fallback`'s
    /// DELEGATECALL target (the two spans of `EXTENSION`; review finding H-1).
    function _assertExtension(address impl, bytes32 want) internal view returns (address ext) {
        (bool ok, bytes memory ret) = impl.staticcall(abi.encodeWithSignature("EXTENSION()"));
        if (!ok || ret.length != 32) revert ExtensionMismatch(impl, address(0), address(0));
        ext = abi.decode(ret, (address));
        address nonce1 = vm.computeCreateAddress(impl, 1);
        if (ext != nonce1) revert ExtensionMismatch(impl, ext, nonce1);
        if (ext.codehash != want) revert ExtensionCodehashMismatch(ext, ext.codehash, want);
        string memory artifact = "out/AssayEscrowExtension.sol/AssayEscrowExtension.json";
        _assertBuilt(ext, artifact, address(0));
        string memory art = vm.readFile(artifact);
        string[] memory ids = vm.parseJsonKeys(art, ".deployedBytecode.immutableReferences");
        if (ids.length != 1) revert NotThisBuild(ext, artifact);
        LinkRef[] memory spans = abi.decode(
            vm.parseJson(
                art, string.concat(".deployedBytecode.immutableReferences.['", ids[0], "']")
            ),
            (LinkRef[])
        );
        bytes memory code = ext.code;
        if (spans.length == 0) revert NotThisBuild(ext, artifact);
        for (uint256 i = 0; i < spans.length; i++) {
            if (spans[i].length != 32 || _word(code, spans[i].start) != uint256(uint160(ext))) {
                revert NotThisBuild(ext, artifact);
            }
        }
    }

    /// solc's placeholder for `ChannelDoor`: `__$` + the first 34 hex digits of
    /// keccak256("<source path>:<name>") + `$__`.
    function _channelDoorPlaceholder() internal pure returns (string memory) {
        string memory h = vm.toString(keccak256("src/libraries/ChannelDoor.sol:ChannelDoor"));
        bytes memory b = bytes(h);
        bytes memory cut = new bytes(34);
        for (uint256 i = 0; i < 34; i++) {
            cut[i] = b[i + 2];
        }
        return string.concat("__$", string(cut), "$__");
    }

    function _hex40(address a) internal pure returns (string memory) {
        bytes memory b = bytes(vm.toString(a));
        bytes memory out = new bytes(40);
        for (uint256 i = 0; i < 40; i++) {
            out[i] = b[i + 2];
        }
        return string(out);
    }
}
