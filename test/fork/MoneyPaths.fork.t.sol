// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.24;

import {X402EscrowDepositTest} from "../X402Escrow.deposit.t.sol";
import {X402EscrowRedeemTest} from "../X402Escrow.redeem.t.sol";
import {X402EscrowBatchTest} from "../X402Escrow.batch.t.sol";
import {X402EscrowWithdrawTest} from "../X402Escrow.withdraw.t.sol";
import {X402EscrowBySigTest} from "../X402Escrow.bysig.t.sol";
import {X402EscrowDomainTest} from "../X402Escrow.domain.t.sol";
import {X402StakeTest} from "../X402Stake.stake.t.sol";
import {X402StakeSlashTest} from "../X402Stake.slash.t.sol";
import {PauseTest} from "../Pause.t.sol";
import {BoundariesTest} from "../Boundaries.t.sol";
import {UpgradeTest} from "../Upgrade.t.sol";

/// The eleven `Fixture`-based suites, unchanged, against the token actually deployed on 46630.
///
/// Nothing is overridden but the fixture's TOKEN. That is the point: an assertion that holds
/// against `MockUSDG` and not against real USDG is a difference in the token, and this file is
/// the only place it can show up. If a test here needs its expectation changed to pass, the
/// change belongs in the test, and the commit message says what the two tokens do differently.
///
/// # What is deliberately NOT here
///
/// **The invariant suites get no fork twin.** 16,384 RPC-backed calls per campaign against an
/// unpinned block is a run whose duration and whose result both move; `docs/chain-facts.md` §6
/// rules that out. `test/invariant/EscrowHandler.sol` and `StakeHandler.sol` are not `Fixture`
/// subclasses anyway — they construct and hold their own `MockUSDG`, which is why they still
/// call `usdg.mint` where every suite here calls `_fund`.
///
/// **The bespoke token doubles stay doubles.** Several of these suites deploy a second escrow in
/// front of `RedeemObserverUSDG`, `WithdrawObserverUSDG`, `WithdrawReentrantUSDG`,
/// `BatchObserverUSDG`, `ConfigShiftingUSDG`, `EighteenDecimals` or `InertAsset`. Those tests
/// keep working on the fork and keep proving what they proved — they are about the escrow's
/// behaviour against a HOSTILE token, not about USDG. **Do not try to make them use the real
/// token.**
///
/// **Five assertions skip**, the ones carrying `mockTokenOnly`: one needs `setBlocked` (the 46630
/// token has no blocklist at all, measured — `docs/chain-facts.md` §1a) and four need
/// `setTransferFeeBps`. They print as skipped rather than passing silently.
///
/// **`name()` and `symbol()` are never called on the fork token.** Its one post-Shanghai opcode
/// lives on that path; `docs/chain-facts.md` §1b. Nothing in `src/` calls them either.
contract ForkEscrowDepositTest is X402EscrowDepositTest {
    function setUp() public override {
        forkMode = true;
        super.setUp();
    }
}

contract ForkEscrowRedeemTest is X402EscrowRedeemTest {
    function setUp() public override {
        forkMode = true;
        super.setUp();
    }
}

contract ForkEscrowBatchTest is X402EscrowBatchTest {
    function setUp() public override {
        forkMode = true;
        super.setUp();
    }
}

contract ForkEscrowWithdrawTest is X402EscrowWithdrawTest {
    function setUp() public override {
        forkMode = true;
        super.setUp();
    }
}

contract ForkEscrowBySigTest is X402EscrowBySigTest {
    function setUp() public override {
        forkMode = true;
        super.setUp();
    }
}

contract ForkEscrowDomainTest is X402EscrowDomainTest {
    function setUp() public override {
        forkMode = true;
        super.setUp();
    }
}

contract ForkStakeTest is X402StakeTest {
    function setUp() public override {
        forkMode = true;
        super.setUp();
    }
}

contract ForkStakeSlashTest is X402StakeSlashTest {
    function setUp() public override {
        forkMode = true;
        super.setUp();
    }
}

contract ForkPauseTest is PauseTest {
    function setUp() public override {
        forkMode = true;
        super.setUp();
    }
}

contract ForkBoundariesTest is BoundariesTest {
    function setUp() public override {
        forkMode = true;
        super.setUp();
    }
}

contract ForkUpgradeTest is UpgradeTest {
    function setUp() public override {
        forkMode = true;
        super.setUp();
    }
}
