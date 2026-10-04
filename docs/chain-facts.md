# Chain facts — Robinhood Chain

Everything on this page was **measured**, read-only, from the public RPC. Nothing here
was copied from a doc, an explorer or a plan. Every row names the command that
produced it, so any of it can be re-run and disagreed with.

- **Measured:** 2026-09-07 (UTC), between 16:39 and 16:42.
- **Tool:** `forge` / `cast` **1.2.1-nightly**, commit
  `7e68208eaae86342998f4a713d27a538ce5a3fbb`, built 2025-05-30. That version and commit are
  the pin; they identify the build anywhere, which the install path does not. This is the
  pinned Foundry build for this repository and is **not** to be upgraded — including to
  re-measure. If a re-measurement happens on a different build, record that build here
  rather than silently replacing these numbers.
- **Read-only.** No transaction was sent, no key was touched, nothing was broadcast.
  `cast chain-id`, `cast code`, `cast call` and `cast storage` are all `eth_call`-class
  JSON-RPC reads.

| network | RPC | chain id |
|---|---|---|
| mainnet | `https://rpc.mainnet.chain.robinhood.com` | **4663** |
| testnet | `https://rpc.testnet.chain.robinhood.com` | **46630** |

```
$ cast chain-id --rpc-url https://rpc.mainnet.chain.robinhood.com
4663
$ cast chain-id --rpc-url https://rpc.testnet.chain.robinhood.com
46630
```

Both chains answer and are advancing, so an empty result below is a statement about the
address, not about reachability:

```
$ cast block-number --rpc-url https://rpc.mainnet.chain.robinhood.com
56983850
$ cast block-number --rpc-url https://rpc.testnet.chain.robinhood.com
114978870
```

---

## 1. USDG on mainnet — **UNRESOLVED. This blocks the mainnet deploy only.**

The hypothesis was that mainnet USDG sits at the same address as testnet USDG,
`0x915Ef7c9F9f80a69e3BE47A38EE0Bb47607103ec`. **It does not.** There is no code at
that address on 4663:

```
$ cast code 0x915Ef7c9F9f80a69e3BE47A38EE0Bb47607103ec \
    --rpc-url https://rpc.mainnet.chain.robinhood.com
0x
```

`0x` is 2 characters — the empty-code answer. The same command against testnet returns
11,306 characters of bytecode, which is the control that proves the probe itself works:

```
$ cast code 0x915Ef7c9F9f80a69e3BE47A38EE0Bb47607103ec \
    --rpc-url https://rpc.testnet.chain.robinhood.com | tr -d '\n' | wc -c
11306
```

So the four interface probes could not be run on mainnet. `cast` refuses before it
reaches the network, and this is the *whole* mainnet result — not a reverted call, not a
wrong answer, an absent contract:

```
$ cast call 0x915Ef7c9F9f80a69e3BE47A38EE0Bb47607103ec "decimals()(uint8)" \
    --rpc-url https://rpc.mainnet.chain.robinhood.com
Error: contract 0x915ef7c9f9f80a69e3be47a38ee0bb47607103ec does not have any code
```

…identically for `DOMAIN_SEPARATOR()(bytes32)`, `nonces(address)(uint256)` and
`authorizationState(address,bytes32)(bool)`.

**What this means.** The mainnet USDG address must come from Robinhood Chain's
documentation or from the operator. It is deliberately **not guessed here**, and no value is
written into this table that a later reader could mistake for a measurement. The mainnet
deployment record must refuse to proceed until this row is filled in *and* the four
probes below have been re-run against the real address.

**Nothing else is blocked by this.** Building, testing and the testnet deployment do not need
the mainnet token address.

### One candidate was probed and came back empty

Recorded so the next person does not spend the same minute on it. This is a probe
result, **not** an adopted address:

```
# Global Dollar (USDG) as deployed on Ethereum L1
$ cast code 0xe343167631d89B6Ffc58B88d6b7fB0228795491D \
    --rpc-url https://rpc.mainnet.chain.robinhood.com
0x
```

### §1a. What the TESTNET token actually is — and it is not a proxy

Measured fresh here rather than carried over, so this page stands on its own:

| probe (testnet USDG `0x915Ef7…03ec`) | result | reading |
|---|---|---|
| `symbol()(string)` | `"USDG"` | it is the token |
| `name()(string)` | `"USDG"` | |
| `decimals()(uint8)` | **`6`** | 1:1 USD peg mapping and the `uint64` amount width both rest on this |
| `DOMAIN_SEPARATOR()(bytes32)` | `execution reverted, data: "0x"` | **no EIP-2612** |
| `nonces(address)(uint256)` | `execution reverted, data: "0x"` | **no EIP-2612** |
| `authorizationState(address,bytes32)(bool)` | `execution reverted, data: "0x"` | **no EIP-3009** |
| runtime size | **5,652 bytes**, 19 PUSH4 selectors | a plain contract, not a proxy front end |
| EIP-1967 implementation slot | `0x00…00` | **not upgradeable, not proxied** |
| `isBlocked` / `isFrozen` / `blocklist` / `isBlacklisted` / `frozen` | all revert | **THERE IS NO BLOCKLIST ON 46630** |
| `claim()`, `getClaimCooldown`, `COOLDOWN_PERIOD`, `dailyClaimAmount`, `lastClaimTime`, `founderMint`, `setDailyClaimAmount` | present | it is a **faucet** |
| `owner()` | `0x99F7F9d6246155c0EB4E58d24ac56a8739b77a9F` | Ownable, one key |
| `keccak256(runtime code)` | `0xf37549bb5a61edd116fc93067c60c1c091577250252e36e4eb08188f3525f1b1` | pinned by `test/fork/ForkFacts.t.sol` |

```
$ cast call 0x915Ef7c9F9f80a69e3BE47A38EE0Bb47607103ec "decimals()(uint8)" \
    --rpc-url https://rpc.testnet.chain.robinhood.com
6
$ cast call 0x915Ef7c9F9f80a69e3BE47A38EE0Bb47607103ec "DOMAIN_SEPARATOR()(bytes32)" \
    --rpc-url https://rpc.testnet.chain.robinhood.com
Error: server returned an error response: error code 3: execution reverted, data: "0x"
$ cast call 0x915Ef7c9F9f80a69e3BE47A38EE0Bb47607103ec "nonces(address)(uint256)" \
    0x0000000000000000000000000000000000000001 \
    --rpc-url https://rpc.testnet.chain.robinhood.com
Error: server returned an error response: error code 3: execution reverted, data: "0x"
$ cast call 0x915Ef7c9F9f80a69e3BE47A38EE0Bb47607103ec \
    "authorizationState(address,bytes32)(bool)" \
    0x0000000000000000000000000000000000000001 \
    0x0000000000000000000000000000000000000000000000000000000000000000 \
    --rpc-url https://rpc.testnet.chain.robinhood.com
Error: server returned an error response: error code 3: execution reverted, data: "0x"
```

Testnet USDG is **not** behind an EIP-1967 proxy — the implementation slot is zero, so
the bytecode above is the token itself and cannot be swapped under us:

```
$ cast storage 0x915Ef7c9F9f80a69e3BE47A38EE0Bb47607103ec \
    0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc \
    --rpc-url https://rpc.testnet.chain.robinhood.com
0x0000000000000000000000000000000000000000000000000000000000000000
```

The whole exported surface, enumerated from the bytecode rather than guessed — every PUSH4
constant in the 5,652 runtime bytes, measured 2026-09-10:

```
['06fdde03','095ea7b3','18160ddd','23b872dd','313ce567','4e71d92d','5307a574','6e99d52f',
 '70a08231','715018a6','7f301731','8da5cb5b','95d89b41','a9059cbb','b77cf9c6','cd26dcd2',
 'd7e5321b','dd62ed3e','f2fde38b']
4e71d92d claim()                5307a574 getClaimCooldown(address)
6e99d52f COOLDOWN_PERIOD()      7f301731 dailyClaimAmount()
b77cf9c6 lastClaimTime(address) cd26dcd2 founderMint(address,uint256)
d7e5321b setDailyClaimAmount(uint256)
```

Twelve of the nineteen are ERC-20 + Ownable; the seven named above are a **faucet**. There is no
blocklist selector, no pause, no supply controller, no EIP-2612 and no EIP-3009.

**What this costs, and it is the honest half of the finding.** The blocklist behaviour mainnet
USDG is presumed to have cannot be exercised against 46630, because the token deployed there does not have it.
`MockUSDG.setBlocked` remains the only way to reach it, and a mock is not evidence about a token.
**The real-blocklist proof is therefore OWED against mainnet USDG, and it cannot start until §1's
address exists.** `test/fork/Blocklist.fork.t.sol` proves the escrow's *accounting* under a
reverting transfer, which is the mechanism a blocklist produces and is the half that is provable
today; it does not prove anything about the issuer's token.

**What it buys.** Every gas figure and every token interaction in this repo can now be re-run
against a real deployed ERC-20 rather than the cheapest possible one — and the direction of the
difference is the opposite of what was assumed. Measured: `MockUSDG.transfer` **30,506** gas, real
46630 USDG `transfer` **26,253** (on a fork of a recent block). The mock is the more
expensive token. Every margin computed from it is conservative, not optimistic.

### §1b. The token carries ONE post-Shanghai opcode, and this repo is pinned to Shanghai

A finding of the fork run, not of a document. `foundry.toml` pins `evm_version = "shanghai"`, so
the fork VM executes the real token's real bytecode under Shanghai rules. Under those rules
`symbol()` and `name()` **revert**:

```
[FAIL: EvmError: Revert] test_theTokenIsUsdgWithSixDecimals()
  ├─ [3243] 0x915Ef7…03ec::symbol() [staticcall]
  │   └─ ← [NotActivated] EvmError: NotActivated
```

Scanning the runtime code for post-Shanghai opcodes finds exactly one: **`MCOPY` (0x5E, EIP-5656,
Cancun) at pc 4325**, on the shared string-return helper `name()` and `symbol()` both tail into.
144 `PUSH0`s and nothing else post-Shanghai. Re-running the same test with `--evm-version cancun`
(a one-off CLI run; the config was not changed) passes.

**On chain both getters work** — `cast call … "symbol()(string)"` returns `"USDG"`, and both chains
report `ArbSys.arbOSVersion() == 116`. The gap is between this repo's compile target and the
chain's, not in the token.

**The pin stays, and this is the ruling.** Shanghai is a subset of Cancun, so a Shanghai-compiled
contract runs correctly on a Cancun chain; raising `evm_version` would change the runtime bytecode
of all three production contracts, move gate 4's sizes, gate 6's hashes and gate 8's snapshot, and
is a decision no test may make on its own. The cost is that two **view** functions of the
settlement token cannot be read on a fork. `X402Escrow` and `X402Stake` touch only `decimals`,
`balanceOf`, `approve`, `transfer` and `transferFrom` — none of which reach the MCOPY — so **no
money path is affected**, which is what the fork suite exists to exercise.
`test/fork/ForkFacts.t.sol::test_theTokensStringGettersAreUnreachableUnderTheShanghaiPin` asserts
the unreachability, so this page goes red the day the pin moves.

**Open risk.** Because mainnet USDG could not be probed, we do not know that it is the
same implementation as testnet's. If the mainnet token *does* answer `DOMAIN_SEPARATOR()`
or `nonces()`, the Permit2 decision (D-11) still stands — Permit2 ships either way — but
the risk register gains a row: the two networks run different token code, and anything
inferred from testnet about the token must be re-checked.

---

## 2. Permit2 — present on both networks, byte-identical size

The canonical Uniswap Permit2 singleton, `0x000000000022D473030F116dDEE9F6B43aC78BA3`:

```
$ cast code 0x000000000022D473030F116dDEE9F6B43aC78BA3 \
    --rpc-url https://rpc.mainnet.chain.robinhood.com | tr -d '\n' | wc -c
18306
$ cast code 0x000000000022D473030F116dDEE9F6B43aC78BA3 \
    --rpc-url https://rpc.testnet.chain.robinhood.com | tr -d '\n' | wc -c
18306
```

18,306 characters = `0x` + 18,304 hex digits = **9,152 bytes**, the expected figure and the
same on both chains. (Counted with the trailing newline stripped; a bare `| wc -c` reports
18307 because `cast` prints one.)

This is the measurement D-11 rests on: the token offers neither EIP-2612 nor EIP-3009, and
Permit2 is deployed, so Permit2 is the pull-payment path.

---

## 3. Safe{Wallet} on 4663 — **deployed.** Information only; gates nothing.

All four canonical deterministic addresses carry code on mainnet, and the same code sizes
on testnet:

| address | mainnet chars | testnet chars | what |
|---|---|---|---|
| `0x29fcB43b46531BcA003ddC8FCB67FFE91900C762` | 48844 | 48844 | v1.4.1 SafeL2 singleton |
| `0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67` | 6110 | 6110 | v1.4.1 SafeProxyFactory |
| `0x3E5c63644E683549055b9Be8653de26E0B4CD36E` | 47602 | 47602 | v1.3.0 SafeL2 singleton |
| `0xa6B71E26C5e0845f74c812102Ca7114b6a896AB2` | 7550 | 7550 | v1.3.0 SafeProxyFactory |

A singleton **and** its factory both present means a Safe is deployable here, for both the
1.3.0 and 1.4.1 lines.

**Read this next to the custody decision, because it changes its character.** The design
decision settles the 4663 treasury as a **single-signer Ledger EOA, no Safe**, and
accepts that as a downgrade from Solana's Squads multisig. This measurement says that downgrade is a
*choice*, not a constraint — the multisig machinery is on chain today. Whoever revisits
custody starts from these four addresses and needs no new deployment.

This line does **not** gate the runbook. The deploy tooling refuses a mainnet deploy over
the missing USDG address above; it does not refuse one over this.

### Context, same measurement run

```
$ cast code 0x4e59b44847b379578588920cA78FbF26c0B4956C \
    --rpc-url https://rpc.mainnet.chain.robinhood.com | wc -c   # 141 → present
$ cast code 0xcA11bde05977b3631167028862bE2a173976CA11 \
    --rpc-url https://rpc.mainnet.chain.robinhood.com | wc -c   # 7619 → present
```

The deterministic CREATE2 deployer (`0x4e59b448…`) and Multicall3 are both live on 4663.

---

## What must happen before the mainnet deploy

1. Obtain the mainnet USDG address from Robinhood Chain's documentation or the operator.
2. Re-run the four probes from §1 against it and paste the outputs into this file.
3. Confirm `decimals()` is **6**. If it is anything else, **stop** — the 1:1 USD peg
   mapping and the `uint64` amount width both rest on that number, and the correct
   response is to re-open the design, not to widen a type.

---

## 5. The gas ceiling `MAX_REDEEM_BATCH = 64` is measured against — **RESOLVED**

This page previously recorded **no** gas limit for either chain, so `MAX_REDEEM_BATCH = 64` was a
number chosen and written down rather than derived. It is now derived. Two read-only `cast` calls,
run against both chains on 2026-09-09:

```sh
$ cast block latest --rpc-url https://rpc.testnet.chain.robinhood.com | grep gasLimit
gasLimit             1125899906842624
$ cast block latest --rpc-url https://rpc.mainnet.chain.robinhood.com | grep gasLimit
gasLimit             1125899906842624
```

**`1125899906842624` is 2^50, and it is not a limit.** It is the Arbitrum Orbit placeholder: the
block header carries an effectively unbounded value because Orbit does not meter per block. The
real ceiling is the per-**transaction** one, and it lives in the `ArbGasInfo` precompile at
`0x…006C`:

```sh
$ cast call 0x000000000000000000000000000000000000006C \
    "getGasAccountingParams()(uint256,uint256,uint256)" \
    --rpc-url https://rpc.mainnet.chain.robinhood.com
7000000     # speedLimitPerSecond
32000000    # gasPoolMax
32000000    # maxTxGasLimit          <-- the ceiling a batch must clear
```

Identical on 46630. Both chains report `ArbSys.arbOSVersion() == 116`.

| | |
|---|---|
| `maxTxGasLimit` | **32,000,000** (both chains) |
| worst measured `redeemVoucherBatch(64)`, `MockUSDG` | **5,235,730** (distinct payer, distinct provider) |
| worst measured `redeemVoucherBatch(64)`, **real 46630 USDG** | **5,323,988** — on a fork of a recent block |
| share of the ceiling | **16.6 %** (from the real-token figure; 16.4 % from the mock) |
| headroom | **6.01×**, i.e. ~416,800 gas per voucher, ~208,400 per token transfer |

The batch figures are `test_measure_distinctPayerBatchOfSixtyFour`, re-measured 2026-09-09
(`MockUSDG`) and 2026-09-10 (real token, on a fork) against `src/X402Escrow.sol` at sha256
`e796474e…`. **The two derived rows above come from them and are only true for
that file**: the 2026-09-08 edition read 5,180,000 / 16.2 % / 6.18×
against a version of the escrow three commits older, and stayed on this page after the source moved
because nothing tied the two together. Neither page is gated by a test, so **re-derive it in the same change that re-measures
`docs/gas.md`** — the two pages are one measurement.

**So 64 is validated, with the caveat named.** Every gas figure in `docs/gas.md` was against
`MockUSDG`, roughly the cheapest possible ERC-20; the worst case now also has a real-token figure
beside it (below). Real USDG **on 4663** is presumed to be an upgradeable proxy with a blocklist, with
**two transfers per voucher** — unverified, because the address is unknown. **The 46630 token is
neither** (§1a). The margin above says how much that may cost before the cap
binds: each of the 128 transfers in a worst-case batch may become ~208,400 gas more expensive
before a 64-item batch reaches `maxTxGasLimit`. A proxied transfer with a blocklist read is tens of
thousands of gas, not hundreds — so the cap holds, and it holds with the factor stated rather than
asserted.

`speedLimitPerSecond = 7,000,000` is an economics fact, not a correctness one: sustained throughput
above it raises the base fee. It is not a reason to lower the batch.

**DONE for 46630, 2026-09-10.** `test_measure_distinctPayerBatchOfSixtyFour` re-run through
`test/fork/MoneyPaths.fork.t.sol::ForkEscrowBatchTest`, same tree, same commit, token swapped:
**5,323,988** against the mock's 5,235,730. The margin above is now computed from a real deployed
ERC-20, and the four rows are re-derived from the larger of the two.

**The direction is the opposite of what was predicted.** The expectation, extrapolated from a single
transfer (`MockUSDG` 30,506 vs real 26,253), was roughly **540,000 lower**. It came back **88,258
higher** — +1.69 %. A single-transfer figure does not extrapolate to a batch: the warm/cold slot mix
of 128 transfers differs from an isolated one, and the sign reverses. `docs/gas.md` carries the
table and the reasoning.

**Still owed, and unobtainable:** the same measurement against **4663**. That needs the mainnet USDG
address, which §1 does not have.

**A fork run has no pinned block** (§6), so the 5,323,988 is an observation with a block beside it
and not a pin. It must never enter `.gas-snapshot`; `script/check-fork-isolation.sh` (gate 9)
refuses it if it tries.

---

## 6. How deep the public RPC will serve state — **a fork block cannot be pinned**

Measured 2026-09-10 by binary search: ask for `totalSupply()` at `latest - k` and widen `k` until
the node refuses. Read-only; every call is an `eth_call`.

```sh
$ T=https://rpc.testnet.chain.robinhood.com
$ U=0x915Ef7c9F9f80a69e3BE47A38EE0Bb47607103ec
$ N=$(cast block-number --rpc-url $T)
$ lo=0; hi=100000
$ while [ $((hi-lo)) -gt 2000 ]; do
    mid=$(( (lo+hi)/2 ))
    if cast call $U "totalSupply()(uint256)" --rpc-url $T --block $((N-mid)) >/dev/null 2>&1
    then lo=$mid; else hi=$mid; fi
  done
$ echo "latest=$N  deepest servable ~ N-$lo  first refusal ~ N-$hi"
latest=116449785  deepest servable ~ N-6250  first refusal ~ N-7812
```

The two refusals are **node-side** errors, not chain errors — the block exists, the node no longer
holds its state trie:

```
$ cast call $U "totalSupply()(uint256)" --rpc-url $T --block $((N-7812))
Error: server returned an error response: error code -32000: metadata is not found, 116441975
$ cast call $U "totalSupply()(uint256)" --rpc-url $T --block $((N-50000))
Error: server returned an error response: error code -32000: missing trie node
  bf1c84ef1fab7d008b3cd6719477989c2bb31a6bc31f82e8d6342df6383eb0ed (path ) state
  0xbf1c84ef… is not available, not found
```

Block time, over the same 10,000 blocks:

```
$ cast block $N --rpc-url $T --field timestamp            # 1788986951
$ cast block $((N-10000)) --rpc-url $T --field timestamp  # 1788985503
# 1448 s per 10,000 blocks = 0.1448 s per block
```

**So the public RPC serves roughly FIFTEEN MINUTES of state** — 6,250 blocks × 0.1448 s ≈ 905 s.

**And the window itself is not a constant.** The same search on 2026-09-09 returned
`deepest servable ~ N-4687, first refusal ~ N-6250` — about eleven minutes. The depth moves with
the node's own pruning, so it may not be relied on either.

> **A fork block cannot be pinned.** `--fork-block-number` names a block the node will have pruned
> before the next CI run. Every fork test therefore runs against `latest`, which makes a fork run
> **non-deterministic by construction**: block number, base fee and the token's `totalSupply` all
> move between runs.
>
> Two things follow, and `script/check-fork-isolation.sh` (gate 9) enforces both. The fork suite
> **must never join gate 7's determinism contract or gate 8's snapshot**, and a fork test **must
> assert behaviour, never gas equality** — a fork-measured gas figure is a recorded observation
> with a block number beside it, not a pin.
