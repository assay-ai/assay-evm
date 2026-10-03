// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.24;

/// A six-decimal ERC-20 that reverts a transfer touching ONE named address, and behaves
/// identically to a plain token otherwise.
///
/// # Why this is not `MockUSDG.setBlocked`
///
/// `MockUSDG` is an adversary in three dimensions at once — a blocklist, a fee-on-transfer
/// switch and a mint anyone may call. A fixture that is wrong in two ways passes a test for the
/// wrong reason and would still pass after the guard under test was deleted. This contract is
/// wrong in exactly one: `BLOCKED` is set at construction, cannot change, and nothing else here
/// deviates from a plain ERC-20.
///
/// # What it does and does not model
///
/// It models the MECHANISM a Paxos blocklist produces — `transfer`/`transferFrom` reverting for
/// one party — and nothing about Paxos. The token deployed at 46630 has no blocklist at all
/// (`docs/chain-facts.md` §1a, measured), so the real interaction is unprovable until the
/// mainnet USDG address exists (risk register §10). Do not let a green run here be read as
/// "the blocklist case is covered".
contract BlockingUSDG {
    string public constant name = "Blocking USDG";
    string public constant symbol = "USDG";
    uint8 public constant decimals = 6;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    address public immutable BLOCKED;

    error TransferBlocked(address who);

    constructor(address blocked_) {
        BLOCKED = blocked_;
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
        if (from == BLOCKED) revert TransferBlocked(from);
        if (to == BLOCKED) revert TransferBlocked(to);
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}
