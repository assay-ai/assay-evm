// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.38;

import {Script} from "forge-std/Script.sol";

error UnexpectedLinks(uint256 libraries);
error LinkedLibraryMismatch(address impl, address got, address want);

/// Reads back which `ChannelDoor` library an `AssayEscrow` implementation is linked to (D-28).
/// forge deploys and links the library itself, so the address is taken from the implementation's
/// code at the link offsets this build's artifact names.
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
}
