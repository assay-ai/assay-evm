// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.24;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Fixture} from "./helpers/Fixture.sol";
import {VoucherSigner} from "./helpers/VoucherSigner.sol";
import {X402ConfigPreDispute} from "./helpers/legacy/X402ConfigPreDispute.sol";
import {X402StakePreDispute} from "./helpers/legacy/X402StakePreDispute.sol";
import {X402Config} from "../src/X402Config.sol";
import {X402Stake} from "../src/X402Stake.sol";
import {IX402Config} from "../src/interfaces/IX402Config.sol";
import {SlashAttestation, ResponseClass, SlashStatus, ParamSet} from "../src/Types.sol";
import {Constants} from "../src/Constants.sol";
import "../src/Errors.sol";

/// The dispute upgrade, run against the REAL pre-upgrade code (verbatim copies at 833b362 in
/// `test/helpers/legacy/`): every stake, every slash record in each of its three reachable
/// states, the totals, the attestation domain and the whole Config survive, the appended fields
/// read as zero, the slash delay reads 72 hours, and a record proposed before the upgrade can be
/// disputed after it.
contract UpgradeDisputeTest is Fixture {
    uint256 internal verifierKeyPk = 0x7E5717;
    address internal verifierAddr;
    address internal beneficiary = address(0xA6E7);
    address internal provider2 = address(0x9302);
    address internal arbiterAddr = address(0xA4B1);

    X402ConfigPreDispute internal oldConfig;
    X402StakePreDispute internal oldStake;

    bytes32 internal constant EXECUTED = bytes32("u-exec");
    bytes32 internal constant CANCELLED = bytes32("u-cancel");
    bytes32 internal constant PENDING = bytes32("u-pending");
    bytes32 internal constant PENDING2 = bytes32("u-pending2");

    function setUp() public virtual override {
        super.setUp();
        verifierAddr = vm.addr(verifierKeyPk);

        ParamSet memory p = config.params();
        oldConfig = X402ConfigPreDispute(
            address(
                new ERC1967Proxy(
                    address(new X402ConfigPreDispute()),
                    abi.encodeCall(X402ConfigPreDispute.initialize, (p, admin, owner))
                )
            )
        );
        oldStake = X402StakePreDispute(
            address(
                new ERC1967Proxy(
                    address(new X402StakePreDispute()),
                    abi.encodeCall(
                        X402StakePreDispute.initialize,
                        (IX402Config(address(oldConfig)), IERC20(address(usdg)))
                    )
                )
            )
        );

        vm.prank(admin);
        oldConfig.registerVerifier(
            verifierAddr, bytes32("verifier-evm-2026-09"), uint64(block.timestamp) + 180 * 86_400
        );

        // Two providers, one of them part-way out.
        _fund(address(this), 3_000_000_000);
        usdg.approve(address(oldStake), 3_000_000_000);
        oldStake.depositStakeFor(provider, 1_000_000_000);
        oldStake.depositStakeFor(provider2, 2_000_000_000);
        vm.prank(provider2);
        oldStake.requestUnstake(500_000_000);

        // One record in each state: executed, cancelled, still pending (x2).
        _propose(EXECUTED, provider);
        _propose(CANCELLED, provider);
        vm.warp(block.timestamp + Constants.SLASH_DELAY_SECONDS);
        oldStake.executeSlash(EXECUTED);
        vm.prank(admin);
        oldStake.cancelSlash(CANCELLED);
        _propose(PENDING, provider);
        _propose(PENDING2, provider2);
    }

    function _propose(bytes32 id, address who) internal {
        SlashAttestation memory a = SlashAttestation({
            requestId: id,
            provider: who,
            beneficiary: beneficiary,
            status: uint8(ResponseClass.DataFail),
            penalty: 1_000_000,
            policy: keccak256("policy v1"),
            issuedAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp) + 3 * 86_400
        });
        oldStake.proposeSlash(
            a, VoucherSigner.signAttestation(verifierKeyPk, oldStake.DOMAIN_SEPARATOR(), a)
        );
    }

    function _upgradeBoth() internal returns (X402Config c, X402Stake s) {
        address cImpl = address(new X402Config());
        address sImpl = address(new X402Stake());
        // Config FIRST: the new Stake calls `slashDelaySeconds`, `arbiter` and `assertActive`,
        // which the old Config does not have (`test_theOrderMatters`).
        vm.startPrank(owner);
        oldConfig.upgradeToAndCall(cImpl, "");
        oldStake.upgradeToAndCall(sImpl, "");
        vm.stopPrank();
        c = X402Config(address(oldConfig));
        s = X402Stake(address(oldStake));
    }

    function _assertRecord(X402Stake s, bytes32 id, X402StakePreDispute.SlashRecord memory b)
        internal
        view
    {
        X402Stake.SlashRecord memory a = s.slashRecordOf(id);
        assertEq(a.provider, b.provider, "provider");
        assertEq(uint256(a.status), uint256(b.status), "status");
        assertEq(a.penalty, b.penalty, "penalty");
        assertEq(a.beneficiary, b.beneficiary, "beneficiary");
        assertEq(a.proposedAt, b.proposedAt, "proposedAt");
        assertEq(a.verifier, b.verifier, "verifier");
        assertEq(a.executableAt, b.executableAt, "executableAt");
        assertEq(a.reserved, b.reserved, "reserved");
        assertEq(a.capAllowance, b.capAllowance, "capAllowance");
        assertEq(a.applied, b.applied, "applied");
        assertEq(a.executedAt, b.executedAt, "executedAt");
        assertEq(a.policy, b.policy, "policy");
        assertEq(a.disputedAt, 0, "the appended field reads zero");
    }

    function _assertStake(X402Stake s, address who, X402StakePreDispute.ProviderStake memory b)
        internal
        view
    {
        X402Stake.ProviderStake memory a = s.stakeOf(who);
        assertEq(abi.encode(a), abi.encode(b), "the whole ProviderStake");
    }

    function test_theDisputeUpgradePreservesEveryStakeRecordAndSetting() public {
        bytes32[4] memory ids = [EXECUTED, CANCELLED, PENDING, PENDING2];
        X402StakePreDispute.SlashRecord[4] memory recs;
        for (uint256 i = 0; i < 4; i++) {
            recs[i] = oldStake.slashRecordOf(ids[i]);
        }
        assertEq(uint256(recs[0].status), uint256(SlashStatus.Executed));
        assertEq(uint256(recs[1].status), uint256(SlashStatus.Cancelled));
        assertEq(uint256(recs[2].status), uint256(SlashStatus.Pending));

        X402StakePreDispute.ProviderStake memory s1 = oldStake.stakeOf(provider);
        X402StakePreDispute.ProviderStake memory s2 = oldStake.stakeOf(provider2);
        uint128[4] memory totals = [
            oldStake.totalStaked(),
            oldStake.totalDeposited(),
            oldStake.totalWithdrawn(),
            oldStake.totalSlashed()
        ];
        bytes32 sep = oldStake.DOMAIN_SEPARATOR();
        bytes memory paramsBefore = abi.encode(oldConfig.params());
        bytes memory keyBefore = abi.encode(oldConfig.verifierKey(verifierAddr));
        uint256 vault = usdg.balanceOf(address(oldStake));

        (X402Config c, X402Stake s) = _upgradeBoth();

        for (uint256 i = 0; i < 4; i++) {
            _assertRecord(s, ids[i], recs[i]);
        }
        _assertStake(s, provider, s1);
        _assertStake(s, provider2, s2);
        assertEq(s.totalStaked(), totals[0]);
        assertEq(s.totalDeposited(), totals[1]);
        assertEq(s.totalWithdrawn(), totals[2]);
        assertEq(s.totalSlashed(), totals[3]);
        // The pre-dispute build is named "x402 Settlement"; the current one "Assay Settlement".
        // Only the name moves: same version, chain and proxy.
        bytes32 renamed = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("Assay Settlement"),
                keccak256("2"),
                block.chainid,
                address(s)
            )
        );
        assertTrue(sep != renamed, "the pre-dispute build carries the old name");
        assertEq(s.DOMAIN_SEPARATOR(), renamed, "the attestation domain moves by its name only");
        assertEq(usdg.balanceOf(address(s)), vault);
        assertEq(address(s.CONFIG()), address(c));

        assertEq(abi.encode(c.params()), paramsBefore, "params");
        assertEq(abi.encode(c.verifierKey(verifierAddr)), keyBefore, "verifier registry");
        assertEq(c.admin(), admin);
        assertEq(c.owner(), owner);
        assertFalse(c.paused());

        // The appended Config state starts empty, and the delay at the old constant.
        assertEq(c.arbiter(), address(0), "no arbiter until appointed");
        assertEq(c.slashDelaySeconds(), 72 * 3600, "the upgraded proxy keeps 72 hours");
        assertFalse(c.blocked(provider));
        assertFalse(c.blocked(buyer));
    }

    /// A judgement proposed BEFORE the upgrade can be disputed, upheld and executed after it;
    /// and one left alone executes exactly as before.
    function test_aPreUpgradeRecordTakesPartInTheDispute() public {
        (X402Config c, X402Stake s) = _upgradeBoth();
        vm.prank(admin);
        c.setArbiter(arbiterAddr);

        vm.prank(provider);
        s.disputeSlash(PENDING);
        assertEq(uint256(s.slashRecordOf(PENDING).status), uint256(SlashStatus.Disputed));

        vm.warp(block.timestamp + Constants.SLASH_DELAY_SECONDS);
        vm.expectRevert(SlashNotPending.selector);
        s.executeSlash(PENDING);
        s.executeSlash(PENDING2); // undisputed: proceeds as today

        vm.prank(arbiterAddr);
        s.upholdSlash(PENDING);
        s.executeSlash(PENDING);
        assertEq(uint256(s.slashRecordOf(PENDING).status), uint256(SlashStatus.Executed));
        assertEq(s.stakeOf(provider).pendingSlash, 0);
        assertEq(s.stakeOf(provider2).pendingSlash, 0);
    }

    /// The upgrade order is load-bearing: a new Stake behind an OLD Config cannot take a deposit
    /// (the old Config has no `assertActive`), and works once Config is upgraded too.
    function test_theOrderMatters_configBeforeStake() public {
        address sImpl = address(new X402Stake());
        vm.prank(owner);
        oldStake.upgradeToAndCall(sImpl, "");
        X402Stake s = X402Stake(address(oldStake));

        _fund(address(this), 1_000_000);
        usdg.approve(address(s), 1_000_000);
        vm.expectRevert();
        s.depositStakeFor(provider, 1_000_000);

        address cImpl = address(new X402Config());
        vm.prank(owner);
        oldConfig.upgradeToAndCall(cImpl, "");
        s.depositStakeFor(provider, 1_000_000);
    }
}
