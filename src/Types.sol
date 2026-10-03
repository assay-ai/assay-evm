// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.24;

/// The EIP-712 voucher. Eight fields, binding strictly more than the Solana 239-byte layout:
/// the domain tag becomes `name`+`version`, the program id becomes `verifyingContract`, and
/// `chainId` is new. `pay_to` is deliberately absent — on EVM one contract holds every buyer,
/// so "which escrow" is fully determined by `verifyingContract` + `payer`, and a `payTo` field
/// would be a second source for one identity.
///
/// Field order is `attestation.rs`'s `Voucher`, minus that one field. It is load-bearing: the
/// EIP-712 type string below lists the fields in this order, so reordering the struct without
/// reordering the string changes what every existing signature means. `test/Types.t.sol` rebuilds
/// the string from this struct's compiled ABI so that cannot happen quietly.
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

/// The verifier's judgement. Signed against X402Stake's domain, never X402Escrow's — two
/// verifying contracts means a captured attestation cannot be replayed at the escrow door even
/// if the two structs ever came to share a shape.
///
/// `status` is a raw `uint8` rather than `ResponseClass` on purpose: it arrives from off chain
/// and EIP-712 encodes an enum as `uint8` anyway, but a Solidity enum parameter reverts with a
/// bare `Panic(0x21)` on an out-of-range byte, before any of this program's own checks run. As a
/// `uint8` the value is checked against [`ResponseClass`] explicitly and refused with
/// `StatusDoesNotSlash`, which is the diagnosis a dispute needs.
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

/// The buyer's own ceilings on their escrow, signed by the buyer. No Anchor struct corresponds:
/// on Solana the buyer signs the instruction itself, so there is nothing to type. Here the
/// limits travel as a signed message the redeemer submits, so they need a type of their own —
/// with `nonce` and `deadline`, which an instruction signature did not need.
struct SetLimits {
    address buyer;
    uint64 maxVoucherAmount;
    uint64 maxPerWindow;
    uint64 nonce;
    uint64 deadline;
}

/// Opening the withdrawal delay, signed by the buyer. Same reasoning as [`SetLimits`].
struct RequestWithdraw {
    address buyer;
    uint64 amount;
    uint64 nonce;
    uint64 deadline;
}

/// Everything X402Config's admin can change, in one struct so `updateConfig` validates it as
/// a set — the two split shares are only meaningful together (update_config.rs).
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

/// state.rs's `SlashStatus`, plus a zero value it does not have.
///
/// On Solana "no record" is the absence of the `["slash", request_id]` PDA. A Solidity mapping
/// has no absence — every unread slot is zero — so the zero value must *be* "no record", or an
/// unproposed request id would read back as `Pending` and `SlashAlreadyExists` would never fire.
/// Anchor's three states keep their order after it. A record leaves `Pending` exactly once and
/// neither terminal state has an edge back out; that is what keeps the reservation accounting
/// single-entry.
enum SlashStatus {
    None,
    Pending,
    Executed,
    Cancelled
}

/// attestation.rs's `ResponseClass`, discriminants included.
///
/// The program does not classify anything — that is off-chain business logic. It carries the
/// class because the class is *signed*: the protocol design makes `DataFail` the only class that
/// may ever touch stake, so putting the byte in the message makes that a chain-enforced
/// rule rather than a backend convention, and a `SystemError` attestation cannot be resubmitted
/// as a slash because changing the byte breaks the signature. Reordering this enum silently
/// changes what an already-signed attestation means; `test/Types.t.sol` pins the discriminants.
enum ResponseClass {
    Pass,
    SystemError,
    RequestError,
    DataFail
}

/// events.rs's `CancelReason`. `Withdrawn` is the admin's decision on an arbitration outcome,
/// `Expired` is the platform failing to execute its own judgement inside the grace period, and
/// `VerifierUnavailable` is a revocation reaching through to kill work in flight — which is the
/// property the whole two-phase design exists to deliver.
enum CancelReason {
    Withdrawn,
    Expired,
    VerifierUnavailable
}

// The four EIP-712 type strings.
//
// Each is the canonical encoding of the struct above it: `Name(type field,type field,…)`, no
// spaces except the one between each type and its name, fields in declaration order. There is
// nothing in the language tying these literals to those structs — that tie is
// `test/Types.t.sol`, which rebuilds each string from the compiled struct and compares. Editing
// a struct without editing its string here (or the reverse) is a red test, not a silent change
// of meaning for every signature already issued.
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
