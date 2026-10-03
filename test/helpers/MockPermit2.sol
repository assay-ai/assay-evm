// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IPermit2} from "../../src/interfaces/IPermit2.sol";

interface IERC20Minimal {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// NOT Permit2. A double that enforces what X402Escrow relies on and nothing else: the
/// signature recovers to `owner`, the `spender` bound into the digest is `msg.sender`, the
/// deadline has not passed, and a nonce is spent once.
///
/// It does **not** reproduce Permit2's real EIP-712 domain or typehash — its digest is a plain
/// `keccak256(abi.encode(…))` with a literal tag, so nothing here proves anything about
/// compatibility with the canonical deployment. Compatibility with the canonical
/// deployment at `0x000000000022D473030F116dDEE9F6B43aC78BA3` is exercised by
/// `test/fork/Permit2.fork.t.sol` against a live RPC.
contract MockPermit2 is IPermit2 {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    error InvalidSigner();
    error PermitExpired();
    error NonceUsed();

    mapping(address => mapping(uint256 => bool)) public used;

    function digest(address token, uint256 amount, uint256 nonce, uint256 deadline, address spender)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode("mock-permit2", token, amount, nonce, deadline, spender));
    }

    /// Test helper: what a buyer's wallet would sign for `spender` (the escrow).
    function signFor(
        uint256 pk,
        address token,
        uint256 amount,
        uint256 nonce,
        uint256 deadline,
        address spender
    ) external pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(pk, digest(token, amount, nonce, deadline, spender));
        return abi.encodePacked(r, s, v);
    }

    function permitTransferFrom(
        PermitTransferFrom calldata permit,
        SignatureTransferDetails calldata details,
        address owner,
        bytes calldata signature
    ) external override {
        if (block.timestamp > permit.deadline) revert PermitExpired();
        if (used[owner][permit.nonce]) revert NonceUsed();
        bytes32 d = digest(
            permit.permitted.token,
            permit.permitted.amount,
            permit.nonce,
            permit.deadline,
            msg.sender
        );
        (address signer,,) = ECDSA.tryRecover(d, signature);
        if (signer == address(0) || signer != owner) revert InvalidSigner();
        used[owner][permit.nonce] = true;
        IERC20Minimal(permit.permitted.token).transferFrom(
            owner, details.to, details.requestedAmount
        );
    }
}

interface IDepositWithPermit2 {
    function depositWithPermit2(
        address buyer,
        uint64 amount,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external;
}

/// A Permit2 that re-enters the escrow through the door it was called from — the Permit2 half of
/// `ReentrantUSDG`, and the only thing that can exercise `nonReentrant` on `depositWithPermit2`.
///
/// `PERMIT2` is an arbitrary address this contract calls out to, so it is as much an untrusted
/// caller-back as the asset is. It funds its own re-entry for the same reason `ReentrantUSDG`
/// does: a nested call that would have failed on its own merits proves nothing about the guard.
contract ReentrantPermit2 is IPermit2 {
    address public escrow;
    uint64 public reenterAmount;
    bool private entered;

    function setEscrow(address escrow_, uint64 amount) external {
        escrow = escrow_;
        reenterAmount = amount;
    }

    function permitTransferFrom(
        PermitTransferFrom calldata permit,
        SignatureTransferDetails calldata details,
        address owner,
        bytes calldata
    ) external override {
        if (!entered) {
            entered = true;
            // A second, self-consistent deposit for the same owner, from inside the first.
            IDepositWithPermit2(escrow).depositWithPermit2(
                owner, reenterAmount, permit.nonce + 1, permit.deadline, hex""
            );
        }
        IERC20Minimal(permit.permitted.token).transferFrom(
            owner, details.to, details.requestedAmount
        );
    }
}
