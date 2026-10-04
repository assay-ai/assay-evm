// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.24;

import {Fixture} from "./helpers/Fixture.sol";
import {VoucherSigner} from "./helpers/VoucherSigner.sol";
import {X402EscrowV2} from "./helpers/X402EscrowV2.sol";
import {X402EscrowBadDomainV2} from "./helpers/X402EscrowBadDomainV2.sol";
import {X402EscrowSilentDomainV2} from "./helpers/X402EscrowSilentDomainV2.sol";
import {X402Config} from "../src/X402Config.sol";
import {X402Escrow} from "../src/X402Escrow.sol";
import {X402Stake} from "../src/X402Stake.sol";
import {IX402Config} from "../src/interfaces/IX402Config.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {Voucher, ParamSet} from "../src/Types.sol";
import "../src/Errors.sol";

/// Design decision D-1, executed. The contracts are upgradeable by design decision D-1
/// — for parity with the Solana program's `BPFLoaderUpgradeable` authority — and the
/// parity claim is only true if three things hold: only the admin upgrades, `initialize` runs
/// exactly once and never on an implementation, and **an upgrade preserves both the storage and
/// the EIP-712 domain separator**, so a voucher signed before it redeems after it.
///
/// # What this file does NOT re-prove, and where those proofs live
///
/// The standing no-untested-guard rule pulled two of the three rows that belong here forward
/// into the changes that shipped the guards, so they are already measured:
///
/// - `X402Config._authorizeUpgrade`'s `onlyAdmin` — `X402Config.admin.t.sol`
///   `test_wrongSigner_onlyTheAdminUpgradesConfig`, mutation row **C6**.
/// - `X402Config`'s `_disableInitializers()` — same file,
///   `test_wrongState_theImplementationCannotBeInitialised`, row **C7**.
/// - `X402Escrow._authorizeUpgrade` and its `_disableInitializers()` —
///   `X402Escrow.deposit.t.sol`, rows **E7**, **E8**, and **E19** for the live `CONFIG.admin()`
///   read.
///
/// `test_theEarlierAuthorityProofsStillHold` re-asserts those four in one place so that a reader
/// of this file can see they hold without taking it on trust, and so deleting one of the earlier
/// tests cannot silently remove the property.
///
/// **`X402Stake` had neither proof.** It has no upgrade test and no initializer test anywhere in
/// the suite before this file, so its three guards are genuinely this task's, and rows S1–S3 in
/// `MUTATION-LOG.md` are new coverage rather than a second copy.
contract UpgradeTest is Fixture {
    address internal attacker = address(0xBAD1);

    /// keccak256("eip1967.proxy.implementation") - 1.
    bytes32 internal constant IMPL_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function _implementationOf(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, IMPL_SLOT))));
    }

    // --- (a) only the admin upgrades --------------------------------------------------------

    /// **X402Stake's upgrade door, proved for the first time.** The other two are proved in
    /// `X402Config.admin.t.sol` and the escrow suite; this one had no test at all, which is why the
    /// money contract holding every provider's collateral is the row this file actually adds.
    function test_wrongSigner_onlyTheAdminUpgradesStake() public {
        address v2 = address(new X402Stake());

        vm.prank(attacker);
        vm.expectRevert(NotAdmin.selector);
        stake.upgradeToAndCall(v2, "");

        // The redeemer is not the admin either — the largest key is one key (D-6), and the
        // redeemer is the one role that is routinely a hot key.
        vm.prank(redeemer);
        vm.expectRevert(NotAdmin.selector);
        stake.upgradeToAndCall(v2, "");
        assertEq(_implementationOf(address(stake)), address(stakeImpl), "nothing moved");

        vm.prank(admin);
        stake.upgradeToAndCall(v2, "");
        assertEq(_implementationOf(address(stake)), v2, "the admin moved it");
    }

    /// The three earlier proofs, re-asserted rather than restated. If `X402Config.admin.t.sol` or
    /// `X402Escrow.deposit.t.sol` ever loses its upgrade test, this one still goes red.
    function test_theEarlierAuthorityProofsStillHold() public {
        address escrowV2 = address(new X402EscrowV2());
        address configV2 = address(new X402Config());

        vm.prank(attacker);
        vm.expectRevert(NotAdmin.selector);
        escrow.upgradeToAndCall(escrowV2, "");

        vm.prank(attacker);
        vm.expectRevert(NotAdmin.selector);
        config.upgradeToAndCall(configV2, "");

        vm.prank(admin);
        escrow.upgradeToAndCall(escrowV2, "");
        assertEq(X402EscrowV2(address(escrow)).version2(), "v2");

        vm.prank(admin);
        config.upgradeToAndCall(configV2, "");
        assertEq(_implementationOf(address(config)), configV2);
    }

    /// The two money contracts read `CONFIG.admin()` LIVE. Handing the admin over therefore hands
    /// over the upgrade authority of all three in one transaction — the property that makes "one
    /// key" true (D-1), and the reason D-6's mistyped `newAdmin` is unrecoverable.
    ///
    /// Proved on **X402Stake**, because mutation row E19 already proved it on the escrow.
    function test_theStakeUpgradeAuthorityFollowsTheConfigAdmin() public {
        address newAdmin = address(0xA11);
        ParamSet memory p = config.params(); // read BEFORE the prank: prank arms the NEXT call
        vm.prank(admin);
        config.updateConfig(p, newAdmin);

        address v2 = address(new X402Stake());
        vm.prank(admin);
        vm.expectRevert(NotAdmin.selector);
        stake.upgradeToAndCall(v2, "");

        vm.prank(newAdmin);
        stake.upgradeToAndCall(v2, "");
        assertEq(_implementationOf(address(stake)), v2);
    }

    // --- (b) initialize runs once, and never on an implementation ---------------------------

    /// **X402Stake's `initializer` modifier and its `_disableInitializers()`, both new.** Without
    /// the first, a second call re-points `CONFIG` and `ASSET` on a live, funded stake vault;
    /// without the second, anybody initialises the implementation and — because a UUPS
    /// implementation carries `upgradeToAndCall` in its own code — upgrades it to something with
    /// a `delegatecall`-to-`selfdestruct`, which historically bricked live proxies.
    function test_wrongState_theStakeProxyAndItsImplementationCannotBeInitialised() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        stake.initialize(IX402Config(address(config)), IERC20(address(usdg)));

        vm.prank(attacker);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        stakeImpl.initialize(IX402Config(address(config)), IERC20(address(usdg)));

        assertEq(address(stakeImpl.CONFIG()), address(0), "the implementation has no config, ever");
        assertEq(address(stake.CONFIG()), address(config), "and the proxy's is untouched");
    }

    // --- (c) an upgrade preserves state, the domain, and outstanding vouchers ----------------

    /// THE PARITY PROPERTY, and the reason this task exists.
    ///
    /// On Solana the program id survives an upgrade, so a signature made against it survives.
    /// Here the proxy address is the EIP-712 `verifyingContract`, so the same must be true —
    /// asserted on money, on the replay high-water mark, on the limits, on the pool total, on the
    /// domain separator, and finally on a real voucher signed BEFORE the upgrade and redeemed
    /// AFTER it.
    function test_anUpgradePreservesEveryBalanceTheDomainAndAnOutstandingVoucher() public {
        _fund(buyer, 100_000_000);
        vm.startPrank(buyer);
        usdg.approve(address(escrow), 100_000_000);
        escrow.deposit(100_000_000);
        escrow.setLimits(10_000_000, 50_000_000);
        vm.stopPrank();

        // One voucher already spent, so `seqHigh` is not zero and the assertion below is not
        // satisfied by a fresh mapping slot.
        Voucher memory spent = _voucher(1, 250_000);
        // Both arguments built BEFORE the prank. `vm.prank` arms the NEXT call, and
        // `escrow.DOMAIN_SEPARATOR()` inside the argument list is a call — it consumes the prank
        // and `redeemVoucher` then arrives from the test contract, which is `NotRedeemer`.
        // `Fixture` spells this hazard out, and it is easy to commit anyway; measured, not reasoned
        // about.
        bytes memory spentSig =
            VoucherSigner.signVoucher(buyerKey, escrow.DOMAIN_SEPARATOR(), spent);
        vm.prank(redeemer);
        escrow.redeemVoucher(spent, spentSig);

        // A voucher signed NOW, against the CURRENT implementation, deliberately not redeemed
        // until after the upgrade.
        Voucher memory pending = _voucher(2, 1_000_000);
        bytes memory sigBefore =
            VoucherSigner.signVoucher(buyerKey, escrow.DOMAIN_SEPARATOR(), pending);

        bytes32 sepBefore = escrow.DOMAIN_SEPARATOR();
        uint128 balanceBefore = escrow.escrowOf(buyer).balance;
        uint64 seqHighBefore = escrow.escrowOf(buyer).seqHigh;
        uint64 maxVoucherBefore = escrow.escrowOf(buyer).maxVoucherAmount;
        uint64 maxWindowBefore = escrow.escrowOf(buyer).maxPerWindow;
        uint64 spentInWindowBefore = escrow.escrowOf(buyer).spentInWindow;
        uint128 totalBefore = escrow.totalEscrowed();
        uint128 redeemedBefore = escrow.escrowOf(buyer).totalRedeemed;

        // The `new` is a CREATE, which is also a call, so it too must precede the prank.
        address v2 = address(new X402EscrowV2());
        vm.prank(admin);
        escrow.upgradeToAndCall(v2, "");

        assertEq(escrow.DOMAIN_SEPARATOR(), sepBefore, "the separator must not move");
        assertEq(escrow.escrowOf(buyer).balance, balanceBefore, "balance");
        assertEq(escrow.escrowOf(buyer).seqHigh, seqHighBefore, "seqHigh");
        assertEq(escrow.escrowOf(buyer).maxVoucherAmount, maxVoucherBefore, "per-call limit");
        assertEq(escrow.escrowOf(buyer).maxPerWindow, maxWindowBefore, "window limit");
        assertEq(escrow.escrowOf(buyer).spentInWindow, spentInWindowBefore, "the window counter");
        assertEq(escrow.escrowOf(buyer).totalRedeemed, redeemedBefore, "totalRedeemed");
        assertEq(escrow.totalEscrowed(), totalBefore, "the pool total");
        assertEq(address(escrow.CONFIG()), address(config), "CONFIG");
        assertEq(address(escrow.STAKE()), address(stake), "STAKE");
        assertEq(address(escrow.ASSET()), address(usdg), "ASSET");

        // The new code is live and its appended slot starts at zero, having overwritten nothing.
        assertEq(X402EscrowV2(address(escrow)).upgradedAt(), 0);
        X402EscrowV2(address(escrow)).markUpgraded();
        assertEq(X402EscrowV2(address(escrow)).upgradedAt(), block.timestamp);
        assertEq(escrow.escrowOf(buyer).balance, balanceBefore, "the append moved no money");
        assertEq(escrow.totalEscrowed(), totalBefore, "the append moved no pool total");

        // AND the voucher signed before the upgrade still redeems. This is the parity claim.
        vm.prank(redeemer);
        escrow.redeemVoucher(pending, sigBefore);
        assertEq(escrow.escrowOf(buyer).balance, balanceBefore - 1_000_000);
        assertEq(escrow.escrowOf(buyer).seqHigh, 2);
    }

    /// The append lands at slot **59**, past the parent's `uint256[50] __gap` (slots 9-58), not
    /// inside it — a common assumption says the opposite and it is measurably wrong. Measured here
    /// so the claim in `X402EscrowV2`'s header is a number rather than an assertion, and so that a
    /// future reader does not conclude the gap is being consumed when it is not.
    ///
    /// Storage-safe either way, which is exactly why the error was invisible; the difference is
    /// that appending in a derived contract is an unbounded habit, while shrinking the parent's
    /// gap is a budget.
    function test_theAppendedFieldLandsPastTheParentsGapNotInsideIt() public {
        address v2 = address(new X402EscrowV2());
        vm.prank(admin);
        escrow.upgradeToAndCall(v2, "");
        X402EscrowV2(address(escrow)).markUpgraded();

        assertEq(uint256(vm.load(address(escrow), bytes32(uint256(59)))), block.timestamp, "59");
        for (uint256 slot = 9; slot <= 58; slot++) {
            assertEq(uint256(vm.load(address(escrow), bytes32(slot))), 0, "the gap stayed empty");
        }
    }

    /// The stake side of the same claim: a verifier's attestation domain does not move either, so
    /// a proposal in flight is not orphaned by an upgrade.
    function test_anUpgradeDoesNotMoveTheStakeDomainSeparatorOrItsTotals() public {
        _fund(address(this), 500_000_000);
        usdg.approve(address(stake), 500_000_000);
        stake.depositStakeFor(provider, 500_000_000);

        bytes32 sepBefore = stake.DOMAIN_SEPARATOR();
        uint128 stakedBefore = stake.totalStaked();
        uint128 bondedBefore = stake.stakeOf(provider).bonded;

        address v2 = address(new X402Stake());
        vm.prank(admin);
        stake.upgradeToAndCall(v2, "");

        assertEq(stake.DOMAIN_SEPARATOR(), sepBefore, "the attestation domain must not move");
        assertEq(stake.totalStaked(), stakedBefore, "totalStaked");
        assertEq(stake.stakeOf(provider).bonded, bondedBefore, "the provider's bond");
    }

    /// And the config side: the parameter set and the admin survive, so the upgrade authority
    /// does not evaporate mid-upgrade.
    function test_anUpgradePreservesTheParameterSetAndTheAdmin() public {
        ParamSet memory before = config.params();
        address v2 = address(new X402Config());
        vm.prank(admin);
        config.upgradeToAndCall(v2, "");
        assertEq(abi.encode(config.params()), abi.encode(before), "params");
        assertEq(config.admin(), admin, "admin");
    }

    // --- (d) the negative that (c) guards against -------------------------------------------

    /// An implementation with a DIFFERENT EIP-712 name or version moves the domain separator and
    /// kills every outstanding voucher. Nothing on chain refuses it — `_authorizeUpgrade` checks
    /// *who*, never *what*. This test exists so the failure is written down and measured rather
    /// than discovered, and `docs/deploy-runbook.md` §7 names it as the one thing an upgrade must
    /// never do.
    function test_wrongState_anImplementationWithADifferentDomainKillsOutstandingVouchers()
        public
    {
        _fund(buyer, 100_000_000);
        vm.startPrank(buyer);
        usdg.approve(address(escrow), 100_000_000);
        escrow.deposit(100_000_000);
        escrow.setLimits(10_000_000, 50_000_000);
        vm.stopPrank();

        Voucher memory v = _voucher(1, 250_000);
        bytes32 sepBefore = escrow.DOMAIN_SEPARATOR();
        bytes memory sigBefore = VoucherSigner.signVoucher(buyerKey, sepBefore, v);

        // The signature is good against the CURRENT domain — proved, so that the failure below
        // is attributable to the upgrade and to nothing else.
        assertEq(
            VoucherSigner.recoverVoucher(sepBefore, v, sigBefore), buyer, "good before the upgrade"
        );

        address bad = address(new X402EscrowBadDomainV2());
        vm.prank(admin);
        escrow.upgradeToAndCall(bad, "");

        bytes32 sepAfter = X402EscrowBadDomainV2(address(escrow)).DOMAIN_SEPARATOR();
        assertTrue(sepAfter != sepBefore, "version 2 -> 3 must move the separator");

        // And the concrete consequence: the pre-upgrade signature no longer recovers to the buyer
        // under the new domain. Every outstanding voucher is dead, silently, with no revert
        // anywhere in the upgrade transaction.
        assertTrue(
            VoucherSigner.recoverVoucher(sepAfter, v, sigBefore) != buyer,
            "a voucher signed under the old domain is dead"
        );
    }

    /// The same failure reached from the other side: the **name**, not the version. Kept separate
    /// because an operator changing "x402 Settlement" to "X402 Settlement" while tidying a string
    /// is a more plausible mistake than bumping a version deliberately, and because one test
    /// proving one of the two fields would leave the other unmeasured.
    ///
    /// It is asserted against `_domainSeparatorV4`'s own inputs rather than through a second stub
    /// contract: the separator is `keccak256(abi.encode(TYPE_HASH, nameHash, versionHash, chainId,
    /// verifyingContract))`, so recomputing it with one hash changed is the whole of the claim.
    function test_wrongState_aDifferentEip712NameMovesTheSeparatorToo() public view {
        bytes32 typeHash = keccak256(
            "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
        );
        bytes32 live = keccak256(
            abi.encode(
                typeHash,
                keccak256("x402 Settlement"),
                keccak256("2"),
                block.chainid,
                address(escrow)
            )
        );
        assertEq(live, escrow.DOMAIN_SEPARATOR(), "the shipped domain, recomputed");

        bytes32 renamed = keccak256(
            abi.encode(
                typeHash,
                keccak256("X402 Settlement"), // one capital letter
                keccak256("2"),
                block.chainid,
                address(escrow)
            )
        );
        assertTrue(renamed != live, "one capital letter kills every outstanding voucher");
    }

    /// The same failure with the alarm disconnected, and the reason (c) does not stop at the
    /// getter. `X402EscrowSilentDomainV2` leaves `DOMAIN_SEPARATOR()` returning the old value —
    /// it is `external` and non-`virtual`, so an implementation cannot change it even if it
    /// wanted to — and moves only `_hashTypedDataV4`, which is what every signature check
    /// actually uses. The exported domain and the enforced domain then disagree.
    ///
    /// An upgrade test that compared the getter and stopped would be green here. This one is red
    /// on the thing that matters: a voucher signed before the upgrade no longer redeems, and the
    /// contract diagnoses it as `SignerIsNotPayer` — an operator would read that as "the backend
    /// signed with the wrong key", which is the wrong incident entirely.
    function test_wrongState_anImplementationCanMoveTheENFORCEDDomainWithoutMovingTheGETTER()
        public
    {
        _fund(buyer, 100_000_000);
        vm.startPrank(buyer);
        usdg.approve(address(escrow), 100_000_000);
        escrow.deposit(100_000_000);
        escrow.setLimits(10_000_000, 50_000_000);
        vm.stopPrank();

        Voucher memory v = _voucher(1, 250_000);
        bytes32 sepBefore = escrow.DOMAIN_SEPARATOR();
        bytes memory sig = VoucherSigner.signVoucher(buyerKey, sepBefore, v);

        address silent = address(new X402EscrowSilentDomainV2());
        vm.prank(admin);
        escrow.upgradeToAndCall(silent, "");

        // The alarm every lazy test reads is still silent.
        assertEq(escrow.DOMAIN_SEPARATOR(), sepBefore, "the GETTER did not move");

        // The voucher is dead all the same, and the error names the wrong cause.
        vm.prank(redeemer);
        vm.expectRevert(SignerIsNotPayer.selector);
        escrow.redeemVoucher(v, sig);
    }

    function _voucher(uint64 seq, uint64 amount) internal view returns (Voucher memory v) {
        v = Voucher({
            payer: buyer,
            provider: provider,
            amount: amount,
            resourceHash: keccak256("https://example.test/search"),
            requestHash: keccak256(abi.encodePacked("request", seq)),
            seq: seq,
            issuedAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp) + 300
        });
    }
    // --- the third upgrade-safety variable: the FUNCTION SURFACE -------------------------------

    /// Three things decide whether an upgrade is safe: the storage layout, the EIP-712 domain,
    /// and the set of functions the new implementation exports. The first two are gated —
    /// `script/check-layout.sh` and the runbook's `DOMAIN_SEPARATOR()` comparison plus its
    /// redeem-a-real-voucher check. **The third was gated on `X402Escrow` alone**, by
    /// `X402Escrow.withdraw.t.sol::test_theExitPaysMsgSenderAndTheAbiHasNoOtherWithdrawDoor`.
    ///
    /// Measured: adding `setAdminUnchecked(address)` to `X402Config` — a function that hands the
    /// admin key, and with it the upgrade authority of all three contracts, to any caller — left
    /// **all 382 tests passing**. These two tests are the escrow pin's missing halves.
    ///
    /// They are a **belt**, and they ship in the same commit that would change them, which is the
    /// limit the escrow pin has always had. The **brace** is `abiKeccak` in
    /// `deployments/<chainId>.json`: that is written once at deploy time and can only be changed
    /// by an operator rewriting the record after the gate has named the added signature, which is
    /// a separate act at a separate time. See `script/abi-surface.sh`.
    function test_theConfigFunctionSurfaceIsPinnedByName() public view {
        string[17] memory expected = [
            "UPGRADE_INTERFACE_VERSION()",
            "admin()",
            "assertCanSign(address)",
            "canSign(address)",
            "initialize((address,address,uint64,uint64,uint64,uint64,uint16,uint16,uint16,uint16),address)",
            "params()",
            "paused()",
            "proxiableUUID()",
            "registerVerifier(address,bytes32,uint64)",
            "revokeVerifier(address)",
            "setPaused(bool)",
            "slashProviderBps()",
            "updateConfig((address,address,uint64,uint64,uint64,uint64,uint16,uint16,uint16,uint16),address)",
            "upgradeToAndCall(address,bytes)",
            "verifierExpiry(address)",
            "verifierKey(address)",
            "" // the 17th slot is deliberately empty: a 17th function makes this test red
        ];
        _assertSurface("X402Config", 16, _dyn17(expected));
    }

    function test_theStakeFunctionSurfaceIsPinnedByName() public view {
        string[25] memory expected = [
            "ASSET()",
            "CONFIG()",
            "DOMAIN_SEPARATOR()",
            "UPGRADE_INTERFACE_VERSION()",
            "bondedOf(address)",
            "cancelSlash(bytes32)",
            "depositStake(uint64)",
            "depositStakeFor(address,uint64)",
            "eip712Domain()",
            "executeSlash(bytes32)",
            "expireSlash(bytes32)",
            "initialize(address,address)",
            "proposeSlash((bytes32,address,address,uint8,uint64,bytes32,uint64,uint64),bytes)",
            "proxiableUUID()",
            "requestUnstake(uint64)",
            "slashRecordOf(bytes32)",
            "stakeOf(address)",
            "totalDeposited()",
            "totalSlashed()",
            "totalStaked()",
            "totalWithdrawn()",
            "upgradeToAndCall(address,bytes)",
            "withdrawStake(uint64)",
            "withdrawableOf(address)",
            "" // the 25th slot is deliberately empty: a 25th function makes this test red
        ];
        _assertSurface("X402Stake", 24, _dyn25(expected));
    }

    /// Both directions, as the escrow's pin does them: nothing exported that is not on the list,
    /// and nothing on the list that stopped being exported. A count alone would let a rename
    /// through.
    function _assertSurface(string memory name, uint256 count, string[] memory expected)
        internal
        view
    {
        string memory artifact =
            vm.readFile(string.concat(vm.projectRoot(), "/out/", name, ".sol/", name, ".json"));
        string[] memory keys = vm.parseJsonKeys(artifact, ".methodIdentifiers");
        assertEq(keys.length, count, string.concat(name, "'s external surface changed size"));

        for (uint256 i = 0; i < keys.length; i++) {
            bool found;
            for (uint256 j = 0; j < expected.length; j++) {
                if (keccak256(bytes(keys[i])) == keccak256(bytes(expected[j]))) found = true;
            }
            assertTrue(found, string.concat("an external function nobody pinned: ", keys[i]));
        }
        for (uint256 j = 0; j < expected.length - 1; j++) {
            bool found;
            for (uint256 i = 0; i < keys.length; i++) {
                if (keccak256(bytes(keys[i])) == keccak256(bytes(expected[j]))) found = true;
            }
            assertTrue(
                found, string.concat("a pinned external function disappeared: ", expected[j])
            );
        }
    }

    function _dyn17(string[17] memory a) internal pure returns (string[] memory out) {
        out = new string[](17);
        for (uint256 i = 0; i < 17; i++) {
            out[i] = a[i];
        }
    }

    function _dyn25(string[25] memory a) internal pure returns (string[] memory out) {
        out = new string[](25);
        for (uint256 i = 0; i < 25; i++) {
            out[i] = a[i];
        }
    }

    /// The shell half, pinned the way `test_theWeakVerifierCannotSeeAnUnrecordedUpgrade` pins the
    /// ERC-1967 slot read: by source text, so that "simplifying" the scripts fails a test rather
    /// than passing review.
    function test_theDeploymentScriptsCarryTheFunctionSurfaceGate() public view {
        bytes memory rec =
            bytes(vm.readFile(string.concat(vm.projectRoot(), "/script/new-deployment-record.sh")));
        assertGt(_countU(rec, "abiKeccak"), 0, "the record must carry an abiKeccak per contract");
        assertGt(_countU(rec, "abiFunctions"), 0, "and the named list a reviewer reads");

        bytes memory ver =
            bytes(vm.readFile(string.concat(vm.projectRoot(), "/script/verify-deployment.sh")));
        assertGt(_countU(ver, "abiKeccak"), 0, "verify-deployment.sh must compare it");
        assertGt(_countU(ver, "abi_hash"), 0, "against a freshly computed surface");
        assertGt(_countU(ver, "function surface"), 0, "and must fail by that name");

        bytes memory chk =
            bytes(vm.readFile(string.concat(vm.projectRoot(), "/script/check-bytecode.sh")));
        assertGt(_countU(chk, "abiKeccak"), 0, "and CI gate 6 must compare it too");
        // The pipe form of this call fails with "odd number of digits" and, under
        // `set -euo pipefail`, aborted the gate before it compared anything. It had never run,
        // because no record had reached "status": "deployed".
        assertEq(
            _countU(chk, "deployedBytecode | cast keccak"),
            0,
            "check-bytecode.sh must not pipe bytecode into cast keccak"
        );
    }

    function _countU(bytes memory h, string memory needle) internal pure returns (uint256 n) {
        bytes memory x = bytes(needle);
        if (x.length == 0 || x.length > h.length) return 0;
        for (uint256 i = 0; i + x.length <= h.length; i++) {
            uint256 j = 0;
            while (j < x.length && h[i + j] == x[j]) j++;
            if (j == x.length) n++;
        }
    }
}
