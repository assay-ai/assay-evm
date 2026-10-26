// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.38;

/// @notice EIP-712 payment voucher signed by the payer (or one of its delegates).
/// @dev Field order must match `VOUCHER_TYPEHASH`; reordering changes every signature's meaning.
struct Voucher {
    address payer;
    address provider;
    uint64 amount;
    bytes32 resourceHash;
    bytes32 requestHash;
    uint64 seq;
    uint64 issuedAt;
    uint64 expiresAt;
}

/// @notice EIP-712 slash judgement signed by a verifier, under AssayStake's domain.
/// @dev `status` is a raw `uint8` so an out-of-range value reverts `StatusDoesNotSlash` rather
/// than an enum-conversion panic.
struct SlashAttestation {
    bytes32 requestId;
    address provider;
    address beneficiary;
    uint8 status; // ResponseClass
    uint64 penalty;
    bytes32 policy;
    uint64 issuedAt;
    uint64 expiresAt;
}

/// @notice EIP-712 authorisation by which a buyer sets its escrow spending limits.
struct SetLimits {
    address buyer;
    uint64 maxVoucherAmount;
    uint64 maxPerWindow;
    uint64 nonce;
    uint64 deadline;
}

/// @notice EIP-712 authorisation by which a buyer requests a withdrawal.
struct RequestWithdraw {
    address buyer;
    uint64 amount;
    uint64 nonce;
    uint64 deadline;
}

/// @notice EIP-712 authorisation by which a payer lets a delegate key sign vouchers, within caps
/// and until `validUntil`.
/// @dev A delegate can sign vouchers only. `nonce` is the escrow's shared `authNonce`.
struct AuthorizeDelegate {
    address payer;
    address delegate;
    uint64 maxVoucherAmount;
    uint64 maxPerWindow;
    uint64 validUntil;
    uint64 nonce;
    uint64 deadline;
}

/// @notice EIP-712 authorisation by which a payer revokes a delegate.
struct RevokeDelegate {
    address payer;
    address delegate;
    uint64 nonce;
    uint64 deadline;
}

/// @notice The admin-settable economic parameters, validated together as one set.
struct ParamSet {
    address treasury;
    address redeemer;
    uint64 unbondingPeriodSeconds;
    uint64 minimumStake;
    uint64 penaltyAmount;
    uint64 verifierDailyCap;
    uint16 takeRateBps;
    uint16 slashAgentBps;
    uint16 slashPlatformBps;
    uint16 slashCapBps;
}

/// @notice Lifecycle of a slash record.
/// @dev `None` (zero) means no record exists. A record leaves `Pending` or `Disputed` exactly once
/// into a terminal state. `Disputed` returns to `Pending` on `upholdSlash` or ends `Cancelled`.
/// New members are appended only, so stored values keep their meaning across upgrades.
enum SlashStatus {
    None,
    Pending,
    Executed,
    Cancelled,
    Disputed
}

/// @notice Verifier classification of a response. Only `DataFail` may slash stake.
/// @dev Discriminants are signed into attestations; never reorder.
enum ResponseClass {
    Pass,
    SystemError,
    RequestError,
    DataFail
}

/// @notice Why a slash record was cancelled.
/// @dev `Withdrawn`: cancelled by the admin or arbiter. `Expired`: not executed within the grace
/// period. `VerifierUnavailable`: the signing key was revoked or expired. `DisputeUnresolved`: a
/// dispute was not ruled on within `DISPUTE_TIMEOUT_SECONDS`.
enum CancelReason {
    Withdrawn,
    Expired,
    VerifierUnavailable,
    DisputeUnresolved
}

// EIP-712 type hashes. Each string is the canonical encoding of the struct above, with fields in
// declaration order.
bytes32 constant VOUCHER_TYPEHASH = keccak256(
    "Voucher(address payer,address provider,uint64 amount,bytes32 resourceHash,"
    "bytes32 requestHash,uint64 seq,uint64 issuedAt,uint64 expiresAt)"
);

bytes32 constant SLASH_ATTESTATION_TYPEHASH = keccak256(
    "SlashAttestation(bytes32 requestId,address provider,address beneficiary,"
    "uint8 status,uint64 penalty,bytes32 policy,uint64 issuedAt,uint64 expiresAt)"
);

bytes32 constant SET_LIMITS_TYPEHASH = keccak256(
    "SetLimits(address buyer,uint64 maxVoucherAmount,uint64 maxPerWindow,"
    "uint64 nonce,uint64 deadline)"
);

bytes32 constant REQUEST_WITHDRAW_TYPEHASH =
    keccak256("RequestWithdraw(address buyer,uint64 amount,uint64 nonce,uint64 deadline)");

bytes32 constant AUTHORIZE_DELEGATE_TYPEHASH = keccak256(
    "AuthorizeDelegate(address payer,address delegate,uint64 maxVoucherAmount,"
    "uint64 maxPerWindow,uint64 validUntil,uint64 nonce,uint64 deadline)"
);

bytes32 constant REVOKE_DELEGATE_TYPEHASH =
    keccak256("RevokeDelegate(address payer,address delegate,uint64 nonce,uint64 deadline)");
