// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.24;

/// Models the three USDG properties that matter: 6 decimals, a Paxos-style blocklist, and a
/// fee-on-transfer switch for the delta assertion. Deliberately minimal — it is not an
/// ERC-20 reference implementation, it is an adversary.
///
/// **Two of those three are hypotheses about MAINNET USDG on 4663, whose address nobody has**
/// (`docs/risk-register.md` §10). The token actually deployed on 46630 is 5,652 bytes of plain
/// Ownable ERC-20 plus a faucet: **no blocklist under any of five spellings, no fee-on-transfer,
/// not proxied** — enumerated from its bytecode, `docs/chain-facts.md` §1a.
///
/// So the levers here are still the right ones to defend against, and they are still not evidence
/// about a deployed token. `test/fork/MoneyPaths.fork.t.sol` re-runs these suites against the real
/// 46630 token; the five assertions that need `setBlocked` or `setTransferFeeBps` carry
/// `Fixture.mockTokenOnly` and SKIP there, because the fork cannot supply their premise.
///
/// For the accounting consequence of a reverting payout — the property a blocklist actually
/// exercises — use `test/helpers/BlockingUSDG.sol`, which is wrong in exactly one way. This
/// contract is wrong in three at once, and a fixture wrong in two passes for the wrong reason.
contract MockUSDG {
    string public constant name = "Global Dollar";
    string public constant symbol = "USDG";
    uint8 public constant decimals = 6;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => bool) public blocked;
    uint256 public totalSupply;
    uint16 public transferFeeBps;

    error Blocked(address who);

    function setBlocked(address who, bool value) external {
        blocked[who] = value;
    }

    function setTransferFeeBps(uint16 bps) external {
        transferFeeBps = bps;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) internal {
        if (blocked[from]) revert Blocked(from);
        if (blocked[to]) revert Blocked(to);
        balanceOf[from] -= amount;
        uint256 received = amount - (amount * transferFeeBps) / 10_000;
        balanceOf[to] += received;
        totalSupply -= amount - received;
    }
}

/// A second adversary, for exactly one guard: `nonReentrant` on the funding paths.
///
/// It is a token whose `transferFrom` calls back into `X402Escrow.depositFor` before returning,
/// which is the shape a real ERC-777-style hook or a malicious upgradeable asset would have.
/// Six decimals so `initialize` accepts it; everything else is the minimum an escrow touches.
///
/// Separate from [`MockUSDG`] rather than a flag on it, because a token that re-enters on every
/// transfer cannot also serve the tests that need an ordinary transfer.
///
/// **It funds its own re-entry.** Before recursing it mints itself the amount and approves the
/// escrow for it, so the nested `depositFor` is a call that would genuinely SUCCEED if it were
/// let through. Without that, the nested pull underflows an allowance and the mutation is killed
/// by the mock's own arithmetic rather than by anything the escrow does — a proof that would be
/// measuring the double.
contract ReentrantUSDG {
    uint8 public constant decimals = 6;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    /// The escrow to re-enter, and how much to ask it for. Set after the escrow exists.
    address public escrow;
    uint64 public reenterAmount;
    bool private reentered;

    function setEscrow(address escrow_, uint64 amount) external {
        escrow = escrow_;
        reenterAmount = amount;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        if (escrow != address(0) && !reentered) {
            reentered = true;
            // Everything the nested deposit needs to go through: the token pays for it itself.
            balanceOf[address(this)] += reenterAmount;
            allowance[address(this)][escrow] = type(uint256).max;
            // The re-entry. Its revert is bubbled by SafeERC20's `_callOptionalReturn`, so the
            // test sees `ReentrancyGuardReentrantCall` and not a wrapper error.
            IDepositFor(escrow).depositFor(from, reenterAmount);
        }
        return true;
    }
}

interface IDepositFor {
    function depositFor(address buyer, uint64 amount) external;
}

/// A token that **returns `false`** from `transferFrom` and moves nothing — the ERC-20 return
/// convention taken seriously by a token that is refusing.
///
/// This is one of the two adversaries that make `SafeERC20` a *proved* requirement rather than a
/// reviewed one. [`MockUSDG`] always returns `true` and always returns 32 bytes, so against it
/// alone a bare `ASSET.transferFrom(…)` with the boolean discarded is indistinguishable from
/// `ASSET.safeTransferFrom(…)` — measured, that substitution survived the entire suite.
contract FalseReturningUSDG {
    uint8 public constant decimals = 6;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    /// Refuses, in the way the standard allows a token to refuse: `false`, no revert, no move.
    function transferFrom(address, address, uint256) external pure returns (bool) {
        return false;
    }
}

/// A token that **returns no data at all** and moves the balances anyway — USDT's shape, and the
/// reason `SafeERC20` exists in the first place.
///
/// Against this token the *correct* implementation must SUCCEED: `_callOptionalReturn` accepts an
/// empty return from an address with code. A bare `ASSET.transferFrom(…)` through the `IERC20`
/// interface cannot — Solidity tries to ABI-decode a `bool` out of zero bytes and reverts. So
/// this mock is the one that kills the substitution by refusing to work without `SafeERC20`,
/// where [`FalseReturningUSDG`] kills it by working when it should not.
contract NoReturnUSDG {
    uint8 public constant decimals = 6;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
    }

    /// No `returns (bool)`. The call succeeds and the returndata is empty.
    function transferFrom(address from, address to, uint256 amount) external {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

/// A third adversary, for the guard the funding doors could not prove: a token whose **payout**
/// re-enters `redeemVoucher`.
///
/// [`ReentrantUSDG`] re-enters from `transferFrom`, which is the money-IN direction, and there
/// `nonReentrant` overlaps with the measured-delta assertion — `test/MUTATION-LOG.md` rows E4 and
/// E23 record that deleting the modifier is caught by the delta and not by the guard. A payout has
/// no delta to fall back on, so this mock re-enters from `transfer` instead, which is the only
/// place the guard is the sole thing standing between a voucher and being paid twice.
///
/// It carries the re-entry as raw calldata rather than a typed `Voucher`, so this file needs no
/// import from `src/` and the test decides what the nested call is. The inner revert is bubbled
/// verbatim, and `SafeERC20._callOptionalReturn` bubbles it again, so the test sees
/// `ReentrancyGuardReentrantCall` rather than a wrapper.
contract RedeemReentrantUSDG {
    uint8 public constant decimals = 6;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    address public escrow;
    bytes public reentryCalldata;
    bool private armed;
    bool public didReenter;

    function arm(address escrow_, bytes calldata data) external {
        escrow = escrow_;
        reentryCalldata = data;
        armed = true;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    /// The payout door. Re-enters ONCE, before returning — where an ERC-777-style hook, or a
    /// callback added by an upgrade to an upgradeable asset, would sit.
    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        if (armed) {
            armed = false; // once, or the recursion has no floor
            didReenter = true;
            (bool ok, bytes memory ret) = escrow.call(reentryCalldata);
            if (!ok) {
                assembly ("memory-safe") {
                    revert(add(ret, 0x20), mload(ret))
                }
            }
        }
        return true;
    }
}

/// The scalar getters `X402Stake` exposes, for the two observers below. Only scalars, so this
/// file needs no mirror of `ProviderStake` or `SlashRecord` that could silently drift from the
/// structs it would be copying.
interface IStakeObserved {
    function totalStaked() external view returns (uint128);
    function totalWithdrawn() external view returns (uint128);
    function totalSlashed() external view returns (uint128);
    function withdrawableOf(address provider) external view returns (uint64);
    function bondedOf(address provider) external view returns (uint64);
}

/// A settlement asset that re-enters a **VIEW** from inside `transfer` and records what it sees.
///
/// The committed pattern, after `RedeemObserverUSDG` and `WithdrawObserverUSDG`: nothing has to
/// be mutated for the observation to exist, the outer call succeeds, and its storage survives to
/// be asserted. That is what makes it a proof of the effects-before-interactions ORDERING rather
/// than a proof of `nonReentrant`, which is a different guard doing a different job.
///
/// It fires on the FIRST `transfer` only. `X402Stake.executeSlash` makes two, and the first is
/// the earliest moment an outsider can look.
contract StakeObserverUSDG {
    uint8 public constant decimals = 6;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    address public stake;
    address public watched;
    bool private armed;

    uint128 public seenTotalStaked;
    uint128 public seenTotalWithdrawn;
    uint128 public seenTotalSlashed;
    uint64 public seenWithdrawable;
    uint64 public seenBonded;
    bool public observed;

    function arm(address stake_, address watched_) external {
        stake = stake_;
        watched = watched_;
        armed = true;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        if (armed) {
            armed = false;
            observed = true;
            seenTotalStaked = IStakeObserved(stake).totalStaked();
            seenTotalWithdrawn = IStakeObserved(stake).totalWithdrawn();
            seenTotalSlashed = IStakeObserved(stake).totalSlashed();
            seenWithdrawable = IStakeObserved(stake).withdrawableOf(watched);
            seenBonded = IStakeObserved(stake).bondedOf(watched);
        }
        return true;
    }
}

/// The adversary for `nonReentrant` on `X402Stake`'s two token-moving doors: an asset that calls
/// back into the contract from inside `transferFrom` (the money-IN hook) or from inside
/// `transfer` (the money-OUT hook), carrying raw calldata the test chooses.
///
/// **It funds its own re-entry**, for `ReentrantUSDG`'s reason: without that, a nested pull
/// underflows an allowance and the mutation is killed by this mock's own arithmetic rather than
/// by anything the contract under test does — a proof that would be measuring the double.
contract ReentrantStakeUSDG {
    uint8 public constant decimals = 6;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    address public target;
    bytes public reentryCalldata;
    uint256 public fundSelf;
    bool public onPull;
    bool public onPayout;
    bool private fired;
    bool public didReenter;

    function arm(address target_, bytes calldata data, uint256 fundSelf_, bool pull, bool payout)
        external
    {
        target = target_;
        reentryCalldata = data;
        fundSelf = fundSelf_;
        onPull = pull;
        onPayout = payout;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        if (onPull) _fire();
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        if (onPayout) _fire();
        return true;
    }

    /// Once, or the recursion has no floor. The inner revert is bubbled verbatim, and
    /// `SafeERC20._callOptionalReturn` bubbles it again, so the test sees the real error.
    function _fire() internal {
        if (fired || target == address(0)) return;
        fired = true;
        didReenter = true;
        balanceOf[address(this)] += fundSelf;
        allowance[address(this)][target] = type(uint256).max;
        (bool ok, bytes memory ret) = target.call(reentryCalldata);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }
}
