// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.38;

import {Script} from "forge-std/Script.sol";

error UnexpectedLinks(uint256 libraries);
error LinkedLibraryMismatch(address impl, address got, address want);
error NotThisBuild(address at, string artifact);

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
                for (uint256 j = spans[i].start; j < spans[i].start + spans[i].length; j++) {
                    got[j] = 0;
                    want[j] = 0;
                }
            }
        }
        if (keccak256(got) != keccak256(want)) revert NotThisBuild(at, artifact);
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
