// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.24;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IX402Config} from "../../src/interfaces/IX402Config.sol";
import "../../src/Errors.sol";

/// The NEGATIVE case, and the reason every X402 implementation must be constructed with
/// `EIP712("x402 Settlement", "2")`. The name and version are ShortString IMMUTABLES compiled
/// into the implementation; change either and the proxy's domain separator changes on the next
/// block, and every voucher a buyer has already signed becomes unredeemable. Nothing on chain
/// stops this — `_authorizeUpgrade` checks *who*, never *what* — so the only controls are the
/// runbook (`docs/deploy-runbook.md` §7) and `Upgrade.t.sol`'s (d).
///
/// The base list and its ORDER are load-bearing, and they are copied from `X402Escrow` for that
/// reason: `Initializable` and `UUPSUpgradeable` are ERC-7201 namespaced and consume no
/// sequential slot, `EIP712` takes slots 0 and 1 (`_nameFallback`, `_versionFallback`) and
/// `ReentrancyGuard` takes slot 2 (`_status`). Declaring `CONFIG` first therefore lands it on
/// slot 3, exactly where the real escrow keeps it, so `_authorizeUpgrade` still reads the right
/// address after the upgrade and the proxy is not bricked by the test that uses it.
///
/// It is deliberately layout-incompatible in every other respect. It exists to be upgraded
/// **to** in exactly one test, and that test asserts the damage rather than the recovery. Do not
/// reuse it, and do not "fix" its layout to match: a stub that matched would prove nothing.
contract X402EscrowBadDomainV2 is Initializable, UUPSUpgradeable, EIP712, ReentrancyGuard {
    IX402Config public CONFIG;

    /// Version "3" where the shipped implementations say "2". One character.
    constructor() EIP712("x402 Settlement", "3") {
        _disableInitializers();
    }

    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    function _authorizeUpgrade(address) internal view override {
        if (msg.sender != CONFIG.admin()) revert NotAdmin();
    }
}
