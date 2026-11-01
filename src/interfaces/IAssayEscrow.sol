// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IAssayConfig} from "./IAssayConfig.sol";
import {IAssayStakeView} from "./IAssayStakeView.sol";
import {AssayEscrowStorage} from "../AssayEscrowStorage.sol";
import {Voucher, ChannelVoucher, ChannelRef} from "../Types.sol";

/// @title IAssayEscrow
/// @notice Every function the escrow proxy answers: the `AssayEscrow` core plus the
///         `AssayEscrowExtension` its `fallback` reaches. This is the integrator ABI; the core's
///         artifact alone lacks the extension's functions. `test/EscrowSplit.t.sol` holds it equal
///         to the union of both contracts' selectors.
interface IAssayEscrow {
    // --- core ---------------------------------------------------------------------------
    function CONFIG() external view returns (IAssayConfig);
    function STAKE() external view returns (IAssayStakeView);
    function ASSET() external view returns (IERC20);
    function totalEscrowed() external view returns (uint128);
    function totalHeld() external view returns (uint128);
    function EXTENSION() external view returns (address);
    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function UPGRADE_INTERFACE_VERSION() external view returns (string memory);
    function proxiableUUID() external view returns (bytes32);
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;
    function eip712Domain()
        external
        view
        returns (
            bytes1 fields,
            string memory name,
            string memory version,
            uint256 chainId,
            address verifyingContract,
            bytes32 salt,
            uint256[] memory extensions
        );
    function initialize(IAssayConfig config, IAssayStakeView stake, IERC20 asset) external;

    function escrowOf(address buyer) external view returns (AssayEscrowStorage.Escrow memory);
    function held(address payer, uint64 seq)
        external
        view
        returns (AssayEscrowStorage.HeldPayment memory);
    function delegationOf(address payer, address delegate)
        external
        view
        returns (AssayEscrowStorage.Delegation memory);
    function delegatesOf(address payer) external view returns (address[] memory);
    function channelBooks(bytes32 key, address to)
        external
        view
        returns (uint256 state, uint128 unpaid, uint128 totalUnpaid, uint128 held);

    function deposit(uint64 amount) external;
    function depositFor(address buyer, uint64 amount) external;
    function setLimits(uint64 maxVoucherAmount, uint64 maxPerWindow) external;
    function requestWithdraw(uint64 amount) external;
    function withdraw() external;
    function authorizeDelegate(
        address delegate,
        uint64 maxVoucherAmount,
        uint64 maxPerWindow,
        uint64 validUntil
    ) external;
    function revokeDelegate(address delegate) external;

    function collectHeld(address payer, uint64 seq) external;
    function collectHeldBatch(address[] calldata payers, uint64[] calldata seqs) external;
    function refundHeld(address payer, uint64 seq) external;
    function refundHeldBatch(address[] calldata payers, uint64[] calldata seqs) external;

    function settleChannels(
        ChannelVoucher[] calldata vs,
        bytes calldata sigs,
        uint64[] calldata fromSettled,
        uint64[] calldata charges
    ) external;
    function collectChannels(ChannelRef[] calldata refs, uint64[] calldata keepHeld) external;
    function refundChannels(
        ChannelRef[] calldata refs,
        uint40[] calldata buckets,
        uint64[] calldata amounts,
        bytes32[] calldata refundIds
    ) external;
    function claimUnpaid(address to) external;

    // --- extension ----------------------------------------------------------------------
    function redeemVoucher(Voucher calldata v, bytes calldata sig) external;
    function redeemVoucherBatch(Voucher[] calldata vs, bytes[] calldata sigs) external;
    function setLimitsBySig(
        address buyer,
        uint64 maxVoucherAmount,
        uint64 maxPerWindow,
        uint64 nonce,
        uint64 deadline,
        bytes calldata sig
    ) external;
    function requestWithdrawBySig(
        address buyer,
        uint64 amount,
        uint64 nonce,
        uint64 deadline,
        bytes calldata sig
    ) external;
    function authorizeDelegateBySig(
        address payer,
        address delegate,
        uint64 maxVoucherAmount,
        uint64 maxPerWindow,
        uint64 validUntil,
        uint64 nonce,
        uint64 deadline,
        bytes calldata sig
    ) external;
    function revokeDelegateBySig(
        address payer,
        address delegate,
        uint64 nonce,
        uint64 deadline,
        bytes calldata sig
    ) external;
    function effectiveCapsOf(address payer, address delegate)
        external
        view
        returns (
            uint64 maxVoucherAmount,
            uint64 maxPerWindow,
            uint64 delegateMaxVoucherAmount,
            uint64 delegateMaxPerWindow
        );
}
