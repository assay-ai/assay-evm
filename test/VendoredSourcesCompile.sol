// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.24;

// COMPILE ASSERTION — NOT A BEHAVIOURAL TEST.
//
// It asserts one thing and asserts it at build time: every file named in
// lib/openzeppelin/MANIFEST exists and compiles under this project's exact settings
// (solc 0.8.24, evm_version = shanghai, via_ir, optimizer at 200 runs). It exercises
// nothing and proves nothing about behaviour; ECDSA's low-s property is proved by
// Toolchain.t.sol, and every other vendored file gets its behavioural coverage from the
// task that first uses it.
//
// It exists because of what was true before it: `forge build` pulled exactly ONE of the
// 31 vendored sources into the graph (ECDSA.sol, via Toolchain.t.sol). SafeERC20, EIP712,
// ReentrancyGuard and the whole proxy/** + UUPS tree were committed and never once fed to
// the compiler, so a vendored file that was truncated, mis-copied or deleted would have
// stayed invisible until the first change that imported it, and would have surfaced
// there as that change's bug.
//
// It is also the second, independent answer to a deleted vendored file: script/check-vendor.sh
// compares the directory against MANIFEST, and this file breaks the build. Removing a file
// now requires defeating both.
//
// Every import is aliased, so this file declares no names of its own and two vendored
// paths that export the same symbol (interfaces/IERC20.sol and token/ERC20/IERC20.sol)
// cannot collide.
//
// Regenerate after any change to MANIFEST:
//   awk '{gsub(/\.sol$/,"",$0); a=$0; gsub(/[^A-Za-z0-9]/,"_",a); \
//         print "import \"@openzeppelin/contracts/" $0 ".sol\" as " a ";"}' lib/openzeppelin/MANIFEST

import "@openzeppelin/contracts/interfaces/IERC1271.sol" as interfaces_IERC1271;
import "@openzeppelin/contracts/interfaces/IERC1363.sol" as interfaces_IERC1363;
import "@openzeppelin/contracts/interfaces/IERC165.sol" as interfaces_IERC165;
import "@openzeppelin/contracts/interfaces/IERC1967.sol" as interfaces_IERC1967;
import "@openzeppelin/contracts/interfaces/IERC20.sol" as interfaces_IERC20;
import "@openzeppelin/contracts/interfaces/IERC5267.sol" as interfaces_IERC5267;
import "@openzeppelin/contracts/interfaces/draft-IERC1822.sol" as interfaces_draft_IERC1822;
import "@openzeppelin/contracts/interfaces/draft-IERC6093.sol" as interfaces_draft_IERC6093;
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol" as proxy_ERC1967_ERC1967Proxy;
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol" as proxy_ERC1967_ERC1967Utils;
import "@openzeppelin/contracts/proxy/Proxy.sol" as proxy_Proxy;
import "@openzeppelin/contracts/proxy/beacon/IBeacon.sol" as proxy_beacon_IBeacon;
import "@openzeppelin/contracts/proxy/utils/Initializable.sol" as proxy_utils_Initializable;
import "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol" as proxy_utils_UUPSUpgradeable;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol" as token_ERC20_IERC20;
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol" as
    token_ERC20_extensions_IERC20Permit;
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol" as token_ERC20_utils_SafeERC20;
import "@openzeppelin/contracts/utils/Address.sol" as utils_Address;
import "@openzeppelin/contracts/utils/Errors.sol" as utils_Errors;
import "@openzeppelin/contracts/utils/Panic.sol" as utils_Panic;
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol" as utils_ReentrancyGuard;
import "@openzeppelin/contracts/utils/ShortStrings.sol" as utils_ShortStrings;
import "@openzeppelin/contracts/utils/StorageSlot.sol" as utils_StorageSlot;
import "@openzeppelin/contracts/utils/Strings.sol" as utils_Strings;
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol" as utils_cryptography_ECDSA;
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol" as utils_cryptography_EIP712;
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol" as
    utils_cryptography_MessageHashUtils;
import "@openzeppelin/contracts/utils/introspection/IERC165.sol" as utils_introspection_IERC165;
import "@openzeppelin/contracts/utils/math/Math.sol" as utils_math_Math;
import "@openzeppelin/contracts/utils/math/SafeCast.sol" as utils_math_SafeCast;
import "@openzeppelin/contracts/utils/math/SignedMath.sol" as utils_math_SignedMath;
