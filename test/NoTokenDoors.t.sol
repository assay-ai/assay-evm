// SPDX-License-Identifier: PolyForm-Strict-1.0.0
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

/// **No role has a door that transfers a token to itself (D-17).** The only ways a token leaves
/// `X402Escrow` or `X402Stake` are a signed voucher's held payment (collected to its provider and
/// the treasury), the buyer's `withdraw()`, the provider's
/// `withdrawStake`, and the two-phase slash; there is no sweep, no rescue, no "excess" transfer,
/// for any role and any token. The owner's power over that money is the upgrade.
///
/// **That is not "no role can redirect money".** The ADMIN, without the owner, holds bounded
/// indirect powers through parameters (risk register §4a): it can register a verifier and raise
/// the slash parameters, which allows a slash of up to 50% of a provider's at-risk stake to a
/// beneficiary it picks after the 72 h delay (the owner stops it inside the delay with
/// `setAdmin`, then the fresh admin's `revokeVerifier`); and it can repoint the treasury and raise
/// the take rate to 30%, which takes effect with no delay. This file pins the token-moving LINES;
/// it cannot see where a parameter sends the money.
///
/// This file is the tripwire for a future change that adds one. It pins, as SOURCE TEXT, every
/// line in `src/` that can move a token, together with the function it sits in. A new
/// `safeTransfer`, `transfer`, `transferFrom`, `approve`, low-level `call`, `delegatecall` or
/// `selfdestruct` anywhere in the three contracts — or an existing one moved into another
/// function — is a red test that names the line. The ABI surface pins
/// (`test_theExitPaysMsgSenderAndTheAbiHasNoOtherWithdrawDoor`, `Upgrade.t.sol`'s three
/// `…SurfaceIsPinnedByName`) are the second, independent half: a new external function of any
/// name fails them.
///
/// It also pins that the owner is consulted in exactly one place in each money contract — the
/// upgrade door — so an `onlyOwner`-style gate on some new function cannot appear quietly.
contract NoTokenDoorsTest is Test {
    /// A token-moving line, the function it must sit in, and the file.
    struct Site {
        string file;
        string fn;
        string line;
    }

    string[7] internal NEEDLES = [
        "safeTransfer",
        ".transfer(",
        "transferFrom(",
        "approve(",
        ".call",
        "delegatecall",
        "selfdestruct"
    ];

    function _sites() internal pure returns (Site[8] memory s) {
        // buyer money: the measured-delta pull, the buyer's own exit, a held voucher's two payouts
        // (redeem into hold: `_redeem` itself moves no token)
        s[0] =
            Site("X402Escrow", "_pullExact", "ASSET.safeTransferFrom(from, address(this), amount);");
        s[1] = Site("X402Escrow", "withdraw", "ASSET.safeTransfer(msg.sender, amount);");
        s[2] = Site(
            "X402Escrow",
            "_collectHeld",
            "if (providerAmount > 0) ASSET.safeTransfer(provider, providerAmount);"
        );
        s[3] =
            Site("X402Escrow", "_collectHeld", "if (fee > 0) ASSET.safeTransfer(p.treasury, fee);");
        // provider collateral: deposit, the provider's own exit, the executed slash's two payouts
        s[4] = Site(
            "X402Stake",
            "depositStakeFor",
            "ASSET.safeTransferFrom(msg.sender, address(this), amount);"
        );
        s[5] = Site("X402Stake", "withdrawStake", "ASSET.safeTransfer(msg.sender, amount);");
        s[6] = Site(
            "X402Stake",
            "executeSlash",
            "if (agentAmount > 0) ASSET.safeTransfer(rec.beneficiary, agentAmount);"
        );
        s[7] = Site(
            "X402Stake",
            "executeSlash",
            "if (platformAmount > 0) ASSET.safeTransfer(p.treasury, platformAmount);"
        );
    }

    function test_theOnlyTokenMovingLinesAreThePinnedUserAuthorisedOnes() public view {
        string[3] memory files = ["X402Escrow", "X402Stake", "X402Config"];
        Site[8] memory pinned = _sites();
        uint256 matched;

        for (uint256 f = 0; f < files.length; f++) {
            bytes memory src =
                bytes(vm.readFile(string.concat(vm.projectRoot(), "/src/", files[f], ".sol")));
            string memory currentFn = "";
            uint256 lineStart;
            for (uint256 i = 0; i <= src.length; i++) {
                if (i != src.length && src[i] != "\n") continue;
                (bool code, string memory line) = _codeLine(src, lineStart, i);
                lineStart = i + 1;
                if (!code) continue;

                string memory fn = _functionName(line);
                if (bytes(fn).length != 0) currentFn = fn;

                if (!_containsAny(line)) continue;
                bool ok;
                for (uint256 k = 0; k < pinned.length; k++) {
                    if (
                        _eq(pinned[k].file, files[f]) && _eq(pinned[k].fn, currentFn)
                            && _eq(pinned[k].line, line)
                    ) ok = true;
                }
                assertTrue(
                    ok,
                    string.concat(
                        "an unpinned token-moving line in ", files[f], ".", currentFn, ": ", line
                    )
                );
                matched++;
            }
        }
        assertEq(matched, pinned.length, "a pinned token-moving line disappeared or moved");
    }

    /// The owner is read in the upgrade door of each money contract and nowhere else, and
    /// `X402Config` gates exactly two doors on it: its own upgrade and `setAdmin`. Ownership
    /// transfer itself is OpenZeppelin's `Ownable2Step`, which holds no token handle.
    function test_theOwnerGatesOnlyTheUpgradeAndTheAdminAppointment() public view {
        string memory escrow = vm.readFile(string.concat(vm.projectRoot(), "/src/X402Escrow.sol"));
        string memory stake = vm.readFile(string.concat(vm.projectRoot(), "/src/X402Stake.sol"));
        string memory config = vm.readFile(string.concat(vm.projectRoot(), "/src/X402Config.sol"));

        string memory door = "        if (msg.sender != CONFIG.owner()) revert NotOwner();\n";
        assertEq(_codeCount(escrow, "owner()"), 1, "the escrow reads the owner outside its upgrade");
        assertEq(_count(escrow, door), 1, "the escrow's upgrade door is not the pinned one");
        assertEq(_codeCount(stake, "owner()"), 1, "the stake reads the owner outside its upgrade");
        assertEq(_count(stake, door), 1, "the stake's upgrade door is not the pinned one");

        assertEq(_count(config, " onlyOwner"), 2, "Config gates a third door on the owner");
        assertEq(
            _count(config, "function _authorizeUpgrade(address) internal override onlyOwner {}"),
            1,
            "Config's upgrade door is not owner-gated"
        );
        assertEq(
            _count(config, "function setAdmin(address newAdmin) external onlyOwner {"),
            1,
            "setAdmin is not owner-gated"
        );
        // Config never names a token at all.
        assertEq(_count(config, "IERC20"), 0, "Config imports a token interface");
        assertEq(_count(config, "SafeERC20"), 0, "Config imports SafeERC20");
    }

    // --- helpers -------------------------------------------------------------------------

    /// The trimmed line between `start` and `end`, and whether it is code (not blank, not a
    /// `//`, `///`, `/*` or `*` comment line).
    function _codeLine(bytes memory src, uint256 start, uint256 end)
        internal
        pure
        returns (bool, string memory)
    {
        uint256 s = start;
        while (s < end && (src[s] == " " || src[s] == "\t")) s++;
        uint256 e = end;
        while (e > s && (src[e - 1] == " " || src[e - 1] == "\t" || src[e - 1] == "\r")) e--;
        if (s >= e) return (false, "");
        if (src[s] == "*") return (false, "");
        if (s + 1 < e && src[s] == "/" && (src[s + 1] == "/" || src[s + 1] == "*")) {
            return (false, "");
        }
        bytes memory out = new bytes(e - s);
        for (uint256 i = 0; i < out.length; i++) {
            out[i] = src[s + i];
        }
        return (true, string(out));
    }

    /// `name` for a line that starts `function name(`, else "".
    function _functionName(string memory line) internal pure returns (string memory) {
        bytes memory l = bytes(line);
        bytes memory kw = bytes("function ");
        if (l.length <= kw.length) return "";
        for (uint256 i = 0; i < kw.length; i++) {
            if (l[i] != kw[i]) return "";
        }
        uint256 j = kw.length;
        while (j < l.length && l[j] != "(") j++;
        bytes memory out = new bytes(j - kw.length);
        for (uint256 i = 0; i < out.length; i++) {
            out[i] = l[kw.length + i];
        }
        return string(out);
    }

    function _containsAny(string memory line) internal view returns (bool) {
        for (uint256 k = 0; k < NEEDLES.length; k++) {
            if (_count(line, NEEDLES[k]) != 0) return true;
        }
        return false;
    }

    /// Occurrences of `needle` on code lines only (comments may name the owner freely).
    function _codeCount(string memory source, string memory needle)
        internal
        pure
        returns (uint256 n)
    {
        bytes memory src = bytes(source);
        uint256 lineStart;
        for (uint256 i = 0; i <= src.length; i++) {
            if (i != src.length && src[i] != "\n") continue;
            (bool code, string memory line) = _codeLine(src, lineStart, i);
            lineStart = i + 1;
            if (code) n += _count(line, needle);
        }
    }

    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    function _count(string memory haystack, string memory needle)
        internal
        pure
        returns (uint256 n)
    {
        bytes memory h = bytes(haystack);
        bytes memory x = bytes(needle);
        if (x.length == 0 || x.length > h.length) return 0;
        for (uint256 i = 0; i + x.length <= h.length; i++) {
            uint256 j = 0;
            while (j < x.length && h[i + j] == x[j]) j++;
            if (j == x.length) n++;
        }
    }
}
