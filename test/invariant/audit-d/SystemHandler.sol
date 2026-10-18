// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {X402Config} from "../../../src/X402Config.sol";
import {X402Escrow} from "../../../src/X402Escrow.sol";
import {X402Stake} from "../../../src/X402Stake.sol";
import {IX402Config} from "../../../src/interfaces/IX402Config.sol";
import {IX402StakeView} from "../../../src/interfaces/IX402StakeView.sol";
import {
    Voucher, SlashAttestation, ResponseClass, SlashStatus, ParamSet
} from "../../../src/Types.sol";
import {Constants} from "../../../src/Constants.sol";
import {Fee} from "../../../src/libraries/Fee.sol";
import {MockUSDG} from "../../helpers/MockUSDG.sol";
import {VoucherSigner} from "../../helpers/VoucherSigner.sol";

/// Audit D: one handler over the WHOLE system (Config + Stake + Escrow sharing one token), so the
/// cross-contract edge (`redeem` reads `STAKE.bondedOf`) and the config levers (pause, blocklist,
/// slash delay, arbiter, verifier registry, params) are in the same random walk as the money.
///
/// Every call is a low-level `call` under `vm.prank`, so a refusal never aborts the step: the
/// handler checks, for every attempt, the property that relates its OUTCOME to the pre-state
/// (e.g. "succeeded => not paused", "caller is the provider and the record is disputable =>
/// succeeded"). A breach increments `violations[key]` and records the first message; the
/// invariant contract asserts every key is still zero.
///
/// Around every action `_pre`/`_post` diff every slash record (status machine, frozen fields,
/// executableAt monotonicity, uphold deadline) and every blocked subject's balances.
contract SystemHandler is Test {
    MockUSDG public usdg;
    X402Config public config;
    X402Stake public stake;
    X402Escrow public escrow;

    address public constant OWNER = address(0x0A1E);
    address public constant ADMIN0 = address(0xADAA);
    address public constant ADMIN1 = address(0xADAB);
    address public constant TREASURY = address(0x7EA5);
    address public constant REDEEMER = address(0x4EED);

    address[3] public buyers;
    uint256[3] internal buyerKeys;
    address[3] public delegates;
    uint256[3] internal delegateKeys;
    address[3] public providers;
    /// Signers that can be registered as verifiers. Index 3 and 4 are the two ARBITER candidates,
    /// so the walk can reach "the arbiter is (also) a verifier".
    address[5] public signers;
    uint256[5] internal signerKeys;
    address[2] public beneficiaries;
    address[2] public strangers;

    // --- ghosts --------------------------------------------------------------------------------
    uint256 public donatedEscrow;
    uint256 public donatedStake;

    struct Snap {
        SlashStatus status;
        uint64 executableAt;
        uint64 disputedAt;
        uint64 reserved;
        uint64 penalty;
        uint64 capAllowance;
        address provider;
        address verifier;
        address beneficiary;
    }

    bytes32[] public ids;
    mapping(bytes32 => Snap) internal snap;
    uint256 internal nextId;
    uint256 internal constant MAX_RECORDS = 40;

    mapping(bytes32 => uint256) public violations;
    string public firstViolation;
    bytes32 public firstViolationKey;

    /// Coverage: attempts and successes per action name.
    mapping(bytes32 => uint256) public tried;
    mapping(bytes32 => uint256) public ok;
    bytes32[] public actionNames;
    mapping(bytes32 => bool) internal known;

    bytes32 internal currentAction;

    // pre-state of the blocked subjects
    uint128[3] internal preBuyerBal;
    bool[3] internal preBuyerBlocked;
    uint128[3] internal preProvAtRisk;
    bool[3] internal preProvBlocked;
    uint64[3] internal seenSeqHigh;
    uint64[3] internal seenAuthNonce;

    constructor() {
        vm.warp(1_760_000_000);
        for (uint256 i = 0; i < 3; i++) {
            buyerKeys[i] = 0xB000 + i + 1;
            buyers[i] = vm.addr(buyerKeys[i]);
            delegateKeys[i] = 0xD000 + i + 1;
            delegates[i] = vm.addr(delegateKeys[i]);
        }
        providers = [address(0x9301), address(0x9302), address(0x9303)];
        for (uint256 i = 0; i < 5; i++) {
            signerKeys[i] = 0x5160 + i + 1;
            signers[i] = vm.addr(signerKeys[i]);
        }
        beneficiaries = [address(0xBE01), address(0xBE02)];
        strangers = [address(0x5701), address(0x5702)];

        usdg = new MockUSDG();
        ParamSet memory p = ParamSet({
            treasury: TREASURY,
            redeemer: REDEEMER,
            unbondingPeriodSeconds: 14 * 86_400,
            // = the providers' opening bond, and the smallest the provider-day rule admits
            // (review R-1: 1 000 USDG * 1 000 bps = 100 USDG = 2 * penaltyAmount). Both day caps
            // hold exactly two maximal records, so window clamps are reached through several
            // records per day; a provider slashed under the minimum also stops redeeming.
            minimumStake: 1_000_000_000,
            penaltyAmount: 50_000_000,
            verifierDailyCap: 100_000_000, // = 2 * penaltyAmount (audit G G-1)
            takeRateBps: 1_000,
            slashAgentBps: 6_000,
            slashPlatformBps: 3_000,
            slashCapBps: 1_000
        });
        config = X402Config(
            address(
                new ERC1967Proxy(
                    address(new X402Config()),
                    abi.encodeCall(X402Config.initialize, (p, ADMIN0, OWNER))
                )
            )
        );
        stake = X402Stake(
            address(
                new ERC1967Proxy(
                    address(new X402Stake()),
                    abi.encodeCall(
                        X402Stake.initialize, (IX402Config(address(config)), IERC20(address(usdg)))
                    )
                )
            )
        );
        escrow = X402Escrow(
            address(
                new ERC1967Proxy(
                    address(new X402Escrow()),
                    abi.encodeCall(
                        X402Escrow.initialize,
                        (
                            IX402Config(address(config)),
                            IX402StakeView(address(stake)),
                            IERC20(address(usdg)),
                            address(0)
                        )
                    )
                )
            )
        );

        vm.startPrank(ADMIN0);
        config.setArbiter(signers[3]);
        config.registerVerifier(signers[0], bytes32("v0"), uint64(block.timestamp) + 300 * 86_400);
        vm.stopPrank();

        for (uint256 i = 0; i < 3; i++) {
            usdg.mint(address(this), 1_000_000_000);
            usdg.approve(address(stake), 1_000_000_000);
            stake.depositStakeFor(providers[i], 1_000_000_000);
            // Buyers start funded and armed so the redeem path is reachable from step one.
            usdg.mint(buyers[i], 500_000_000);
            vm.startPrank(buyers[i]);
            usdg.approve(address(escrow), type(uint256).max);
            escrow.deposit(500_000_000);
            escrow.setLimits(100_000_000, 300_000_000);
            vm.stopPrank();
            _ghostSet(buyers[i], address(0), 100_000_000, 300_000_000, type(uint64).max);
        }
    }

    // =========================================================================================
    // plumbing
    // =========================================================================================

    function _violate(bytes32 key, string memory why) internal {
        if (violations[key] == 0 && firstViolationKey == bytes32(0)) {
            firstViolationKey = key;
            firstViolation = string.concat(_s(currentAction), ": ", why);
        }
        violations[key] += 1;
    }

    function _s(bytes32 b) internal pure returns (string memory) {
        uint256 n;
        while (n < 32 && b[n] != 0) n++;
        bytes memory out = new bytes(n);
        for (uint256 i = 0; i < n; i++) {
            out[i] = b[i];
        }
        return string(out);
    }

    function _call(address who, address target, bytes memory data)
        internal
        returns (bool success)
    {
        if (!known[currentAction]) {
            known[currentAction] = true;
            actionNames.push(currentAction);
        }
        tried[currentAction] += 1;
        vm.prank(who);
        (success,) = target.call(data);
        if (success) ok[currentAction] += 1;
    }

    function actionCount() external view returns (uint256) {
        return actionNames.length;
    }

    /// Handler calls in this run that did not revert, early returns included. Every action
    /// reaches its target through `_call`, so in practice this is every fuzzed call. Read by
    /// `SystemInvariantsTest.afterInvariant` to tell a full run from a shrunk sequence.
    uint256 public steps;

    modifier step(bytes32 name) {
        steps += 1;
        currentAction = name;
        _pre();
        _;
        _post();
    }

    function _pre() internal {
        for (uint256 i = 0; i < 3; i++) {
            preBuyerBal[i] = escrow.escrowOf(buyers[i]).balance;
            preBuyerBlocked[i] = config.blocked(buyers[i]);
            X402Stake.ProviderStake memory s = stake.stakeOf(providers[i]);
            preProvAtRisk[i] = s.bonded + s.unbonding;
            preProvBlocked[i] = config.blocked(providers[i]);
        }
    }

    function _post() internal {
        // seqHigh and authNonce are high-water marks; the delegate list agrees with positions.
        for (uint256 i = 0; i < 3; i++) {
            X402Escrow.Escrow memory e = escrow.escrowOf(buyers[i]);
            if (e.seqHigh < seenSeqHigh[i]) _violate("monotonic", "seqHigh went backwards");
            if (e.authNonce < seenAuthNonce[i]) _violate("monotonic", "authNonce went backwards");
            seenSeqHigh[i] = e.seqHigh;
            seenAuthNonce[i] = e.authNonce;
            address[] memory list = escrow.delegatesOf(buyers[i]);
            for (uint256 k = 0; k < list.length; k++) {
                X402Escrow.Delegation memory d = escrow.delegationOf(buyers[i], list[k]);
                if (d.listPosition != k + 1 || d.revoked) {
                    _violate("delegateList", "listed delegate has a wrong position or is revoked");
                }
            }
            for (uint256 k = 0; k < 3; k++) {
                X402Escrow.Delegation memory d = escrow.delegationOf(buyers[i], delegates[k]);
                if (d.listPosition > list.length) {
                    _violate("delegateList", "position past the list");
                }
                if (d.listPosition != 0 && list[d.listPosition - 1] != delegates[k]) {
                    _violate("delegateList", "position points at another delegate");
                }
                if (d.listPosition == 0 && d.validUntil != 0 && !d.revoked) {
                    _violate("delegateList", "an unlisted grant is still live");
                }
            }
        }
        // Blocked subjects: balances never decrease through their own (or any non-slash) action.
        for (uint256 i = 0; i < 3; i++) {
            if (preBuyerBlocked[i] && config.blocked(buyers[i])) {
                if (escrow.escrowOf(buyers[i]).balance < preBuyerBal[i]) {
                    _violate("blockedBalance", "a blocked buyer's escrow balance decreased");
                }
            }
            if (
                preProvBlocked[i] && config.blocked(providers[i]) && currentAction != "executeSlash"
            ) {
                X402Stake.ProviderStake memory s = stake.stakeOf(providers[i]);
                if (s.bonded + s.unbonding < preProvAtRisk[i]) {
                    _violate("blockedBalance", "a blocked provider's stake decreased");
                }
            }
        }

        // The status machine, the frozen fields, and executableAt monotonicity.
        uint64 nowTs = uint64(block.timestamp);
        for (uint256 k = 0; k < ids.length; k++) {
            bytes32 id = ids[k];
            Snap memory o = snap[id];
            X402Stake.SlashRecord memory r = stake.slashRecordOf(id);
            if (
                r.provider != o.provider || r.verifier != o.verifier
                    || r.beneficiary != o.beneficiary || r.penalty != o.penalty
                    || r.reserved != o.reserved || r.capAllowance != o.capAllowance
            ) _violate("frozenField", "a frozen record field changed");
            if (r.executableAt < o.executableAt) {
                _violate("executableAtEarlier", "executableAt moved earlier");
            }
            if (r.disputedAt != o.disputedAt && o.disputedAt != 0) {
                _violate("disputedTwice", "disputedAt was rewritten");
            }
            if (r.status != o.status) {
                bool legal;
                if (o.status == SlashStatus.Pending) {
                    if (r.status == SlashStatus.Disputed) {
                        legal = o.disputedAt == 0 && r.disputedAt == nowTs && nowTs < o.executableAt;
                        if (o.disputedAt != 0) _violate("disputedTwice", "second dispute landed");
                    } else if (r.status == SlashStatus.Executed) {
                        legal = nowTs >= o.executableAt
                            && uint256(nowTs)
                                < uint256(o.executableAt) + Constants.SLASH_EXECUTION_GRACE_SECONDS;
                    } else if (r.status == SlashStatus.Cancelled) {
                        legal = true;
                    }
                } else if (o.status == SlashStatus.Disputed) {
                    if (r.status == SlashStatus.Pending) {
                        bool inTime = uint256(nowTs)
                            < uint256(o.disputedAt) + Constants.DISPUTE_TIMEOUT_SECONDS;
                        bool exOk =
                            r.executableAt == (nowTs > o.executableAt ? nowTs : o.executableAt);
                        legal = inTime && exOk;
                        if (!inTime) _violate("upholdLate", "uphold at/after disputedAt+30d");
                        if (!exOk) _violate("executableAtEarlier", "uphold executableAt != max");
                    } else if (r.status == SlashStatus.Cancelled) {
                        legal = true;
                    } else if (r.status == SlashStatus.Executed) {
                        _violate("disputedExecuted", "a Disputed record was executed");
                    }
                }
                if (!legal) _violate("transition", "illegal status transition");
            } else if (r.executableAt != o.executableAt) {
                _violate("transition", "executableAt moved without an uphold");
            }
            snap[id] = Snap({
                status: r.status,
                executableAt: r.executableAt,
                disputedAt: r.disputedAt,
                reserved: r.reserved,
                penalty: r.penalty,
                capAllowance: r.capAllowance,
                provider: r.provider,
                verifier: r.verifier,
                beneficiary: r.beneficiary
            });
        }
    }

    // --- actor selection ------------------------------------------------------------------------

    function _admin() internal view returns (address) {
        return config.admin();
    }

    function _arbiter() internal view returns (address) {
        return config.arbiter();
    }

    /// A caller drawn from every role, for the role-check doors.
    function _anyCaller(uint256 seed) internal view returns (address) {
        uint256 c = seed % 10;
        if (c == 0 || c == 1) return _admin();
        if (c == 2 || c == 3) return _arbiter() == address(0) ? strangers[0] : _arbiter();
        if (c == 4) return OWNER;
        if (c == 5) return strangers[seed % 2];
        if (c == 6) return signers[0];
        if (c == 7) return providers[seed % 3];
        if (c == 8) return buyers[seed % 3];
        return REDEEMER;
    }

    function _anyAddress(uint256 seed) internal view returns (address) {
        uint256 c = seed % 8;
        if (c == 0) return buyers[(seed / 8) % 3];
        if (c == 1) return providers[(seed / 8) % 3];
        if (c == 2) return delegates[(seed / 8) % 3];
        if (c == 3) return signers[(seed / 8) % 5];
        if (c == 4) return strangers[(seed / 8) % 2];
        if (c == 5) return _arbiter();
        if (c == 6) return beneficiaries[(seed / 8) % 2];
        return TREASURY;
    }

    function _pickId(uint256 seed) internal view returns (bytes32) {
        if (ids.length == 0) return bytes32(uint256(1));
        return ids[seed % ids.length];
    }

    /// Prefers an OPEN record (Pending/Disputed) three times in four, so the slash doors are hit.
    function _pickOpen(uint256 seed) internal view returns (bytes32) {
        uint256 n = ids.length;
        if (n == 0) return bytes32(uint256(1));
        if (seed % 4 == 3) return ids[seed % n];
        for (uint256 k = 0; k < n; k++) {
            bytes32 id = ids[(seed + k) % n];
            if (_open(stake.slashRecordOf(id).status)) return id;
        }
        return ids[seed % n];
    }

    function _open(SlashStatus s) internal pure returns (bool) {
        return s == SlashStatus.Pending || s == SlashStatus.Disputed;
    }

    // =========================================================================================
    // escrow
    // =========================================================================================

    function deposit(uint256 funderSeed, uint256 buyerSeed, uint64 amount)
        external
        step("deposit")
    {
        address funder = funderSeed % 4 == 3 ? strangers[funderSeed % 2] : buyers[funderSeed % 3];
        address buyer = buyers[buyerSeed % 3];
        amount = uint64(bound(amount, 0, 1_000_000_000));
        usdg.mint(funder, amount);
        vm.prank(funder);
        usdg.approve(address(escrow), amount);
        bool paused = config.paused();
        bool blk = config.blocked(buyer) || config.blocked(funder);
        bool s = funder == buyer
            ? _call(funder, address(escrow), abi.encodeCall(X402Escrow.deposit, (amount)))
            : _call(funder, address(escrow), abi.encodeCall(X402Escrow.depositFor, (buyer, amount)));
        if (s && paused) _violate("pause", "deposit while paused");
        if (s && blk) _violate("block", "deposit by/for a blocked party");
    }

    function setLimits(uint256 buyerSeed, uint64 a, uint64 b) external step("setLimits") {
        address buyer = buyers[buyerSeed % 3];
        a = uint64(bound(a, 0, 200_000_000));
        b = uint64(bound(b, 0, 600_000_000));
        bool paused = config.paused();
        bool blk = config.blocked(buyer);
        bool s = _call(buyer, address(escrow), abi.encodeCall(X402Escrow.setLimits, (a, b)));
        if (s) _ghostSet(buyer, address(0), a, b, type(uint64).max);
        if (s && paused) _violate("pause", "setLimits while paused");
        if (s && blk) _violate("block", "setLimits by a blocked buyer");
    }

    function _sigParams(address buyer, uint256 nonceSeed, uint64 dl)
        internal
        view
        returns (uint64 nonce, uint64 deadline)
    {
        nonce = escrow.escrowOf(buyer).authNonce;
        if (nonceSeed % 5 == 4) nonce += 1;
        if (nonceSeed % 7 == 6 && nonce > 0) nonce -= 1;
        deadline = uint64(block.timestamp) + uint64(bound(dl, 0, 3_700));
        if (nonceSeed % 11 == 10) deadline = uint64(block.timestamp) - 1;
    }

    function setLimitsBySig(uint256 buyerSeed, uint64 a, uint64 b, uint256 nonceSeed, uint64 dl)
        external
        step("setLimitsBySig")
    {
        uint256 i = buyerSeed % 3;
        address buyer = buyers[i];
        a = uint64(bound(a, 0, 200_000_000));
        b = uint64(bound(b, 0, 600_000_000));
        (uint64 nonce, uint64 deadline) = _sigParams(buyer, nonceSeed, dl);
        bytes memory sig = VoucherSigner.signSetLimits(
            buyerKeys[i], escrow.DOMAIN_SEPARATOR(), buyer, a, b, nonce, deadline
        );
        bool paused = config.paused();
        bool blk = config.blocked(buyer);
        bool s = _call(
            strangers[0],
            address(escrow),
            abi.encodeCall(X402Escrow.setLimitsBySig, (buyer, a, b, nonce, deadline, sig))
        );
        if (s) _ghostSet(buyer, address(0), a, b, type(uint64).max);
        if (s && paused) _violate("pause", "setLimitsBySig while paused");
        if (s && blk) _violate("block", "setLimitsBySig for a blocked buyer");
    }

    function requestWithdraw(uint256 buyerSeed, uint64 amount, bool bySig, uint256 nonceSeed)
        external
        step("requestWithdraw")
    {
        uint256 i = buyerSeed % 3;
        address buyer = buyers[i];
        amount = uint64(bound(amount, 0, 1_000_000_000));
        bool paused = config.paused();
        bool blk = config.blocked(buyer);
        bool s;
        if (bySig) {
            currentAction = "requestWithdrawBySig";
            (uint64 nonce, uint64 deadline) = _sigParams(buyer, nonceSeed, uint64(nonceSeed >> 8));
            bytes memory sig = VoucherSigner.signRequestWithdraw(
                buyerKeys[i], escrow.DOMAIN_SEPARATOR(), buyer, amount, nonce, deadline
            );
            s = _call(
                REDEEMER,
                address(escrow),
                abi.encodeCall(
                    X402Escrow.requestWithdrawBySig, (buyer, amount, nonce, deadline, sig)
                )
            );
        } else {
            s = _call(buyer, address(escrow), abi.encodeCall(X402Escrow.requestWithdraw, (amount)));
        }
        if (s && paused) _violate("pause", "requestWithdraw while paused");
        if (s && blk) _violate("block", "requestWithdraw by a blocked buyer");
    }

    function withdraw(uint256 buyerSeed) external step("withdraw") {
        address buyer = buyers[buyerSeed % 3];
        X402Escrow.Escrow memory e = escrow.escrowOf(buyer);
        uint256 tokBefore = usdg.balanceOf(buyer);
        bool paused = config.paused();
        bool blk = config.blocked(buyer);
        bool s = _call(buyer, address(escrow), abi.encodeCall(X402Escrow.withdraw, ()));
        if (s) {
            if (paused) _violate("pause", "withdraw while paused");
            if (blk) _violate("block", "withdraw by a blocked buyer");
            if (block.timestamp < e.withdrawAvailableAt) _violate("escrowExit", "early withdraw");
            uint256 want = e.withdrawRequested < e.balance ? e.withdrawRequested : e.balance;
            if (usdg.balanceOf(buyer) - tokBefore != want) _violate("escrowExit", "wrong payout");
        }
    }

    function authorizeDelegate(
        uint256 buyerSeed,
        uint256 delSeed,
        uint64 a,
        uint64 b,
        uint64 life,
        bool bySig,
        uint256 nonceSeed
    ) external step("authorizeDelegate") {
        uint256 i = buyerSeed % 3;
        address buyer = buyers[i];
        address del = delegates[delSeed % 3];
        a = uint64(bound(a, 0, 150_000_000));
        b = uint64(bound(b, 0, 400_000_000));
        uint64 validUntil = uint64(block.timestamp) + uint64(bound(life, 0, 400 * 86_400));
        bool paused = config.paused();
        bool blk = config.blocked(buyer) || config.blocked(del);
        bool s;
        if (bySig) {
            currentAction = "authorizeDelegateBySig";
            (uint64 nonce, uint64 deadline) = _sigParams(buyer, nonceSeed, uint64(nonceSeed >> 8));
            bytes memory sig = VoucherSigner.signAuthorizeDelegate(
                buyerKeys[i],
                escrow.DOMAIN_SEPARATOR(),
                buyer,
                del,
                a,
                b,
                validUntil,
                nonce,
                deadline
            );
            s = _call(
                strangers[1],
                address(escrow),
                abi.encodeCall(
                    X402Escrow.authorizeDelegateBySig,
                    (buyer, del, a, b, validUntil, nonce, deadline, sig)
                )
            );
        } else {
            s = _call(
                buyer,
                address(escrow),
                abi.encodeCall(X402Escrow.authorizeDelegate, (del, a, b, validUntil))
            );
        }
        if (s) _ghostSet(buyer, del, a, b, validUntil);
        if (s && paused) _violate("pause", "authorizeDelegate while paused");
        if (s && blk) _violate("block", "authorizeDelegate with a blocked party");
    }

    /// revokeDelegate must ALWAYS work for a listed delegate (paused or blocked or not).
    function revokeDelegate(uint256 buyerSeed, uint256 delSeed, bool bySig, uint256 nonceSeed)
        external
        step("revokeDelegate")
    {
        uint256 i = buyerSeed % 3;
        address buyer = buyers[i];
        address del = delegates[delSeed % 3];
        bool listed = escrow.delegationOf(buyer, del).listPosition != 0;
        bool s;
        if (bySig) {
            currentAction = "revokeDelegateBySig";
            uint64 nonce = escrow.escrowOf(buyer).authNonce;
            uint64 deadline = uint64(block.timestamp) + uint64(bound(nonceSeed, 0, 3_600));
            bytes memory sig = VoucherSigner.signRevokeDelegate(
                buyerKeys[i], escrow.DOMAIN_SEPARATOR(), buyer, del, nonce, deadline
            );
            s = _call(
                strangers[0],
                address(escrow),
                abi.encodeCall(X402Escrow.revokeDelegateBySig, (buyer, del, nonce, deadline, sig))
            );
        } else {
            s = _call(buyer, address(escrow), abi.encodeCall(X402Escrow.revokeDelegate, (del)));
        }
        if (s) _ghostRevoke(buyer, del);
        if (listed && !s) _violate("revokeLiveness", "revokeDelegate refused a listed delegate");
        if (!listed && s) {
            _violate("revokeLiveness", "revokeDelegate accepted an unlisted delegate");
        }
    }

    struct RedeemPlan {
        uint256 signerIdx; // 0 = payer, 1..3 = delegate
        address provider;
        uint64 amount;
        uint64 seqDelta;
        uint64 skew;
        uint64 life;
    }

    function _voucher(uint256 buyerIdx, RedeemPlan memory rp, uint64 seq)
        internal
        view
        returns (Voucher memory v, bytes memory sig, address delegate)
    {
        uint64 nowTs = uint64(block.timestamp);
        // issuedAt in [now - 2300, now + 200]
        uint64 issuedAt = nowTs + 200 - uint64(bound(rp.skew, 0, 2_500));
        v = Voucher({
            payer: buyers[buyerIdx],
            provider: rp.provider,
            amount: rp.amount,
            resourceHash: keccak256("audit-d"),
            requestHash: keccak256(abi.encode(buyerIdx, seq, rp.amount, nowTs)),
            seq: seq,
            issuedAt: issuedAt,
            expiresAt: issuedAt + uint64(bound(rp.life, 1, 320))
        });
        uint256 key = rp.signerIdx == 0 ? buyerKeys[buyerIdx] : delegateKeys[rp.signerIdx - 1];
        delegate = rp.signerIdx == 0 ? address(0) : delegates[rp.signerIdx - 1];
        sig = VoucherSigner.signVoucher(key, escrow.DOMAIN_SEPARATOR(), v);
    }

    function _plan(uint256 seed, uint64 amount, uint256 buyerIdx)
        internal
        view
        returns (RedeemPlan memory rp)
    {
        rp.signerIdx = seed % 2 == 0 ? 0 : 1 + (seed >> 1) % 3;
        rp.provider = seed % 13 == 12 ? strangers[0] : providers[(seed >> 4) % 3];
        X402Escrow.Escrow memory e = escrow.escrowOf(buyers[buyerIdx]);
        uint64 ceil = e.maxVoucherAmount;
        if (e.balance < ceil) ceil = uint64(e.balance);
        if (ceil == 0) ceil = 1;
        rp.amount = uint64(bound(amount, 1, (seed % 9 == 8) ? 2 * uint256(ceil) : ceil));
        rp.seqDelta = uint64((seed >> 8) % 3);
        rp.skew = uint64(seed >> 16);
        rp.life = uint64(seed >> 80);
    }

    /// One voucher, through the single door, by the redeemer (or by an impostor).
    function redeem(uint256 buyerSeed, uint256 seed, uint64 amount) external step("redeem") {
        uint256 bi = buyerSeed % 3;
        RedeemPlan memory rp = _plan(seed, amount, bi);
        X402Escrow.Escrow memory e = escrow.escrowOf(buyers[bi]);
        (Voucher memory v, bytes memory sig, address del) =
            _voucher(bi, rp, e.seqHigh + rp.seqDelta);
        address caller = seed % 17 == 16 ? strangers[1] : REDEEMER;

        uint256 provBefore = usdg.balanceOf(v.provider);
        uint256 treasBefore = usdg.balanceOf(TREASURY);
        uint128 heldBefore = escrow.totalHeld();
        bool paused = config.paused();
        bool blk = config.blocked(v.payer) || config.blocked(v.provider)
            || (del != address(0) && config.blocked(del));
        uint16 take = config.params().takeRateBps;
        uint64 hold = config.collectHoldSeconds();
        bool s = _call(caller, address(escrow), abi.encodeCall(X402Escrow.redeemVoucher, (v, sig)));
        if (!s) return;
        if (caller != REDEEMER) _violate("role", "redeem by a non-redeemer");
        if (paused) _violate("pause", "redeem while paused");
        if (blk) _violate("block", "redeem paid/charged a blocked party");
        _checkRedeemCaps(v, del, 0, 0);
        // Redeem into hold: nobody is paid, the amount is held with the take rate and clock frozen.
        if (usdg.balanceOf(v.provider) != provBefore) _violate("payout", "provider paid at redeem");
        if (usdg.balanceOf(TREASURY) != treasBefore) _violate("payout", "treasury paid at redeem");
        X402Escrow.HeldPayment memory hp = escrow.held(v.payer, v.seq);
        if (
            hp.status != X402Escrow.HeldStatus.Held || hp.amount != v.amount
                || hp.provider != v.provider || hp.takeRateBps != take
                || hp.collectableAt != uint64(block.timestamp) + hold
        ) _violate("hold", "the held record is not the redemption");
        if (escrow.totalHeld() != heldBefore + v.amount) _violate("hold", "totalHeld not raised");
        if (escrow.escrowOf(v.payer).balance != e.balance - v.amount) {
            _violate("payout", "payer debit");
        }
    }

    /// Redeem into hold: a collect of one of the payer's recent seqs, by the redeemer or a
    /// stranger. It may land only on a `Held` record, not paused, neither payer nor provider
    /// blocked, from `collectableAt` for the redeemer and `collectableAt + HELD_TIMEOUT` for
    /// anybody else — and it pays exactly the split frozen at redemption.
    function collectHeld(uint256 buyerSeed, uint256 seed) external step("collectHeld") {
        uint256 bi = buyerSeed % 3;
        address payer = buyers[bi];
        uint64 high = escrow.escrowOf(payer).seqHigh;
        uint64 back = uint64(seed % 4);
        if (high <= back) return;
        uint64 seq = high - back;
        X402Escrow.HeldPayment memory hp = escrow.held(payer, seq);
        address caller = seed % 5 == 4 ? strangers[0] : REDEEMER;
        address treasury = config.params().treasury;
        uint256 provBefore = usdg.balanceOf(hp.provider);
        uint256 treasBefore = usdg.balanceOf(treasury);
        bool paused = config.paused();
        bool blk = config.blocked(payer) || config.blocked(hp.provider);
        uint256 opensAt = uint256(hp.collectableAt)
            + (caller == REDEEMER ? 0 : uint256(Constants.HELD_TIMEOUT_SECONDS));
        bool s =
            _call(caller, address(escrow), abi.encodeCall(X402Escrow.collectHeld, (payer, seq)));
        if (!s) return;
        if (hp.status != X402Escrow.HeldStatus.Held) _violate("hold", "collect of a non-Held");
        if (block.timestamp < opensAt) _violate("hold", "collect before its time");
        if (paused) _violate("pause", "collect while paused");
        if (blk) _violate("block", "collect paid a blocked party");
        (uint64 fee, uint64 net) = Fee.splitFee(hp.amount, hp.takeRateBps);
        if (treasury == hp.provider) {
            if (usdg.balanceOf(hp.provider) - provBefore != uint256(net) + fee) {
                _violate("payout", "collect total");
            }
        } else {
            if (usdg.balanceOf(hp.provider) - provBefore != net) _violate("payout", "collect net");
            if (usdg.balanceOf(treasury) - treasBefore != fee) _violate("payout", "collect fee");
        }
        if (escrow.held(payer, seq).status != X402Escrow.HeldStatus.Collected) {
            _violate("hold", "collected record not marked");
        }
    }

    /// Redeem into hold: a refund, by the redeemer or a stranger. It may land only for the
    /// redeemer, on a `Held` record, before the timeout; it credits the whole amount back and
    /// leaves the window counter alone.
    function refundHeld(uint256 buyerSeed, uint256 seed) external step("refundHeld") {
        uint256 bi = buyerSeed % 3;
        address payer = buyers[bi];
        X402Escrow.Escrow memory e = escrow.escrowOf(payer);
        uint64 back = uint64(seed % 4);
        if (e.seqHigh <= back) return;
        uint64 seq = e.seqHigh - back;
        X402Escrow.HeldPayment memory hp = escrow.held(payer, seq);
        address caller = seed % 7 == 6 ? strangers[1] : REDEEMER;
        bool s = _call(caller, address(escrow), abi.encodeCall(X402Escrow.refundHeld, (payer, seq)));
        if (!s) return;
        if (caller != REDEEMER) _violate("role", "refund by a non-redeemer");
        if (hp.status != X402Escrow.HeldStatus.Held) _violate("hold", "refund of a non-Held");
        if (block.timestamp >= uint256(hp.collectableAt) + Constants.HELD_TIMEOUT_SECONDS) {
            _violate("hold", "refund after the timeout");
        }
        X402Escrow.Escrow memory a = escrow.escrowOf(payer);
        if (a.balance != e.balance + hp.amount) _violate("hold", "refund credit");
        if (a.spentInWindow != e.spentInWindow) _violate("hold", "refund restored the window");
    }

    // --- the payer's authorisation, modelled here (review 2026-10-16 F5) -----------------------
    //
    // The caps checks below compare a redemption with what THIS HANDLER saw the payer authorise,
    // not with the contract's own `effectiveCapsOf`. The rules are D-21's, written out from the
    // spec rather than read back: a lowering (or a revocation) holds the pair in force before it
    // until `now + TIGHTEN_DELAY` — for a delegate never past the grant's `validUntil` before the
    // change — only if the grant could still sign; a pair is checked WHOLE (current, or held
    // while the hold runs); a running hold merges field by field into a new one (one slot).

    struct GhostGrant {
        uint64 v;
        uint64 w;
        uint64 validUntil; // type(uint64).max for the escrow's own caps (key address(0))
        bool revoked;
    }

    struct GhostHold {
        uint64 v;
        uint64 w;
        uint64 until;
    }

    mapping(address => mapping(address => GhostGrant)) internal ghostGrant;
    mapping(address => mapping(address => GhostHold)) internal ghostHold;

    function _ghostCanSign(address payer, address del) internal view returns (bool) {
        GhostGrant memory g = ghostGrant[payer][del];
        if (g.validUntil == 0 || block.timestamp > g.validUntil) return false;
        return !g.revoked || block.timestamp <= ghostHold[payer][del].until;
    }

    function _ghostWriteHold(address payer, address del) internal {
        GhostGrant memory g = ghostGrant[payer][del];
        GhostHold storage h = ghostHold[payer][del];
        uint64 v = g.v;
        uint64 w = g.w;
        if (block.timestamp <= h.until) {
            if (h.v > v) v = h.v;
            if (h.w > w) w = h.w;
        }
        uint256 end = block.timestamp + Constants.TIGHTEN_DELAY_SECONDS;
        if (g.validUntil < end) end = g.validUntil;
        h.v = v;
        h.w = w;
        h.until = uint64(end);
    }

    function _ghostSet(address payer, address del, uint64 a, uint64 b, uint64 validUntil)
        internal
    {
        GhostGrant storage g = ghostGrant[payer][del];
        if ((a < g.v || b < g.w) && (del == address(0) || _ghostCanSign(payer, del))) {
            _ghostWriteHold(payer, del);
        }
        g.v = a;
        g.w = b;
        g.validUntil = validUntil;
        g.revoked = false;
    }

    function _ghostRevoke(address payer, address del) internal {
        if (block.timestamp <= ghostGrant[payer][del].validUntil) _ghostWriteHold(payer, del);
        ghostGrant[payer][del].revoked = true;
    }

    /// Whether (`amount`, window total `spent`) fits the current pair or the held pair whole.
    function _ghostFits(address payer, address del, uint256 amount, uint256 spent)
        internal
        view
        returns (bool)
    {
        GhostGrant memory g = ghostGrant[payer][del];
        if (amount <= g.v && spent <= g.w) return true;
        GhostHold memory h = ghostHold[payer][del];
        return block.timestamp <= h.until && amount <= h.v && spent <= h.w;
    }

    /// `laterE` / `laterD`: what the same payer (and the same delegate) spent AFTER this voucher
    /// in the same batch, at the same instant, so `spentInWindow - later` is this voucher's own
    /// window total.
    function _checkRedeemCaps(Voucher memory v, address del, uint256 laterE, uint256 laterD)
        internal
    {
        uint256 spentE = escrow.escrowOf(v.payer).spentInWindow - laterE;
        if (!_ghostFits(v.payer, address(0), v.amount, spentE)) {
            _violate("caps", "voucher outside every escrow pair the payer authorised");
        }
        if (del != address(0)) {
            if (!_ghostCanSign(v.payer, del)) {
                _violate("delegate", "a delegate paid past its horizon or its grace");
            }
            uint256 spentD = escrow.delegationOf(v.payer, del).spentInWindow - laterD;
            if (!_ghostFits(v.payer, del, v.amount, spentD)) {
                _violate("caps", "voucher outside every delegate pair the payer authorised");
            }
        }
    }

    function redeemBatch(uint256 n, uint256 seed, uint64 amount) external step("redeemBatch") {
        n = bound(n, 1, 4);
        Voucher[] memory vs = new Voucher[](n);
        bytes[] memory sigs = new bytes[](n);
        address[] memory dels = new address[](n);
        uint64[3] memory seqs;
        uint64[3] memory allowance;
        for (uint256 b = 0; b < 3; b++) {
            X402Escrow.Escrow memory e = escrow.escrowOf(buyers[b]);
            seqs[b] = e.seqHigh;
            allowance[b] = uint64(e.balance);
        }
        for (uint256 k = 0; k < n; k++) {
            uint256 sk = uint256(keccak256(abi.encode(seed, k)));
            uint256 bi = sk % 3;
            RedeemPlan memory rp = _plan(sk >> 2, amount / uint64(n), bi);
            seqs[bi] += 1 + (rp.seqDelta == 2 ? 1 : 0);
            if (sk % 23 == 0) seqs[bi] -= 1; // a replayed seq inside the batch
            (vs[k], sigs[k], dels[k]) = _voucher(bi, rp, seqs[bi]);
        }
        bool paused = config.paused();
        bool blk;
        for (uint256 k = 0; k < n; k++) {
            blk = blk || config.blocked(vs[k].payer) || config.blocked(vs[k].provider)
                || (dels[k] != address(0) && config.blocked(dels[k]));
        }
        bool s = _call(
            REDEEMER, address(escrow), abi.encodeCall(X402Escrow.redeemVoucherBatch, (vs, sigs))
        );
        if (!s) return;
        if (paused) _violate("pause", "redeemBatch while paused");
        if (blk) _violate("block", "redeemBatch touched a blocked party");
        for (uint256 k = 0; k < n; k++) {
            uint256 laterE;
            uint256 laterD;
            for (uint256 j = k + 1; j < n; j++) {
                if (vs[j].payer != vs[k].payer) continue;
                laterE += vs[j].amount;
                if (dels[k] != address(0) && dels[j] == dels[k]) laterD += vs[j].amount;
            }
            _checkRedeemCaps(vs[k], dels[k], laterE, laterD);
        }
    }

    // =========================================================================================
    // stake
    // =========================================================================================

    function depositStake(uint256 funderSeed, uint256 provSeed, uint64 amount)
        external
        step("depositStake")
    {
        address prov = providers[provSeed % 3];
        address funder = funderSeed % 3 == 0 ? strangers[funderSeed % 2] : prov;
        amount = uint64(bound(amount, 0, 1_000_000_000));
        usdg.mint(funder, amount);
        vm.prank(funder);
        usdg.approve(address(stake), amount);
        bool paused = config.paused();
        bool blk = config.blocked(prov) || config.blocked(funder);
        bool s =
            _call(funder, address(stake), abi.encodeCall(X402Stake.depositStakeFor, (prov, amount)));
        if (s && paused) _violate("pause", "depositStake while paused");
        if (s && blk) _violate("block", "depositStake with a blocked party");
    }

    function requestUnstake(uint256 provSeed, uint64 amount) external step("requestUnstake") {
        address prov = providers[provSeed % 3];
        uint128 bonded = stake.stakeOf(prov).bonded;
        amount = uint64(bound(amount, 0, bonded + 1));
        bool paused = config.paused();
        bool blk = config.blocked(prov);
        bool s = _call(prov, address(stake), abi.encodeCall(X402Stake.requestUnstake, (amount)));
        if (s && paused) _violate("pause", "requestUnstake while paused");
        if (s && blk) _violate("block", "requestUnstake by a blocked provider");
    }

    function withdrawStake(uint256 provSeed, uint64 amount) external step("withdrawStake") {
        address prov = providers[provSeed % 3];
        X402Stake.ProviderStake memory st = stake.stakeOf(prov);
        uint64 free = stake.withdrawableOf(prov);
        amount = uint64(bound(amount, 0, uint256(st.unbonding) + 1));
        if (provSeed % 2 == 0 && free > 0) amount = uint64(bound(amount, 1, free));
        bool paused = config.paused();
        bool blk = config.blocked(prov);
        uint256 before = usdg.balanceOf(prov);
        bool s = _call(prov, address(stake), abi.encodeCall(X402Stake.withdrawStake, (amount)));
        if (!s) return;
        if (paused) _violate("pause", "withdrawStake while paused");
        if (blk) _violate("block", "withdrawStake by a blocked provider");
        if (amount > free) _violate("stakeExit", "withdrew more than withdrawableOf");
        if (usdg.balanceOf(prov) - before != amount) _violate("stakeExit", "wrong stake payout");
    }

    function proposeSlash(
        uint256 signerSeed,
        uint256 provSeed,
        uint64 penalty,
        uint64 issuedOff,
        uint64 life,
        uint256 idSeed
    ) external step("proposeSlash") {
        uint256 si = signerSeed % 5;
        if (signerSeed % 5 != 4) {
            for (uint256 k = 0; k < 5; k++) {
                if (config.canSign(signers[(si + k) % 5])) {
                    si = (si + k) % 5;
                    break;
                }
            }
        }
        bytes32 id;
        if (idSeed % 8 == 7 || ids.length >= MAX_RECORDS) id = _pickId(idSeed);
        else id = keccak256(abi.encode("audit-d", nextId++));
        uint64 maxPen = config.params().penaltyAmount;
        penalty = uint64(bound(penalty, 0, uint256(maxPen) + uint256(maxPen) / 5 + 1));
        uint64 nowTs = uint64(block.timestamp);
        uint64 issuedAt =
            nowTs - uint64(bound(issuedOff, 0, issuedOff % 4 == 0 ? 8 * 86_400 : 3_600));
        if (issuedOff % 13 == 12) issuedAt = nowTs + 1;
        SlashAttestation memory a = SlashAttestation({
            requestId: id,
            provider: providers[provSeed % 3],
            beneficiary: provSeed % 11 == 10 ? address(0) : beneficiaries[provSeed % 2],
            status: provSeed % 17 == 16
                ? uint8(ResponseClass.SystemError)
                : uint8(ResponseClass.DataFail),
            penalty: penalty,
            policy: keccak256("audit-d policy"),
            issuedAt: issuedAt,
            expiresAt: issuedAt
                + uint64(bound(life, 0, life % 4 == 0 ? 8 * 86_400 : 86_400) + (life % 4 == 0 ? 0 : 7_200))
        });
        bytes memory sig =
            VoucherSigner.signAttestation(signerKeys[si], stake.DOMAIN_SEPARATOR(), a);
        bool paused = config.paused();
        bool canSign = config.canSign(signers[si]);
        uint64 delay = config.slashDelaySeconds();
        bool existed = stake.slashRecordOf(id).status != SlashStatus.None;
        X402Stake.ProviderStake memory st = stake.stakeOf(a.provider);
        uint16 capBps = config.params().slashCapBps;
        address caller = strangers[signerSeed % 2];
        bool s = _call(caller, address(stake), abi.encodeCall(X402Stake.proposeSlash, (a, sig)));
        if (!s) return;
        if (paused) _violate("pause", "proposeSlash while paused");
        if (!canSign) _violate("role", "proposeSlash by a non-signing key");
        if (existed) _violate("replay", "proposeSlash over an existing record");
        X402Stake.SlashRecord memory r = stake.slashRecordOf(id);
        if (r.executableAt != nowTs + delay) _violate("delay", "executableAt != now + live delay");
        uint256 atRisk = uint256(st.bonded) + st.unbonding;
        if (r.capAllowance != (atRisk * capBps) / 10_000) _violate("caps", "capAllowance formula");
        if (r.reserved > r.capAllowance || r.reserved > r.penalty) {
            _violate("caps", "reservation above cap or penalty");
        }
        if (uint256(r.reserved) + st.pendingSlash > atRisk) {
            _violate("reservation", "reservation beyond the stake");
        }
        ids.push(id);
        snap[id] = Snap({
            status: r.status,
            executableAt: r.executableAt,
            disputedAt: r.disputedAt,
            reserved: r.reserved,
            penalty: r.penalty,
            capAllowance: r.capAllowance,
            provider: r.provider,
            verifier: r.verifier,
            beneficiary: r.beneficiary
        });
    }

    function _verifierWindow(address v) internal view returns (uint64 used, uint64 started) {
        uint256 w = uint256(vm.load(address(stake), keccak256(abi.encode(v, uint256(6)))));
        used = uint64(w);
        started = uint64(w >> 64);
    }

    function executeSlash(uint256 idSeed) external step("executeSlash") {
        bytes32 id = _pickOpen(idSeed);
        X402Stake.SlashRecord memory r = stake.slashRecordOf(id);
        bool paused = config.paused();
        bool canSign = config.canSign(r.verifier);
        ParamSet memory p = config.params();
        X402Stake.ProviderStake memory st = stake.stakeOf(r.provider);
        uint256 benBefore = usdg.balanceOf(r.beneficiary);
        uint256 treBefore = usdg.balanceOf(TREASURY);
        bool s = _call(
            strangers[idSeed % 2], address(stake), abi.encodeCall(X402Stake.executeSlash, (id))
        );
        if (!s) return;
        if (paused) _violate("pause", "executeSlash while paused");
        if (!canSign) _violate("role", "executeSlash for a non-signing verifier");
        if (r.status != SlashStatus.Pending) {
            _violate("transition", "executed a non-Pending record");
        }
        X402Stake.SlashRecord memory q = stake.slashRecordOf(id);
        X402Stake.ProviderStake memory s2 = stake.stakeOf(r.provider);
        (uint64 vUsed,) = _verifierWindow(r.verifier);
        // All or wait (D-20): an execution pays the whole reservation, never part of it.
        if (q.applied != r.reserved) _violate("caps", "applied != reserved");
        if (s2.slashedInWindow > r.capAllowance) _violate("caps", "provider window above cap");
        if (vUsed > p.verifierDailyCap) _violate("caps", "verifier window above daily cap");
        uint64 agent = Fee.bpsOf(q.applied, p.slashAgentBps);
        uint64 plat = Fee.bpsOf(q.applied, p.slashPlatformBps);
        if (usdg.balanceOf(r.beneficiary) - benBefore != agent) _violate("payout", "agent share");
        if (usdg.balanceOf(TREASURY) - treBefore != plat) _violate("payout", "platform share");
        if (
            uint256(st.bonded) + st.unbonding - (uint256(s2.bonded) + s2.unbonding)
                != uint256(agent) + plat
        ) _violate("payout", "stake debit != agent + platform");
    }

    function _expectedCancelOk(address caller, SlashStatus st) internal view returns (bool) {
        return (caller == _admin() || (caller == _arbiter() && caller != address(0))) && _open(st);
    }

    function cancelSlash(uint256 idSeed, uint256 callerSeed) external step("cancelSlash") {
        bytes32 id = _pickOpen(idSeed);
        address caller = _anyCaller(callerSeed);
        bool want = _expectedCancelOk(caller, stake.slashRecordOf(id).status);
        bool s = _call(caller, address(stake), abi.encodeCall(X402Stake.cancelSlash, (id)));
        if (s != want) _violate("role", "cancelSlash outcome != (admin|arbiter) && open");
    }

    function cancelSlashBatch(uint256 idSeed, uint256 callerSeed, uint256 n)
        external
        step("cancelSlashBatch")
    {
        n = bound(n, 0, 3);
        bytes32[] memory list = new bytes32[](n);
        address caller = _anyCaller(callerSeed);
        bool want = n > 0;
        for (uint256 k = 0; k < n; k++) {
            list[k] = _pickOpen(idSeed + k);
            for (uint256 j = 0; j < k; j++) {
                if (list[j] == list[k]) want = false;
            }
            want = want && _expectedCancelOk(caller, stake.slashRecordOf(list[k]).status);
        }
        bool s = _call(caller, address(stake), abi.encodeCall(X402Stake.cancelSlashBatch, (list)));
        if (s != want) _violate("role", "cancelSlashBatch outcome mismatch");
    }

    function expireSlash(uint256 idSeed) external step("expireSlash") {
        bytes32 id = _pickOpen(idSeed);
        X402Stake.SlashRecord memory r = stake.slashRecordOf(id);
        bool timedOut = r.status == SlashStatus.Disputed
            ? block.timestamp >= uint256(r.disputedAt) + Constants.DISPUTE_TIMEOUT_SECONDS
            : block.timestamp >= uint256(r.executableAt) + Constants.SLASH_EXECUTION_GRACE_SECONDS;
        bool want = _open(r.status) && (!config.canSign(r.verifier) || timedOut);
        bool s = _call(strangers[0], address(stake), abi.encodeCall(X402Stake.expireSlash, (id)));
        if (s != want) {
            _violate("expire", "expireSlash outcome != open && (unusable key || timed out)");
        }
    }

    function _disputable(bytes32 id) internal view returns (bool) {
        X402Stake.SlashRecord memory r = stake.slashRecordOf(id);
        return
            r.status == SlashStatus.Pending && r.disputedAt == 0 && block.timestamp < r.executableAt;
    }

    /// The provider can ALWAYS dispute a Pending, undisputed record before executableAt — paused
    /// or blocked or not. Any other caller must be refused.
    function disputeSlash(uint256 idSeed, uint256 callerSeed) external step("disputeSlash") {
        bytes32 id = _pickOpen(idSeed);
        X402Stake.SlashRecord memory r = stake.slashRecordOf(id);
        address caller = callerSeed % 4 == 0 ? _anyCaller(callerSeed >> 2) : r.provider;
        bool want = _disputable(id) && caller == r.provider;
        bool s = _call(caller, address(stake), abi.encodeCall(X402Stake.disputeSlash, (id)));
        if (want && !s) {
            _violate("disputeLiveness", "provider could not dispute a disputable record");
        }
        if (!want && s) _violate("transition", "a dispute landed that should have been refused");
    }

    function disputeSlashBatch(uint256 provSeed, uint256 dupSeed)
        external
        step("disputeSlashBatch")
    {
        address prov = providers[provSeed % 3];
        bytes32[] memory tmp = new bytes32[](3);
        uint256 n;
        for (uint256 k = 0; k < ids.length && n < 3; k++) {
            bytes32 id = ids[(k + provSeed) % ids.length];
            if (stake.slashRecordOf(id).provider == prov && _disputable(id)) tmp[n++] = id;
        }
        bool dup = n > 0 && dupSeed % 5 == 4;
        bytes32[] memory list = new bytes32[](dup ? n + 1 : n);
        for (uint256 k = 0; k < n; k++) {
            list[k] = tmp[k];
        }
        if (dup) list[n] = tmp[0];
        bool want = n > 0 && !dup;
        bool s = _call(prov, address(stake), abi.encodeCall(X402Stake.disputeSlashBatch, (list)));
        if (want && !s) _violate("disputeLiveness", "disputeSlashBatch refused disputable records");
        if (!want && s) _violate("transition", "disputeSlashBatch landed a bad batch");
    }

    function _upholdable(bytes32 id, address caller) internal view returns (bool) {
        X402Stake.SlashRecord memory r = stake.slashRecordOf(id);
        address arb = _arbiter();
        return caller == arb && r.status == SlashStatus.Disputed
            && block.timestamp < uint256(r.disputedAt) + Constants.DISPUTE_TIMEOUT_SECONDS
            && arb != r.verifier;
    }

    function upholdSlash(uint256 idSeed, uint256 callerSeed) external step("upholdSlash") {
        bytes32 id = _pickOpen(idSeed);
        address caller = _anyCaller(callerSeed);
        if (callerSeed % 3 != 0) caller = _arbiter();
        if (caller == address(0)) return; // no real transaction has msg.sender == 0
        bool want = _upholdable(id, caller);
        bool s = _call(caller, address(stake), abi.encodeCall(X402Stake.upholdSlash, (id)));
        if (s != want) _violate("role", "upholdSlash outcome != arbiter && disputed && in time");
    }

    function upholdSlashBatch(uint256 idSeed, uint256 n) external step("upholdSlashBatch") {
        n = bound(n, 0, 3);
        address caller = _arbiter();
        if (caller == address(0)) return;
        bytes32[] memory list = new bytes32[](n);
        bool want = n > 0;
        for (uint256 k = 0; k < n; k++) {
            list[k] = _pickOpen(idSeed + k * 7);
            for (uint256 j = 0; j < k; j++) {
                if (list[j] == list[k]) want = false;
            }
            want = want && _upholdable(list[k], caller);
        }
        bool s = _call(caller, address(stake), abi.encodeCall(X402Stake.upholdSlashBatch, (list)));
        if (s != want) _violate("role", "upholdSlashBatch outcome mismatch");
    }

    // =========================================================================================
    // config
    // =========================================================================================

    function setPaused(uint256 callerSeed, bool value) external step("setPaused") {
        address caller = callerSeed % 3 == 0 ? _anyCaller(callerSeed >> 2) : _admin();
        if (value && callerSeed % 4 != 0) value = false; // pausing is rarer than unpausing
        bool want = caller == _admin();
        bool s = _call(caller, address(config), abi.encodeCall(X402Config.setPaused, (value)));
        if (s != want) _violate("role", "setPaused outcome != admin");
    }

    function setBlocked(uint256 callerSeed, uint256 targetSeed, bool value)
        external
        step("setBlocked")
    {
        address caller = _anyCaller(callerSeed);
        address target = _anyAddress(targetSeed);
        // Blocks are rarer than unblocks so the walk is not permanently frozen.
        if (value && targetSeed % 3 != 0) value = false;
        bool want = (caller == _admin() || (value && caller == _arbiter() && caller != address(0)))
            && target != address(0);
        bool s =
            _call(caller, address(config), abi.encodeCall(X402Config.setBlocked, (target, value)));
        if (s != want) _violate("role", "setBlocked outcome mismatch");
        if (s && !value && caller != _admin()) _violate("role", "a non-admin unblocked");
    }

    function setSlashDelay(uint256 callerSeed, uint64 d) external step("setSlashDelay") {
        address caller = callerSeed % 4 == 0 ? _anyCaller(callerSeed >> 2) : _admin();
        d = uint64(bound(d, 0, 30 * 86_400));
        if (callerSeed % 5 == 1) d = Constants.MIN_SLASH_DELAY_SECONDS;
        // Fixed bounds since audit F R3: no coupling to the unbonding period.
        bool want = caller == _admin() && d >= Constants.MIN_SLASH_DELAY_SECONDS
            && d <= Constants.MAX_SLASH_DELAY_SECONDS;
        bool s = _call(caller, address(config), abi.encodeCall(X402Config.setSlashDelay, (d)));
        if (s != want) _violate("role", "setSlashDelay outcome mismatch");
    }

    function setArbiter(uint256 callerSeed, uint256 candSeed) external step("setArbiter") {
        address caller = callerSeed % 4 == 0 ? _anyCaller(callerSeed >> 2) : _admin();
        address cand;
        uint256 c = candSeed % 6;
        if (c == 0) cand = signers[3];
        else if (c == 1) cand = signers[4];
        else if (c == 2) cand = address(0);
        else if (c == 3) cand = _admin();
        else if (c == 4) cand = signers[(candSeed >> 3) % 3];
        else cand = strangers[0];
        X402Config.VerifierKey memory k = config.verifierKey(cand);
        bool want = caller == _admin() && cand != address(0) && cand != _admin()
            && cand != config.params().redeemer && !(k.registered && !k.revoked);
        bool s = _call(caller, address(config), abi.encodeCall(X402Config.setArbiter, (cand)));
        if (s != want) _violate("role", "setArbiter outcome mismatch");
    }

    function registerVerifier(uint256 callerSeed, uint256 vSeed, uint64 life)
        external
        step("registerVerifier")
    {
        address caller = callerSeed % 4 == 0 ? _anyCaller(callerSeed >> 2) : _admin();
        address v = signers[vSeed % 5];
        uint64 expiresAt = uint64(block.timestamp) + uint64(bound(life, 0, 370 * 86_400));
        bool want = caller == _admin() && !config.verifierKey(v).registered && v != _admin()
            && v != _arbiter() && expiresAt > block.timestamp
            && expiresAt <= block.timestamp + Constants.MAX_VERIFIER_KEY_LIFETIME_SECONDS;
        bool s = _call(
            caller,
            address(config),
            abi.encodeCall(X402Config.registerVerifier, (v, bytes32("audit-d"), expiresAt))
        );
        if (s != want) _violate("role", "registerVerifier outcome mismatch");
    }

    function revokeVerifier(uint256 callerSeed, uint256 vSeed) external step("revokeVerifier") {
        address caller = callerSeed % 4 == 0 ? _anyCaller(callerSeed >> 2) : _admin();
        if (vSeed % 3 != 0) return; // rarer, or the walk runs out of signing keys
        address v = signers[(vSeed / 3) % 5];
        X402Config.VerifierKey memory k = config.verifierKey(v);
        bool want = caller == _admin() && k.registered && !k.revoked;
        bool s = _call(caller, address(config), abi.encodeCall(X402Config.revokeVerifier, (v)));
        if (s != want) _violate("role", "revokeVerifier outcome mismatch");
    }

    function updateConfig(
        uint256 callerSeed,
        uint64 unbonding,
        uint64 penalty,
        uint64 dailyCap,
        uint16 take,
        uint16 agent,
        uint16 platform,
        uint16 cap
    ) external step("updateConfig") {
        address caller = callerSeed % 4 == 0 ? _anyCaller(callerSeed >> 2) : _admin();
        ParamSet memory p = config.params();
        p.unbondingPeriodSeconds = uint64(bound(unbonding, 10 * 86_400, 31 * 86_400));
        p.penaltyAmount = uint64(bound(penalty, 0, 200_000_000));
        p.verifierDailyCap = uint64(bound(dailyCap, 0, 1_000_000_000));
        p.takeRateBps = uint16(bound(take, 0, 3_200));
        p.slashAgentBps = uint16(bound(agent, 0, 10_000));
        p.slashPlatformBps = uint16(bound(platform, 0, 10_000 - p.slashAgentBps + 50));
        p.slashCapBps = uint16(bound(cap, 0, 5_200));
        // Up to twice the opening minimum, so sets that satisfy the provider-day rule (review R-1)
        // stay reachable alongside the ones it refuses.
        p.minimumStake = uint64(bound(callerSeed >> 8, 0, 2_000_000_000));
        bool s =
            _call(caller, address(config), abi.encodeCall(X402Config.updateConfig, (p, address(0))));
        if (s && caller != _admin()) _violate("role", "updateConfig by a non-admin");
    }

    function setAdmin(uint256 callerSeed, uint256 candSeed) external step("setAdmin") {
        address caller = callerSeed % 3 == 0 ? _anyCaller(callerSeed >> 2) : OWNER;
        uint256 c = candSeed % 4;
        address cand = c == 0 ? ADMIN0 : c == 1 ? ADMIN1 : c == 2 ? _arbiter() : address(0);
        bool want = caller == OWNER && cand != address(0) && cand != _arbiter();
        bool s = _call(caller, address(config), abi.encodeCall(X402Config.setAdmin, (cand)));
        if (s != want) _violate("role", "setAdmin outcome mismatch");
    }

    // =========================================================================================
    // time and donations
    // =========================================================================================

    /// Warps forward, steered onto the boundaries every door is written against.
    function warp(uint256 choice, uint64 small) external step("warp") {
        uint256 c = choice % 12;
        uint256 nowTs = block.timestamp;
        uint256 target = nowTs + bound(small, 1, 4 * 86_400);
        int256 nudge = int256(uint256((choice >> 8) % 3)) - 1; // -1, 0, +1
        if (c >= 2 && c <= 7 && ids.length > 0) {
            X402Stake.SlashRecord memory r = stake.slashRecordOf(_pickOpen(choice >> 16));
            uint256 base;
            if (c == 2 || c == 3) {
                base = r.executableAt;
            } else if (c == 4 || c == 5) {
                base = uint256(r.executableAt) + Constants.SLASH_EXECUTION_GRACE_SECONDS;
            } else {
                base = r.disputedAt == 0
                    ? nowTs
                    : uint256(r.disputedAt) + Constants.DISPUTE_TIMEOUT_SECONDS;
            }
            target = uint256(int256(base) + nudge);
        } else if (c == 8) {
            target = uint256(
                int256(uint256(escrow.escrowOf(buyers[(choice >> 16) % 3]).withdrawAvailableAt))
                    + nudge
            );
        } else if (c == 9) {
            X402Stake.ProviderStake memory st = stake.stakeOf(providers[(choice >> 16) % 3]);
            target = uint256(
                int256(uint256(st.unbondingStartedAt) + config.params().unbondingPeriodSeconds)
                    + nudge
            );
        } else if (c == 10) {
            X402Escrow.Escrow memory e = escrow.escrowOf(buyers[(choice >> 16) % 3]);
            target =
                uint256(int256(uint256(e.windowStartedAt) + Constants.SLASH_WINDOW_SECONDS) + nudge);
        } else if (c == 11) {
            target = uint256(
                int256(uint256(config.verifierKey(signers[(choice >> 16) % 5]).expiresAt)) + nudge
            );
        }
        if (target <= nowTs) target = nowTs + 1;
        if (target > nowTs + 60 * 86_400) target = nowTs + 60 * 86_400;
        vm.warp(target);
        tried["warp"] += 1;
        ok["warp"] += 1;
    }

    function donate(bool toStake, uint64 amount) external step("donate") {
        amount = uint64(bound(amount, 1, 1_000_000));
        if (toStake) {
            usdg.mint(address(stake), amount);
            donatedStake += amount;
        } else {
            usdg.mint(address(escrow), amount);
            donatedEscrow += amount;
        }
    }

    // =========================================================================================
    // views for the invariants
    // =========================================================================================

    function idsLength() external view returns (uint256) {
        return ids.length;
    }

    function signer(uint256 i) external view returns (address) {
        return signers[i];
    }

    /// Every address that can ever hold the token in this world.
    function holders() public view returns (address[] memory h) {
        h = new address[](27);
        uint256 n;
        h[n++] = address(this);
        h[n++] = address(escrow);
        h[n++] = address(stake);
        h[n++] = TREASURY;
        h[n++] = REDEEMER;
        h[n++] = OWNER;
        h[n++] = ADMIN0;
        h[n++] = ADMIN1;
        for (uint256 i = 0; i < 3; i++) {
            h[n++] = buyers[i];
            h[n++] = delegates[i];
            h[n++] = providers[i];
        }
        for (uint256 i = 0; i < 5; i++) {
            h[n++] = signers[i];
        }
        for (uint256 i = 0; i < 2; i++) {
            h[n++] = beneficiaries[i];
            h[n++] = strangers[i];
        }
        assembly ("memory-safe") {
            mstore(h, n)
        }
    }
}
