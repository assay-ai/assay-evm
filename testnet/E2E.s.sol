// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {X402Config} from "../src/X402Config.sol";
import {X402Escrow} from "../src/X402Escrow.sol";
import {X402Stake} from "../src/X402Stake.sol";
import {
    Voucher, SlashAttestation, ParamSet, ResponseClass, SlashStatus
} from "../src/Types.sol";
import {Constants} from "../src/Constants.sol";
import {
    ProgramPaused,
    NotAdmin,
    NotRedeemer,
    SignerIsNotPayer,
    VoucherSeqNotIncreasing,
    VoucherExpired,
    VoucherExceedsPerCallLimit,
    EscrowWindowLimitExceeded,
    WithdrawNotYetAvailable,
    UnbondingPeriodNotElapsed,
    SlashNotYetExecutable,
    SlashExecutionWindowClosed
} from "../src/Errors.sol";
import {MockUSDG} from "../test/helpers/MockUSDG.sol";
import {VoucherSigner} from "../test/helpers/VoucherSigner.sol";

/// Testnet end-to-end exercise of a deployment, in three phases chosen by `E2E_PHASE`:
///
/// - `live`     broadcast: verifier enrolment, stake, deposit, limits, single and batch
///              redemption, slash proposal and cancellation, withdraw and unstake requests,
///              pause round trip. Every step is checked against the state it should leave.
/// - `withdraw` broadcast, at least `WITHDRAW_DELAY_SECONDS` after `live`: the buyer withdraws.
/// - `time`     simulation only (no broadcast), on the live state: the refusals, then
///              `vm.warp` past the slash delay, the unbonding period and the slash grace to
///              execute and expire slashes and withdraw stake.
///
/// Keys and addresses come from the environment; nothing here names a deployment.
contract E2E is Script {
    X402Config internal config;
    X402Stake internal stake;
    X402Escrow internal escrow;
    MockUSDG internal usdg;

    uint256 internal deployerPk;
    uint256 internal adminPk;
    uint256 internal redeemerPk;
    uint256 internal verifierPk;
    uint256 internal buyerPk;
    uint256 internal providerPk;

    address internal admin;
    address internal redeemer;
    address internal verifier;
    address internal buyer;
    address internal provider;
    address internal treasury;

    uint64 internal constant U = 1e6; // one token, 6 decimals

    error Check(string what);

    function setUp() public {
        config = X402Config(vm.envAddress("PROXY_CONFIG"));
        stake = X402Stake(vm.envAddress("PROXY_STAKE"));
        escrow = X402Escrow(vm.envAddress("PROXY_ESCROW"));
        usdg = MockUSDG(vm.envAddress("USDG_ADDRESS"));

        deployerPk = vm.envUint("DEPLOYER_PK");
        adminPk = vm.envUint("ADMIN_PK");
        redeemerPk = vm.envUint("REDEEMER_PK");
        verifierPk = vm.envUint("VERIFIER_PK");
        buyerPk = vm.envUint("BUYER_PK");
        providerPk = vm.envUint("PROVIDER_PK");

        admin = vm.addr(adminPk);
        redeemer = vm.addr(redeemerPk);
        verifier = vm.addr(verifierPk);
        buyer = vm.addr(buyerPk);
        provider = vm.addr(providerPk);
        treasury = config.params().treasury;
    }

    function run() external {
        string memory phase = vm.envString("E2E_PHASE");
        bytes32 h = keccak256(bytes(phase));
        if (h == keccak256("live")) _live();
        else if (h == keccak256("withdraw")) _withdraw();
        else if (h == keccak256("time")) _time();
        else revert Check("E2E_PHASE must be live, withdraw or time");
    }

    // ── live ─────────────────────────────────────────────────────────────────────────────

    function _live() internal {
        _expect(config.admin() == admin, "config admin is ADMIN_PK");
        _expect(config.params().redeemer == redeemer, "config redeemer is REDEEMER_PK");
        _expect(!config.paused(), "deployment starts unpaused");

        // 1. Verifier enrolment.
        if (!config.canSign(verifier)) {
            vm.broadcast(adminPk);
            config.registerVerifier(verifier, "e2e-verifier", uint64(block.timestamp + 30 days));
        }
        _expect(config.canSign(verifier), "verifier can sign");
        console2.log("[ok] verifier registered");

        // 2. Tokens.
        vm.startBroadcast(deployerPk);
        usdg.mint(buyer, 1_000 * U);
        usdg.mint(provider, 500 * U);
        vm.stopBroadcast();

        // 3. Provider stake.
        uint64 bondedBefore = stake.bondedOf(provider);
        vm.startBroadcast(providerPk);
        usdg.approve(address(stake), type(uint256).max);
        stake.depositStake(200 * U);
        vm.stopBroadcast();
        _expect(stake.bondedOf(provider) == bondedBefore + 200 * U, "bonded += 200");
        _expect(stake.bondedOf(provider) >= config.params().minimumStake, "provider clears minimum");
        console2.log("[ok] provider staked 200, bonded =", stake.bondedOf(provider));

        // 4. Buyer deposit and limits.
        uint128 escrowBefore = escrow.escrowOf(buyer).balance;
        vm.startBroadcast(buyerPk);
        usdg.approve(address(escrow), type(uint256).max);
        escrow.deposit(300 * U);
        X402Escrow.Escrow memory e = escrow.escrowOf(buyer);
        if (e.maxVoucherAmount != 50 * U || e.maxPerWindow != 200 * U) {
            escrow.setLimits(50 * U, 200 * U);
        }
        vm.stopBroadcast();
        e = escrow.escrowOf(buyer);
        _expect(e.balance == escrowBefore + 300 * U, "escrow balance += 300");
        _expect(e.maxVoucherAmount == 50 * U && e.maxPerWindow == 200 * U, "limits set");
        console2.log("[ok] buyer deposited 300, escrow balance =", uint256(e.balance));

        // 5. Redemption: one single, one batch of two. Fee is takeRateBps of each amount.
        uint16 bps = config.params().takeRateBps;
        uint256 providerTok = usdg.balanceOf(provider);
        uint256 treasuryTok = usdg.balanceOf(treasury);
        uint64 seq = e.seqHigh;

        Voucher memory v1 = _voucher(seq + 1, 10 * U);
        bytes memory s1 = VoucherSigner.signVoucher(buyerPk, escrow.DOMAIN_SEPARATOR(), v1);
        _expect(escrow.recoverVoucherSigner(v1, s1) == buyer, "on-chain recovery names buyer");
        vm.broadcast(redeemerPk);
        escrow.redeemVoucher(v1, s1);

        Voucher[] memory vs = new Voucher[](2);
        bytes[] memory ss = new bytes[](2);
        vs[0] = _voucher(seq + 2, 5 * U);
        vs[1] = _voucher(seq + 3, 7 * U);
        ss[0] = VoucherSigner.signVoucher(buyerPk, escrow.DOMAIN_SEPARATOR(), vs[0]);
        ss[1] = VoucherSigner.signVoucher(buyerPk, escrow.DOMAIN_SEPARATOR(), vs[1]);
        vm.broadcast(redeemerPk);
        escrow.redeemVoucherBatch(vs, ss);

        uint256 gross = 22 * U;
        uint256 fee = (10 * U * bps) / 10_000 + (5 * U * bps) / 10_000 + (7 * U * bps) / 10_000;
        e = escrow.escrowOf(buyer);
        _expect(e.seqHigh == seq + 3, "seqHigh advanced by 3");
        _expect(e.balance == escrowBefore + 300 * U - gross, "escrow debited 22");
        _expect(usdg.balanceOf(provider) == providerTok + gross - fee, "provider paid net");
        _expect(usdg.balanceOf(treasury) == treasuryTok + fee, "treasury paid fee");
        console2.log("[ok] redeemed 3 vouchers, gross 22, fee", fee);

        // 6. Slash: one proposal left pending for `time`, one proposed and cancelled.
        bytes32 tag = keccak256(abi.encode(vm.envString("E2E_RUN_TAG")));
        bytes32 reqA = keccak256(abi.encode(tag, "slash-a"));
        bytes32 reqB = keccak256(abi.encode(tag, "slash-b"));
        uint64 penalty = config.params().penaltyAmount;

        (SlashAttestation memory a, bytes memory sa) = _attestation(reqA, penalty);
        vm.broadcast(deployerPk); // permissionless submission
        stake.proposeSlash(a, sa);
        _expect(stake.slashRecordOf(reqA).status == SlashStatus.Pending, "slash A pending");

        (SlashAttestation memory b, bytes memory sb) = _attestation(reqB, penalty);
        vm.broadcast(deployerPk);
        stake.proposeSlash(b, sb);
        vm.broadcast(adminPk);
        stake.cancelSlash(reqB);
        _expect(stake.slashRecordOf(reqB).status == SlashStatus.Cancelled, "slash B cancelled");
        console2.log("[ok] slash A pending, slash B cancelled");

        // 7. Exit requests.
        vm.broadcast(buyerPk);
        escrow.requestWithdraw(50 * U);
        e = escrow.escrowOf(buyer);
        _expect(e.withdrawRequested == 50 * U, "withdraw requested 50");
        _expect(
            e.withdrawAvailableAt >= block.timestamp + Constants.WITHDRAW_DELAY_SECONDS - 60,
            "withdraw delayed one hour"
        );

        uint64 unbondingBefore = stake.stakeOf(provider).unbonding;
        vm.broadcast(providerPk);
        stake.requestUnstake(20 * U);
        _expect(stake.stakeOf(provider).unbonding == unbondingBefore + 20 * U, "unbonding += 20");
        console2.log("[ok] withdraw 50 and unstake 20 requested");

        // 8. Pause round trip.
        vm.broadcast(adminPk);
        config.setPaused(true);
        _expect(config.paused(), "paused");
        vm.broadcast(adminPk);
        config.setPaused(false);
        _expect(!config.paused(), "unpaused");
        console2.log("[ok] pause round trip");

        console2.log("slash A request id");
        console2.logBytes32(reqA);
        console2.log("LIVE PHASE PASSED");
    }

    // ── withdraw ─────────────────────────────────────────────────────────────────────────

    function _withdraw() internal {
        X402Escrow.Escrow memory e = escrow.escrowOf(buyer);
        _expect(e.withdrawRequested > 0, "a withdrawal is pending");
        _expect(block.timestamp >= e.withdrawAvailableAt, "withdraw delay has elapsed");
        uint256 tokBefore = usdg.balanceOf(buyer);
        uint64 amount = e.withdrawRequested;
        vm.broadcast(buyerPk);
        escrow.withdraw();
        _expect(usdg.balanceOf(buyer) == tokBefore + amount, "buyer received the withdrawal");
        _expect(escrow.escrowOf(buyer).balance == e.balance - amount, "escrow debited");
        _expect(escrow.escrowOf(buyer).withdrawRequested == 0, "request cleared");
        console2.log("[ok] buyer withdrew", amount);
        console2.log("WITHDRAW PHASE PASSED");
    }

    // ── time (simulation only) ───────────────────────────────────────────────────────────

    function _time() internal {
        bytes32 tag = keccak256(abi.encode(vm.envString("E2E_RUN_TAG")));
        bytes32 reqA = keccak256(abi.encode(tag, "slash-a"));
        ParamSet memory p = config.params();
        X402Escrow.Escrow memory e = escrow.escrowOf(buyer);

        // Refusals, against the real deployed state.
        Voucher memory replay = _voucher(e.seqHigh, 1 * U);
        _reverts(
            address(escrow),
            redeemer,
            abi.encodeCall(
                X402Escrow.redeemVoucher,
                (replay, VoucherSigner.signVoucher(buyerPk, escrow.DOMAIN_SEPARATOR(), replay))
            ),
            VoucherSeqNotIncreasing.selector,
            "replayed seq"
        );
        Voucher memory forged = _voucher(e.seqHigh + 1, 1 * U);
        _reverts(
            address(escrow),
            redeemer,
            abi.encodeCall(
                X402Escrow.redeemVoucher,
                (forged, VoucherSigner.signVoucher(providerPk, escrow.DOMAIN_SEPARATOR(), forged))
            ),
            SignerIsNotPayer.selector,
            "voucher not signed by the payer"
        );
        Voucher memory ok = _voucher(e.seqHigh + 1, 1 * U);
        bytes memory okSig = VoucherSigner.signVoucher(buyerPk, escrow.DOMAIN_SEPARATOR(), ok);
        _reverts(
            address(escrow),
            buyer,
            abi.encodeCall(X402Escrow.redeemVoucher, (ok, okSig)),
            NotRedeemer.selector,
            "redeem by a non-redeemer"
        );
        Voucher memory big = _voucher(e.seqHigh + 1, e.maxVoucherAmount + 1);
        _reverts(
            address(escrow),
            redeemer,
            abi.encodeCall(
                X402Escrow.redeemVoucher,
                (big, VoucherSigner.signVoucher(buyerPk, escrow.DOMAIN_SEPARATOR(), big))
            ),
            VoucherExceedsPerCallLimit.selector,
            "voucher over the per-call limit"
        );
        _reverts(
            address(config),
            buyer,
            abi.encodeCall(X402Config.setPaused, (true)),
            NotAdmin.selector,
            "pause by a non-admin"
        );
        _reverts(
            address(stake),
            deployerPk == 0 ? address(0) : vm.addr(deployerPk),
            abi.encodeCall(X402Stake.executeSlash, (reqA)),
            SlashNotYetExecutable.selector,
            "slash executed inside the delay"
        );
        _reverts(
            address(stake),
            provider,
            abi.encodeCall(X402Stake.withdrawStake, (20 * U)),
            UnbondingPeriodNotElapsed.selector,
            "stake withdrawn inside the unbonding period"
        );
        vm.prank(admin);
        config.setPaused(true);
        _reverts(
            address(escrow),
            buyer,
            abi.encodeCall(X402Escrow.deposit, (1 * U)),
            ProgramPaused.selector,
            "deposit while paused"
        );
        vm.prank(admin);
        config.setPaused(false);
        console2.log("[ok] 8 refusals hold");

        // A voucher that expired is refused after the grace.
        Voucher memory late = _voucher(e.seqHigh + 1, 1 * U);
        bytes memory lateSig = VoucherSigner.signVoucher(buyerPk, escrow.DOMAIN_SEPARATOR(), late);
        uint256 t0 = block.timestamp;
        vm.warp(late.expiresAt + Constants.REDEEM_GRACE_SECONDS + 1);
        _reverts(
            address(escrow),
            redeemer,
            abi.encodeCall(X402Escrow.redeemVoucher, (late, lateSig)),
            VoucherExpired.selector,
            "expired voucher"
        );
        vm.warp(t0);

        // Execute slash A after the delay.
        X402Stake.SlashRecord memory rec = stake.slashRecordOf(reqA);
        _expect(rec.status == SlashStatus.Pending, "slash A still pending");
        vm.warp(rec.executableAt);
        uint256 benBefore = usdg.balanceOf(rec.beneficiary);
        uint256 treBefore = usdg.balanceOf(p.treasury);
        uint128 slashedBefore = stake.stakeOf(provider).totalSlashed;
        stake.executeSlash(reqA);
        rec = stake.slashRecordOf(reqA);
        uint256 agentAmt = (uint256(rec.applied) * p.slashAgentBps) / 10_000;
        uint256 platAmt = (uint256(rec.applied) * p.slashPlatformBps) / 10_000;
        _expect(rec.status == SlashStatus.Executed, "slash A executed");
        _expect(rec.applied > 0, "a penalty was applied");
        _expect(usdg.balanceOf(rec.beneficiary) == benBefore + agentAmt, "agent share paid");
        _expect(usdg.balanceOf(p.treasury) == treBefore + platAmt, "platform share paid");
        _expect(
            stake.stakeOf(provider).totalSlashed == slashedBefore + agentAmt + platAmt,
            "provider debited exactly the taken shares"
        );
        console2.log("[ok] slash A executed: applied", rec.applied);

        // Withdraw stake once the unbonding period has run.
        X402Stake.ProviderStake memory s = stake.stakeOf(provider);
        vm.warp(uint256(s.unbondingStartedAt) + p.unbondingPeriodSeconds);
        uint256 provTok = usdg.balanceOf(provider);
        uint64 out = stake.withdrawableOf(provider);
        _expect(out > 0, "something is withdrawable");
        vm.prank(provider);
        stake.withdrawStake(out);
        _expect(usdg.balanceOf(provider) == provTok + out, "provider received unbonded stake");
        console2.log("[ok] provider withdrew unbonded stake", out);

        // A fresh proposal left past its execution grace can no longer execute and expires.
        bytes32 reqC = keccak256(abi.encode(tag, "slash-c"));
        (SlashAttestation memory c, bytes memory sc) = _attestation(reqC, p.penaltyAmount);
        stake.proposeSlash(c, sc);
        X402Stake.SlashRecord memory recC = stake.slashRecordOf(reqC);
        vm.warp(uint256(recC.executableAt) + Constants.SLASH_EXECUTION_GRACE_SECONDS);
        _reverts(
            address(stake),
            buyer,
            abi.encodeCall(X402Stake.executeSlash, (reqC)),
            SlashExecutionWindowClosed.selector,
            "slash executed after its grace"
        );
        stake.expireSlash(reqC);
        _expect(stake.slashRecordOf(reqC).status == SlashStatus.Cancelled, "slash C expired");
        console2.log("[ok] slash C expired after its grace");

        console2.log("TIME PHASE PASSED");
    }

    // ── helpers ──────────────────────────────────────────────────────────────────────────

    function _voucher(uint64 seq, uint64 amount) internal view returns (Voucher memory) {
        return Voucher({
            payer: buyer,
            provider: provider,
            amount: amount,
            resourceHash: keccak256("e2e:resource"),
            requestHash: keccak256(abi.encode("e2e:request", seq)),
            seq: seq,
            issuedAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp + 240)
        });
    }

    function _attestation(bytes32 requestId, uint64 penalty)
        internal
        view
        returns (SlashAttestation memory a, bytes memory sig)
    {
        a = SlashAttestation({
            requestId: requestId,
            provider: provider,
            beneficiary: buyer,
            status: uint8(ResponseClass.DataFail),
            penalty: penalty,
            policy: keccak256("e2e:policy"),
            issuedAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp + 1 days)
        });
        sig = VoucherSigner.signAttestation(verifierPk, stake.DOMAIN_SEPARATOR(), a);
    }

    function _reverts(
        address target,
        address from,
        bytes memory data,
        bytes4 selector,
        string memory what
    ) internal {
        vm.prank(from);
        (bool success, bytes memory ret) = target.call(data);
        if (success || ret.length < 4 || bytes4(ret) != selector) {
            revert Check(string.concat("expected refusal: ", what));
        }
    }

    function _expect(bool ok, string memory what) internal pure {
        if (!ok) revert Check(what);
    }
}
