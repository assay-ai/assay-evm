# Mutation log

Every guard in `src/` is proved by breaking it, running the *named* test, and confirming the
test fails **for the stated reason and not another one** — then restoring and re-running green. A
guard whose mutation nobody has run is a guard nobody has tested; a test that stays green under
its own mutation is recorded here as such rather than quietly dropped.

An **equivalent mutant** — a mutation that changes the source text but provably cannot change the
result on any input — is recorded with the argument for why, not padded out with a test that
pretends to catch it. Writing a test that "fails" on an equivalent mutant means asserting on
something other than behaviour.

Columns: the guard, the exact mutation applied, the test named as its prover, and the observed
result verbatim.

**Procedure.** For each row the mutation is applied to the source file, the named test (or the
whole suite, where the row says so) is run, the verbatim result is recorded, and the file is
restored from a byte-exact copy whose SHA-256 is checked before the next row. Sections follow the
order in which each contract surface was implemented; a "round" names that surface (the Window
round, the redeem round, and so on), and a "follow-up round" is a later pass over the same surface
after code review. Row ids (W1a, S8, C35, T13, ...) are stable and are cited from code comments.
Decision ids D-1 ... D-15 are defined in `docs/design-decisions.md`.

Throughout the log, probe and fixture files (for example `test/_C22Probe.t.sol`,
`X402EscrowT10ReentrancyProbe.t.sol`, `*.T12GOOD.sol`) and the `mutate.py` helper were temporary
working files used while mutating. They are not committed to this repository.

---

## Predictions that measurement disproved

Two predictions written down before the code existed turned out to be wrong when measured. They are
named here rather than only inside a table row, because a log that repeats a claim it has measured
to be false is worse than no log. Both were reproduced a second time in review.

| Source | What it predicted | What is actually true |
|---|---|---|
| test plan | `>=` → `>` on the window-edge branch will be caught by `test_aFullWindowDrainsToZeroAndStaysThere`, via `decay(type(uint64).max, 0, type(uint64).max)`, which "overflows `elapsed` handling" | That input has `elapsed = type(uint64).max`, which is `>` as well as `>=` — the **same branch under both spellings**, so the test passes. Nor does anything overflow: `nowTs - startedAt` is exact in `uint64` there. The mutation is an equivalent mutant (row W2a) and no test can catch it; coverage of that branch comes from deleting it (row W2b). |
| test plan | replacing the subtraction with an independent division fails `test_theFeeSplitNeverLosesOrInventsABaseUnit` at row `(7, 3_000)` | It fails at row `(1, 1_000)`. `assertEq` halts at the **first** failing row, and both rows lose a unit — the named row is simply not the one reached (row F1). |

---

## `src/libraries/Window.sol`

| # | Guard | Mutation | Named test | Observed |
|---|---|---|---|---|
| W1a | `if (nowTs <= startedAt) return counter;` | `<=` → `<` | `test_aClockThatWentBackwardsReturnsCapacityToNobody`, `test_noTimeElapsedCarriesTheWholeCounter` | **SURVIVED** — `2 passed; 0 failed`. **Equivalent mutant; this row proves nothing and the coverage for this branch is carried by W1b below.** `<` still catches every backwards clock; the only input it newly lets through is `nowTs == startedAt`, where the fall-through computes `elapsed = 0`, `remaining = window`, and `(counter * window + window - 1) / window == counter`. Identical output on every input. The test plan predicted this. |
| W1b | same guard — **this is the row that carries W1's coverage** | **branch deleted entirely** | `test_aClockThatWentBackwardsReturnsCapacityToNobody` | **FAILED**, for the stated reason: `[FAIL: panic: arithmetic underflow or overflow (0x11)]` — `nowTs - startedAt` underflows on `decay(1_000, T, T - 1)`. This is the row that carries the guard. |
| W2a | `if (elapsed >= Constants.SLASH_WINDOW_SECONDS) return 0;` | `>=` → `>` | whole `WindowTest` contract (12 tests) | **SURVIVED** — `12 passed; 0 failed`. **Equivalent mutant; this row proves nothing, the coverage for this branch is carried by W2b below, and the test plan's prediction here is measurably wrong.** The test plan expected `decay(type(uint64).max, 0, type(uint64).max)` in `test_aFullWindowDrainsToZeroAndStaysThere` to catch it; that input has `elapsed = type(uint64).max`, which is `> W` as well as `>= W`, so it takes the same branch. The only input the mutation reaches is `elapsed == W` exactly, where the fall-through gives `remaining = 0` and `carried = (counter * 0 + W - 1) / W == 0` — the same `0` the branch returns. No input distinguishes them. |
| W2b | same guard — **this is the row that carries W2's coverage** | **branch deleted entirely** | `test_aFullWindowDrainsToZeroAndStaysThere` | **FAILED**, for the stated reason: `[FAIL: panic: arithmetic underflow or overflow (0x11)]` — `window - elapsed` underflows on `decay(1_000, T, T + W + 1)`. This is the row that carries the guard. |
| W3 | `+ window - 1` (the `div_ceil` term) | term deleted, leaving a floor | `test_theDrainRoundsUp`, `testFuzz_theDrainNeverReturnsTheLastUnitEarly` | **FAILED**, for the stated reason: `[FAIL: assertion failed: 0 != 1] test_theDrainRoundsUp` — `decay(1, T, T + W - 1)` returns 0 instead of 1. The fuzz property failed with it and shrank to `args=[1, 507357]` → `counter = 1, elapsed = 75362`: `[FAIL: the last unit was returned early: 0 <= 0]`. |

### Fix round 2 — the degenerate implementations

A mutation breaks one guard; a **degenerate** replaces the whole function with something trivially
wrong. They answer a different question — not "is this branch tested?" but "what would this test
still pass against?" — and the review found the test plan's only Window property test passing against
all three.

| # | Degenerate | Named test | Observed |
|---|---|---|---|
| D1 | `decay` returns `0` for every input | `testFuzz_decayIsMonotonicAndBounded` | **FAILED** after fix round 2: `[FAIL: decay disagrees with the closed form: 0 != 5; … args=[14, 7256989019529938566]]`. Before fix round 2 it **PASSED** — `assertLe(a, counter)` and `assertLe(b, a)` are both satisfied by the constant zero. Suite-wide: 3 passed / 9 failed. |
| D2 | `decay` returns `counter` for every input (never drains) | `testFuzz_decayIsMonotonicAndBounded` | **FAILED** after fix round 2: `[FAIL: decay disagrees with the closed form: 14 != 5]`. Before, it **PASSED** — the identity is monotone and bounded by `counter`. Suite-wide: 4 passed / 8 failed. |
| D3 | `decay` ignores `nowTs` entirely (always reports one second elapsed) | `testFuzz_decayIsMonotonicAndBounded` | **FAILED** after fix round 2: `[FAIL: decay disagrees with the closed form: 14 != 5]`. Before, it **PASSED** — a fixed 1s drain is still monotone and still bounded. Suite-wide: 3 passed / 9 failed. |
| W4 | `Window.narrow`'s `if (value > type(uint64).max) revert MathOverflow();` deleted | — | **SURVIVED, necessarily.** `remaining < window` is enforced two lines above, so `carried <= counter <= type(uint64).max` and the branch is unreachable. No test can catch its removal, and none was written to pretend otherwise. It exists for consistency with `Fee.narrow` by a deliberate design choice, not for safety — that reasoning is in its NatSpec. The only observable difference is gas. |

**What each Window test actually proves** — the counterpart of the Fee section below.
 For each test, what it would still pass against:

- `testFuzz_decayIsMonotonicAndBounded` — **was the vacuous one.** It survived D1, D2 and D3, all
  measured. It now pins the value at every sampled instant against a closed form written as
  floor-plus-remainder rather than as the implementation's biased numerator, and its range spans
  `2 * W` so it covers the interior, the edge and the discontinuity. It kills all three.
- `test_aZeroCounterStaysZeroWhateverTheClockSays` — survives D1, D2 **and** D3. Inherent to the
  case: every input it asserts has `counter == 0`, and all three degenerates return 0 there. It
  pins the zero-counter branch and nothing else, and no rewrite would change that.
- `testFuzz_decaySaturatesAtOrPastTheWindowEdge` — survives **D1** (a function that always returns
  0 has certainly saturated). Kills D2 and D3.
- `testFuzz_theDrainNeverReturnsTheLastUnitEarly` — survives **D2 and D3** (both return a non-zero
  value inside the window). Kills D1. It is the mirror image of the one above, which is why both
  are kept.
- `test_noTimeElapsedCarriesTheWholeCounter` — survives **D2 and D3**. One input, `elapsed = 0`,
  where the identity is the right answer.
- `test_aClockThatWentBackwardsReturnsCapacityToNobody` — survives **D2**. The identity is also the
  right answer for a backwards clock. Kills D1 and D3.
- `test_aFullWindowDrainsToZeroAndStaysThere` — survives **D1**. Kills D2 and D3.
- `test_theDrainIsLinearAcrossTheWindow`, `test_theDrainRoundsUp`, `test_boundaryAtExactlyOneWindow`,
  `test_anAnchorOfZeroIsSimplyAVeryOldWindow`, `test_aSaturatedCounterDoesNotOverflowOrTruncate` —
  kill all three. These are the value-pinning tests from the Anchor table.

The suite as a whole killed all three degenerates even before fix round 2; the defect was that the
one test *named* as the general property was the one proving least, and that was not written down.

**The honesty note the test plan asks for.** Two of the three mutations named in the test plan are
survivable, and one of the two is survivable for a *different* reason than the test plan gives (W2a).
Both are equivalent mutants on a pure function: the mutated source computes the identical value on
every input in the domain, so no test can distinguish them and none should be invented to pretend
otherwise. What actually guards each branch is its deletion — W1b and W2b — because the branch is
load-bearing for the *checked arithmetic* below it, not for the value it returns at the boundary.
W3 is the only row where the mutation changes an answer rather than reaching a revert.

---

## `src/libraries/Fee.sol`

| # | Guard | Mutation | Named test | Observed |
|---|---|---|---|---|
| F1 | `providerAmount = amount - fee` (the remainder is a SUBTRACTION, never a second division) | replaced with an independent computation, `uint64((uint256(amount) * (10_000 - takeRateBps)) / 10_000)` | `test_theFeeSplitNeverLosesOrInventsABaseUnit`, `testFuzz_feePlusProviderAlwaysEqualsAmount` | **FAILED**, for the stated reason — a base unit vanishes between the two floors: `[FAIL: provider amount: 0 != 1]` and `[FAIL: assertion failed: 5010 != 5011; … args=[5011, 4883]]`. Note the table test halts at its *first* failing row, `(1, 1_000)`, not at the test plan's `(7, 3_000)`; both rows lose the unit, `assertEq` simply reaches the earlier one. |
| F2 | `uint256(amount) * takeRateBps` in `splitFee` | widening dropped → `amount * takeRateBps` | `test_theFeeSplitNeverLosesOrInventsABaseUnit` | **FAILED**, for the stated reason: `[FAIL: panic: arithmetic underflow or overflow (0x11)]` — the `(type(uint64).max, 3_000)` row overflows `uint64` and checked arithmetic panics. |
| F3 | `uint256(amount) * bps` in `bpsOf` | widening dropped → `amount * bps` | `test_bpsOfAtTheEndsOfItsRange`, `testFuzz_bpsOfIsExactlyTheFloorOfTheShare` | **FAILED**, for the stated reason: `[FAIL: panic: arithmetic underflow or overflow (0x11)]`, the fuzz shrinking to `args=[18446744073709551615, 10]`. `bpsOf` needs its own row: it is a separate multiplication site, and F2 does not execute it. |
| F4 | `bpsOf`'s value itself | `return 0;` unconditionally | `test_bpsOfAtTheEndsOfItsRange`, `testFuzz_bpsOfIsExactlyTheFloorOfTheShare`, `testFuzz_splitFeeTakesExactlyBpsOf` | **FAILED**: `[FAIL: 10k bps is the whole: 0 != 18446744073709551615]`, `[FAIL: bpsOf lost part of the share: 184467440737095516150 >= 10000]`, `[FAIL: the two splits disagree: 18446744073709551 != 0]`. **Run because the test plan's only `bpsOf` test does not catch this**: `testFuzz_bpsOfNeverExceedsTheAmount` asserts `bpsOf(a, b) <= a`, which holds for a function that always returns zero — run alone against F4 it reported `[PASS] … (runs: 514)`. That test names a bound, not the value, so the three tests above were added to pin the value. |

### Fix round 1 — the checked narrowing

| # | Guard | Mutation | Named test | Observed |
|---|---|---|---|---|
| F5 | `if (value > type(uint64).max) revert MathOverflow();` in `Fee.narrow` | guard removed, leaving the bare truncating `uint64(value)` cast the test plan specified | `test_bpsOfRevertsMathOverflowWhenTheNarrowingWouldLoseABit`, `test_splitFeeRevertsMathOverflowWhenTheNarrowingWouldLoseABit` | **FAILED**, both: `[FAIL: next call did not revert as expected]`. The stated reason — with the guard gone the overflowing share is silently wrapped and returned instead of refused. |
| F6 | the **name** the guard reverts with | `revert MathOverflow()` → `revert AmountExceedsUint64()` | same two tests | **FAILED**, both: `[FAIL: Error != expected error: AmountExceedsUint64() != custom error 0x9d565d4e]`. Run because F5 only proves *a* revert happens; this proves the tests assert the *named* error. `0x9d565d4e` is `cast sig "MathOverflow()"`. |

### Fix round 2 — the Fee degenerates the review found surviving

| # | Degenerate | Named test | Observed |
|---|---|---|---|
| E5 | **both** `bpsOf` and `splitFee`'s fee return `0` | `testFuzz_splitFeeTakesExactlyBpsOf` | **FAILED** after fix round 2: `[FAIL: both splits agree on a wrong value: 0 != 8178285812]`. Before, it **PASSED** at `runs: 514` — the test asserted only that the two agree, and two functions degenerate in the same way agree perfectly. An independently computed floor is now asserted alongside the equality. |
| E4 | `splitFee` ignores `takeRateBps` and uses a fixed `1_000` bps | `test_aCallTooSmallToDividePaysTheProviderInFull` | **FAILED** after fix round 2: `[FAIL: floor(1.2) is one base unit: 0 != 1]`. Before, it **PASSED** — all three of its ported cases use `bps = 1_000`, so it could not see a `splitFee` that ignored its rate. A second rate was added; `testFuzz_splitFeeTakesExactlyBpsOf` also fails it now (`[FAIL: the two splits disagree: 1 != 0]`). |

**What each Fee test actually proves**, since two of them are weaker than their names suggest:

- `testFuzz_feePlusProviderAlwaysEqualsAmount` cannot fail while `providerAmount` is defined by
  subtraction — the identity is structural. Its whole value is catching F1, and it does.
- `testFuzz_bpsOfNeverExceedsTheAmount` is a bound, not a value; F4 is the proof that it is not
  load-bearing on its own. It survives `bpsOf ≡ amount` (the identity) as well as `bpsOf ≡ 0`.
- `testFuzz_splitFeeTakesExactlyBpsOf` **was relational only** and survived E5. It now anchors
  one side to an independently computed floor, so agreement between the two entry points is no
  longer sufficient to pass it.
- `test_aCallTooSmallToDividePaysTheProviderInFull` **exercised a single rate** and survived E4.
  It now exercises two, and asserts that the same amount at two rates yields different fees.
- `testFuzz_theSlashSplitNeverLosesOrInventsABaseUnit` ports `execute_slash.rs:170-178` and proves
  the three-way split conserves base units. It **survives F4** (`0 + 0 + applied == applied` still
  conserves), and that is correct: it asserts conservation, not the size of either share.

---

## `src/X402Config.sol`

Prover: `test/X402Config.admin.t.sol` — **17 tests as of the 2026-09-08 fix round**; the counts
quoted inside individual rows are the suite size at the time that row was measured and are left as
measured rather than restated. Every row was applied to `src/X402Config.sol`,
run with `forge test --match-contract X402ConfigAdminTest`, then restored; the file was diffed
against a pristine copy afterwards and the whole suite re-run from a wiped `out/` and `cache/`.

Rows C1–C5 are the five the test plan names. C6 and C7 are two the test plan deferred to the **upgrade round**;
they are recorded here instead, because the project rule is that a guard ships with a test that
fails when it is removed, and both tests were cheap to write now. C8–C16 are guards the test plan's
table does not cover; C11 in particular found a guard whose removal **no test from the original plan
catches**, and a test was added for it.

| # | Guard | Mutation | Named test | Observed |
|---|---|---|---|---|
| C1 | `if (msg.sender != admin) revert NotAdmin();` on `setPaused` | `onlyAdmin` deleted from `setPaused` | `test_wrongSigner_onlyAdminPauses` | **FAILED**, for the stated reason: `[FAIL: next call did not revert as expected]` — a stranger's `setPaused(true)` succeeds. |
| C1b | the **name** that guard reverts with | `revert NotAdmin()` → `revert InvalidAdmin()` | `test_wrongSigner_onlyAdminPauses` | **FAILED**: `[FAIL: Error != expected error: InvalidAdmin() != custom error 0x7bfa4b9f]`. Run because C1 proves only that *a* revert happens; this proves the test asserts the *named* error. `0x7bfa4b9f` is `NotAdmin()`. |
| C2 | `if (initialAdmin == address(0)) revert InvalidAdmin();` | branch deleted | `test_wrongState_theZeroAdminIsRefusedAtConstruction` | **FAILED**, for the stated reason: `[FAIL: next call did not revert as expected]` — a contract nobody can ever administer or upgrade deploys. `test_happyPath_…` still `[PASS]`, correctly: it does not test this. |
| C2b | the **name** that guard reverts with | `revert InvalidAdmin()` → `revert NotAdmin()` | `test_wrongState_theZeroAdminIsRefusedAtConstruction` | **FAILED**: `[FAIL: Error != expected error: NotAdmin() != custom error 0xb5eba9f0]`. `0xb5eba9f0` is `InvalidAdmin()`. |
| C3 | `p.slashAgentBps == 0 \|\|` — `state.rs:180` | first disjunct replaced with `false` | `test_wrongState_everyBoundIsRefusedAtConstruction` (the `slashAgentBps = 0` block) | **FAILED**, for the stated reason: `[FAIL: next call did not revert as expected]` — a penalty split that compensates nobody is admitted. |
| C4 | `p.takeRateBps > Constants.MAX_TAKE_RATE_BPS` | `>` → `>=` | `test_boundary_theBoundsAdmitTheirOwnValue` | **FAILED**, for the stated reason: `[FAIL: InvalidTakeRateBps()]` — the legal ceiling value 3,000 is refused. |
| C5 | `p.unbondingPeriodSeconds < Constants.MIN_UNBONDING_PERIOD_SECONDS` | `<` → `<=` | `test_boundary_theBoundsAdmitTheirOwnValue` | **FAILED**, for the stated reason: `[FAIL: UnbondingPeriodTooShort()]` — exactly 11 days is refused. |
| C6 | `onlyAdmin` on `_authorizeUpgrade` — **the test plan defers this to the upgrade round** | modifier deleted | `test_wrongSigner_onlyTheAdminUpgradesConfig` (written here rather than in the upgrade round) | **FAILED**, for the stated reason: `[FAIL: next call did not revert as expected]` — a stranger replaces the implementation of all three contracts' parameter authority. |
| C7 | `_disableInitializers()` in the constructor — **the test plan defers this to the upgrade round** | statement deleted | `test_wrongState_theImplementationCannotBeInitialised` (written here rather than in the upgrade round) | **FAILED**, for the stated reason: `[FAIL: next call did not revert as expected]` — a stranger initialises the implementation, becomes *its* admin, and can then `upgradeToAndCall` on it directly. |
| C8 | `p.slashCapBps == 0 \|\|` — `state.rs:188` | first disjunct replaced with `false` | `test_wrongState_everyBoundIsRefusedAtConstruction` (the `slashCapBps = 0` block, added to the test plan's list) | **FAILED**, for the stated reason: `[FAIL: next call did not revert as expected]` — a zero cap switches slashing off silently, which is `revoke_verifier`'s job done badly. |
| C9 | `p.slashCapBps > Constants.MAX_SLASH_CAP_BPS` | `>` → `>=` | `test_boundary_theBoundsAdmitTheirOwnValue` | **FAILED**, for the stated reason: `[FAIL: InvalidSlashCapBps()]` — the legal ceiling value 5,000 is refused. |
| C10 | `p.unbondingPeriodSeconds > Constants.MAX_UNBONDING_PERIOD_SECONDS` | `>` → `>=` | `test_boundary_theBoundsAdmitTheirOwnValue` | **FAILED**, for the stated reason: `[FAIL: UnbondingPeriodTooLong()]` — exactly 30 days is refused. |
| C11 | the `uint32(...)` **widening** in the split sum — `state.rs:180` widens both shares to `u32` | widening dropped, leaving `uint16 + uint16` | `test_wrongState_aSplitThatOverflowsUint16IsStillRefusedByName` | **FAILED**: `[FAIL: Error != expected error: panic: arithmetic underflow or overflow (0x11) != InvalidSplitBps()]`. **This row is why the test exists.** Under the mutation `test_wrongState_everyBoundIsRefusedAtConstruction` and `test_validation_judgesTheSplitAsAPairNotFieldByField` both still `[PASS]` — every share they use sums under 65,535 — so the test plan's tests do not cover this guard at all. `60_000 + 10_000` overflows `uint16`, and checked arithmetic panics *before* the comparison: the set is still refused, but with `Panic(0x11)` instead of the name an operator can act on. |
| C12 | `emit PauseToggled(...)` | statement deleted | `test_setPausedEmitsPauseToggled` | **FAILED**, for the stated reason: `[FAIL: log != expected log]`. |
| C13 | `emit ConfigInitialized(...)` | statement deleted | `test_initializeEmitsConfigInitialized` | **FAILED**, for the stated reason: `[FAIL: expected an emit, but no logs were emitted afterwards…]`. |
| C14 | `_params = initialParams;` (the effect) | statement deleted | `test_happyPath_initializeStoresValidatedParams`, `test_theStoredParamsAreThisInstancesOwn` | **FAILED**, both: `[FAIL: treasury: 0x0000…0000 != 0x0000…7EA5]` and `[FAIL: the second proxy stored its own set verbatim: 0x00…00 != 0x…f00d…]`. |
| C15 | `admin = initialAdmin;` | → `admin = msg.sender;` (the plausible wrong port — Solana's admin *is* the signer) | `test_happyPath_initializeStoresValidatedParams`, `test_theStoredParamsAreThisInstancesOwn` | **FAILED**, both: `[FAIL: admin: 0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496 != 0x…adAA]` — through a proxy `msg.sender` is the deployer of the proxy, not the intended admin. `test_wrongState_theZeroAdminIsRefusedAtConstruction` still `[PASS]`, correctly. |
| C16 | the `_validate(initialParams)` **call** | statement deleted | `test_wrongState_everyBoundIsRefusedAtConstruction` | **FAILED**, for the stated reason: `[FAIL: next call did not revert as expected]` — the first refused set (`treasury == address(0)`) is admitted. |

### The degenerate implementations

Not "is this branch tested?" but "what would this test still pass against?". Three degenerates
were constructed and run against the whole suite.

| # | Degenerate | Named test | Observed |
|---|---|---|---|
| DC1 | **the field-at-a-time validator** — the pair check `agent + platform <= 10_000` replaced by two independent per-field ceilings (`agent <= 9_000`, `platform <= 4_000`), chosen so every *other* test's inputs stay legal | `test_validation_judgesTheSplitAsAPairNotFieldByField` | **FAILED**, and **it is the only test that fails**: `[FAIL: InvalidSplitBps()]`, suite `13 passed; 1 failed`. The kill is the third leg — `agent = 9_001` against `platform = 999`, legal as a pair and refused by any per-field ceiling. This is the pair-validation requirement, measured: a field-at-a-time check refuses legal moves, and exactly one test in this file notices. (A first attempt with ceilings of 5,000/5,000 also died, but in `setUp()`, which proves nothing about which test carries the property — recorded because the weaker degenerate is the honest one.) |
| DC2 | `params()` returns a **literal** equal to `_valid()` instead of `_params` | `test_theStoredParamsAreThisInstancesOwn` | **FAILED**: `[FAIL: the second proxy stored its own set verbatim: 0x…7ea5… != 0x…f00d…]`, plus three more. Suite `10 passed; 4 failed`. **`test_happyPath_initializeStoresValidatedParams` PASSES against it** — reading ten fields back is still reading a constant, which is exactly why the second-instance test exists. |
| DC3 | `setPaused` ignores its argument: `paused = value` → `paused = true` | `test_wrongSigner_onlyAdminPauses` | **FAILED**: `[FAIL: and it is reversible]`, suite `13 passed; 1 failed`. The test plan's version of this test stopped after `assertTrue(config.paused())` and would have **passed**; the reversibility leg was added for this. **DC3 was not enough** — see C23 below, where a *toggle* survives the very walk this row added. |

### What each Config test would still pass against

**Read C11 first — it is the sixth gate in this project that passed while answering a different
question than the one asked.** `state.rs:180` widens both `u16` split shares to `u32` before
summing. Remove that widening and **both** originally planned tests that touch the split still
PASSED: `test_wrongState_everyBoundIsRefusedAtConstruction` and
`test_validation_judgesTheSplitAsAPairNotFieldByField`, because every share either of them uses
sums well under 65,535. On a set like `agent = 60_000, platform = 10_000` the mutated code reverts
`Panic(0x11)` — the checked addition overflows *before* the comparison — instead of
`InvalidSplitBps()`. The set is still refused, so the tests' question ("is an illegal split
refused?") is still answered yes; the question that mattered ("is it refused **by name**?") was
never asked. Same shape as the five before it: a test that **bounds or relates** where it should
**pin**. The fix was one input that makes the two spellings disagree, in
`test_wrongState_aSplitThatOverflowsUint16IsStillRefusedByName`.


- `test_happyPath_initializeStoresValidatedParams` — **survives DC2** (a constant `params()`) and
  every validation degenerate. It pins ten values but cannot tell stored state from a literal.
  Kills C14, C15.
- `test_theStoredParamsAreThisInstancesOwn` — the counterweight to the above. Kills DC2, C14, C15.
  Survives every mutation inside `_validate`, and survives a `setPaused` that does nothing.
- `test_wrongState_everyBoundIsRefusedAtConstruction` — eleven refusals by name; kills C3, C8, C16
  and any `_validate` that skips a field. **Survives C11** (it never sums two shares past 65,535)
  and survives every `>`/`>=` boundary mutation, because each of its inputs is one step *past* the
  bound. It is a refusal test and proves nothing about what is admitted.
- `test_boundary_theBoundsAdmitTheirOwnValue` — the counterweight: kills C4, C5, C9, C10. Survives
  a `_validate` that is a no-op entirely, which is why it is never cited alone.
- `test_boundary_penaltyAmountIsBoundedAtNeitherEnd` — survives every mutation in this table except
  C14/DC2. Its whole job is to fail if anybody *adds* a bound `state.rs:68-75` deliberately omits.
- `test_validation_judgesTheSplitAsAPairNotFieldByField` — the only test that kills DC1. Survives
  C11 and every non-split mutation.
- `test_wrongState_aSplitThatOverflowsUint16IsStillRefusedByName` — the only test that kills C11.
  Survives everything else; it exercises one input.
- `test_wrongSigner_onlyAdminPauses` — kills C1, C1b, DC3. Survives every validation mutation, and
  **survives C23**: its `false -> true -> false` walk is a sequence a toggle satisfies exactly as
  well as an assignment. It is a who-may-call test; what `setPaused` writes is
  `test_setPausedAssignsItsArgumentAndIsIdempotent`'s.
- `test_wrongState_theZeroAdminIsRefusedAtConstruction` — kills C2, C2b. **Survives C15**, correctly:
  `msg.sender` is never zero, so a wrong-source admin is still a non-zero admin.
- `test_wrongState_initializeRunsExactlyOnce` — no mutation in this table kills anything it alone
  covers; it pins the `initializer` modifier, whose removal is not in the table because deleting it
  makes `initialize` re-callable and this test is the one that says so. Recorded as a single-purpose
  test, not as coverage for anything else.
- `test_initializeEmitsConfigInitialized`, `test_setPausedEmitsPauseToggled` — kill C13 and C12
  respectively, and nothing else. Both assert the full data payload, not just the topic.
- `test_wrongSigner_onlyTheAdminUpgradesConfig` — kills C6. It also pins that the proxy's storage
  survives an upgrade (`admin` and the whole `ParamSet` re-read afterwards), which is the only
  exercise `__gap` gets in this round.
- `test_wrongState_theImplementationCannotBeInitialised` — kills C7 and nothing else.

### Guards deliberately without a test

`canSign`, `assertCanSign` and `verifierExpiry` are placeholders until the verifier-registry round, that fail closed (`false`,
`revert VerifierNotRegistered()`, `0`). **No test asserts on them**, deliberately: a test pinning a
placeholder would have to be deleted rather than extended when the verifier-registry round lands, and a deleted test is
indistinguishable from a test that was never written.

### Config follow-up decisions (2026-09-08)

**Decision A — `ParamSet`'s field order, pinned now rather than at the deposit round's layout gate.** As of
the Config round, `ParamSet` is `X402Config._params`, a **storage** struct in slots 1-3 behind a UUPS proxy,
so a reorder is a silent layout change, not a message change. `test_structsAbiEncodeInDeclarationOrder`
in `test/Types.t.sol` was extended to cover it.

| # | Guard | Mutation | Named test | Observed |
|---|---|---|---|---|
| C17 | `ParamSet` field **order** | `minimumStake` ↔ `penaltyAmount` swapped in `src/Types.sol` (same type, so everything still compiles) | `test_structsAbiEncodeInDeclarationOrder` | **FAILED**, for the stated reason: `[FAIL: ParamSet field 3: 5 != 4]`. Suite-wide `55 passed; 1 failed` — **the entire `X402ConfigAdminTest` passes under it**, which is the gap this row closes: that suite builds named struct literals and reads named fields, so a transposition is invisible to it end to end. |
| C18 | `ParamSet` field **order** | `treasury` ↔ `redeemer` swapped | `test_structsAbiEncodeInDeclarationOrder` | **FAILED**, for the stated reason: `[FAIL: ParamSet field 0: 0x…2222 != 0x…1111]`. Suite-wide `55 passed; 1 failed` — again the only failure. Two rows because the risk is two-sided: C17 is the "pack it better" edit, C18 the ordinary transposition of two adjacent same-type fields. |

**What the `ParamSet` half of that test would still pass against.** It survives every change to
`X402Config`, every validation mutation, and any change to the *values* in `ParamSet`. It sees
exactly one thing: position. It does **not** see a retype that keeps the width (`uint64` → `int64`
would decode identically), and it does not see the storage layout directly — only the declaration
order the layout is derived from.

**Decision B — `slashProviderBps()`**, ported from `state.rs:127-131`, on the contract that owns the
parameters rather than derived again at X402Stake's use site.

| # | Guard | Mutation | Named test | Observed |
|---|---|---|---|---|
| C19 | `slashProviderBps()`'s value | `return 0;` unconditionally | `test_theProviderKeepsTheRemainderOfEveryPenalty` | **FAILED**: `[FAIL: the provider keeps 10% of _valid(): 0 != 1000]`. |
| C20 | the **platform** term of the remainder | `taken = agent + platform` → `taken = agent` | `test_theProviderKeepsTheRemainderOfEveryPenalty` | **FAILED**: `[FAIL: … 4000 != 1000]`. |
| C21 | the **agent** term of the remainder | `taken = agent + platform` → `taken = platform` | `test_theProviderKeepsTheRemainderOfEveryPenalty` | **FAILED**: `[FAIL: … 7000 != 1000]`. |
| C22 | the **saturation** in `slashProviderBps()` | `taken >= 10_000 ? 0 : uint16(10_000 - taken)` → bare `uint16(10_000 - taken)` | whole suite | **SURVIVED** — `56 passed; 0 failed`. **Equivalent mutant on every reachable state, and no test should be invented to pretend otherwise.** `_validate` makes `slashAgentBps + slashPlatformBps <= 10_000` true of every set that can reach `_params`, so `taken` is never `> 10_000` and the two spellings return the same value on every input the contract can hold. It mirrors `state.rs:127-131`, which is saturating for the reason its own comment gives — an abort inside a split is the least debuggable place for a missing validation to surface — and it is a belt for whatever writes `_params` next (the `updateConfig` round's `updateConfig`), not for today. Recorded as survived. |

**Why `test_theProviderKeepsTheRemainderOfEveryPenalty` pins values rather than the sum.** The
requirement was explicit and C20/C21 are the measurement behind it: a test asserting
only `agent + platform + provider == 10_000` is satisfied by an implementation that computes the
remainder from the wrong fields, because the identity is structural once the remainder is a
subtraction. The test states three numbers at three parameter sets — 1,000 / 0 / 9,999 — chosen so
no single wrong formula produces all three (dropping the platform term gives 4,000 / 1,000 / 9,999;
dropping the agent term gives 7,000 / 9,000 / 10,000). The sum identity is asserted **after** the
values, never instead of them.

**What `test_theProviderKeepsTheRemainderOfEveryPenalty` would still pass against.** C22, and
every mutation outside `slashProviderBps`. It is a pure value test on three parameter sets; it says
nothing about what happens on a set where `agent + platform > 10_000`, because `_validate` makes
that set unreachable. (The `ParamSet` half of `test_structsAbiEncodeInDeclarationOrder` has its own
note under Decision A above.)


---

## `src/X402Config.sol` follow-up round — four review findings (2026-09-08)

Four rows the earlier passes did not have. Three of them are the same shape as C11 and as the five
before it: **a test that relates or bounds where it must pin**, and in every case the survivor was
found by mutation rather than by reading.

| # | Guard | Mutation | Named test | Observed |
|---|---|---|---|---|
| C23 | `setPaused`'s **assignment** — `set_paused.rs:41` is `config.paused = paused;` | `paused = value;` → `paused = !paused;` (a toggle) | `test_setPausedAssignsItsArgumentAndIsIdempotent` | **FAILED**: `[FAIL: setPaused(false) on an unpaused config leaves it unpaused]`, suite `58 passed; 1 failed`. **`test_wrongSigner_onlyAdminPauses` still PASSES under it** — measured, run alone: `[PASS]`. Its `false -> true -> false` walk is exactly the sequence a toggle satisfies. DC3 caught "latch true" and stopped there, so the whole class of argument-ignoring writes was still open. Under the toggle an operator hitting pause twice **un-pauses the system**, during the incident that made them hit it twice. The kill comes from the two legs a walk cannot contain: `setPaused(false)` on an unpaused config and `setPaused(true)` on a paused one. |
| C24 | `ParamSet`'s field **widths** | `uint64 minimumStake` → `uint128` | `test_paramSetCarriesItsDeclaredWidthsAndOrder` | **FAILED**: `[FAIL: ParamSet canonical ABI tuple: order AND width: (address,address,uint64,uint128,…) != (address,address,uint64,uint64,…)]`, suite `58 passed; 1 failed`. **Before this test existed the same mutation left 56 of 56 green**, C17/C18 included: `abi.encode` pads every field to a 32-byte word, so a positional decode is blind to width. It is not a cosmetic blindness — `forge inspect X402Config storageLayout` under the mutation shows `_params` at **128 bytes** and `__gap` at **slot 5**, against 96 bytes and slot 4 unmutated. Behind a live UUPS proxy that is the layout break decision A existed to prevent, arriving through the one property the pin could not see. |
| C25 | `ParamSet`'s field **widths**, the other direction | `uint64 verifierDailyCap` → `uint32` | `test_paramSetCarriesItsDeclaredWidthsAndOrder` | **FAILED**: `[FAIL: … (…,uint64,uint64,uint64,uint32,uint16,…) != (…,uint64,uint64,uint64,uint64,uint16,…)]`, suite `58 passed; 1 failed`. Run because C24 only proves the gate sees a field getting *bigger*; a narrowing repacks the struct just as thoroughly, and a "these values never exceed 2^32" argument is exactly the plausible edit. |
| C26 | `ParamSet`'s **order across a width boundary** | `verifierDailyCap` (`uint64`) moved after `takeRateBps` (`uint16`) | `test_paramSetCarriesItsDeclaredWidthsAndOrder` **and** `test_structsAbiEncodeInDeclarationOrder` | **FAILED**, both: `[FAIL: … (…,uint64,uint16,uint64,uint16,…) != …]` and `[FAIL: ParamSet field 5: 7 != 6]`, suite `57 passed; 2 failed`. Recorded to show the two assertions are **complementary, not redundant**: C17's swap of two `uint64`s does not change the tuple string at all (the width gate cannot see it), and C24's widen does not change any position (the order gate cannot see it). Each catches what the other is blind to; only a cross-width reorder trips both. |
| C27 | `_validate`'s **check order** — `state.rs:134-164` then `state.rs:168-191` | all nine checks reversed end to end | `test_theCheckOrderMatchesAnchorWhenTwoBoundsAreViolatedAtOnce` | **FAILED**: `[FAIL: Error != expected error: MissingRedeemer() != MissingBeneficiary()]`, suite `58 passed; 1 failed`. **Before this test existed the same mutation left 56 of 56 green** — every other refusal test violates exactly one bound, and a singly-invalid set names the same error under any ordering, *by construction*. Order is only observable on a doubly-invalid set. |
| C28 | `_validate`'s check order, minimally | `redeemer` checked before `treasury` (one adjacent swap, at the head) | `test_theCheckOrderMatchesAnchorWhenTwoBoundsAreViolatedAtOnce` | **FAILED**: `[FAIL: Error != expected error: MissingRedeemer() != MissingBeneficiary()]`. Run because C27 reverses everything and could be caught by the first row alone; this proves one adjacent transposition is enough. |
| C29 | `_validate`'s check order, at the **tail** of the chain | `verifierDailyCap` checked before `minimumStake` | `test_theCheckOrderMatchesAnchorWhenTwoBoundsAreViolatedAtOnce` | **FAILED**: `[FAIL: Error != expected error: InvalidVerifierDailyCap() != InvalidMinimumStake()]`. Run because C27 and C28 both fail on the test's **first** row — `vm.expectRevert` halts there — so neither shows the later rows are load-bearing. This one can only be caught by the eighth row, and is. |

**Why the check order is worth a test at all.** It is not a stylistic property. It decides which
name a doubly-invalid parameter set gets, and the whole point of keeping `Errors.sol`'s names equal
to `error.rs`'s is that an operator holding the Solana runbook and the EVM runbook sees the same
name for the same bad config. A reordering makes the two chains disagree on exactly the sets where
somebody is already having a bad day.

**The honest limitation of `test_theCheckOrderMatchesAnchorWhenTwoBoundsAreViolatedAtOnce`.** Its
rows are `vm.expectRevert` calls in sequence, so it halts at the **first** failing row — C27 and
C28 both report the head-of-chain mismatch, and only C29 demonstrates that a later row can fail on
its own. The rows chain across consecutive checks (treasury→redeemer→take rate→split→cap→unbonding
floor→unbonding ceiling→minimum stake→daily cap) plus one non-adjacent pair, so any single adjacent
transposition breaks a row; what it does not prove is that *every* row would fail independently
under some mutation, only that each is reachable when the ones before it hold.

### What the three new tests would still pass against

- `test_setPausedAssignsItsArgumentAndIsIdempotent` — kills C23, DC3 and any argument-ignoring
  write. Survives every mutation outside `setPaused`, and says nothing about **who** may call it;
  that is `test_wrongSigner_onlyAdminPauses`. It also does not assert the event — C12 covers that.
- `test_paramSetCarriesItsDeclaredWidthsAndOrder` — kills C24, C25, C26. **Survives C17 and C18**,
  the two same-type reorders, which is why the positional test stays. It reads solc's own ABI, so
  it cannot be satisfied by a hand-written string that drifted. It still cannot see `__gap`'s size
  or a field inserted into `X402Config` **before** `_params`: both move the layout without touching
  this struct, and only a layout snapshot catches them (the deposit round).
- `test_theCheckOrderMatchesAnchorWhenTwoBoundsAreViolatedAtOnce` — kills C27, C28, C29. Survives
  every mutation that changes *whether* a bound refuses rather than *when* it is reached; the
  single-violation tests carry that and this one adds nothing to it. **Single-violation tests
  cannot see order by construction** — that is the sentence this row exists to put in writing.

---

## `X402Config.updateConfig` (`update_config.rs`, ported one-for-one)

Four guards, one derived-value coupling, and two mutations that **survive on purpose**. Every row
below was applied to `src/X402Config.sol`, run, and restored; the "Observed" column is verbatim
`forge test` output.

The door is five lines. What makes it worth thirteen rows is that three of its properties are
invisible to the obvious test: the whole-set validation is only visible on a *legal* move that a
field-at-a-time check would refuse, the partial write is invisible to a one-field happy path, and
the event's `admin` is only distinguishable from `msg.sender` on a call that hands over.

| # | Guard | Mutation | Named test | Observed |
|---|---|---|---|---|
| C30 | the `_validate(q)` call | statement deleted | `test_wrongState_updateRefusesEveryBoundJustAsInitializeDoes` | **FAILED**, for the stated reason: `[FAIL: next call did not revert as expected]` — the first refused set (`treasury == address(0)`) lands. Also killed `test_wrongState_theSetIsValidatedAsAWhole` and `test_wrongState_anInvalidSetMovesNothing`, both `next call did not revert as expected`. Suite `9 passed; 3 failed`. |
| C31 | the zero-address sentinel | `if (newAdmin != address(0)) admin = newAdmin;` → `admin = newAdmin;` | `test_wrongState_theZeroAddressNeverBecomesAdmin` | **FAILED**, for the stated reason: `[FAIL: address(0) left the initial admin in place: 0x0000…0000 != 0x…adAA]`. The contract has no administrator from that call onwards, which is why seven other tests die with `NotAdmin()` behind it. Suite `4 passed; 8 failed`. |
| C32 | the sentinel's **sense** | `newAdmin != address(0)` → `newAdmin == address(0)` | `test_happyPath_adminHandoverIsOneStep` | **FAILED**, for the stated reason: `[FAIL: the handover landed in this same call: 0x…adAA != 0x…bEEF]`. Run because C31 only proves the branch is load-bearing; inverting it is the plausible edit (the sentinel reads either way to a hurried eye) and it both blocks every real handover *and* installs the zero admin on every "leave it" call. Suite `3 passed; 9 failed`. |
| C33 | `onlyAdmin` | modifier deleted | `test_wrongSigner_onlyAdminUpdates` | **FAILED**, for the stated reason: `[FAIL: next call did not revert as expected]`. Also killed `test_happyPath_adminHandoverIsOneStep`, whose middle leg is the *retired* admin being refused. Suite `10 passed; 2 failed`. |
| C34 | `_params = q` | statement deleted | `test_happyPath_aChangeBindsInTheSlotItArrives` | **FAILED**, for the stated reason: `[FAIL: the one field that changed: 1000 != 2000]`. Suite `6 passed; 6 failed`. |
| C35 | `_params = q` as a **whole-set** write | `_params = q;` → `_params.takeRateBps = q.takeRateBps;` (the partial writer) | `test_updateWritesTheWholeSetItWasGivenTwiceOver` | **FAILED**: `[FAIL: first update: treasury: 0x…7EA5 != 0x…F00D]`, suite `7 passed; 5 failed`. **`test_happyPath_aChangeBindsInTheSlotItArrives` PASSES under it** — measured — *even though that test reads all ten fields back*. See the note below; this is the row the follow-up warning was about, and reading ten fields back is not by itself the fix. |
| C36 | `updateConfig` uses **its argument** | `ParamSet memory q = p;` → `q` assigned a hard-coded literal equal to `_other()` (the argument-ignoring writer) | `test_updateWritesTheWholeSetItWasGivenTwiceOver` | **FAILED**: `[FAIL: second update: treasury: 0x…F00D != 0x…B0A7]`, suite `4 passed; 8 failed`. The **second** update is the kill: the first one is the literal, so a test performing one update would have passed. |
| C37 | validation of the **set**, not the field | whole body replaced with a field-at-a-time writer — each field assigned into `_params` and `_validate(_params)` run after each, `slashPlatformBps` landing before `slashAgentBps` | `test_wrongState_theSetIsValidatedAsAWhole` | **FAILED**: `[FAIL: InvalidSplitBps()]`, and **it is the only test that fails** — suite `11 passed; 1 failed`. The kill is the legal move `(6000, 3000) → (3000, 7000)`, which transits the illegal `(6000, 7000)` if the platform share lands first. Every refusal test in this file still passes under it, because the illegal sets are still refused; what the field-at-a-time writer breaks is the *legal* move. |
| C38 | the event's `admin` is the **post**-state | `emit ConfigUpdated(admin, q)` → `emit ConfigUpdated(msg.sender, q)` | `test_updateEmitsConfigUpdatedCarryingThePostState` | **FAILED**: `[FAIL: log != expected log]`, suite `11 passed; 1 failed`. The two are equal on every call that does **not** hand over, which is why the test's second leg hands over. |
| C39 | the emit is **after** the handover | `emit` moved above `if (newAdmin != address(0)) admin = newAdmin;` | `test_updateEmitsConfigUpdatedCarryingThePostState` | **FAILED**: `[FAIL: log != expected log]`, suite `11 passed; 1 failed`. Verbose diff: emitted `admin: 0x…adAA`, expected `admin: 0x…bEEF`. This is the **one** ordering property in this instruction that a test can see at all — see the note on C41. |
| C40 | the emit itself | statement deleted | `test_updateEmitsConfigUpdatedCarryingThePostState` | **FAILED**: `[FAIL: log != expected log]`, suite `11 passed; 1 failed`. |
| C41 | the admin handover **applied last** | `if (newAdmin != address(0)) admin = newAdmin;` moved **above** `_validate(q)` and `_params = q` | whole suite | **SURVIVED** — `71 passed; 0 failed`. **Equivalent mutant, and the test plan instructs that no test be invented for it.** A revert is atomic on the EVM, so the only run in which the ordering could matter is one that reverts, and that run rolls the early assignment back. The ordering is kept for parity with `update_config.rs:84-87` and for the reader — a future edit that inserts a check *between* the write and the handover would make it live, and that edit is what the comment there is addressed to. `test_wrongState_anInvalidSetMovesNothing` passes under both spellings. **CORRECTED 2026-09-08 (review Q4): that test does not assert a stronger property.** The earlier wording here called atomicity "the property that IS observable", which overstates it — C47 below moves `_validate` *after* both writes and also survives all 73, so the "moved nothing" assertions are EVM revert semantics and cannot fail for any implementation that reverts at all. Same equivalent-mutant category as this row, not a stronger one. |
| C42 | the saturation in `slashProviderBps()`, **re-measured with the second writer present** | `taken >= 10_000 ? 0 : uint16(10_000 - taken)` → bare `uint16(10_000 - taken)` (C22's mutation) | whole suite | **SURVIVED** — `71 passed; 0 failed`, unchanged from the Config round. Still an equivalent mutant: `updateConfig` runs `_validate` before `_params = q`, so the second door that writes `_params` bounds `slashAgentBps + slashPlatformBps <= 10_000` exactly as `initialize` does. See the three-way measurement below. |

### C35, in full — why reading ten fields back is not the fix

`test_happyPath_aChangeBindsInTheSlotItArrives` copies `_valid()`, sets `takeRateBps = 2_000`, sends
it, and then reads **all ten** fields back against the set it sent. Under C35 — where `updateConfig`
writes `takeRateBps` and nothing else — that test still **passes**, measured. It has to: the other
nine fields of the argument are already the nine fields in storage, because the argument was built
by patching one field of the stored set. The full read-back is asserting what the test itself set
up, which is the third of the four recurring shapes named in the project's review checklist.

The property needs two updates whose value sets are **disjoint** from each other and from the
initial set, which is `test_updateWritesTheWholeSetItWasGivenTwiceOver` and why `_other()` and
`_third()` differ from `_valid()` and from each other in all ten fields. The single-field happy
path is kept — it is what C34 kills — but it must never be cited as covering the whole-set write.

### C42, in full — the three-way measurement behind "C22 is still unreachable"

A temporary probe (`test/_C22Probe.t.sol`, written for this measurement and deleted afterwards)
pushed `slashAgentBps = 60_000, slashPlatformBps = 10_000` through `updateConfig` and then read
`slashProviderBps()`:

| Source | Result |
|---|---|
| unmutated | `[FAIL: InvalidSplitBps()]` — the set never reaches `_params`; the saturation is not reached, so C22/C42 remain equivalent mutants |
| C30 applied (`updateConfig` skips `_validate`) | `[PASS]`, `slashProviderBps on an unvalidated set: 0` — the saturation is now **live** and doing its job |
| C30 **and** C42 applied | `[FAIL: panic: arithmetic underflow or overflow (0x11)]` — `slashProviderBps()` is a bricked view for every reader, on a state the contract now holds |

That is the coupling stated as a measurement rather than an argument: C22/C42's unreachability is a
property of **both** writers of `_params`, and the moment either one stops validating, the belt
becomes the only thing between an operator error and a permanently reverting view on the contract
X402Stake reads its split from. A future writer of `_params` that skips `_validate` is the defect;
the saturation is not.

### What each `updateConfig` test would still pass against

- `test_happyPath_aChangeBindsInTheSlotItArrives` — kills C34. **Survives C35** (see above),
  survives C30, and survives every event mutation. A one-field patch, which is the console's real
  shape, and the reason it cannot see a partial write.
- `test_updateWritesTheWholeSetItWasGivenTwiceOver` — kills C34, C35, C36. Survives every
  validation mutation (all three of its sets are legal), every admin mutation (it never hands
  over), and every event mutation. It is the whole-set counterweight and nothing else.
- `test_handingTheCurrentSetBackUnchangedIsLegalAndChangesNothing` — kills C36 and nothing else it
  is alone in killing. Its job is to fail if anybody adds a "must differ" rule to this door, the way
  `EscrowLimitsUnchanged` guards the escrow's; `update_config.rs` has no such rule and neither does
  this. Survives C34 (a no-op writer trivially leaves the set unchanged) — never cite it for the write.
- `test_wrongSigner_onlyAdminUpdates` — kills C33. Survives everything inside the body, because
  under it the body never runs.
- `test_wrongState_theSetIsValidatedAsAWhole` — the only test that kills C37. Also kills C30. Its
  first half is a **legal** move; a suite of refusal tests cannot contain this property, because
  the field-at-a-time writer refuses illegal sets exactly as correctly as the real one does.
- `test_wrongState_updateRefusesEveryBoundJustAsInitializeDoes` — twelve refusals by name through
  *this* door, each also asserting the refused call moved neither a parameter nor the admin. Kills
  C30. Survives every mutation that changes what is *admitted*. It deliberately duplicates
  `test_wrongState_everyBoundIsRefusedAtConstruction`'s rows through the other door: that
  `initialize` bounds a set says nothing about `updateConfig`, and C42's unreachability argument
  rests on both. It does **not** pin the check *order* — that is
  `test_theCheckOrderMatchesAnchorWhenTwoBoundsAreViolatedAtOnce`, on the shared `_validate`.
- `test_wrongState_anInvalidSetMovesNothing` — kills C30. **Survives C41 AND C47 by construction**, which is
  the point of the row: it is *not* the observable half of "applied last", because there is no observable
  half. Corrected 2026-09-08 (review Q4); what it is worth is stated at the test.
- `test_happyPath_adminHandoverIsOneStep` — kills C32, C33. Survives C31 (under which the handover
  to a non-zero address still works — it is the *zero* case C31 breaks). Its middle leg, the retired
  admin being refused, is the only place the "one step" claim is actually tested: a two-step
  handover would leave the old admin in charge and fail there.
- `test_wrongState_theZeroAddressNeverBecomesAdmin` — the only test that kills C31. Its second half
  runs the sentinel against an admin that has **already moved**, so it distinguishes "leave the
  current admin alone" from "restore the admin this proxy was initialised with"; the first half
  alone cannot, and would also pass against an `updateConfig` that never touches the admin at all.
- `test_updateEmitsConfigUpdatedCarryingThePostState` — kills C38, C39, C40. Survives every state
  mutation that leaves the emitted values equal to the sent ones. Both legs assert the **full** data
  payload, not just the topic; the second leg hands over, which is the only call on which `admin`
  and `msg.sender` differ.
- `test_updateDoesNotTouchThePauseInEitherPosition` — no mutation in this table is killed by it
  alone. It exists as a **negative** claim with two positions: `updateConfig` neither writes
  `paused` nor reads it as a gate. `update_config.rs` has no pause check, and it must not grow one —
  re-parameterising a paused system is usually why it was paused. Recorded as a single-purpose test.
- `test_theDerivedProviderShareFollowsAnUpdate` — pins that `slashProviderBps()` is derived from
  `_params` at read time rather than latched at `initialize`, at three sets and three stated values
  (1,000 / 5,000 / 9,999), never the sum identity alone (C20/C21 is why). Killed by C34 and C35 too,
  which is a second, independent witness for the whole-set write.

### `updateConfig` follow-up round — four test findings from review (2026-09-08)

Five more rows. Three close a **negative-space** gap: the `updateConfig` suite pinned what this door must
refuse and, for the parameters, that it adds no must-differ rule — but nothing checked that it adds
no precondition the reference lacks, and nothing checked `onlyAdmin` on the *ordinary* path. Two of
the three survivors below were found in review, not by the implementer's own pass.

**`newAdmin` splits this door into two calls, and a guard can cover one and miss the other.** That
is the shape behind C43, and it is worth naming separately from the "asserts less than its name"
family: the test *was* a wrong-signer test and *did* fail on a wrong signer. It exercised the
handover path only, so it answered "may a stranger hand the role over?" while its name claims "may
a stranger update?".

| # | Guard | Mutation | Named test | Observed |
|---|---|---|---|---|
| C43 | `onlyAdmin` on the **ordinary parameter update**, not only the handover | modifier replaced by `if (newAdmin != address(0) && msg.sender != admin) revert NotAdmin();` — any caller may rewrite all ten parameters whenever `newAdmin == address(0)` | `test_wrongSigner_onlyAdminUpdates` (first leg) | **FAILED**, for the stated reason: `[FAIL: next call did not revert as expected]`; suite `12 passed; 2 failed` (the second is `test_happyPath_adminHandoverIsOneStep`'s middle leg). **Against the file as committed at `8d4f1ef` this mutation left `test_wrongSigner_onlyAdminUpdates` PASSING** — measured in review and reproduced — because that test sent `next` as `newAdmin` and so never exercised the path every ordinary update takes. The fix is a first leg with `newAdmin == address(0)`. |
| C44 | the admin handover adds **no must-differ rule** — `update_config.rs:84-86` refuses `Pubkey::default()` and only that, so `Some(current_admin)` is accepted | `if (newAdmin == admin) revert InvalidAdmin();` inserted before the handover | `test_handingTheAdminRoleToItselfIsLegalAndANoOp` | **FAILED**: `[FAIL: InvalidAdmin()]`, suite `13 passed; 1 failed` — sole failure. **Survived all 71 tests before this test existed**: no test in the file ever passed the *current* admin as `newAdmin`. The parameters had this coverage (`test_handingTheCurrentSetBackUnchangedIsLegalAndChangesNothing`); the admin did not, and the admin is the half a second call cannot undo. |
| C45 | the door adds **no precondition the reference lacks** | `if (q.treasury == q.redeemer) revert MissingBeneficiary();` inserted after `_validate(q)` | `test_updateAddsNoPreconditionTheReferenceLacks` | **FAILED**: `[FAIL: MissingBeneficiary()]`, suite `13 passed; 1 failed` — sole failure. **Survived all 71 tests before this test existed.** Nothing in `state.rs:134-191` requires the two addresses to differ. |
| C46 | the same, a second invented rule | `if (q.penaltyAmount > q.minimumStake) revert PenaltyExceedsMaximum();` after `_validate(q)` | `test_updateAddsNoPreconditionTheReferenceLacks` | **FAILED**: `[FAIL: PenaltyExceedsMaximum()]`, suite `6 passed; 8 failed`. Recorded with its honest count: this one is caught **incidentally** by seven other tests as well, because `_other()` and `_third()` happen to violate it. It is the weaker of the two and is kept only to show the negative-space row is not pinned to one specific invented rule. |
| C46b | the same, a third invented rule chosen so **nothing else** can see it | `if (q.unbondingPeriodSeconds % 86_400 != 0) revert UnbondingPeriodTooShort();` after `_validate(q)` | `test_updateAddsNoPreconditionTheReferenceLacks` | **FAILED**: `[FAIL: UnbondingPeriodTooShort()]`, suite-wide `72 passed; 1 failed` — **the only failure in all 73 tests**. Every other set in the whole repo uses a round number of days, which is exactly why an invented "must be whole days" rule is the plausible edit and exactly why nothing else could catch it. This is the row that shows `test_updateAddsNoPreconditionTheReferenceLacks` earns its keep; C45 and C46 are corroboration. |
| C47 | **validate last** — `_validate(q)` moved *below* `_params = q` and the handover | as stated | whole suite | **SURVIVED** — `73 passed; 0 failed`. Equivalent mutant, and the reason C41's row and the per-test audit were corrected above: the "moved nothing" assertions in `_refused` and in `test_wrongState_anInvalidSetMovesNothing` cannot fail for **any** implementation that reverts at all, so they are EVM revert semantics rather than a property of this contract. They are kept as a regression guard on that machine property holding *for this door* — a low-level call, a `try/catch` or an assembly `return` in here is what they would notice — and must not be cited as proof of ordering. |

### What the three new tests would still pass against

- `test_wrongSigner_onlyAdminUpdates` (now two legs) — kills C33 and C43. Survives everything
  inside the body, because under those mutations the body never runs. Neither leg says anything
  about what a *legitimate* update writes.
- `test_handingTheAdminRoleToItselfIsLegalAndANoOp` — the only test that kills C44. Its third leg
  repeats the self-handover after the role has moved to `next`, so it is not a statement about the
  initial admin. Survives every parameter mutation *except* through its `_assertParamsEq` legs,
  which duplicate coverage `test_updateWritesTheWholeSetItWasGivenTwiceOver` owns — never cite this
  test for the whole-set write.
- `test_updateAddsNoPreconditionTheReferenceLacks` — kills C45, C46, C46b. It is a pure
  **acceptance** test: it survives every mutation that changes what is *refused*, including deleting
  `_validate` entirely (C30), and must never be cited as bounds coverage. Its seven rows are
  legal under `state.rs:134-191`, so it is only as good as that reading — if a row is ever found to
  violate the reference, the row is the bug, not the contract. It cannot see an invented
  precondition on a *combination* it does not happen to construct; the class is open-ended by
  nature, which is why the three mutations above pick three different shapes.

### The negative space is now covered on three surfaces, and that is deliberate

`update_config.rs` is a door whose whole job is to accept. Three tests say so, on three different
things, and each was added only after a mutation proved the others could not see it:

| Surface | Test | Survivor it kills |
|---|---|---|
| the parameter **set** | `test_handingTheCurrentSetBackUnchangedIsLegalAndChangesNothing` | a must-differ rule on `_params` |
| the **admin** | `test_handingTheAdminRoleToItselfIsLegalAndANoOp` | C44 |
| the **bounds** | `test_updateAddsNoPreconditionTheReferenceLacks` | C45, C46, C46b |

---

## The verifier registry in `src/X402Config.sol`

**Rewritten wholesale in fix round 1 (2026-09-08), not patched.** The first version of this section
recorded whole-suite counts against a 20-test suite that had already grown to 21 (review nit Q6) and
under-reported V22's failures (Q5), and its guards no longer exist in the shape it described — the
`revokedAt != 0` sentinel is now a stored `revoked` flag. Every row below is a fresh run against the
the tree at that revision, `forge test --match-contract X402ConfigVerifierTest`, suite size **25**.
Hand-adjusting counts in a stale log is worse than re-running it.

### What forced the rewrite: a degenerate registry that passed 21 of 21

The the verifier-registry round review wrote the most degenerate registry that still compiles behind `IX402Config` and it
passed the whole suite on the first try. Five substitutions, none of which any test could see:

- **D1** `registeredAt` is a hard-coded `1_760_000_000`. Every registration whose stamp was asserted
  happened at `T`.
- **D2** the one-shot rule keys on `expiresAt != 0 || revokedAt != 0`, never on `registered`.
- **D3** `revokeVerifier`'s "never enrolled" refusal keys on the same two timestamps.
- **D4** revocation **destroys** the rest of the record (`registeredAt = 0; expiresAt = 0`), which
  makes `verifierExpiry(revokedKey)` return `0` — a function on `IX402Config` that the slash-exit round's
  `expireSlash` reads.
- **D5** with D4 in place, `canSign` needs no revocation check at all:
  `return k.expiresAt != 0 && block.timestamp <= k.expiresAt;`. Neither flag participates in any
  control flow anywhere in the contract.

Three things follow, and all three are in the tree now: the record is asserted **whole** everywhere
(`_assertRecord`), `registeredAt` is pinned at **two clocks**, and the states where the flags and the
timestamps disagree are built with **`vm.store`** and asserted at an ordinary timestamp. The
sentinel itself was the fifth: `revoked` is a stored flag, because Anchor carries both `status` and
`revoked_at` (`state.rs:218, 226`) and collapsing them is what let D2–D5 exist.

**The same degenerate, adapted only where the new field forced it, now fails six of 25:**

```console
[FAIL: registered much later: registeredAt: 1760000000 != 1760777777]  test_registrationStampsTheClockItRanAt
[FAIL: the log carries the clock, not a constant: 1760000000 != 1760777777]
                                                    test_theRegistrationLogIsExactlyOneAndCarriesTheClockItRanAt
[FAIL: a live expiry is not an enrolment]           test_theTwoFlagsAreLoadBearingAtEveryDoor
[FAIL: after the revoke: registeredAt: 0 != 1760000000]        test_wrongState_revocationCanNeverBeUndone
[FAIL: an expired key still stamps: registeredAt: 0 != 1760000000]
                                                    test_anExpiredKeyMayStillBeRevokedAndRevokedWinsTheDiagnosis
[FAIL: revoked at the zero instant: expiresAt: 0 != 1000]      test_revocationLandsEvenWhenTheStampItselfIsZero
Suite result: FAILED. 19 passed; 6 failed; 0 skipped
Ran 7 test suites: 92 tests passed, 6 failed, 0 skipped (98 total tests)
```

### The mutations — 38 rows, one survivor

| # | Guard | Mutation | Named test | Observed (suite of 25) |
|---|---|---|---|---|
| V1 | `if (verifier == address(0)) revert ZeroAddress();` | branch deleted | `test_wrongState_theZeroAddressIsNeverAVerifier` | **FAILED** `24 passed; 1 failed` — `[FAIL: next call did not revert as expected]`. |
| V2 | `if (verifiers[verifier].registered) revert VerifierAlreadyRegistered();` | branch deleted | `test_wrongState_revocationCanNeverBeUndone`, `test_wrongState_anExpiredKeyCannotBeReRegisteredEither`, `test_theTwoFlagsAreLoadBearingAtEveryDoor` | **FAILED** `22 passed; 3 failed` — `[FAIL: next call did not revert as expected]` ×3. A revoked key, a lapsed key and a `vm.store`-built enrolled key are all re-registered clean without it. |
| V3 | `expiresAt <= nowTs` (`register_verifier.rs:53`) | `<=` → `<` | `test_boundary_registrationExpiryBounds`, `test_boundary_aCeilingThatWouldOverflowUint64Saturates` | **FAILED** `23 passed; 2 failed` — `[FAIL: next call did not revert as expected]` ×2. |
| V4 | `uint256(expiresAt) > uint256(nowTs) + MAX_VERIFIER_KEY_LIFETIME_SECONDS` | `>` → `>=` | `test_boundary_registrationExpiryBounds` | **FAILED** `23 passed; 2 failed` — `[FAIL: InvalidVerifierExpiry()]`: the ceiling value must be **admitted**. |
| V5 | the `uint256` widening of that sum — the port of `saturating_add` | widening dropped | `test_boundary_aCeilingThatWouldOverflowUint64Saturates` | **FAILED** `24 passed; 1 failed` — `[FAIL: panic: arithmetic underflow or overflow (0x11)]`. The only input that distinguishes the two spellings. |
| V6 | `onlyAdmin` on `registerVerifier` (`register_verifier.rs:28`) | modifier removed | `test_wrongSigner_onlyAdminRegistersAndRevokes` | **FAILED** `24 passed; 1 failed`. |
| V7 | `onlyAdmin` on `revokeVerifier` (`revoke_verifier.rs:23`) | modifier removed | `test_wrongSigner_onlyAdminRegistersAndRevokes` | **FAILED** `24 passed; 1 failed`. Separate row from V6: a guard can cover one door and miss the other (row C43). |
| V8 | the stored `expiresAt` | replaced by `nowTs + MAX` — registration ignores its argument | `test_registrationStoresTheExpiryItWasGivenAndNotADefault` +11 | **FAILED** `13 passed; 12 failed`, e.g. `[FAIL: a fresh registration: expiresAt: 1791536000 != 1775552000]`. Twelve failures now against one before: `_assertRecord` reads the expiry back everywhere. |
| V9 | `registeredAt: nowTs` | → `0` | `test_happyPath_aRegisteredKeyCanSign` +5 | **FAILED** `19 passed; 6 failed`. |
| **V9b** | the same field — **review substitution D1** | → the constant `1_760_000_000` | `test_registrationStampsTheClockItRanAt` | **FAILED** `24 passed; 1 failed` — `[FAIL: registered much later: registeredAt: 1760000000 != 1760777777]`, the sole failure. **This is the row V9 could not carry**: every other registration whose stamp is asserted happens at `T`, so only a second clock kills a constant. |
| V10 | `if (!k.registered) revert VerifierNotRegistered();` in `revokeVerifier` | branch deleted | `test_wrongState_revokingAnUnknownKeyIsRefused`, `test_theTwoFlagsAreLoadBearingAtEveryDoor` | **FAILED** `23 passed; 2 failed`. |
| V11 | `if (k.revoked) revert VerifierAlreadyRevoked();` (`revoke_verifier.rs:54-57`) | branch deleted | `test_wrongState_revocationCanNeverBeUndone` +2 | **FAILED** `22 passed; 3 failed`. |
| **V12** | `k.registered &&` in `canSign` — **review D5, half** | conjunct deleted | `test_theTwoFlagsAreLoadBearingAtEveryDoor` | **FAILED** `24 passed; 1 failed` — `[FAIL: a live expiry is not an enrolment]`, the sole failure, **at an ordinary timestamp**. In the first round this mutant SURVIVED and had to be chased with `vm.warp(0)`; the `vm.store` entry (`registered == false`, live `expiresAt`) kills it properly and the genesis test is gone. |
| V13 | `!k.revoked &&` in `canSign` | conjunct deleted | `test_wrongState_revocationCanNeverBeUndone` +4 | **FAILED** `20 passed; 5 failed` — `[FAIL: a revoked key never signs again]`, `[FAIL: the flag stops the key, not the stamp]`. |
| V14 | `block.timestamp <= k.expiresAt` in `canSign` (`state.rs:254`) | `<=` → `<` | `test_boundary_aKeyIsUsableAtExactlyItsExpiry` | **FAILED** `24 passed; 1 failed` — `[FAIL: the shared instant belongs to the key]`. The `−1` and `+1` legs pass under it; only the exact instant sees it. |
| V15 | the same conjunct | deleted entirely — a key never expires | `test_boundary_aKeyIsUsableAtExactlyItsExpiry` +3 | **FAILED** `21 passed; 4 failed`. |
| V16 | `if (!k.registered) revert VerifierNotRegistered();` in `assertCanSign` | branch deleted | `test_wrongState_anUnknownKeyRevertsWithItsOwnDiagnosis`, `test_theTwoFlagsAreLoadBearingAtEveryDoor` | **FAILED** `23 passed; 2 failed` — `[FAIL: Error != expected error: VerifierKeyExpired() != VerifierNotRegistered()]`. It still reverts; the **diagnosis** is what changes. |
| V17 | `if (k.revoked) revert VerifierRevoked();` | branch deleted | `test_wrongState_revocationCanNeverBeUndone` +3 | **FAILED** `21 passed; 4 failed`. |
| V18 | `if (block.timestamp > k.expiresAt) revert VerifierKeyExpired();` | branch deleted | `test_boundary_aKeyIsUsableAtExactlyItsExpiry` +2 | **FAILED** `22 passed; 3 failed`. |
| V19 | the same comparison | `>` → `>=` | `test_boundary_aKeyIsUsableAtExactlyItsExpiry` | **FAILED** `24 passed; 1 failed` — `[FAIL: VerifierKeyExpired()]`. The reverting form must **admit** the exact instant; two comparisons, two rows. |
| V20 | the **diagnosis order** (`state.rs:249-256`: status before expiry) | the two branches swapped | `test_anExpiredKeyMayStillBeRevokedAndRevokedWinsTheDiagnosis`, `test_wrongState_revocationCanNeverBeUndone` | **FAILED** `23 passed; 2 failed` — `[FAIL: Error != expected error: VerifierKeyExpired() != VerifierRevoked()]`. Invisible to any test that never builds a key in both states at once. |
| V21 | the check order in `revokeVerifier` (`registered` before `revoked`) | the two branches swapped | whole contract | **SURVIVED** — `25 passed; 0 failed`. **Equivalent mutant**, re-derived independently in review: there are exactly two writes to `verifiers[…]`, the whole-struct assignment (`registered: true, revoked: false`) and the revocation (reachable only past `if (!k.registered) revert`), and `registered` is never assigned `false`. So `registered == false ⟹ revoked == false` over every reachable state, the swapped first branch can never fire on an unenrolled entry, and control reaches the identical refusal. Kept as written: it stops being equivalent the moment anything else writes this struct. |
| V22 | **DEGENERATE** | `revokeVerifier` clears `registered` instead of setting `revoked` | 4 tests | **FAILED** `21 passed; 4 failed` — `[FAIL: after the revoke: registered: false != true]` and three more. (The first round recorded this as `18 passed; 2 failed` and missed the event test; the whole-record helper now catches it in four places.) |
| V23 | **DEGENERATE** — the registry is really one key | `canSign` ignores its argument and reads `verifiers[address(0x7E51)]` | `test_oneKeysLifecycleDoesNotTouchAnother` +2 | **FAILED** `22 passed; 3 failed`. 22 of 25 pass: a single-address suite cannot see it. |
| V24 | **NEGATIVE SPACE** — neither door is gated on the pause | `if (paused) revert ProgramPaused();` added to `registerVerifier` | `test_theRegistryIsNotGatedOnThePause` | **FAILED** `24 passed; 1 failed` — `[FAIL: ProgramPaused()]`, the sole failure. |
| V25 | **NEGATIVE SPACE** — no precondition the reference lacks | `if (label == bytes32(0)) revert InvalidVerifierExpiry();` added | `test_registrationAddsNoPreconditionTheReferenceLacks` | **FAILED** `22 passed; 3 failed`. |
| V26 | the same, a second invented rule nothing else can see | `if (verifier == admin) revert ZeroAddress();` added | `test_registrationAddsNoPreconditionTheReferenceLacks` | **FAILED** `24 passed; 1 failed` — `[FAIL: ZeroAddress()]`, the sole failure. No other test in the repo enrols the admin. |
| VE1 | `emit VerifierRegistered(…, label, …)` | `label` → `bytes32(0)` | `test_registrationEmitsVerifierRegistered`, `test_theRegistrationLogIsExactlyOneAndCarriesTheClockItRanAt` | **FAILED** `23 passed; 2 failed`. `label` is stored **nowhere**; the log is the only place it exists. |
| VE2 | the same event's `expiresAt` | the argument → `nowTs + MAX` | same two, plus the ceiling test | **FAILED** `22 passed; 3 failed`. |
| VE3 | `emit VerifierRevokedEvent(…, k.revokedAt)` | → `k.registeredAt` | `test_revocationEmitsVerifierRevokedEvent`, `test_theRevocationLogIsExactlyOneAndCarriesTheClockItRanAt` | **FAILED** `23 passed; 2 failed`. |
| VE4 | the same event's `admin` topic | `msg.sender` → `verifier` | same two | **FAILED** `23 passed; 2 failed` — including the raw-topic assertion. |
| **VE5** | **how many** logs a registration emits — **review substitution E2** | a spurious second `VerifierRegistered` for `address(0)` | `test_theRegistrationLogIsExactlyOneAndCarriesTheClockItRanAt` | **FAILED** `24 passed; 1 failed` — `[FAIL: a registration emits exactly one event: 2 != 1]`. `vm.expectEmit` matches *a* log and cannot see this; only `vm.recordLogs` can. |
| **VE6** | the `registeredAt` **in the log**, with storage left correct | → the constant `1_760_000_000` | `test_theRegistrationLogIsExactlyOneAndCarriesTheClockItRanAt` | **FAILED** `24 passed; 1 failed` — `[FAIL: the log carries the clock, not a constant: 1760000000 != 1760777777]`. V9b covers storage; this is its log twin, and the only event assertion at a clock other than `T`. |
| V27 | `verifierExpiry` | `return 0;` | 11 tests | **FAILED** `14 passed; 11 failed`. `_assertRecord` reads it back everywhere the record is asserted. |
| **V28** | revocation **preserves** the rest of the record — **review substitution D4** | `k.registeredAt = 0; k.expiresAt = 0;` added to `revokeVerifier` | `test_wrongState_revocationCanNeverBeUndone` +3 | **FAILED** `21 passed; 4 failed` — `[FAIL: after the revoke: registeredAt: 0 != 1760000000]`. Not tidiness: it makes `verifierExpiry(revokedKey)` return `0`, and the slash-exit round's `expireSlash` reads that. |
| V29 | `k.revoked = true;` | deleted — only the stamp is written | `test_wrongState_revocationCanNeverBeUndone` +5 | **FAILED** `19 passed; 6 failed`. |
| V30 | `k.revokedAt = uint64(block.timestamp);` | deleted — only the flag is written | `test_wrongState_revocationCanNeverBeUndone` +4 | **FAILED** `20 passed; 5 failed`. Both halves of the revocation write have their own row, because the flag is the control and the stamp is the evidence. |
| **V31** | the one-shot rule reads the **flag** — **review substitution D2** | rekeyed on `prev.expiresAt != 0 \|\| prev.revokedAt != 0` | `test_theTwoFlagsAreLoadBearingAtEveryDoor` | **FAILED** `24 passed; 1 failed` — `[FAIL: VerifierAlreadyRegistered()]`, the sole failure. The `vm.store` entry with `registered == false` and a live expiry is the only state that distinguishes them. |
| **V32** | `revokeVerifier`'s enrolment check reads the **flag** — **review D3** | rekeyed on `k.expiresAt == 0 && k.revokedAt == 0` | `test_theTwoFlagsAreLoadBearingAtEveryDoor` | **FAILED** `24 passed; 1 failed`, the sole failure. |
| **V33** | `assertCanSign` reads the **two flags** — **review D3/D5** | both branches rekeyed on the two timestamps | `test_theTwoFlagsAreLoadBearingAtEveryDoor`, `test_revocationLandsEvenWhenTheStampItselfIsZero` | **FAILED** `23 passed; 2 failed`. |
| **V34** | `canSign` reads `revoked` and not `revokedAt` | `!k.revoked` → `k.revokedAt == 0` — the spelling this contract shipped in `3925ae3` | `test_theTwoFlagsAreLoadBearingAtEveryDoor`, `test_revocationLandsEvenWhenTheStampItselfIsZero` | **FAILED** `23 passed; 2 failed` — `[FAIL: the flag stops the key, not the stamp]`, `[FAIL: and it is stopped]`. This is the row that proves the fix-round change was a real behavioural difference and not a rename. |

### The one survivor

V21, and it is an equivalent mutant with the argument above. Nothing else survives. V12, the first
round's second survivor, is killed at an ordinary timestamp now and
`test_wrongState_anUnknownKeyCannotSignEvenAtTimestampZero` has been deleted along with the reason it
existed.

### The weakest degenerate that still passes — record it, do not pretend it does not

`F1`, and it survives **25 of 25 and 98 of 98**:

```solidity
        emit VerifierRegistered(verifier, msg.sender, label, nowTs, expiresAt);
        // F1: a second, unannounced enrolment of an address the caller never named, written with
        //     NO log.
        verifiers[address(0xBACC1DE)] = VerifierKey({
            registeredAt: nowTs,
            expiresAt: expiresAt,
            revokedAt: 0,
            registered: true,
            revoked: false
        });
```

**No test can close this and none should pretend to.** The registry has no enumeration — no count,
no index, no `registeredKeys()` — so the only trace an enrolment leaves is its log, and F1 emits
none. A test can only assert about addresses it names, and the backdoor's address is one of `2^160`;
a fuzzer will not find it either. What VE5 bought is narrower and real: any enrolment that *does*
announce itself is now caught, so the residual is exactly **"an enrolment that emits nothing"**.

Two things would close it, neither of them a test, and both outside the verifier-registry round's test plan:

- a `uint256 public verifierCount` incremented on registration, asserted after each one — one slot
  out of `__gap`, and it catches a backdoor whether or not the backdoor also increments it (1 vs 2);
- off-chain monitoring that reconciles the set of `VerifierRegistered` logs against what the operator
  believes is enrolled — which is what a chain without enumeration always needs.

**The slash-exit round and any reviewer should read this as the boundary of what conformance here proves:** the
suite proves that the *named* address is enrolled exactly as asked and that nothing else is
announced. It does not, and cannot, prove that nothing else was enrolled.

### What each verifier-registry test would still pass against

- `test_happyPath_aRegisteredKeyCanSign` — kills V8, V9, V27. Would pass against `canSign ≡ true`
  and against a `revokeVerifier` that does nothing. It is a whole-record read now, so it is no
  longer the "asserts only what it set up" shape — but it is still one clock, which is why V9b needs
  its own test.
- `test_registrationStampsTheClockItRanAt` — the only test that kills **V9b (review D1)**. Two
  registrations at two clocks, plus a re-read of the first after the second is written.
- `test_registrationStoresTheExpiryItWasGivenAndNotADefault` — kills V8, V15, V23. Two lifetimes,
  both values pinned and the instant between them walked.
- `test_theRegistryIsThisProxysOwn` — kills V27. Its job is the proxy dimension only.
- `test_oneKeysLifecycleDoesNotTouchAnother` — kills V23. The only test that says a revocation is
  per-key.
- `test_wrongSigner_onlyAdminRegistersAndRevokes` — kills V6 and V7 on four legs (pranked stranger
  and the test contract's own sender, on both doors). Survives everything inside either body.
- `test_wrongState_anUnknownKeyCannotSign` / `…RevertsWithItsOwnDiagnosis` / `…HasNoExpiryAndNoStruct`
  — the zero-entry trio. The first proves less than its name (V12 used to survive it); the second
  kills V16 by **naming** the error; the third kills V27.
- **`test_theTwoFlagsAreLoadBearingAtEveryDoor`** — the single most load-bearing test in the file.
  Sole or joint killer of V12, V31, V32, V33, V34, and a failing witness in eight more. It is also
  the layout regression test: `_writeEntry` reads its own `vm.store` back through `verifierKey`, so
  it fails if the mapping leaves slot 4 or the struct is reordered. It proves nothing about
  boundaries or events.
- `test_revocationLandsEvenWhenTheStampItselfIsZero` — kills V33 and V34 alongside the test above.
  The **only** assertion in the file on an input a live chain cannot produce, and it is a regression
  test on a measured defect (the `revokedAt == 0` sentinel), not a substitute for coverage.
- `test_wrongState_revokingAnUnknownKeyIsRefused` — kills V10.
- `test_wrongState_theZeroAddressIsNeverAVerifier` — kills V1.
- `test_wrongState_revocationCanNeverBeUndone` — kills V2, V11, V13, V17, V20, V22, V28, V29, V30.
  Its `assertFalse(canSign(v))` still proves the least of everything in it; what carries it is the
  six-instant sweep, the **whole-record** assertion after the revoke and after the refused revoke,
  and the refused re-registration.
- `test_wrongState_anExpiredKeyCannotBeReRegisteredEither` — kills V2 through the *lapsed* door.
- `test_anExpiredKeyMayStillBeRevokedAndRevokedWinsTheDiagnosis` — the only test that kills V20's
  first witness; also kills V9, V22, V28, V29, V30.
- `test_boundary_aKeyIsUsableAtExactlyItsExpiry` — kills V14, V15, V18, V19. −1 / exact / +1 on
  **both** surfaces.
- `test_boundary_registrationExpiryBounds` — kills V3, V4, V23. Both ends at −1 / exact / +1 on three
  addresses, every admitted call followed by a state read.
- `test_boundary_aCeilingThatWouldOverflowUint64Saturates` — the only test that kills V5.
- `test_registrationEmitsVerifierRegistered` — kills VE1, VE2, VE4. One clock, one log, matched not
  counted; VE5 and VE6 are what it cannot see.
- `test_theRegistrationLogIsExactlyOneAndCarriesTheClockItRanAt` — the only test that kills **VE5**
  and **VE6**. Reads the raw logs: count, emitter, topic arity, signature hash, both topics, and all
  three data fields, at `T + 777_777`.
- `test_theRevocationLogIsExactlyOneAndCarriesTheClockItRanAt` — the same for the revocation log,
  at a third clock.
- `test_theRegistryIsNotGatedOnThePause` — the only test that kills V24. Pure acceptance.
- `test_registrationAddsNoPreconditionTheReferenceLacks` — kills V25, V26. Pure acceptance; never
  bounds coverage.

---

## `src/X402Escrow.sol` (storage, `deposit`, `depositFor`, `depositWithPermit2`)

Every row: the mutation applied to `src/X402Escrow.sol` alone, the *named* test run on its own
(`forge test --match-contract X402EscrowDepositTest --match-test <name>`), the verbatim result, then
`src/X402Escrow.sol` restored from a byte-exact `GOOD` copy and re-verified by SHA-256. The
restore hash is asserted after every row and again at the end (`restored GOOD: True`).

Where a mutation deletes a `revert`, the observed failure is `next call did not revert as expected`
— the "named custom error" is the selector the test's `vm.expectRevert` was waiting for, given in
the third column.

| # | Guard | Mutation | Named test (expecting) | Observed |
|---|---|---|---|---|
| E1 | `_pullExact`: `if (ASSET.balanceOf(address(this)) - before != amount) revert TransferAmountMismatch();` | deleted | `test_wrongState_aShortTransferReverts` (`TransferAmountMismatch`) | **FAILED**: `[FAIL: next call did not revert as expected] test_wrongState_aShortTransferReverts() (gas: 247861)` — the escrow credits 1,000,000 having received 990,000 |
| E2 | `depositFor`: `if (CONFIG.paused()) revert ProgramPaused();` | deleted | `test_wrongState_depositIsClosedWhilePaused` (`ProgramPaused`) | **FAILED**: `[FAIL: next call did not revert as expected] test_wrongState_depositIsClosedWhilePaused() (gas: 235399)` |
| E3 | `depositFor`: `if (amount == 0) revert ZeroAmount();` | deleted | `test_wrongState_zeroIsRefused` (`ZeroAmount`) | **FAILED**: `[FAIL: next call did not revert as expected] test_wrongState_zeroIsRefused() (gas: 84250)` |
| E4 | `depositFor`: `nonReentrant` | deleted | `test_wrongState_aReentrantAssetCannotRecurseIntoDepositFor` (`ReentrancyGuardReentrantCall`) | **FAILED**: `[FAIL: Error != expected error: TransferAmountMismatch() != ReentrancyGuardReentrantCall()]`. **Read the observed error.** The re-entrant token funds its own nested deposit, so the nested call succeeds — and then the OUTER delta assertion sees `amount + reenterAmount` and refuses. On the funding paths `nonReentrant` and E1/E6 overlap: the money is held by the delta check even without the modifier. `nonReentrant` is not redundant, but what it is load-bearing *for* is `redeemVoucher` (**The redeem round**), `redeemVoucherBatch` (**The batch round**) and `withdraw()` (**The `withdraw()` round**), which pay money OUT and have no delta to fall back on. Recorded rather than dressed up as a stronger proof than it is. |
| E5 | `depositWithPermit2`: `_credit(buyer, amount)` | → `_credit(msg.sender, amount)` | `test_happyPath_permit2DepositCreditsTheSigner` | **FAILED**: `[FAIL: assertion failed: 0 != 1000000] test_happyPath_permit2DepositCreditsTheSigner() (gas: 790554)` — the buyer's escrow is empty and the relayer holds the credit |
| E6 | `depositWithPermit2`: the `balanceOf` delta assertion | deleted | `test_wrongState_aShortTransferRevertsThroughPermit2` (`TransferAmountMismatch`) | **FAILED**: `[FAIL: next call did not revert as expected] test_wrongState_aShortTransferRevertsThroughPermit2() (gas: 797373)` |
| E7 | `_authorizeUpgrade`: `if (msg.sender != CONFIG.admin()) revert NotAdmin();` | deleted | `test_wrongSigner_onlyTheAdminUpgradesEscrow` (`NotAdmin`) | **FAILED**: `[FAIL: next call did not revert as expected] test_wrongSigner_onlyTheAdminUpgradesEscrow() (gas: 1300880)` — a stranger moved the implementation |
| E8 | constructor: `_disableInitializers()` | deleted | `test_wrongState_theImplementationCannotBeInitialised` (`InvalidInitialization`) | **FAILED**: `[FAIL: next call did not revert as expected] test_wrongState_theImplementationCannotBeInitialised() (gas: 110821)` |
| E9 | `depositFor`: `if (buyer == address(0)) revert ZeroAddress();` | deleted | `test_wrongState_theZeroAddressCannotBeFunded` (`ZeroAddress`) | **FAILED**: `[FAIL: next call did not revert as expected] test_wrongState_theZeroAddressCannotBeFunded() (gas: 228349)` |
| E10 | `depositWithPermit2`: `if (PERMIT2 == address(0)) revert Permit2NotConfigured();` | deleted | `test_wrongState_permit2PathRefusesWhenUnconfigured` (`Permit2NotConfigured`) | **FAILED**: `[FAIL: call reverted as expected, but without data]` — the call reaches `IPermit2(address(0)).permitTransferFrom` and reverts with no data at all, which is the diagnosis-free failure the guard exists to replace |
| E11 | `depositWithPermit2`: `if (CONFIG.paused()) revert ProgramPaused();` | deleted | `test_wrongState_permit2DepositIsClosedWhilePaused` (`ProgramPaused`) | **FAILED**: `[FAIL: next call did not revert as expected] test_wrongState_permit2DepositIsClosedWhilePaused() (gas: 785127)` |
| E12 | `depositWithPermit2`: `if (amount == 0) revert ZeroAmount();` | deleted | `test_wrongState_permit2RefusesZeroAmountAndTheZeroBuyer` (`ZeroAmount`) | **FAILED**: `[FAIL: Error != expected error: InvalidSigner() != ZeroAmount()]` — a zero-amount permit is carried all the way into Permit2 |
| E13 | `depositWithPermit2`: `if (buyer == address(0)) revert ZeroAddress();` | deleted | `test_wrongState_permit2RefusesZeroAmountAndTheZeroBuyer` (`ZeroAddress`) | **FAILED**: `[FAIL: Error != expected error: InvalidSigner() != ZeroAddress()]` |
| E14 | `initialize`: `if (IERC20Decimals(address(asset)).decimals() != 6) revert AssetDecimalsNotSix();` | deleted | `test_wrongState_initializeRefusesAnAssetThatIsNotSixDecimals` (`AssetDecimalsNotSix`) | **FAILED**: `[FAIL: next call did not revert as expected] (gas: 223436)` |
| E15 | `initialize`: the three `ZeroAddress` checks | deleted | `test_wrongState_initializeRefusesAZeroConfigOrStakeOrAsset` (`ZeroAddress`) | **FAILED**: `[FAIL: next call did not revert as expected] (gas: 161672)` |
| E16 | `_credit`: `e.balance += amount;` | → `e.balance = amount;` | `test_happyPath_depositsAccumulate` | **FAILED**: `[FAIL: assertion failed: 2000005 != 3000008]` — the second deposit replaced the first (`deposit_stake.rs:75`) |
| E17 | `_credit`: `totalEscrowed += amount;` | → `totalEscrowed = amount;` | `test_twoBuyersDoNotShareABalance` | **FAILED**: `[FAIL: assertion failed: 2222222 != 3333333]` — the pool total is the last deposit, not the sum |
| E18 | `_credit`: `e.totalFunded += amount;` | deleted | `test_happyPath_depositCreditsTheBuyerAndThePool` | **FAILED**: `[FAIL: assertion failed: 0 != 1000000]` |
| E19 | `_authorizeUpgrade` reads `CONFIG.admin()` **live** | → `address(0xADAA)` (a cached/hard-coded admin) | `test_theUpgradeAuthorityFollowsConfigsAdmin` (`NotAdmin`) | **FAILED**: `[FAIL: next call did not revert as expected] (gas: 1339179)` — after `updateConfig` hands Config to a new admin, the OLD admin still upgrades the escrow. This is the row that proves "read live, never cached". |
| E20 | `_credit`: `emit Deposited(buyer, msg.sender, …)` | → `emit Deposited(buyer, buyer, …)` | `test_happyPath_theEventNamesTheFunderNotTheBuyer` | **FAILED**: `[FAIL: log != expected log] (gas: 233518)` |
| E21 | `initialize`: the `WITHDRAW_DELAY_SECONDS > CLOCK_SKEW + VOUCHER_MAX_LIFETIME + REDEEM_GRACE` check | deleted | whole `X402EscrowDepositTest` (38 tests) | **SURVIVED** — `38 passed; 0 failed`. **Equivalent mutant, necessarily.** Every term is a compile-time constant, so the condition is folded to `false` by the optimiser and no input can reach it; `test/Types.t.sol::test_withdrawDelayOutlivesTheLongestRedeemableVoucher` is the assertion that goes red if the numbers ever change. The check exists so that such a change also produces a deployment that cannot be initialised. No test was written to pretend otherwise. |
| E22 | constructor: `EIP712("x402 Settlement", "2")` | → `"3"` | `test_theDomainSeparatorIsTheProxysAndNamesX402Settlement` | **FAILED**: `[FAIL: assertion failed: 0x305b68806b7a42f818a801dab9f7ca9004b7703c4c3d9d3d2e82fd0ce745fc09 != 0xd7b9716ac8a5e91f19e6961d69dec8565fb16cf93e7a9f48d0f8219f7915a5b9]` — the domain separator moved, which is every outstanding voucher dead (D-1/D-7) |

### The degenerates

| # | Degenerate | Result |
|---|---|---|
| DE1 | Stores `mapping(address => uint128)` and `totalEscrowed` only; `escrowOf` synthesises an `Escrow` with `balance` and `totalFunded` set and the other ten fields zero; the four addresses declared in a different order; **no `__gap`**. Every guard E1-E20 kept. | Before `test_theStorageLayoutIsTheOneTheSnapshotCommitsTo` existed: **37 of 37 PASSED** — the whole suite. `script/check-layout.sh` refused it (`CONFIG moved: slot 3+0 -> 5+0`, `escrows was removed`, `struct X402Escrow.Escrow was removed`, `every contract must end with a __gap`), but nothing in `forge test` did. That is a gate a person has to run standing in for a test that runs itself, so the suite was hardened. After: **37 of 38**, failing `[FAIL: CONFIG at slot 3: 0x…0F4240 != 0xF62849…]`. |
| DE2 | The real implementation with one line changed: `e.totalFunded += amount;` → `e.totalFunded = e.balance;` — an alias rather than a lifetime total. | **38 of 38 PASSED**, and `script/check-layout.sh` accepts it (the layout is identical). **The residual gap of this round, and it cannot be closed here**: `balance` and `totalFunded` diverge only after money leaves, and no path in the deposit round takes money out. **The redeem round (`redeemVoucher`) is the first path in this project that lowers `escrows[buyer].balance`, so the redeem round owes** an assertion that `totalFunded` did *not* move when the balance fell; `withdraw()` (the `withdraw()` round) owes the same on its own path. (the limits-and-withdraw-request round is `setLimitsBySig`/`requestWithdraw` and moves no money.) |

### What each deposit test actually proves

- `test_theStorageLayoutIsTheOneTheSnapshotCommitsTo` — the only test that kills DE1. Reads the
  proxy's raw slots: the four addresses at 3-6, `totalEscrowed` at 8, `escrows[buyer]` at
  `keccak256(abi.encode(buyer, 7))`, `balance` in the low 16 bytes of the struct's slot 0,
  `totalFunded` in the HIGH half of slot 3, and slots 1 and 2 untouched. It is what makes the
  twelve-field struct load-bearing at a point where ten of the fields have no writer.
- `test_happyPath_depositsAccumulate` — the only test that kills E16. Three distinct non-round
  amounts with a read between each, so "assign", "double" and "keep the last" all disagree.
- `test_twoBuyersDoNotShareABalance` / `testFuzz_totalEscrowedIsTheSumOfEveryBalance` — kill E17.
  A single global balance passes every single-buyer test in the file and fails these.
- `test_theBalancesAreThisProxysOwn` / `test_theStoredAddressesAreThisProxysOwn` — two proxies over
  one implementation. A hard-coded getter or shared state satisfies one instance, never both.
- `test_happyPath_depositMovesTheTokensToTheEscrow`, `test_happyPath_anybodyMayFundAnybody` — assert
  the token side as well as the credit side. The credit assertions alone would be satisfied by an
  implementation that moved no tokens at all once the delta check went with it (E1); these pin the
  movement independently of the guard that measures it.
- `test_happyPath_permit2DepositCreditsTheSigner` — kills E5. Asserts all four of: the signer's
  credit, the pool total, the signer's drained token balance, and that the RELAYER's escrow is
  still empty.
- `test_wrongSigner_aPermit2SignatureCannotCreditSomebodyElse` and
  `test_wrongSigner_aPermit2SignatureIsBoundToOneEscrow` — the two halves of the Permit2 rule:
  the credited account is the `owner` the signature is checked against, and the digest binds
  `msg.sender`, so one escrow's signature is not another's. Both assert `nothing moved` afterwards.
- `test_theDomainSeparatorIsTheProxysAndNamesX402Settlement` — the only test that kills E22, and
  the only one that pins the two strings that may never change. Recomputed from the literals, not
  read back from the contract.
- `test_theUpgradeAuthorityFollowsConfigsAdmin` — the only test that kills E19.
  `test_wrongSigner_onlyTheAdminUpgradesEscrow` alone passes against a hard-coded admin.
- `test_wrongState_aShortTransferCreditsNothing` — the *state* half of E1: not only that it
  reverted, but that the escrow, the pool and the buyer's wallet are all where they were.
- `test_happyPath_unpausingReopensTheDoor` — pure acceptance. It exists so `if (CONFIG.paused())`
  cannot be "hardened" into something that never re-opens; it bounds no coverage.
- `test_happyPath_everyFieldOfAFreshEscrowIsZero` — all twelve fields, because "unopened means
  disarmed" (`state.rs:545-551`) is the security property that replaces `open_escrow` entirely.

### Follow-up round 1 (review findings F1-F4)

The review's own degenerate **DX1** — `totalFunded` aliased to `balance`, `nonReentrant` deleted
from the Permit2 door, and `SafeERC20` replaced by a bare `transferFrom` — passed **38 of 38 and
the layout gate**. **DX2** added a permutation of the ten never-written `Escrow` members, a retyped
`STAKE` and a shrunken `__gap`, and still passed 38 of 38. Four tests and four mutation rows were
added in answer; the suite is now 42 tests.

| # | Guard | Mutation | Named test (expecting) | Observed |
|---|---|---|---|---|
| E23 | `depositWithPermit2`: `nonReentrant` | deleted | `test_wrongState_aReentrantPermit2CannotRecurseIntoDepositWithPermit2` (`ReentrancyGuardReentrantCall`) | **FAILED**: `[FAIL: Error != expected error: TransferAmountMismatch() != ReentrancyGuardReentrantCall()] (gas: 613778)`. Before this row and its test, deleting the modifier failed **nothing at all** (measured in review: 38/38). Read the observed error exactly as E4's: `ReentrantPermit2` funds its own nested deposit, the nested deposit succeeds, and the outer delta assertion then refuses `amount + reenterAmount`. The two funding doors are alike in this, and the same warning applies — what the modifier is load-bearing *for* is the redeem, batch and `withdraw()` rounds. |
| E24 | `_pullExact`: `ASSET.safeTransferFrom(...)` | → `ASSET.transferFrom(...)`, boolean discarded | `test_happyPath_aTokenThatReturnsNoDataIsAccepted` and `test_wrongState_aTokenThatReturnsFalseStopsTheDeposit` | **FAILED, both**: `[FAIL: EvmError: Revert] test_happyPath_aTokenThatReturnsNoDataIsAccepted() (gas: 441487)` — the bare call cannot ABI-decode a `bool` out of a USDT-shaped token's empty returndata, so the deposit that *must* work does not; and `[FAIL: Error != expected error: TransferAmountMismatch() != SafeERC20FailedOperation(0x1d14…)] test_wrongState_aTokenThatReturnsFalseStopsTheDeposit()` — a refusing token is diagnosed as a fee-on-transfer surprise. Against `MockUSDG` alone this substitution survived the whole suite, because a mock that can only return `true` cannot test the return convention. |
| E26 | the `Escrow` struct's member ORDER (a layout guard, not a code guard) | swap `seqHigh` and `authNonce` — same slot, different offsets, struct still 128 bytes | `test_theTwelveEscrowFieldsDecodeFromTheFourSlotsTheSnapshotCommitsTo` | **FAILED**: `[FAIL: seqHigh: slot 0, offset 16: 333000000000003 != 222000000000002] (gas: 20608)`. The D-4 size assertion in `check-layout.sh` passes on this mutation (128 bytes either way) and so did every test before this one existed. |
| E27 | `IX402StakeView public STAKE` — the *type* of the getter, not its value | → `address public STAKE` (with `STAKE = address(stake)` in `initialize`) | `test_happyPath_initializeStoresTheFourAddresses` | **FAILED to COMPILE**, which is the loudest available failure: `Error (9582): Member "bondedOf" not found or not visible after argument-dependent lookup in address.` The test calls `escrow.STAKE().bondedOf(provider)` rather than `address(escrow.STAKE())`, so the declared interface types are pinned by the compiler. `address(...)` accepts a plain `address` just as happily, which is why the earlier assertions did not see this. |

**Re-runs against the fixed source.** E1, E2, E3, E4 and E21 were re-run after the fix round (E21's
guard was re-spelled to name `Constants.MAX_VOUCHER_REDEEMABLE_LIFE_SECONDS`, so its row had to be
re-measured against the new text):

```
E1   [FAIL: next call did not revert as expected] test_wrongState_aShortTransferReverts() (gas: 247905)
E2   [FAIL: next call did not revert as expected] test_wrongState_depositIsClosedWhilePaused() (gas: 235399)
E3   [FAIL: next call did not revert as expected] test_wrongState_zeroIsRefused() (gas: 84360)
E4   [FAIL: Error != expected error: TransferAmountMismatch() != ReentrancyGuardReentrantCall()] (gas: 657480)
E21  Suite result: ok. 42 passed; 0 failed; 0 skipped          <-- SURVIVED, as logged
```

E5-E20 and E22 mutate code this fix round did not change, against tests it did not change; their
rows above stand, and the review independently re-ran nine of them (E1, E4, E5, E10, E12, E16,
E17, E19, E21) and reported every one verbatim-identical to this log.

### The degenerates, re-run

| Degenerate | Before the fix round | After |
|---|---|---|
| **DX1** (review): `totalFunded` alias + Permit2 `nonReentrant` deleted + bare `transferFrom` | **38 of 38 PASSED**, and `check-layout.sh` accepted it | **FAILS**: `Suite result: FAILED. 39 passed; 3 failed` — `test_happyPath_aTokenThatReturnsNoDataIsAccepted`, `test_wrongState_aTokenThatReturnsFalseStopsTheDeposit`, `test_wrongState_aReentrantPermit2CannotRecurseIntoDepositWithPermit2` |
| **DX2** (review): DX1 + the ten never-written members permuted + `STAKE` retyped to `address` + `__gap[50]` → `[10]` | **38 of 38 PASSED**; only the classifier refused it | **FAILS at COMPILE TIME**: `Error (9582): Member "bondedOf" not found or not visible after argument-dependent lookup in address.` (and had it compiled, `test_theTwelveEscrowFieldsDecodeFromTheFourSlotsTheSnapshotCommitsTo` kills the permutation — E26 proves that in isolation) |
| **DX1 minus the `SafeERC20` degeneracy** — isolating which fix kills what | — | **FAILS**: `Suite result: FAILED. 41 passed; 1 failed` — only the Permit2 re-entrancy test, exactly as designed |
| **DE2** — `e.totalFunded = e.balance;` and nothing else | 38 of 38 | **42 of 42 PASSED**, and the layout gate accepts it. **Still the weakest surviving degenerate, and still unclosable in the deposit round**: `balance` and `totalFunded` diverge only after money leaves an escrow, and no path here takes money out. **The redeem round (`redeemVoucher`) owes the assertion.** |

### The layout gate, re-proved — three new controls and the `--update` hole

`--update` used to copy `forge inspect`'s output straight into the snapshot with no classification,
so an illegal change plus `--update` in one commit was a green gate that read as routine
maintenance in the diff (review F4). It now classifies first and refuses anything that is not
identical or an append; a deliberate redeploy takes `--redeploy-not-an-upgrade "<reason>"`, which
writes the reason, the timestamp and the classifier's refusal text **into the snapshot**, and still
exits non-zero.

| Control | Expected | Got | The gate said |
|---|---|---|---|
| I — a variable appended **after** `__gap`, gap left at 50 (F6) | REFUSED | **REFUSED** | `new variable afterTheGap sits at slot 59, at or AFTER the new gap at 9 -- __gap must remain the LAST declaration…` (previously classified APPEND) |
| J — `uint256[50] __gap` → `bytes32[50]` (F7) | REFUSED | **REFUSED** | `__gap in the new layout is bytes32[50]; it must stay uint256[N]` (previously classified APPEND) |
| K — the gap shrinks by 40 with no new field | REFUSED | **REFUSED** | `the gap shrank by 40 slots but the new fields consumed 0; they must be equal` |
| F4a — an illegal reorder **plus `--update`** | the snapshot must NOT be written | **REFUSED**, snapshot byte-identical afterwards (`shasum -c` OK) | `X402Escrow: --update REFUSED — this is not an append, and --update will not launder one.` |
| F4b — the same reorder through `--redeploy-not-an-upgrade "<reason>"` | written, loudly, still non-zero | **written**, `exit=1` | the snapshot gained `_redeploy: {reason, at, refusedBecause:[…], note:"…must be REDEPLOYED; upgrading one to this layout corrupts its storage."}`, and the next plain check printed `X402Escrow: layout unchanged — snapshot carries a REDEPLOY note: <reason>` |

Controls A-H from the first round were re-run unchanged against the fixed classifier and all eight
still give their recorded verdicts (`controls exit=0`, `restored GOOD: True`).

---

## `src/libraries/Voucher712.sol` and `X402Escrow.recoverVoucherSigner` / `_recover`

Every row: the mutation applied to one source file, the *named* test run on its own
(`forge test --match-contract X402EscrowDomainTest --match-test <name>`), the verbatim result, then
the file restored from a byte-exact `GOOD` copy and re-verified by SHA-256. Each mutation
is checked to match exactly one occurrence, and asserts the restore hash at the end (`restored GOOD: True`). Rows whose "named
test" column says WHOLE SUITE were run against `X402EscrowDomainTest` entire, because the property
they break is not one test's.

### What this round found before it found anything else: the test plan's own encoder test was inert

The test plan's `test_flippingAnySingleSignedFieldChangesTheRecoveredSigner` builds its eight variants
as

```solidity
Voucher[8] memory mutated;
for (uint256 i = 0; i < 8; i++) mutated[i] = base;   // <-- eight copies of ONE POINTER
mutated[0].payer = address(0xDEAD);
…
mutated[7].expiresAt = base.expiresAt + 1;
```

A `Voucher memory` is a reference. `mutated[i] = base` stores the same reference eight times, so
`mutated[0].payer = …` writes through to `base` itself and the next seven writes land on the same
object. By the assertion loop all eight entries are **one** voucher with **all eight** fields
changed — the test still passes, it has simply stopped being eight single-field flips.

That is not a stylistic problem. Measured, first run: replacing **any single member** of
`Voucher712.hashVoucher` with a constant — an encoder that does not sign that field at all —
**survived it**, eight times out of eight:

```
===== V1 | hashVoucher: the payer member -> the literal address(0x5Aa2…E598)
   [PASS] test_flippingAnySingleSignedFieldChangesTheRecoveredSigner() (gas: 89599)
   Suite result: ok. 1 passed; 0 failed
```

…and identically for V2-V8. The fix is `mutated[i] = _voucher();` — a fresh allocation per entry —
plus four assertions in the test that fail loudly if the array ever aliases again. Rows V1-V8 below
are the **re-run against the fixed test**, and all eight now die. Both runs are recorded because
the first one is the finding.

### The rows

| # | Guard | Mutation | Named test (expecting) | Observed |
|---|---|---|---|---|
| S1 | `_recover`: `if (sig.length != 65) revert InvalidSignature();` | deleted | `test_wrongSigner_aSixtySixByteSignatureIsRefused` (`InvalidSignature`) | **FAILED**: `[FAIL: next call did not revert as expected] test_wrongSigner_aSixtySixByteSignatureIsRefused() (gas: 29956)` — a 65-byte signature with one junk byte appended recovers to `buyer` and nothing refuses it |
| S1b | the same deletion | deleted | `test_wrongSigner_theCompactSixtyFourByteFormIsRefused` (`InvalidSignature`) | **FAILED**: `[FAIL: Error != expected error: BadSignatureV() != InvalidSignature()] (gas: 42175)`. **Read the observed error, and read why this row exists.** With the guard gone, `calldataload` at `sig.offset + 0x40` reads the word *past* the end of calldata, which is zero, so `v == 0` and the **v** guard refuses it. The compact form is still refused — by the wrong guard, with the wrong name. On its own this test would have "caught" the mutation only because it asserts the selector; a test asserting merely "it reverts" would have passed. S1 is the row that proves the length guard on its own merits, and it is why `test_wrongSigner_aSixtySixByteSignatureIsRefused` was added to the test plan's file list. |
| S2 | `_recover`: `if (uint256(s) > Constants.SECP256K1_HALF_N) revert MalleableSignature();` | deleted | `test_wrongSigner_aMalleatedSignatureIsRefused` (`MalleableSignature`) | **FAILED**: `[FAIL: Error != expected error: InvalidSignature() != custom error 0xf0ad0d09] (gas: 26992)` (`0xf0ad0d09` is `MalleableSignature()`). **What this measures, exactly.** OZ 5.1's `ECDSA.tryRecover(hash, v, r, s)` makes the same low-s test at `ECDSA.sol:143` and answers `RecoverError.InvalidSignatureS`, which guard 4 turns into `InvalidSignature`. So the *accept/refuse decision* on a malleated twin survives this deletion; what does not survive is the **name**. The guard is kept for the name — an operator reading `MalleableSignature` in a log knows a twin was submitted, where `InvalidSignature` says only "something was wrong with the bytes" — and this row is the honest statement of what it is worth. |
| S2b | the same guard | `>` → `>=` | `test_theLowSCeilingIsHalfNItselfAndTheGuardIsStrictlyAboveIt` | **FAILED**: `[FAIL: half n itself is legal] (gas: 29418)` — `SECP256K1_HALF_N` is the last **accepted** value under EIP-2 (`0 < s <= n/2`), not the first refused one. The boundary is read off the operator: −1 legal, exactly legal, +1 refused. |
| S3 | `_recover`: `if (v != 27 && v != 28) revert BadSignatureV();` | deleted | `test_wrongSigner_vOutsideTwentySevenAndTwentyEightIsRefused` (`BadSignatureV`) | **FAILED**: `[FAIL: Error != expected error: InvalidSignature() != custom error 0xd38922ec] (gas: 29300)` (`0xd38922ec` is `BadSignatureV()`) — `ecrecover` returns `address(0)` for `v = 29`, so the revert becomes `InvalidSignature`. Only the expected-selector assertion catches this. |
| S3b | the same guard | `v != 27 && v != 28` → `v > 28` | `test_vIsAcceptedAtTwentySevenAndTwentyEightAndRefusedEitherSideOfThem` | **FAILED**: `[FAIL: 26 is outside the set: 0x8baa579f… != 0xd38922ec…] (gas: 30138)` — `0x8baa579f` is forge-std's `assertTrue` failure, i.e. `v = 26` was not refused with `BadSignatureV`. A one-sided guard admits the 0/1 encoding some libraries emit, which `ecrecover` then answers with `address(0)`. |
| S4 | `_recover`: guard 4, the `signer == address(0)` **disjunct only** | `err != NoError \|\| signer == address(0)` → `err != NoError` | whole `X402EscrowDomainTest` | **SURVIVED** — `17 passed; 0 failed`. **Equivalent mutant, provably.** After guards 1-3, the only two states `ECDSA.tryRecover(hash, v, r, s)` can return are `NoError` with a non-zero signer and `InvalidSignature` with `address(0)` (`ECDSA.sol:143-153`; its third state, `InvalidSignatureS`, is unreachable here because guard 2 fired first, and `InvalidSignatureLength` belongs to the `bytes`-taking overload we do not call). So `signer == address(0)` and `err != NoError` are the *same predicate*, and no input can distinguish them. The test plan anticipated this and asked for "a hand-built `(v, r, s)` that recovers to zero without an OZ error" — **no such input exists**, so no test was written to pretend otherwise. |
| S5 | `_recover`: guard 4, the `err != NoError` **disjunct only** | → `signer == address(0)` | whole `X402EscrowDomainTest` | **SURVIVED** — `17 passed; 0 failed`. The other half of S4's equivalence, run in the other direction so the claim is symmetric rather than asserted. |
| S6 | `_recover`: guard 4 **entirely** | deleted | `test_wrongSigner_pureGarbageDoesNotRecoverToTheZeroAddress` (`InvalidSignature`) | **FAILED**: `[FAIL: next call did not revert as expected] (gas: 24739)` — `(r = 0, s = 1, v = 27)` "recovers" to `address(0)` and is handed back to the caller as a signer. S4/S5 say the two disjuncts are interchangeable; this says the pair is not optional. |
| S7 | `recoverVoucherSigner`: `_hashTypedDataV4(...)` | replaced with the bare struct hash | whole `X402EscrowDomainTest` | **FAILED**: `Suite result: FAILED. 12 passed; 5 failed`, including both replay tests — `[FAIL: assertion failed: 0x937a9bfd… != 0x5Aa2337f…] test_aVoucherSignedForOneChainDoesNotVerifyOnAnother()` and `[FAIL: assertion failed: 0x88b4D835… != 0x5Aa2337f…] test_aVoucherSignedForOneDeploymentDoesNotVerifyOnAnother()`, plus `test_happyPath_recoversThePayer`, `test_wrongSigner_anotherKeysSignatureRecoversToThatOtherKey` and the fuzz test. One mutation, two replay properties, which is why both tests exist. |
| S8 | `_recover`: guards 2 and 3 | order swapped — `v` checked before low-s | whole `X402EscrowDomainTest` | **SURVIVED** — `17 passed; 0 failed`. **Not an equivalent mutant**: the two orders disagree on a signature that is *both* high-s and `v ∉ {27,28}`, which gets `MalleableSignature` one way and `BadSignatureV` the other. Nothing in the suite submits one, because neither answer is wrong — both name a real defect in the same bytes, and the caller's behaviour (revert) is identical. Recorded as surviving with its reason rather than given a test that would pin an arbitrary tie-break. It is also degenerate W1 below. |
| E1 | `hashVoucher`: `VOUCHER_TYPEHASH` | → `SET_LIMITS_TYPEHASH` | whole `X402EscrowDomainTest` | **FAILED**: `Suite result: FAILED. 11 passed; 6 failed` — `test_theVoucherStructHashIsTheTypehashAndTheEightFieldsInDeclarationOrder` (`[FAIL: assertion failed: 0xa624973d… != 0x5393b0a5…]`), `test_happyPath_recoversThePayer`, both replay tests, `test_wrongSigner_anotherKeysSignatureRecoversToThatOtherKey` and the fuzz test. The distinct typehash per kind is what closes cross-kind replay; this is the row that proves it is actually in the preimage. |

**The eight field rows.** Each replaces one member of `hashVoucher`'s `abi.encode` with the literal
value that member has in the test's base voucher — arity unchanged, so the *base* voucher still
hashes correctly and only the flipped variant collides. That is the mutation that isolates
`test_flippingAnySingleSignedFieldChangesTheRecoveredSigner`; **dropping** a member instead
(row E9) changes the encoding for every voucher and is caught by the happy path rather than by the
flip test. All eight are run against the FIXED test.

| # | Member replaced by its literal | Named test | Observed |
|---|---|---|---|
| E2 | `v.payer` → `address(0x5Aa2337f51913D3e66494D24BE7690eAc751E598)` | `test_flippingAnySingleSignedFieldChangesTheRecoveredSigner` | **FAILED**: `[FAIL: a signed field was not actually signed] (gas: 44970)` |
| E3 | `v.provider` → `address(0x9309)` | the same | **FAILED**: `[FAIL: a signed field was not actually signed] (gas: 52758)` |
| E4 | `v.amount` → `uint64(250_000)` | the same | **FAILED**: `[FAIL: a signed field was not actually signed] (gas: 60543)` |
| E5 | `v.resourceHash` → `keccak256("https://example.test/search")` | the same | **FAILED**: `[FAIL: a signed field was not actually signed] (gas: 68464)` |
| E6 | `v.requestHash` → `keccak256("canonical request")` | the same | **FAILED**: `[FAIL: a signed field was not actually signed] (gas: 76284)` |
| E7 | `v.seq` → `uint64(1)` | the same | **FAILED**: `[FAIL: a signed field was not actually signed] (gas: 83899)` |
| E8 | `v.issuedAt` → `uint64(1_760_000_000)` | the same | **FAILED**: `[FAIL: a signed field was not actually signed] (gas: 91685)` |
| E8b | `v.expiresAt` → `uint64(1_760_000_300)` | the same | **FAILED**: `[FAIL: a signed field was not actually signed] (gas: 99446)` |

| # | Guard | Mutation | Named test | Observed |
|---|---|---|---|---|
| E9 | `hashVoucher`: `v.seq` | **dropped** from `abi.encode` entirely | `test_flippingAnySingleSignedFieldChangesTheRecoveredSigner` | **SURVIVED**: `1 passed; 0 failed` — see the correction below |
| E9b | the same deletion | | whole `X402EscrowDomainTest` | **FAILED**: `Suite result: FAILED. 11 passed; 6 failed` — `test_happyPath_recoversThePayer` (`[FAIL: assertion failed: 0xE645e002… != 0x5Aa2337f…]`), both replay tests, the struct-hash test, `test_wrongSigner_anotherKeysSignatureRecoversToThatOtherKey` and the fuzz test |
| E10 | `hashVoucher`: `v.issuedAt` / `v.expiresAt` | transposed | `test_theVoucherStructHashIsTheTypehashAndTheEightFieldsInDeclarationOrder` | **FAILED**: `[FAIL: assertion failed: 0x1a585c34… != 0x5393b0a5…] (gas: 2.30ms)`. This is exactly the Anchor F-13 hazard (`attestation.rs:437-450`: "transposing the pair still yields 239 bytes and still passes every length assert, and both fields are `i64`") in its EIP-712 form — both members are `uint64`, so nothing but this assertion distinguishes the two orders. |
| E11 | `hashSetLimits`: `nonce` / `deadline` | transposed | `test_theSetLimitsAndRequestWithdrawHashesEncodeTheirArgumentsInOrder` | **FAILED**: `[FAIL: assertion failed: 0xa2316da9… != 0x56a71bb9…]` |
| E12 | `hashRequestWithdraw`: `nonce` / `deadline` | transposed | the same | **FAILED**: `[FAIL: assertion failed: 0x4e709078… != 0xc6c233b5…]` |

### Where this log disagrees with the test plan

Two of the test plan's predictions are measurably wrong, and both were reproduced twice.

| Source | What it predicted | What is actually true |
|---|---|---|
| test plan | "any single field in `abi.encode` in `hashVoucher` — drop `v.seq` → `test_flippingAnySingleSignedFieldChangesTheRecoveredSigner` at index 5" | **Dropping** a member changes the encoding of *every* voucher, base included, so the flip test's `!= buyer` holds for all eight indices and it **passes** (row E9, measured twice). What kills a dropped member is `test_happyPath_recoversThePayer` (row E9b). The mutation that isolates the flip test is **substituting the base value**, arity unchanged — rows E2-E8b. Both forms are run here; only one of them says what the test plan thinks it says. |
| test plan | on deleting `signer == address(0)`: "if it does [survive], add a test that calls `_recover` through a harness with a hand-built `(v, r, s)` that recovers to zero without an OZ error" | It survives (S4), and **that test cannot exist**: OZ's `tryRecover(hash, v, r, s)` returns `address(0)` **iff** it returns `RecoverError.InvalidSignature` (`ECDSA.sol:148-153`), so the two disjuncts are one predicate. The guard is recorded as an equivalent mutant with the argument, and the pair is proved together by S6. |

Also worth stating because a reader will look for it: the test plan's `test_wrongSigner_pureGarbageDoesNotRecoverToTheZeroAddress` fills 64 bytes with `0xAB`, and `0xABAB…` **exceeds** `SECP256K1_HALF_N` (`0x7FFF…`), so that signature is refused by guard 2 with `MalleableSignature` and the test as written fails against the correct implementation. The garbage here is `(r = 0, s = 1, v = 27)`: `r` must be a curve point's x-coordinate in `[1, n-1]`, so `r = 0` returns `address(0)` deterministically rather than about half the time, and `s = 1`/`v = 27` keep guards 2 and 3 from firing first. Same for the test plan's `require(sig.length == 65, "not 65 bytes")` in `VoucherSigner.malleate` — a revert string, which this repo does not have anywhere; it is a named error.

### The degenerates

Each is the whole repo suite (`forge test`, 9 suites, 157 tests), not only the domain file.

| # | Degenerate | Result |
|---|---|---|
| G1 | **`_recover` ignores `v`**: `ECDSA.tryRecover(digest, 27, r, s)`, the guard left in place | **DIES**: `154 tests passed, 3 failed` — `test_happyPath_recoversThePayer`, `test_aVoucherSignedForOneDeploymentDoesNotVerifyOnAnother`, `testFuzz_recoverIsTheInverseOfSignForAnyKeyAndAnyVoucher`. The fixture's buyer signs with `v = 28`, so the happy path recovers a stranger; the fuzz test would kill it for whichever constant were chosen. |
| G2 | **`hashVoucher` ignores one field**: `v.requestHash` dropped | **DIES**: `151 tests passed, 6 failed` — the struct-hash test, the happy path, both replay tests, `test_wrongSigner_anotherKeysSignatureRecoversToThatOtherKey`, the fuzz test |
| G3 | **the domain separator ignores `chainId`**: a hand-built `EIP712Domain(string name,string version,address verifyingContract)` used by `DOMAIN_SEPARATOR()` **and** by the digest, so the happy path still agrees with the signer | **DIES**: `155 tests passed, 2 failed` — `test_aVoucherSignedForOneChainDoesNotVerifyOnAnother` (this round) and `test_theDomainSeparatorIsTheProxysAndNamesX402Settlement` (the deposit round). Note it takes a *pair* of tests: the deposit round's one pins the separator's shape, this one pins that it follows `block.chainid`. |
| G4 | **`recoverVoucherSigner` returns `v.payer`** and never recovers anything | **DIES**: `145 tests passed, 12 failed` — every guard test, both replay tests, the flip test, the boundary tests and the cross-kind test |

### The degenerates that SURVIVE, recorded rather than hidden

| # | Degenerate | Result and what it means |
|---|---|---|
| W1 | guards 2 and 3 in the other order (`v` before low-s) — the same source change as S8 | **SURVIVES**: `157 tests passed, 0 failed`. **The weakest surviving degenerate of this round.** The two orders differ only on bytes that are simultaneously high-s and `v ∉ {27,28}`, where they name different (both true) defects. The contract's own comment claims the order is load-bearing "so a malleated twin is diagnosed as malleable"; that claim is true of a *twin* (whose `v` is always 27 or 28, so it reaches guard 2 either way) and is **not** enforced for arbitrary bytes. A reviewer should read the comment as documenting a preference, not an invariant. |
| W2 | `recoverVoucherSigner` declared `external` instead of `public` | **SURVIVES**: `157 tests passed, 0 failed`. Nothing in the suite calls it internally yet; **The redeem round's `redeemVoucher` is what makes `public` load-bearing**, and until that call site exists no test can tell the two apart. |
| W3 | `Voucher712.hashVoucher` takes `Voucher memory` rather than `Voucher calldata` | **SURVIVES**: `157 tests passed, 0 failed`. Behaviourally identical — the difference is a memory copy per call, i.e. gas. `gas_reports` in `foundry.toml` is where that would show, and no test asserts a gas number. |

### Follow-up round 1

The review's own degenerate **passed all 157 tests**: six degeneracies already logged as
survivors (guards 2/3 swapped, `external`, `memory`, OZ replaced by a bare `ecrecover`, guard 4
reduced to one disjunct) **plus a forgery backdoor**:

```solidity
if (r == bytes32(0) && uint256(s_) == 2) return v.payer;   // every escrow, spendable by anybody
```

`r` is a curve point's x-coordinate and must lie in `[1, n-1]`, so no honest signature ever carries
`r == 0`; the one test that presented `r == 0` used `s == 1`. **Every test in the file handed
`_recover` either a real signature or a malformed one — none handed it an adversarially chosen
WELL-FORMED one**, so a single line in an uninhabited corner of the input space was invisible. A
recovery suite that cannot see a hardcoded forgery is not a recovery suite, whatever its row count.

Five tests were added (22 in the file now, 162 in the repo). The procedure is the same as before — one textual mutation per row, the named test, restore from a byte-exact
`GOOD` copy, `restored GOOD: True`.

| # | Mutation | Named test (expecting) | Observed |
|---|---|---|---|
| F1 | **the review's degenerate, entire** — `memory` hash + both auxiliary hashes reading only `buyer` + OZ import dropped + `external` + the `r==0 && s==2` backdoor + guards 2/3 swapped + bare `ecrecover` with guard 4 halved | whole repo suite | **DIES**: `Ran 9 test suites …: 159 tests passed, 3 failed, 0 skipped (162 total tests)` — `[FAIL: a hand-built (r, s, v) was accepted as the payer] test_noSmallStructuredSignatureEverRecoversToThePayer() (gas: 116237)` plus both auxiliary-hash fuzz tests |
| F2 | **the backdoor ALONE**, on otherwise shipped source | whole repo suite | **DIES**: `161 tests passed, 1 failed` — `[FAIL: a hand-built (r, s, v) was accepted as the payer] test_noSmallStructuredSignatureEverRecoversToThePayer() (gas: 115317)`. **Read which test caught it.** `testFuzz_noHandBuiltSignatureEverRecoversToThePayer` did **not**: a fuzzer drawing `bytes32` uniformly never produces `r == 0, s == 2`, and 512 runs did not. The deterministic sweep over small structured values is the half that carries this property; the fuzz covers the rest of the space and a backdoor keyed on a voucher field. Both are needed and neither is decoration. |
| F3 | `hashSetLimits`: all four `uint64` arguments → the pinning vector's literals (111/222/333/444) | `testFuzz_theSetLimitsHashReadsAllFiveOfItsArguments` | **FAILED**: `[FAIL: assertion failed: 0xcdb4b959… != 0xf27c27ef…; counterexample: …]` |
| F3b | the same substitution, against the ONE-VECTOR test that was its only cover before | `test_theSetLimitsAndRequestWithdrawHashesEncodeTheirArgumentsInOrder` | **SURVIVED**: `1 passed; 0 failed` — the finding, reproduced. One vector proves transposition and never substitution. |
| F4 | `hashRequestWithdraw`: all three `uint64` arguments → the vector's literals (555/666/777) | `testFuzz_theRequestWithdrawHashReadsAllFourOfItsArguments` | **FAILED**: `[FAIL: assertion failed: 0x91760291… != 0xf2b6ea41…; counterexample: …]` |
| F5 | the TEST regressed to the aliasing form `mutated[i] = base` (the review's CTRL-1) | `test_flippingAnySingleSignedFieldChangesTheRecoveredSigner` | **FAILED**: `[FAIL: base must be untouched by the writes above: 0x…dEaD != 0x5Aa2337f…]` |
| F5b | the same regression **with anti-aliasing assertions 1-3 deleted** — does the fourth carry it alone? | the same | **FAILED**: `[FAIL: and voucher 7 does not carry voucher 5's: 2 != 1] (gas: 28720)`. Before this fix round the fourth assertion compared `mutated[7].seq` against `base.seq`, which under aliasing are the same object and the same number — inert. It now compares against `pristine`, a third allocation, and this row is the proof that it is no longer inert. |
| F6 | a second recovery call site in ANOTHER `src/` file (`X402Config.sneak` calling `ecrecover`) | `test_recoveryHappensAtExactlyOneCallSiteInSrc` | **FAILED**: `[FAIL: recovery outside the file that owns it: …/evm/src/X402Config.sol] (gas: 30054537)` |
| F7 | a second recovery call site in the **same** file (`X402Escrow.sneak` calling `ECDSA.tryRecover`) | the same | **FAILED**: `[FAIL: there must be exactly one recovery call site in src/: 2 != 1] (gas: 56130506)`. This is why the gate **counts** rather than checking location only — `check-vendor.sh`'s header makes the same argument in the other direction. |
| F8 | **the residual degenerate** — the review's, minus the backdoor and the two auxiliary-hash substitutions | whole repo suite | **SURVIVES**: `162 tests passed, 0 failed`. The new weakest survivor; its source is not reproduced here. |

**The gate found the rule was written down wrong.** `test_recoveryHappensAtExactlyOneCallSiteInSrc`
was first written to count `ecrecover(` and reported `0 != 1`: `src/` contains no `ecrecover` at
all, because the precompile is reached through the vendored OZ library under `lib/` and what `src/`
holds is the `ECDSA.tryRecover(` that calls it. It now counts all three spellings — `ecrecover(`,
`ECDSA.tryRecover(`, `ECDSA.recover(` — on non-comment lines, which is the more useful form of the
rule: what must be unique is the **call site**, not the spelling. It does **not** forbid swapping
OZ for a bare `ecrecover` inside the owning file, and F8 confirms that swap still survives; what it
forbids is a *second* recovery anywhere.

### Rows S2, S4 and S5, amended

Three corrections the review is right about, made in place rather than argued with.

- **S2 understated its own coverage.** Two tests fail when the low-s guard is deleted, not one:
  `test_wrongSigner_aMalleatedSignatureIsRefused` and, measured in review,
  `[FAIL: half n + 1 is not: 0x8baa579f… != 0xf0ad0d09…] test_theLowSCeilingIsHalfNItselfAndTheGuardIsStrictlyAboveIt() (gas: 37367)` → `155 tests passed, 2 failed`. The per-row method here is
  "run one named test", and that is what hid the second; the row is accurate about the test it
  names and was incomplete about the rest.
- **S2, S4 and S5 all hold ONLY while `ECDSA.tryRecover` is the call underneath.** "Name-only" and
  "equivalent mutant" are statements about these guards *together with OZ*, never about the guards
  alone. As written the three rows were exactly the argument a future engineer would cite for
  deleting them — and the review's control `w12` measures what that costs: bare `ecrecover`
  **plus** the low-s deletion gives `[FAIL: next call did not revert as expected]
  test_wrongSigner_aMalleatedSignatureIsRefused()` — the malleated twin **accepted**,
  `155 passed, 2 failed`. Each change is behaviour-preserving alone and unsafe together. Anyone
  who drops OZ owns guards 2 and 4 from that moment. The same sentence is now in `_recover`'s
  natspec, because a reader of the code does not read this file.
- **S8/W1's claim is now in the contract too.** The ordering comment used to read as an invariant;
  it says "preference, measured to survive" in the source as of this fix round.

---

## `src/X402Escrow.sol`: `redeemVoucher`, `_redeem`, `setLimits`

The first path that pays money out. Every guard on it is broken one at a time, the *named* test is
run alone, and the file is restored from a byte-exact `X402Escrow.sol.t10GOOD` copy whose SHA-256
is compared after the restore — `restored GOOD: True` on every row below.

**How these rows were run, and why that is worth stating.** The build machine was heavily loaded,
and one serial row measured `real 290 / user 23` — nearly five minutes of wall clock for
twenty-three seconds of work. Rows R4 onward were therefore run in **six disjoint COPIES
of `evm/`**, in parallel, each worker owning its own `out/`, `cache/` and `GOOD` file. No worker
ever touched another's file and none touched the repository; R1-R3 ran serially in the repository
before the switch. Uniquely-named `*.t10GOOD` backup files throughout, because a generic name once let one run
silently revert another's source file while the suite stayed green.

**Three kinds of row appear below and the difference is the point.**

- **Guard rows (R1-R26, R34-R35)** — one guard broken; the named test must fail *with the named
  error*, not merely fail.
- **Order rows (R27-R32)** — two checks *transposed*. Single-violation tests cannot see order by
  construction, so these are the only cover the check list's ORDER has, and R27/R28 are what pin
  the two deliberate divergences from `redeem_voucher.rs`.
- **Control rows (C1, C2/C2b)** — mutations applied to the TEST file, asserting that a particular
  assertion is live rather than decorative.

### Guards

| # | Guard | Mutation | Named test | Observed |
|---|---|---|---|---|
| R1 | `redeemVoucher`: `msg.sender != p.redeemer` | branch deleted | `test_wrongSigner_onlyTheConfiguredRedeemerMaySubmit` | **FAILED**: `[FAIL: next call did not revert as expected] test_wrongSigner_onlyTheConfiguredRedeemerMaySubmit() (gas: 181412)` |
| R2 | `redeemVoucher`: `CONFIG.paused()` | branch deleted | `test_wrongState_redeemIsClosedWhilePaused` | **FAILED**: `[FAIL: next call did not revert as expected] test_wrongState_redeemIsClosedWhilePaused() (gas: 190647)` |
| R3 | `v.amount == 0` | branch deleted | `test_wrongState_zeroAmountIsRefused` | **FAILED**: `[FAIL: next call did not revert as expected] test_wrongState_zeroAmountIsRefused() (gas: 90205)` |
| R4 | `v.expiresAt <= v.issuedAt` | branch deleted | `test_boundary_theVoucherClockWindowIsBoundedAtBothEnds` | **FAILED**: `[FAIL: next call did not revert as expected] test_boundary_theVoucherClockWindowIsBoundedAtBothEnds() (gas: 181994)` — a voucher whose window is a point, or inverted, is admitted |
| R5 | lifetime bound `>` | → `>=` | the same | **FAILED**, for the stated reason: `[FAIL: VoucherLifetimeTooLong()] test_boundary_theVoucherClockWindowIsBoundedAtBothEnds() (gas: 131679)` — the EXACT 300-second lifetime is refused. This is the row the "admits its own value" half of the test exists for |
| R5b | the same bound | branch deleted | the same | **FAILED**: `[FAIL: next call did not revert as expected] … (gas: 292188)` |
| R6 | clock-skew bound `>` | → `>=` | the same | **FAILED**: `[FAIL: VoucherNotYetValid()] … (gas: 301808)` — exactly `now + 120` refused |
| R7 | redeem-grace bound `>` | → `>=` | the same | **FAILED**: `[FAIL: VoucherExpired()] … (gas: 351692)` — exactly `expiresAt + 1800` refused |
| R8 | `v.seq == 0` | branch deleted | `test_boundary_theSequenceMustStrictlyIncrease` | **FAILED**, with the DIAGNOSIS the test plan predicted: `[FAIL: Error != expected error: VoucherSeqNotIncreasing() != custom error 0x517f98f0] … (gas: 316265)`. `0x517f98f0` is `VoucherSeqZero`; seq 0 is still refused, by the wrong guard and under the wrong name |
| R9 | `v.seq <= e.seqHigh` | → `<` | the same | **FAILED**: `[FAIL: next call did not revert as expected] … (gas: 320687)` — **the double-spend**: a seq EQUAL to `seqHigh` is admitted, so a served voucher can be redeemed twice |
| R9b | `e.seqHigh = v.seq;` (**named degenerate 4a**) | statement deleted | the same | **FAILED**: `[FAIL: assertion failed: 0 != 5] … (gas: 221354)` |
| R9c | `e.seqHigh = v.seq;` (**named degenerate 4b**) | → `= v.seq + 1;` | the same | **FAILED**: `[FAIL: assertion failed: 6 != 5] … (gas: 223189)` |
| R10 | `_recover(…) != v.payer` | → `== address(0)` | `test_wrongSigner_aVoucherSignedByAnotherKeyIsRefused` | **FAILED**: `[FAIL: next call did not revert as expected] … (gas: 179241)` — any key's signature spends the buyer's escrow |
| R11 | `v.amount > e.maxVoucherAmount` | → `>=` | `test_boundary_thePerCallCeilingAdmitsItsOwnValue` | **FAILED**: `[FAIL: VoucherExceedsPerCallLimit()] … (gas: 202177)` — the exact ceiling refused |
| R12 | `spent > e.maxPerWindow` | → `>=` | `test_boundary_theRollingWindowCapAdmitsItsOwnValueAndThenDrains` | **FAILED**: `[FAIL: EscrowWindowLimitExceeded()] … (gas: 305194)` — the exact cap refused |
| R13 | `Window.decay(e.spentInWindow, e.windowStartedAt, nowTs)` | → `e.spentInWindow` | the same | **FAILED**: `[FAIL: EscrowWindowLimitExceeded()] … (gas: 372673)` — the window never drains, so the second half of the test cannot spend |
| R14 | `STAKE.bondedOf(v.provider) < p.minimumStake` | branch deleted | `test_wrongState_anUnderStakedProviderIsNotPaid` | **FAILED**: `[FAIL: next call did not revert as expected] … (gas: 184644)` |
| R15 | the same bound | `<` → `<=` | the same | **FAILED**: `[FAIL: ProviderBelowMinimumStake()] … (gas: 131563)` — the floor stops being inclusive; a provider staked to exactly the minimum stops being paid |
| R16 | `e.balance < v.amount` | branch deleted | `test_boundary_theBalanceAdmitsExactlyWhatIsThere` | **FAILED**, exactly as the test plan predicted: `[FAIL: Error != expected error: panic: arithmetic underflow or overflow (0x11) != custom error 0x71de3750] … (gas: 220040)`. The money is still safe without it — `e.balance -=` refuses — but the guard's job is the DIAGNOSIS, and `0x71de3750` is `EscrowInsufficient` |
| R17 | `e.spentInWindow = uint64(spent);` (**named degenerate 1**) | statement deleted | `test_boundary_theRollingWindowCapAdmitsItsOwnValueAndThenDrains` | **FAILED**: `[FAIL: assertion failed: 0 != 5000000] … (gas: 321837)` |
| R17b | the same | the same | `test_happyPath_theProviderIsPaidAmountMinusFeeAndTheTreasuryTheFee` | **FAILED**: `[FAIL: assertion failed: 0 != 250000] … (gas: 204168)` — two independent tests carry it |
| R18 | `e.windowStartedAt = nowTs > e.windowStartedAt ? nowTs : e.windowStartedAt;` | → `= nowTs;` | `test_theWindowAnchorNeverMovesBackwards` | **FAILED**: `[FAIL: the anchor never moves back: 1760000000 != 1760010000] … (gas: 229102)`. **Read this row with its reachability attached**: `block.timestamp` is non-decreasing on a real chain and this field is only ever written from it, so on chain the two spellings are indistinguishable. The test reaches the difference with `vm.warp` backwards. It is kept because `state.rs:609-611` keeps it, and because "unreachable today" is a property of the caller, not of the line |
| R19 | `totalEscrowed -= v.amount;` (**named degenerate 3**) | statement deleted | `test_happyPath_theProviderIsPaidAmountMinusFeeAndTheTreasuryTheFee` | **FAILED**: `[FAIL: assertion failed: 10000000 != 9750000] … (gas: 208388)` |
| R20 | `e.totalRedeemed += v.amount;` | statement deleted | the same | **FAILED**: `[FAIL: assertion failed: 0 != 250000] … (gas: 189248)` |
| R21 | `safeTransfer(v.provider, providerAmount)` (**named degenerate 2**) | → `safeTransfer(v.provider, v.amount)` | the same | **FAILED**: `[FAIL: assertion failed: 250000 != 225000] … (gas: 184854)` |
| R21b | the same mutation | — | `test_happyPath_theSplitNeverLosesABaseUnit` | **SURVIVED**: `1 passed; 0 failed`. **The finding, reproduced deliberately.** That test's amount is 7 at a 10% rate, so `fee == 0` and gross *is* net: an assertion on the SUM `provider + treasury == amount` cannot see a provider paid the gross, and neither can a value assertion at an amount where the split is trivial. It is a real test of the indivisible case and no test of the split. R21 is the row that carries the split, and it carries it because the happy path pins 225_000 and 25_000 **separately** rather than relating them |
| R22 | both `safeTransfer` calls | deleted | `test_happyPath_theProviderIsPaidAmountMinusFeeAndTheTreasuryTheFee` | **FAILED**: `[FAIL: assertion failed: 0 != 225000] … (gas: 120556)` — the balance falls and nobody is paid |
| R23 | `Fee.splitFee(v.amount, p.takeRateBps)` | → `Fee.splitFee(v.amount, 1_000)` (the fixture's rate, hardcoded) | `test_theTakeRateAndTheTreasuryAreReadAtRedemptionTime` | **FAILED**: `[FAIL: log != expected log] … (gas: 207991)` |
| R24 | `safeTransfer(p.treasury, fee)` | → `safeTransfer(v.provider, fee)` | `test_happyPath_theProviderIsPaidAmountMinusFeeAndTheTreasuryTheFee` | **FAILED**: `[FAIL: assertion failed: 250000 != 225000] … (gas: 160904)` |
| R25 | `_setLimits`: the `EscrowLimitsUnchanged` guard | branch deleted | `test_wrongState_setLimitsRefusesAWriteThatChangesNothing` | **FAILED**: `[FAIL: next call did not revert as expected] … (gas: 25183)` |
| R26 | `_credit`: `e.totalFunded += amount;` (**named degenerate 5 — the debt the deposit round left**) | → `e.totalFunded = e.balance;` | `test_totalFundedIsALifetimeSumOfDepositsAndNeverFollowsTheBalanceDown` | **FAILED**: `[FAIL: totalFunded is the SUM of deposits, not a restatement of the balance: 10150000 != 10400000] … (gas: 280635)`. **This is the row the deposit round could not have.** With nothing spending, the alias is exact on every reachable path and it passed all 162 the voucher-signature round tests. Killing it takes THREE steps, not two — deposit, redeem, **deposit again** — because after a redemption alone the aliased counter still holds the value it was assigned before the spend, and an assertion made there passes against the alias too |
| R34 | `if (fee > 0)` on the treasury transfer | guard deleted | `test_aBlocklistedTreasuryOwedNothingDoesNotHaltThePayout` | **FAILED**: `[FAIL: Blocked(0x0000000000000000000000000000000000007EA5)] … (gas: 198971)`. Without that test the mutation is invisible: `MockUSDG` accepts a zero-value transfer happily, and only its Paxos-style blocklist makes `safeTransfer(treasury, 0)` a call that can fail. At a 0% take rate a blocklisted treasury would otherwise halt every payout in the system |
| R35 | `if (providerAmount > 0)` on the provider transfer | guard deleted | the whole `X402EscrowRedeemTest` contract | **SURVIVED**: `Suite result: ok. 30 passed; 0 failed`. **Recorded as unreachable rather than dressed up.** `providerAmount == 0` requires `fee == amount`, i.e. `takeRateBps == 10_000`, and `X402Config._validate` caps it at `MAX_TAKE_RATE_BPS = 3_000`. No configuration this contract will accept can reach the branch. It mirrors `redeem_voucher.rs:170` and is kept for that symmetry, not for safety |

### Order — the rows that are the only cover the check LIST has

A suite of single-violation tests passes against **any** permutation of the checks. Each row here
transposes two of them and names the test that notices.

| # | Transposition | Named test | Observed |
|---|---|---|---|
| R27 | **the seq admission moved BELOW the signature** — i.e. back to `redeem_voucher.rs:137-144`'s own order | `test_divergence_theSequenceIsCheckedBeforeTheSignature` | **FAILED**: `[FAIL: Error != expected error: SignerIsNotPayer() != VoucherSeqNotIncreasing()] … (gas: 201359)`. **This row is deliberate divergence 1, made visible.** The EVM design checks `seq` first; the Anchor program checks it second; this contract follows the EVM design and this is the test that says which |
| R28 | **the stake floor moved BELOW the balance check** | `test_divergence_theStakeFloorIsCheckedBeforeTheBalance` | **FAILED**: `[FAIL: Error != expected error: EscrowInsufficient() != ProviderBelowMinimumStake()] … (gas: 87250)`. **Deliberate divergence 2, made visible**: `ProviderBelowMinimumStake` is in no check list of the EVM design and is reinstated at `redeem_voucher.rs:148-153`'s position — after the window limit, before the balance |
| R29 | the per-call ceiling moved BELOW the window cap | `test_theCheckOrderIsTheOneTheSpecNames` | **FAILED**: `[FAIL: Error != expected error: EscrowWindowLimitExceeded() != VoucherExceedsPerCallLimit()] … (gas: 398135)` |
| R30 | `ZeroAmount` moved BELOW the first clock-window check | the same | **FAILED**: `[FAIL: Error != expected error: InvalidVoucherWindow() != ZeroAmount()] … (gas: 127307)` |
| R32 | the pause check moved ABOVE the redeemer pin | the same | **FAILED**: `[FAIL: Error != expected error: ProgramPaused() != NotRedeemer()] … (gas: 65394)` |

**One pair in the list is unreachable and has no row.** "not yet valid" and "expired" cannot both
hold: `VoucherNotYetValid` needs `issuedAt > now + 120` and `VoucherExpired` needs
`now > expiresAt + 1800`, while `expiresAt > issuedAt` is enforced two lines above them — so
`expiresAt > issuedAt > now` makes the second condition false. There is no voucher that violates
both, and therefore no test that can order them. Said here rather than left as a gap in the table.

### Effects before interactions — both halves

| # | Mutation | Named test | Observed |
|---|---|---|---|
| R31 | `nonReentrant` deleted from `redeemVoucher`, **effects left where they are** | `test_wrongState_aReentrantAssetCannotRecurseIntoRedeemVoucher` | **FAILED**: `[FAIL: Error != expected error: VoucherSeqNotIncreasing() != ReentrancyGuardReentrantCall()] … (gas: 1276846)`. **Read the observed error.** With the effects written first, the nested redemption is refused by the SEQ guard, not by the modifier — the money never moves. The two defences overlap, and this row says so instead of letting the modifier take credit for the seq rule's work |
| R33 | `nonReentrant` deleted **AND** the interactions moved above the effects | scratch probe `X402EscrowT10ReentrancyProbe.t.sol` (never committed), asserting the DOUBLE payment | **PROBE PASSED — the double spend is real**: `[PASS] test_probe_theSameVoucherPaysTwice() (gas: 1288699)`, i.e. `evil.balanceOf(provider) == 450_000`, `evil.balanceOf(treasury) == 50_000` and `seqHigh == 1` for one 250_000 voucher. This is the half R31 cannot show, and it is why the ordering is a rule rather than a style preference |

The adversary is `RedeemReentrantUSDG` in `test/helpers/MockUSDG.sol` — a token that re-enters from
`transfer` (the payout) rather than from `transferFrom` (the funding), which is what makes it able
to prove something the funding doors' `ReentrantUSDG` cannot: rows E4 and E23 record that on
`depositFor`/`depositWithPermit2` the modifier's deletion is caught by the measured-delta assertion
and not by the guard. A payout has no delta to fall back on. In the shipped test the token is ALSO
made the configured redeemer, so the nested call would clear `onlyRedeemer` too and the guard is
the only thing left refusing it.

### Controls — is the assertion live?

| # | Mutation (to the TEST file) | Named test | Observed |
|---|---|---|---|
| C1 | the re-entrancy test's `vm.expectCall(…, 2)` → `…, 3` | `test_wrongState_aReentrantAssetCannotRecurseIntoRedeemVoucher` | **FAILED**: `[FAIL: expected call to 0xA4AD…828c with data 0x73f9b9b0… to be called 3 times, but was called 2 times] … (gas: 1286547)`. The count is live, and it is the only thing that can assert the nested call was ATTEMPTED: `evil.didReenter()` cannot be read afterwards, because the outer call reverts and that unwinds the mock's storage with the escrow's |
| C2 | the eight field flips regressed to `Voucher memory t = signed;` — the aliasing form | `test_flipOneSignedField_everyFieldIsBound` | **FAILED**: `[FAIL: SignerIsNotPayer()] … (gas: 420226)`. **Read WHICH assertion caught it.** Not the anti-aliasing `assertEq`s — the POSITIVE CONTROL's own revert, because under aliasing the struct handed to the final successful redemption is the tampered one. The `assertEq`s (now including `signed.payer`) are the second line and exist so the failure names the cause rather than saying `SignerIsNotPayer` |
| C2b | the same, re-run after `assertEq(signed.payer, buyer, …)` was added | the same | **FAILED, now for the stated reason**: `[FAIL: the signed struct was rewritten by a flip above: 0xe05fcC23807536bEe418f142D19fa0d21BB0cfF7 != 0x5Aa2337f51913D3e66494D24BE7690eAc751E598] … (gas: 376609)`. C2 and C2b together are the argument for the third assertion: without it the aliasing regression is caught, but by a message that names the wrong thing |

### The degenerates

A mutation breaks one guard; a **degenerate** replaces the implementation with something trivially
wrong and asks what the suite would still accept.

| # | Degenerate | Scope run | Observed |
|---|---|---|---|
| DG1 | **all five named degenerates at once** — `spentInWindow` never written, the provider paid the gross, `totalEscrowed` never decreased, `seqHigh = seq + 1`, `totalFunded = balance` | the whole repository suite | **DIES**: `Ran 10 test suites: 175 tests passed, 18 failed, 0 skipped (193 total tests)`. Eighteen distinct tests, including `[FAIL: totalFunded is the SUM of deposits, not a restatement of the balance: 10150000 != 10400000]`, `[FAIL: assertion failed: 250000 != 225000] test_happyPath_theProviderIsPaidAmountMinusFeeAndTheTreasuryTheFee`, `[FAIL: the provider gets the rest: 16566 != 14910; counterexample: … args=[16566]] testFuzz_theSplitPaysBothSidesAndTheCountersFollow` and `[FAIL: panic: arithmetic underflow or overflow (0x11)] test_boundary_theBalanceAdmitsExactlyWhatIsThere` |
| DG2 | **the weakest survivor** — every change below is provably behaviour-preserving or provably unreachable: `setLimits` loses `nonReentrant` (it makes no external call); the three `Constants` in the clock window replaced by their literal values `300`/`120`/`1800`; `_recover(_hashTypedDataV4(Voucher712.hashVoucher(v)), sig)` replaced by the `public` `recoverVoucherSigner(v, sig)` (one extra hash, same answer, still exactly one recovery call site); `uint256 spent` narrowed to `uint64 spent`; `Fee.splitFee` inlined as `uint64((uint256(v.amount) * p.takeRateBps) / 10_000)` with the remainder by subtraction; the event's `spentInWindow` read back from storage | the whole repository suite | **SURVIVES**: `Ran 10 test suites: 193 tests passed, 0 failed, 0 skipped (193 total tests)`. Its source is in the review. Two of the six are worth a reader's attention rather than a shrug: `uint64 spent` turns a `carried + amount` overflow from `EscrowWindowLimitExceeded` into `Panic(0x11)` — both refuse, and reaching it needs `carried` near `2^64`, which needs a balance near `2^64`; and inlining `Fee.splitFee` drops the shared `MathOverflow` narrowing, which cannot fire while `takeRateBps <= 3_000` but stops being checked anywhere if that cap ever moves |

### Fix round 1 — the address dimension, and the two orderings nothing pinned

Review of redeem round requested changes on one finding, and it is the worst kind this
project has produced twice now: **a guard tested at a single point is a guard tested nowhere.**

Every negative signature test in the first draft used the fixture's own `buyer` and its own
`provider`, so `_redeem`'s signature comparison was only ever exercised at ONE `(payer, provider)`
point. The review wrote a bypass keyed on a different address —

```solidity
if (v.provider != address(uint160(0xBADC0DE)) && recoverVoucherSigner(v, sig) != v.payer) {
    revert SignerIsNotPayer();
}
```

— which passed **193 of 193** tests, and then moved **900 000** out of a funded buyer's escrow on a
voucher carrying sixty-five zero bytes for a signature. `&&` short-circuits, so the recovery is
never even called. It is the second signature-forgery backdoor to walk through a suite in this project;
The voucher-signature round's row F2 was `r == 0 && s == 2` inside `_recover`. Same lesson, one layer up.

Five tests were added (36 in the file, 198 in the repo) and one library extracted. Rows below ran in
six disjoint copies of `evm/` plus three standalone ones, `*.t10GOOD` restores SHA-256 verified,
`restored GOOD: True` on every row.

| # | Mutation | Named test / scope | Observed |
|---|---|---|---|
| X1 | **the review's provider-keyed bypass, ALONE**, on otherwise shipped source | whole suite | **NOW DIES**: `Suite result: FAILED. 34 passed; 2 failed; 0 skipped` — `[FAIL: next call did not revert as expected] test_noProviderAddressIsExemptFromTheSignatureGuard() (gas: 549232)` **and** `[FAIL: the signature guard is not the exact unconditional comparison this test pins: 0 != 1] test_theSignatureComparisonIsUnconditionalInTheSource() (gas: 26556483)`. Two independent tests, one behavioural and one textual |
| X12 | the same bypass | `test_noProviderAddressIsExemptFromTheSignatureGuard` alone | **DIES**: `[FAIL: next call did not revert as expected] … (gas: 549232)` / `0 passed; 1 failed`. The behavioural half stands on its own — it does not need the source gate |
| X11 | the same bypass | `test_theSignatureComparisonIsUnconditionalInTheSource` alone | **DIES**: `[FAIL: the signature guard is not the exact unconditional comparison this test pins: 0 != 1] … (gas: 26556483)`. The textual half stands on its own too. Neither is a substitute for the other: the sweep cannot cover the address space and the gate cannot see a bypass written outside the pinned statement |
| X2 | **the review's whole nine-change degenerate** (the bypass + the (skew, grace) transposition + `seq < seqHigh + 1` + the swapped transfers + the six from DG2) | whole suite | **NOW DIES**: `Ran 10 test suites in 17.03s (35.51s CPU time): 195 tests passed, 3 failed, 0 skipped (198 total tests)` — `[FAIL: Error != expected error: panic: arithmetic underflow or overflow (0x11) != VoucherNotYetValid()] test_boundary_theVoucherClockWindowIsBoundedAtBothEnds() (gas: 404748)`, `[FAIL: next call did not revert as expected] test_noProviderAddressIsExemptFromTheSignatureGuard() (gas: 549905)`, `[FAIL: the signature guard is not the exact unconditional comparison this test pins: 0 != 1] test_theSignatureComparisonIsUnconditionalInTheSource() (gas: 26492978)`. It was `193 passed, 0 failed` before this round |
| X3 | **the (clock-skew, redeem-grace) transposition** — the review's N2, the one adjacent pair in the check list nothing ordered | whole suite | **NOW DIES**: `Suite result: FAILED. 35 passed; 1 failed; 0 skipped` — `[FAIL: Error != expected error: panic: arithmetic underflow or overflow (0x11) != VoucherNotYetValid()] test_boundary_theVoucherClockWindowIsBoundedAtBothEnds() (gas: 403470)`. It was `193 passed, 0 failed` before. The new case is `issuedAt = type(uint64).max - 400`, which is **leg two** of the argument that `v.expiresAt + REDEEM_GRACE_SECONDS` cannot overflow; leg one (`expiresAt = type(uint64).max`) was already pinned |
| X5b | **the two transfers moved ABOVE the six effects**, `nonReentrant` untouched | `test_everyEffectIsWrittenBeforeTheFirstTransfer` | **DIES**: `[FAIL: balance not yet debited at payout time: 10000000 != 9750000] test_everyEffectIsWrittenBeforeTheFirstTransfer() (gas: 1034608)`. **This is the row that makes R33 committable.** R31 proved only that *some* guard refuses a re-entrant redemption (measured: the seq rule, not the modifier) and R33 needed mutated source to show the double payment. `RedeemObserverUSDG` re-enters a **view** from inside the payout and records the six effects; the outer call succeeds, so the mock's storage survives to be asserted. Nothing needs mutating and the batch round's batch inherits the guard |
| X5 | the two transfers **deleted** (a mis-specified first attempt at X5b, kept because it measures something else) | the same test | **DIES**: `[FAIL: the observer never ran, so nothing below is asserting anything] … (gas: 932283)`. The `observed` flag is what stops the four value assertions being vacuously true against a contract that never pays anybody |
| X4 | **`Cast.toUint64`'s guard deleted** — the extracted shared narrowing | whole suite | **DIES** in `test/Fee.t.sol`: `[FAIL: next call did not revert as expected] test_splitFeeRevertsMathOverflowWhenTheNarrowingWouldLoseABit() (gas: 8530)` and `[FAIL: next call did not revert as expected] test_bpsOfRevertsMathOverflowWhenTheNarrowingWouldLoseABit() (gas: 10293)`; `X402EscrowRedeemTest` itself stays `ok. 36 passed`. The redeem path cannot reach the check (see below) — `Fee.t.sol` is what proves the shared guard is real, and it proved it before this round too, for `Fee.narrow` |

**Row W4 is superseded and this is where it went.** `Window.narrow`'s guard was recorded above as a
necessary survivor — unreachable by construction, kept for consistency with the `Fee` design choice. Its
body is now `Cast.toUint64`, so the mutation W4 describes no longer has a site of its own; X4 is the
row that carries it, and X4 dies. The same is true of the `_redeem` narrowings this round added:
`spent <= e.maxPerWindow` makes the check dead code there, and `Cast`'s NatSpec says out loud that
dead-code-ness is not a licence for a bare cast.

### The five named degenerates, re-run against the new tests

Required by the fix instruction: the new tests must not have changed any verdict. None did, and
three now die on more tests than before.

| # | Named degenerate | Observed |
|---|---|---|
| X6 | `spentInWindow` never updated | **DIES**, 9 tests, including the new one: `[FAIL: spentInWindow not yet advanced at payout time: 0 != 250000] test_everyEffectIsWrittenBeforeTheFirstTransfer() (gas: 1057327)`, plus `[FAIL: assertion failed: 0 != 5000000] test_boundary_theRollingWindowCapAdmitsItsOwnValueAndThenDrains()` and `[FAIL: assertion failed: 0 != 17852; counterexample: … args=[17852]] testFuzz_theSplitPaysBothSidesAndTheCountersFollow` |
| X7 | the provider paid the GROSS | **DIES**: `Suite result: FAILED. 27 passed; 9 failed` — `[FAIL: assertion failed: 250000 != 225000] test_happyPath_…`, and the fuzz shrinking to `[FAIL: the provider gets the rest: 946004 != 851404; counterexample: … args=[7606528022517946004]]` |
| X8 | `totalEscrowed` never decreases | **DIES**, 6 tests, including the new one: `[FAIL: totalEscrowed not yet debited at payout time: 10000000 != 9750000] test_everyEffectIsWrittenBeforeTheFirstTransfer() (gas: 1063147)` |
| X9 | `seqHigh = seq + 1` | **DIES**, 13 tests, including the new one: `[FAIL: seqHigh not yet advanced at payout time: 2 != 1] test_everyEffectIsWrittenBeforeTheFirstTransfer() (gas: 1056201)` |
| X10 | `e.totalFunded = e.balance` | **DIES**: `[FAIL: totalFunded is the SUM of deposits, not a restatement of the balance: 10150000 != 10400000] test_totalFundedIsALifetimeSumOfDepositsAndNeverFollowsTheBalanceDown() (gas: 281044)` |

### The weakest survivor, after the fix round

| # | Degenerate | Observed |
|---|---|---|
| X13 | DG2 minus the two changes this round kills — `setLimits` without `nonReentrant`; the three clock `Constants` as literals; `uint256 spent` narrowed to `uint64` with `Cast.toUint64` dropped; `Fee.splitFee` inlined; the event reading `e.spentInWindow` back from storage | **SURVIVES**: `Ran 10 test suites in 19.58s (49.75s CPU time): 198 tests passed, 0 failed, 0 skipped (198 total tests)`. Two of DG2's six are now dead: swapping `_recover(_hashTypedDataV4(…))` for `recoverVoucherSigner(v, sig)` fails the source gate, and there was never a clock transposition in DG2 but the review's N2 was — X3. Source not reproduced here |

---

## `redeemVoucherBatch`

Thirty-three tests were added (`test/X402Escrow.batch.t.sol`; 231 in the repo, up from 198). Every
row below ran in its OWN disjoint copy of `evm/` in a scratch directory, five at a time,
with `lib/` symlinked and everything else copied; a byte-exact `X402Escrow.<NAME>.GOOD` was diffed
against the shipped source before each mutation and restored and SHA-256 verified after it. Every
row's restore hash is `61ca1b53…a614b822`, identical to upstream. **Baseline before every row:
`231 tests passed, 0 failed`.**

The mutations were applied by `mutate.py`, which asserts its anchor text is present exactly once —
so a mutation that silently changed nothing cannot be reported here as a survivor.

### The batch's own guards

| # | Guard | Mutation | Named test | Observed |
|---|---|---|---|---|
| B1 | `if (n > Constants.MAX_REDEEM_BATCH) revert BatchTooLarge();` | `>` → `>=` | `test_boundary_batchSizeLimits` | **DIES**: `225 passed; 6 failed` — `[FAIL: BatchTooLarge()] test_boundary_batchSizeLimits()`, plus every one of the five size-64 measurement tests. The named test is the one that carries it; the measurements failing too is what a bound moved by one looks like from the outside |
| B2 | `if (n == 0) revert EmptyBatch();` | branch deleted | `test_boundary_batchSizeLimits` | **DIES**: `230 passed; 1 failed` — `[FAIL: next call did not revert as expected]`. An empty batch becomes a no-op that emits nothing, moves nothing and SUCCEEDS, which is the shape a redemption job would happily loop on forever |
| B3 | `if (sigs.length != n) revert BatchLengthMismatch();` | branch deleted | `test_wrongState_mismatchedArrayLengthsAreRefused`, `test_wrongState_moreSignaturesThanVouchersAreRefused` | **DIES**: `229 passed; 2 failed` — `[FAIL: Error != expected error: InvalidSignature() != custom error 0x17e37b5c]` on both. **The test plan's prediction is wrong here and this row is where that is recorded**: it expected an array-out-of-bounds `Panic(0x32)`. What actually happens is worse and quieter — both fixtures build their mismatched array with `new bytes[](k)`, whose entries are EMPTY, so item 0 fails `_recover` and the contract answers `InvalidSignature()`. Without the guard, a length mismatch is reported as *the buyer's signature being bad*. That is the diagnosis an operator would chase for an hour |
| B4 | `nonReentrant` on `redeemVoucherBatch` | modifier deleted | `test_wrongState_aReentrantAssetCannotRecurseIntoTheBatch` | **DIES**: `230 passed; 1 failed` — `[FAIL: Error != expected error: VoucherSeqNotIncreasing() != ReentrancyGuardReentrantCall()]`. **Read what that says.** The test dies, but the re-entrant batch is refused *anyway*, by the `seq` rule, because item 0's effects are already written when the payout re-enters. This is the redeem round's row R31 finding at the batch layer: the modifier is a belt and the effects-before-interactions ordering is the brace. It is not redundant — it is what holds if a future edit moves an effect below a transfer — but the guard that actually stops the double spend today is `seq > seqHigh` |
| B5 | `if (msg.sender != p.redeemer) revert NotRedeemer();` | branch deleted | `test_wrongSigner_onlyTheRedeemerMaySubmitABatch` | **DIES**: `228 passed; 3 failed` — two `[FAIL: next call did not revert as expected]` and `[FAIL: Error != expected error: ProgramPaused() != NotRedeemer()]` |
| B6 | `if (CONFIG.paused()) revert ProgramPaused();` | branch deleted | `test_wrongState_theBatchIsClosedWhilePaused` | **DIES**: `230 passed; 1 failed` — `[FAIL: next call did not revert as expected]` |
| B7 | the ORDER of B5 and B6 | the pause gate hoisted above the redeemer pin | `test_wrongSigner_theRedeemerPinIsCheckedBeforeThePauseFlag` | **DIES**: `230 passed; 1 failed` — `[FAIL: Error != expected error: ProgramPaused() != NotRedeemer()]`. Only a submission that violates BOTH guards can see this, which is why the test exists: every single-violation test in the file passes under either order |
| B8 | `ParamSet memory p = CONFIG.params()` read ONCE for the batch | the read moved INSIDE the loop | `test_theParameterSetIsReadOnceForTheWholeBatch` | **DIES**: `229 passed; 2 failed` — `[FAIL: both fees go to the treasury the batch STARTED on: 100 != 200]` and `[FAIL: the batch loop is not the exact one-line delegation this test pins: 0 != 1]`. **Nothing else in the suite can see this mutation**, because a parameter set that holds still makes a per-item read byte-identical to a single one. It took an adversary — `ConfigShiftingUSDG`, a settlement asset that is also the Config admin and moves the treasury from inside item 0's payout — and it is the compromise the property exists to defend against |

### The four named degenerates

| # | Degenerate | Observed |
|---|---|---|
| DG1 | **redeems only the first item** — the loop replaced by `_redeem(vs[0], sigs[0], p);` | **DIES on 13 tests**: `218 passed; 13 failed`. Including `[FAIL: assertion failed: 1 != 8] test_happyPath_aBatchOfEightSettlesAllEight`, `[FAIL: all 64 of the admitted batch settled: 1 != 64] test_boundary_batchSizeLimits`, `[FAIL: a provider was paid something other than its own voucher's net: 0 != 1024]`, and `[FAIL: two transfers per item, or the indices below are wrong: 2 != 8]` |
| DG2 | **every item settles, every payout is the FIRST voucher's** — `_redeem` copied to `_redeemPayFirst`, with `Fee.splitFee(first.amount, …)` and `safeTransfer(first.provider, …)` | **DIES on 7 tests**: `224 passed; 7 failed` — `[FAIL: a provider was paid something other than its own voucher's net: 7200 != 900]`, `[FAIL: each of the four was paid once: 3600 != 900]`, `[FAIL: provider i, its own net: 16 != 1]`, the fuzz at `588956 != 147239`, `[FAIL: transfer 2n is not item n's provider payout: …93090001 != …93090002]`, and both source gates. **`test_happyPath_aBatchOfEightSettlesAllEight` — the test plan's own happy path — PASSES against it**, because one payer, one provider and one amount make "paid from the first voucher" and "paid from its own" the same number eight times over. That is the whole argument for `_varied` |
| DG3 | **`MAX_REDEEM_BATCH` ignored** — the cap deleted | **DIES**: `230 passed; 1 failed` — `[FAIL: Error != expected error: VoucherSeqNotIncreasing() != custom error 0x0b7d62e2] test_boundary_batchSizeLimits`. `0x0b7d62e2` is `BatchTooLarge`; the 65-item batch is admitted and then refused by the seq rule on its first item instead, because the 64-item batch before it had already advanced `seqHigh` |
| DG4 | **skip-and-continue instead of all-or-nothing** — `try this.redeemOneExternal(vs[i], sigs[i], p) {} catch {}` over a new `external` single-item entry point | **DIES on 6 tests**: `225 passed; 6 failed` — every atomicity test (`oneBadVoucherRevertsTheWholeBatch`, `aBadLastItemUnwindsEveryItemBeforeIt`, `anOutOfOrderBatchReverts`, `theSameVoucherTwiceInOneBatchIsRefused`), the re-entrancy prover, and the source gate. The re-entrancy row is the interesting one: swallowing the inner revert also swallows `ReentrancyGuardReentrantCall`, so a skip-and-continue batch silently *continues past* a re-entrancy it provoked |

### The weakest survivor

| # | Mutation | Observed |
|---|---|---|
| B9 | **three changes, none of them behavioural on any fixture in this suite**: (1) `Constants.MAX_REDEEM_BATCH` replaced by the literal `64`; (2) the three size guards permuted to `sigs.length` → cap → empty; (3) the pause gate moved BELOW the three size guards | **SURVIVES**: `231 tests passed, 0 failed`. Source not reproduced here |

**Why each of the three survives, and which is worth a test.** (1) is the only one with real teeth: `test_boundary_theCapIsTheDeclaredConstant` asserts the constant's *value*, not that `redeemVoucherBatch` reads it, so a literal that agrees with the constant today would go on agreeing after somebody edited `Constants.sol` — a silent divergence between the declared bound and the enforced one. It is not catchable behaviourally (the two spellings are identical on every input) and the honest fix is a source gate, which is not written. (2) permutes three guards that are mutually exclusive on every input a caller can construct except `vs.length == 0` with a non-empty `sigs`, where it changes `EmptyBatch` into `BatchLengthMismatch` — no test names that pair, and no operator would read either as the wrong diagnosis. (3) changes only which of two refusals a paused, over-large batch reports.

---

## `setLimitsBySig`, `requestWithdraw`, `requestWithdrawBySig`

Twenty tests were added (`test/X402Escrow.bysig.t.sol`; **251** in the repo, up from 231). Every
row below was applied to the working tree by a script that asserts its anchor
text appears **exactly once** — so a mutation that silently changed nothing cannot be reported
here as a survivor (row T10 was refused on its first spelling, which matched three sites, and had
to be re-anchored). A byte-exact `X402Escrow.T12GOOD.sol` was diffed against the tree *before*
every mutation and restored and SHA-256 verified after it; every restore hash is `ae1f89df…`, and
`Voucher712.T12GOOD.sol` is `2d598f65…`. **Baseline before every row: `251 tests passed, 0
failed`.**

### The guards

| # | Guard | Mutation | Named test | Observed |
|---|---|---|---|---|
| T1 | `if (block.timestamp > deadline) revert SignatureExpired();` | `>` → `>=` | `test_boundary_theDeadlineAdmitsItsOwnInstant` | **DIES**: `250 passed; 1 failed` — `[FAIL: SignatureExpired()]`. The deadline's own instant is refused, which is the half a `-1`/`+1` pair alone would not see |
| T2 | the same guard | branch deleted | `test_boundary_theDeadlineAdmitsItsOwnInstant` | **DIES**: `250 passed; 1 failed` — `[FAIL: next call did not revert as expected]`. An expired authorisation is admitted for ever |
| T3 | `if (nonce != e.authNonce) revert BadNonce();` | branch deleted | `test_wrongState_theSameAuthorisationCannotBeReplayed` | **DIES**: `248 passed; 3 failed` — `[FAIL: Error != expected error: EscrowLimitsUnchanged() != custom error 0x4bd574ec]` (`0x4bd574ec` is `BadNonce`), plus `test_wrongState_oneNonceServesBothDoors` and `test_wrongState_aFutureNonceIsRefusedAsWellAsAStaleOne`, both `[FAIL: next call did not revert as expected]`. **Read the first one**: the replay lands, and what refuses it is `EscrowLimitsUnchanged` — the no-op rule, which happens to catch a replay of *these particular* limits and would catch nothing on a replay of different ones. The nonce is the guard; the no-op rule is a coincidence at this fixture |
| T4 | `e.authNonce = nonce + 1;` | line deleted | `test_wrongState_theSameAuthorisationCannotBeReplayed` | **DIES on 9 tests**: `242 passed; 9 failed` — the nonce never advances, so every second relayed call in the suite is `BadNonce` and both happy paths fail `[FAIL: assertion failed: 0 != 1]` on `authNonce` |
| T5 | `if (_recover(…) != buyer) revert SignerIsNotBuyer();` | `!= buyer` → `== address(0)` | `test_wrongSigner_anotherKeysAuthorisationIsRefused` | **DIES on 7 tests**: `244 passed; 7 failed` — every negative-signature test in the file, the address sweep and the fuzz, all `[FAIL: next call did not revert as expected]`. `_recover` already refuses a recovery to the zero address, so the mutated comparison is unreachable and **any** valid signature by **any** key authorises **any** buyer |
| T6a | `SET_LIMITS_TYPEHASH` in `Voucher712.hashSetLimits` → `REQUEST_WITHDRAW_TYPEHASH` | typehash swapped | — | **DIES on 10 tests**: `241 passed; 10 failed`. **The test plan predicted this row would be carried by `test_wrongSigner_aSetLimitsSignatureIsNotARequestWithdraw`, and it is not** — that test still reverts. The two preimages have different *widths* (six words against five), so no substitution of one typehash for the other can make them collide; what dies instead is the voucher-signature round's `test_theSetLimitsAndRequestWithdrawHashesEncodeTheirArgumentsInOrder` and `testFuzz_theSetLimitsHashReadsAllFiveOfItsArguments`, plus every `setLimitsBySig` fixture. Recorded under this file's rule about predictions that are measurably wrong |
| T6b | **the real cross-kind mutation**: `requestWithdrawBySig` hashes `Voucher712.hashSetLimits(buyer, amount, 0, nonce, deadline)` | struct hash swapped at the door | `test_wrongSigner_aSetLimitsSignatureIsNotARequestWithdraw` | **DIES**: `245 passed; 6 failed` — the named test is `[FAIL: next call did not revert as expected]`. **This is the cross-kind replay.** The test plan's fixture signs `SetLimits(buyer, 5_000_000, 0, 0, deadline)` and presents it as `requestWithdraw(5_000_000)`, and those five words are exactly what the mutated door hashes — so the buyer's authorisation to *cap a voucher at 5 USDG* becomes an authorisation to *start an exit for 5 USDG*. Those fixture values are load-bearing and must not be "tidied" |
| T7 | `if (e.maxVoucherAmount == … && e.maxPerWindow == …) revert EscrowLimitsUnchanged();` | branch deleted | `test_wrongState_settingTheSameLimitsTwiceIsRefused` | **DIES**: `249 passed; 2 failed` — the named test and the redeem round's `test_wrongState_setLimitsRefusesAWriteThatChangesNothing`, both `[FAIL: next call did not revert as expected]` |
| T8 | `_requestWithdraw(buyer, amount)` in `requestWithdrawBySig` | → `_requestWithdraw(msg.sender, amount)` | `test_happyPath_aRelayerCarriesTheBuyersWithdrawRequest` | **DIES on 5 tests**: `246 passed; 5 failed` — the named test `[FAIL: log != expected log]` (the event names the relayer), the sweep `[FAIL: assertion failed: 0 != 500]`, the fuzz, and both pause/inert-asset paths. **This is degenerate DG2 and it is also a guard row**; see the degenerates table |
| T9 | `amount == 0 ? 0 : now + WITHDRAW_DELAY_SECONDS` | the cancel arm deleted — a clock is always set | `test_happyPath_requestingZeroCancels` | **DIES**: `249 passed; 2 failed` — `[FAIL: log != expected log]` on the named test and the fuzz at `[FAIL: assertion failed: 1760003600 != 0]`. A cancel would leave a live maturity behind it |
| T10 | `if (buyer == address(0)) revert ZeroAddress();` | branch deleted | `test_wrongState_theZeroAddressIsRefusedAtBothDoors` | **DIES**: `250 passed; 1 failed` — `[FAIL: Error != expected error: BadSignatureV() != ZeroAddress()]`. It dies on the *name*, not on the outcome: `_recover` refuses the call either way, so this guard is belt over brace and the row records exactly that. It earns its place by making the refusal name the argument that is wrong instead of the signature that could not have been right |
| T11 | `Constants.WITHDRAW_DELAY_SECONDS` in `_requestWithdraw` | → the literal `60` | `test_theWithdrawDelayOutlivesEveryVoucherSignedBeforeTheRequest` | **DIES on 4 tests**: `247 passed; 4 failed` — `[FAIL: assertion failed: 1760000060 != 1760003600]` on the named test, plus both `WithdrawRequested` event assertions and the fuzz. This is the row that ties `initialize`'s const-assert to the constant the clock is actually set by |
| T12 | `initialize`'s `if (WITHDRAW_DELAY_SECONDS <= MAX_VOUCHER_REDEEMABLE_LIFE_SECONDS) revert WithdrawDelayTooShort();` | branch deleted | `test_theWithdrawDelayOutlivesEveryVoucherSignedBeforeTheRequest` | **DIES**: `250 passed; 1 failed` — `[FAIL: initialize no longer carries the const-assert the Rust build carries: 0 != 1]`. **Only a source gate can kill this one.** Every term is a compile-time constant, so the optimiser folds the branch away and no input reaches it; the Rust `const _: () = assert!(…)` it ports has no runtime behaviour to test either. This is the debt the limits-and-withdraw-request round owed |
| T13 | `nonReentrant` on `setLimitsBySig` | modifier deleted | — | **SURVIVES**: `251 tests passed, 0 failed`, and **necessarily**. None of limits-and-withdraw-request round's four doors makes an external call — no transfer, no `balanceOf`, no callback — so there is no point from which anything could re-enter. `test_theFourDoorsMakeNoExternalCallAtAll` measures that against `InertAsset`, an asset that reverts on every call but `decimals()`; the modifier is belt with no brace behind it, and the way that stops being true is somebody adding a read of the asset, which is what that test is watching for |

### The named degenerates

| # | Degenerate | Observed |
|---|---|---|
| DG1 | **`setLimitsBySig` ignores one of the four signed limits** — the signature is verified over all five words and then `_setLimits(buyer, maxVoucherAmount, type(uint64).max)` writes a window cap nobody signed | **DIES on 3 tests**: `248 passed; 3 failed` — `[FAIL: log != expected log] test_happyPath_aRelayerCarriesTheBuyersLimits`, `[FAIL: assertion failed: 18446744073709551615 != 10000] test_theRelayedDoorsHoldAcrossASweepOfBuyers`, and the fuzz at `… != 250`. **Against the test plan's nine tests AS THE BRIEF WROTE THEM it survives**: that happy path asserts only `maxVoucherAmount` and `authNonce`. Measured — with the test plan's nine selected by name it is the `vm.expectEmit` added to the happy path that fails, `8 tests succeeded`, and without that line there would have been nine. A relayed door that can raise the ceiling a buyer just lowered is exactly what the signed-limits design exists to deny |
| DG1b | the same idea one layer down — **`maxPerWindow` dropped from the verified preimage**, `hashSetLimits(buyer, maxVoucherAmount, 0, nonce, deadline)` | **DIES on 8 tests**: `243 passed; 8 failed`, every `setLimitsBySig` fixture at `[FAIL: SignerIsNotBuyer()]`. It dies loudly because `VoucherSigner` is written independently of `Voucher712` and always encodes all five words — the duplication that library's header defends |
| DG2 | **`requestWithdrawBySig` credits the caller instead of the signer** — `_requestWithdraw(msg.sender, amount)` | **DIES on 5 tests**: `246 passed; 5 failed` — row T8. The test plan has no successful `requestWithdrawBySig` fixture at all, so `test_happyPath_aRelayerCarriesTheBuyersWithdrawRequest` had to be written for this; it asserts the clock on the SIGNER's escrow **and** that the relayer's own is untouched |

---

## `withdraw()`

Seventeen tests were added (`test/X402Escrow.withdraw.t.sol`; **268** in the repo, up from 251).
Same harness as the limits-and-withdraw-request round: each anchor is asserted to appear exactly once, a
byte-exact `X402Escrow.T13GOOD.sol` was diffed against the tree before every row and restored and
SHA-256 verified after it, and every restore hash is `85b4feb1…`. **Baseline before every row:
`268 tests passed, 0 failed`.**

### The guards

| # | Guard | Mutation | Named test | Observed |
|---|---|---|---|---|
| W1 | `if (requested == 0) revert NoWithdrawRequested();` | branch deleted | `test_wrongState_withdrawWithNoRequestIsRefused` | **DIES on 3 tests**: `265 passed; 3 failed` — `[FAIL: Error != expected error: EscrowInsufficient() != custom error 0x37c59471]` (`0x37c59471` is `NoWithdrawRequested`). The `amount == 0` guard catches the no-request case *by accident* on an empty request, so what this row proves is that the two conditions are told apart: without W1, "you never asked" is reported as "your escrow is empty" |
| W2 | `if (block.timestamp < e.withdrawAvailableAt) revert WithdrawNotYetAvailable();` | branch deleted | `test_boundary_withdrawIsRefusedOneSecondEarlyAndAdmittedOnTheInstant` | **DIES**: `267 passed; 1 failed` — `[FAIL: next call did not revert as expected]`, the `-1` half. **This mutation is also degenerate DG3**; see below |
| W3 | the same guard | `<` → `<=` | the same test | **DIES on 8+ tests**: `[FAIL: WithdrawNotYetAvailable()]` on every fixture that warps to exactly `WITHDRAW_DELAY_SECONDS`, plus three `[FAIL: log != expected log]`. The maturity instant is admitted, not refused |
| W4 | `Escrow storage e = escrows[msg.sender];` | → `escrows[tx.origin]` | `test_wrongSigner_nobodyElseCanTakeTheBuyersMoney` | **DIES on 8+ tests**: every `vm.prank`ed withdrawal reads an escrow belonging to the test contract's origin rather than to the caller, `[FAIL: NoWithdrawRequested()]` throughout, and the boundary test as `[FAIL: Error != expected error: NoWithdrawRequested() != WithdrawNotYetAvailable()]`. No forwarding-contract variant was needed |
| W5 | `e.withdrawRequested = 0;` | line deleted | `test_happyPath_theBuyerTakesTheirOwnMoneyAfterTheDelay` | **DIES on 5 tests**: `263 passed; 5 failed` — `[FAIL: assertion failed: 4000000 != 0]` on the named test (whose second half re-calls `withdraw()` on the next second and would otherwise be paid again), `[FAIL: the request not yet spent at payout time: 4000000 != 0]` from the observer, and `[FAIL: spent, not left standing: 10000000 != 0]` / `[FAIL: the request is spent either way: …]` from the two partly-filled fixtures |
| W6 | **the transfer moved ABOVE the five effects**, `nonReentrant` untouched | reordered | `test_everyEffectIsWrittenBeforeTheWithdrawalTransfer` | **DIES**: `267 passed; 1 failed` — `[FAIL: balance not yet debited at payout time: 10000000 != 6000000]`. `WithdrawObserverUSDG` re-enters a **view** from inside the payout and records all five effects plus `totalFunded`; the outer call succeeds, so its storage survives to be asserted. Nothing needs mutating for the test to exist, which is what makes it committable |
| W7 | `if (amount == 0) revert EscrowInsufficient();` | branch deleted | `test_wrongState_anEmptyEscrowIsRefusedAndTheRequestSurvives` | **DIES**: `267 passed; 1 failed` — `[FAIL: next call did not revert as expected]`. The empty escrow is "paid" zero and the standing request is CLEARED, so the buyer serves the whole hour again for money that was already theirs — `withdraw.rs:123`'s reason for the guard, reproduced exactly |
| W8 | `totalEscrowed -= amount;` | line deleted | `test_happyPath_theBuyerTakesTheirOwnMoneyAfterTheDelay` | **DIES**: `266 passed; 2 failed` — `[FAIL: assertion failed: 10000000 != 6000000]` and the observer's `[FAIL: totalEscrowed not yet debited: …]`. The pooled solvency counter would drift above the sum of the ledger by every withdrawal ever made |
| W9 | `e.totalWithdrawn += amount;` | line deleted | `test_totalFundedDoesNotMoveWhenTheBalanceFalls` | **DIES on 5 tests**: `263 passed; 5 failed` |
| W10 | `e.balance = balance - amount;` | line deleted | `test_happyPath_theBuyerTakesTheirOwnMoneyAfterTheDelay` | **DIES on 6+ tests**: the money leaves and the ledger does not notice — `[FAIL: assertion failed: 10000000 != 0]` on the drain-it-all fixture |
| W11 | `e.withdrawAvailableAt = 0;` | line deleted | `test_happyPath_theBuyerTakesTheirOwnMoneyAfterTheDelay` | **DIES on 4 tests**: `264 passed; 4 failed` — `[FAIL: assertion failed: 1760003600 != 0]`, plus the observer's `[FAIL: the clock not yet cleared at payout time: …]` |
| W12 | `nonReentrant` on `withdraw` | modifier deleted | `test_wrongState_aReentrantAssetCannotRecurseIntoWithdraw` | **DIES**: `267 passed; 1 failed` — `[FAIL: Error != expected error: NoWithdrawRequested() != ReentrancyGuardReentrantCall()]`. **Read what that says**, as rows R31 and B4 said it before: the test dies, but the re-entrant withdrawal is refused *anyway*, because `withdrawRequested` is already `0` when the payout re-enters. **What actually stops the double payment on this path is the effects-before-interactions ordering, and W6 is the row that proves it.** The modifier is not redundant — it is what holds if a future edit moves an effect below the transfer — but it is the belt and the ordering is the brace |
| W13 | **`totalFunded` must not move when the balance falls** | `e.totalFunded = e.balance;` inserted after the debit | `test_totalFundedDoesNotMoveWhenTheBalanceFalls` | **DIES on 6 tests**: `[FAIL: money IN did not change: 6000000 != 10000000]` on the named test, `[FAIL: totalFunded MOVED on a falling balance: 6000000 != 10000000]` from the observer (so it is caught *at payout time* as well as after), `[FAIL: and totalFunded held still: 0 != 1000]` from the address sweep, and `[FAIL: totalFunded never falls: 0 != 1]` from the fuzz. This is the assertion the redeem round settled on its own path, owed again by the second task that reduces a balance |
| W14 | `min(requested, balance)` | `<=` → `>=`, making it `max` | `test_happyPath_aRequestLargerThanTheBalancePaysWhatIsThere` | **DIES on 6+ tests**: `[FAIL: panic: arithmetic underflow or overflow (0x11)]` where the request exceeds the balance — `e.balance = balance - amount` underflows — and `[FAIL: log != expected log]` where it does not |

### The named degenerates

| # | Degenerate | Observed |
|---|---|---|
| DG3 | **`withdraw()` ignores the 1-hour delay** — the `withdrawAvailableAt` branch deleted (row W2) | **DIES**: `267 passed; 1 failed` — `[FAIL: next call did not revert as expected] test_boundary_withdrawIsRefusedOneSecondEarlyAndAdmittedOnTheInstant`. Only the `-1` half sees it; the exact-instant half passes under the degenerate, which is why the boundary is tested at two points and not one |
| DG4 | **`withdraw()` pays a stored destination rather than `msg.sender`** — a `withdrawTo` mapping and a `setWithdrawTo(address)` setter, with `dest = withdrawTo[msg.sender] == address(0) ? msg.sender : withdrawTo[msg.sender]` and `ASSET.safeTransfer(dest, amount)` | **DIES on exactly ONE test, and it is not a behavioural one**: `267 passed; 1 failed` — `[FAIL: the withdrawal recipient is not the exact msg.sender expression this test pins: 0 != 1] test_theExitPaysMsgSenderAndTheAbiHasNoOtherWithdrawDoor`. **Measured against the test plan's eight tests selected by name: `8 passed; 0 failed`.** Nothing behavioural can see it — the default branch makes it byte-equivalent on every fixture, and it becomes a redirect only once somebody calls the setter. This is the degenerate that justifies the gate, and it is the shape a compromised console would add |
| DG4b | the same hole under a name no source gate greps for — `function rescue(address to, uint64 amount) external { ASSET.safeTransfer(to, amount); }`, an unrestricted drain that nothing calls | **DIES**: `267 passed; 1 failed` — `[FAIL: X402Escrow's external surface changed size: 24 != 23]`. Run to prove the ABI half of that gate has teeth of its own: the source-text half passes this one completely (the pinned recipient line is untouched, `function withdraw` is still one, `function withdrawBySig` is still zero). The gate reads `methodIdentifiers` out of the compiled artifact, so a door added through an inherited contract is caught too |

### The weakest survivor

| # | Mutation | Observed |
|---|---|---|
| W15 | `nonReentrant` deleted from all four of limits-and-withdraw-request round's doors (row T13) | **SURVIVES**: `251 tests passed, 0 failed` at the time it was run. Necessarily: none of `setLimits`, `setLimitsBySig`, `requestWithdraw` or `requestWithdrawBySig` makes an external call, proved against `InertAsset` in `test_theFourDoorsMakeNoExternalCallAtAll`. It is the only guard across both tasks that no test can kill, and the reason is recorded rather than papered over |

---

## `X402Stake`: collateral in, unbonding, collateral out

Nineteen tests were added (`test/X402Stake.stake.t.sol`; **287** in the repo, up from 268, of
which 268 are the pre-existing suites running unchanged against the REAL stake contract in place
of `StakeStub`). Same harness as the limits-and-withdraw-request and `withdraw()` rounds: each anchor is asserted to appear
**exactly once** before replacing it, a byte-exact `X402Stake.T14GOOD.sol` was diffed against the
tree before every row and restored and SHA-256 verified after it, and every restore hash is
`98d8dbbe…`. **Baseline before every row: `287 tests passed, 0 failed`** (rows K1–K14 were first
measured at 285, before the two re-entrancy tests were added; K11 and K14 were re-measured at 287
and their entries below are the re-measurement).

### The guards

| # | Guard | Mutation | Named test | Observed |
|---|---|---|---|---|
| K1 | `requestUnstake`: `if (amount > s.bonded) revert InsufficientBondedStake();` | branch deleted | `test_wrongState_cannotUnstakeMoreThanIsBonded` | **DIES**: `284 passed; 1 failed` — `[FAIL: Error != expected error: panic: arithmetic underflow or overflow (0x11) != custom error 0x51e7d130]` (`0x51e7d130` is `InsufficientBondedStake`). Checked arithmetic refuses it either way; what the guard buys is the diagnosis, and only the expected-selector assertion sees that |
| K2 | `withdrawStake`: `if (block.timestamp < unbondingStartedAt + period) revert UnbondingPeriodNotElapsed();` | branch deleted | `test_boundary_withdrawIsRefusedOneSecondEarlyAndAdmittedOnTheInstant`, the `-1` half | **DIES on 2 tests**: `283 passed; 2 failed` — `[FAIL: Error != expected error: InsufficientUnbondingStake() != custom error 0xb6c7f82e]` on that test and on `test_boundary_aSecondUnstakeRestartsTheClockForTheWholeBalance`. **This mutation is degenerate DG5**; see below |
| K3 | the same guard | `<` → `<=` | the same test, the exact half | **DIES on 6 tests**: `279 passed; 6 failed` — `[FAIL: UnbondingPeriodNotElapsed()]` on every fixture that warps to exactly `unbondingPeriodSeconds`, plus the fuzz. The maturity instant is admitted, not refused |
| K4 | `withdrawStake`: `ProviderStake storage s = stakes[msg.sender];` | → `stakes[tx.origin]` | `test_wrongSigner_nobodyElseTakesAProvidersCollateral` | **DIES on 7 tests**: `278 passed; 7 failed` — the named test at `[FAIL: InsufficientUnbondingStake() != UnbondingPeriodNotElapsed()]` … and here is the part worth reading: **that test kills this row only because it is written `vm.prank(address(0xDEAD), provider)`**, which puts the PROVIDER in `tx.origin` while a stranger is `msg.sender`. Under a plain `vm.prank` the mutation reads the default sender's empty account and reverts with the same error the correct code does, so the test passes and proves nothing. Row W4 on the escrow got its kill from other fixtures; this one had to be designed for |
| K5 | `depositStakeFor`: `if (ASSET.balanceOf(address(this)) - before != amount) revert TransferAmountMismatch();` | branch deleted | `test_wrongState_aFeeOnTransferAssetIsRefusedAtTheDoor` | **DIES**: `284 passed; 1 failed` — `[FAIL: next call did not revert as expected]`. A 1-bps fee-on-transfer asset credits the provider the full argument while the contract received less, and the vault stops matching the sum of the ledger |
| K6 | `depositStakeFor`: `if (amount == 0) revert ZeroAmount();` | branch deleted | `test_wrongState_zeroIsRefused` | **DIES**: `284 passed; 1 failed` — `[FAIL: next call did not revert as expected]` |
| K7 | `depositStakeFor`: `if (provider == address(0)) revert ZeroAddress();` | branch deleted | `test_wrongState_theZeroProviderIsRefused` | **DIES**: `284 passed; 1 failed` — `[FAIL: next call did not revert as expected]`. Nothing else refuses it: a deposit for the zero address is a real transfer into the contract credited to an account nobody holds |
| K8 | `requestUnstake`: `s.unbondingStartedAt = uint64(block.timestamp);` | line deleted | `test_boundary_withdrawIsRefusedOneSecondEarlyAndAdmittedOnTheInstant` | **DIES on 3 tests**: `282 passed; 3 failed` — `[FAIL: assertion failed: 0 != 1760000000]` and both boundary tests at `[FAIL: next call did not revert as expected]`. With the clock left at `0` the period is served before the request is made, so **the unbonding period evaporates for every first-time unstaker** |
| K9 | `withdrawStake`: `if (s.unbonding == 0) s.unbondingStartedAt = 0;` | line deleted | `test_boundary_withdrawIsRefusedOneSecondEarlyAndAdmittedOnTheInstant` | **DIES**: `284 passed; 1 failed` — `[FAIL: assertion failed: 1760000000 != 0]`. A stale anchor on an empty bucket makes the NEXT unstake look already-matured |
| K10 | **the transfer moved ABOVE the five effects**, `nonReentrant` untouched | reordered | `test_everyEffectIsWrittenBeforeTheWithdrawalTransfer` | **DIES**: `284 passed; 1 failed` — `[FAIL: totalStaked not yet debited at payout: 1000000000 != 600000000]`. `StakeObserverUSDG` re-enters a **view** from inside the payout and records five figures; the outer call succeeds, so its storage survives to be asserted. **This is the row that says what actually stops re-entrancy on `withdrawStake`** — the ordering, not the modifier |
| K11 | `nonReentrant` on `withdrawStake` | modifier deleted | `test_wrongState_aReentrantAssetCannotRecurseIntoWithdrawStake` | **DIES**: `286 passed; 1 failed` — `[FAIL: Error != expected error: InsufficientUnbondingStake() != ReentrancyGuardReentrantCall()]`. **Read the observed error**, as rows R31, B4 and W12 said before: the nested withdrawal is refused anyway, because the effects are already written when the asset calls back. The modifier is the belt, K10 is the brace. Measured at 285 before the test existed: it **survived**, `285 passed, 0 failed` |
| K12 | `withdrawStake`: `totalStaked -= amount;` | line deleted | `test_theAccountingIdentityHolds` | **DIES on 5 tests**: `280 passed; 5 failed` — `[FAIL: assertion failed: 1000000000 != 600000000]` on the identity and the boundary, `[FAIL: assertion failed: 35000000 != 0]` on the address sweep, plus the observer and the fuzz. The pooled counter would drift above the sum of the ledger by every withdrawal ever made |
| K13 | `withdrawStake`: `if (amount > s.unbonding) revert InsufficientUnbondingStake();` | branch deleted | `test_wrongState_anAmountBeyondUnbondingIsDiagnosedBeforeTheClock` | **DIES**: `284 passed; 1 failed` — `[FAIL: Error != expected error: UnbondingPeriodNotElapsed() != InsufficientUnbondingStake()]`. It is a DIAGNOSIS row and the test had to be written for it: at every matured instant `withdrawableOf`'s `min` subsumes this check exactly, so the two spellings differ only BEFORE maturity — where the mutation tells a provider to come back later for money that will not be there |
| K14 | `nonReentrant` on `depositStakeFor` | modifier deleted | `test_wrongState_aReentrantAssetCannotRecurseIntoDepositStakeFor` | **DIES**: `286 passed; 1 failed` — `[FAIL: Error != expected error: TransferAmountMismatch() != ReentrancyGuardReentrantCall()]`. Rows E4 and E23 exactly: the token funds its own nested deposit, the nested deposit succeeds, and the OUTER delta then sees `amount + reenterAmount` and refuses. **What holds the money on this path is K5's delta**, not the modifier. Measured at 285 before the test existed: it **survived** |
| K15 | `struct ProviderStake` gains a `uint256 __gap2` member | member appended | `script/check-layout.sh`'s new `check_struct_size` line | **DIES**: `struct X402Stake.ProviderStake is 160 bytes, expected 128 (four slots — the designed packing)`, `LAYOUT_EXIT=1`. A script gate, not a `forge test` row |
| K15b | the same idea with a `uint64 __gap2` | member appended | the same | **SURVIVES the size gate, and this is the finding**: a `uint64` packs into the 16 spare bytes of slot 3 beside `totalSlashed`, so the struct is still 128 bytes and `check_struct_size` says nothing. What caught it was the append-only CLASSIFIER (`X402Stake: APPEND-ONLY change, allowed. Regenerate the snapshot with --update IN THIS COMMIT.`, `LAYOUT_EXIT=1`). The two halves of this gate catch different things and neither subsumes the other — measured, after the first attempt at K15 was written with a `uint64` and passed |

### The named degenerate

| # | Degenerate | Observed |
|---|---|---|
| DG5 | **`withdrawStake` ignores the unbonding period** — the maturity branch deleted (row K2) | **DIES on 2 tests**: `283 passed; 2 failed` — `[FAIL: Error != expected error: InsufficientUnbondingStake() != custom error 0xb6c7f82e]`. Only the `-1` halves see it; both exact-instant halves pass under the degenerate, which is why the boundary is tested at two points and not one. `withdrawableOf` is NOT a second line of defence here — it re-reads the same comparison, so deleting one leaves the other intact and the source is:<br>`function withdrawStake(uint64 amount) external nonReentrant { if (amount == 0) revert ZeroAmount(); ProviderStake storage s = stakes[msg.sender]; if (amount > s.unbonding) revert InsufficientUnbondingStake(); if (amount > withdrawableOf(msg.sender)) revert InsufficientUnbondingStake(); s.unbonding -= amount; … }` — with `withdrawableOf`'s own maturity branch deleted too, so the exit is open the second an unstake is requested |

---

## `proposeSlash`, phase one

Eighteen tests were added (`test/X402Stake.slash.t.sol`; **305** in the repo, up from 287). Same
harness: each anchor is asserted to appear **exactly once** before replacing it, a
byte-exact `X402Stake.T15GOOD.sol` (and `Attestation712.T15GOOD.sol` for P10) was diffed against
the tree before every row and restored and SHA-256 verified after it. **Baseline before every
row: `305 tests passed, 0 failed`.**

### A trap this file should record before the rows

`vm.expectRevert` binds to the **next external call**, and `_sign(a, pk)` makes one — it reads
`stake.DOMAIN_SEPARATOR()`. So the test plan's spelling,
`vm.expectRevert(E.selector); stake.proposeSlash(a, _sign(a, pk));`, arms the cheat code against
the domain read, which succeeds. Measured against a **correct** implementation: **11 of this
file's 17 tests failed** with `next call did not revert as expected`. Every negative case here
therefore goes through `_expect(a, pk, err)`, which builds the signature first. A test suite
written the test plan's way would have been red on correct code and green on nothing.

### The guards

| # | Guard | Mutation | Named test | Observed |
|---|---|---|---|---|
| P1 | `if (CONFIG.paused()) revert ProgramPaused();` | branch deleted | `test_wrongState_proposeIsClosedWhilePaused` | **DIES**: `304 passed; 1 failed` — `[FAIL: next call did not revert as expected]` |
| P2 | `if (a.status != uint8(ResponseClass.DataFail)) revert StatusDoesNotSlash();` | branch deleted | `test_wrongState_onlyDataFailSlashes` | **DIES**: `304 passed; 1 failed`. The test sweeps all three harmless classes AND a byte outside the enum, which is what the `uint8` field exists to let this contract diagnose instead of panicking |
| P3 | `if (slashRecords[a.requestId].status != SlashStatus.None) revert SlashAlreadyExists();` | branch deleted | `test_wrongState_theSameRequestIdCanNeverBeProposedTwice` | **DIES**: `304 passed; 1 failed` — `[FAIL: next call did not revert as expected]`. **THE REPLAY LOCK, and degenerate DG6** |
| P4 | `CONFIG.assertCanSign(verifier);` | line deleted | `test_wrongSigner_anUnregisteredKeyCannotPropose` and `test_wrongSigner_aRevokedKeyCannotPropose` | **DIES on 4 tests**: `301 passed; 4 failed` — both named tests, plus `test_wrongSigner_anAttestationSignedForTheEscrowIsRefusedHere` and `test_flipOneSignedField_everyAttestationFieldIsBound`. With no registry check ANY key judges, which is the whole allowlist |
| P5 | `if (a.penalty > p.penaltyAmount) revert PenaltyExceedsMaximum();` | branch deleted | `test_wrongState_aPenaltyAboveTheConfiguredMaximumIsRefused` | **DIES**: `304 passed; 1 failed` |
| P6 | `if (atRisk == 0) revert NothingToSlash();` | branch deleted | `test_wrongState_nothingToSlash` | **DIES**: `304 passed; 1 failed` — `[FAIL: Error != expected error: SlashCapExceeded() != NothingToSlash()]`. A bare provider is refused either way; **the guard is the diagnosis**, exactly as the test plan predicted, and only the expected-selector assertion sees it |
| P7 | `if (reserved > free) reserved = Cast.toUint64(free);` | the free-balance clamp deleted | `test_theFreeBalanceClampsAReservationTheCapWouldHaveAllowed` | **DIES**: `304 passed; 1 failed` — `[FAIL: clamped to what was free: 1000000 != 500000]`. Without it `Σ pendingSlash` stops being an honest upper bound on what standing judgements can take |
| P8 | `a.expiresAt - a.issuedAt > MAX_ATTESTATION_LIFETIME_SECONDS` | `>` → `>=` | `test_boundary_theAttestationWindow` | **DIES**: `304 passed; 1 failed` — `[FAIL: InvalidAttestationWindow()]`. The ceiling must be ADMITTED exactly |
| P9 | `if (nowTs > a.expiresAt) revert AttestationExpired();` | `>` → `>=` | the same test | **DIES**: `304 passed; 1 failed` — `[FAIL: AttestationExpired()]`. An attestation is valid AT its expiry instant (`attestation.rs:175` is `now <= expires_at`), and **the test plan's version of this test did not cover that instant** — a case had to be added for this row to have anything to kill |
| P10 | `Attestation712.hashAttestation`: `SLASH_ATTESTATION_TYPEHASH` → `VOUCHER_TYPEHASH` | typehash swapped | `test_happyPath_aProposalReservesCollateralAndWaits` | **DIES on 13 tests**: `292 passed; 13 failed`, every fixture at `[FAIL: VerifierNotRegistered()]`. The signing side (`VoucherSigner.signAttestation`) is written independently of this encoder and goes on using the right typehash, which is the duplication that makes this row possible |
| P11 | `if (a.beneficiary == address(0)) revert MissingBeneficiary();` | branch deleted | `test_wrongState_aZeroPenaltyAndAZeroBeneficiaryAreRefused` | **DIES**: `304 passed; 1 failed`. A judgement with no beneficiary reserves a provider's collateral and can then only ever burn it |
| P12 | `if (a.penalty == 0) revert ZeroAmount();` | branch deleted | the same test | **DIES**: `304 passed; 1 failed` — `[FAIL: Error != expected error: NothingToSlash() != ZeroAmount()]`. The `reserved == 0` check catches it downstream; this guard is what stops a zero judgement from spending a request id under the wrong name |
| P13 | `if (reserved > capAllowance) reserved = capAllowance;` | the ceiling clamp deleted | `test_theCapAllowanceClampsAReservationThePenaltyWouldHaveAllowed` | **DIES**: `304 passed; 1 failed` — `[FAIL: cut to the ceiling: 1000000 != 500000]`. **The test plan listed no test for this row**; at the fixture's stake the ceiling is a hundred times the penalty and never binds, so a thin provider had to be written for it |
| P14 | `if (capAllowance == 0) revert SlashCapExceeded();` | branch deleted | `test_wrongState_aCapAllowanceThatRoundsToZeroIsRefused` | **DIES**: `304 passed; 1 failed` — `[FAIL: Error != expected error: NothingToSlash() != custom error 0xc7300280]`. Diagnosis again: a stake so small that 10% of it floors to zero |
| P15 | `s.pendingSlash += reserved;` | line deleted | `test_happyPath_aProposalReservesCollateralAndWaits` | **DIES on 6 tests**: `299 passed; 6 failed` — `[FAIL: assertion failed: 0 != 1000000]` and five more. Without it a proposal shields nothing and `withdrawStake` outruns every judgement in flight |
| P16 | `rec.executableAt = nowTs + Constants.SLASH_DELAY_SECONDS;` | → `nowTs` | the same test | **DIES**: `304 passed; 1 failed` — `[FAIL: assertion failed: 1760000000 != 1760259200]`. **The 72 hours are the whole point of phase one**, and this is the row that pins them to the constant rather than to a literal |
| P17 | `nonReentrant` on `proposeSlash` | modifier deleted | — | **SURVIVES**: `305 tests passed, 0 failed`, and **necessarily**. `proposeSlash` moves no token and calls nothing but `X402Config`, which holds none, so there is no point from which anything could re-enter. Row T13 recorded the same thing about the limits-and-withdraw-request round's four doors. The modifier is belt with no brace; the way that stops being true is somebody adding a transfer |

### The named degenerate

| # | Degenerate | Observed |
|---|---|---|
| DG6 | **`proposeSlash` skips the `status == None` replay lock** (row P3) | **DIES**: `304 passed; 1 failed` — `[FAIL: next call did not revert as expected] test_wrongState_theSameRequestIdCanNeverBeProposedTwice`. Source: `proposeSlash` exactly as shipped with the one line `if (slashRecords[a.requestId].status != SlashStatus.None) revert SlashAlreadyExists();` removed. Every other field of the record is overwritten idempotently, so the ONLY observable difference is `pendingSlash`, which climbs by `reserved` on every resubmission of one captured attestation until it freezes the provider's whole exit. Nothing else stands between an attestation and unbounded reuse — there is no nonce, the attestation's own window is days wide, and the signature is by construction still valid |

---

## `executeSlash`, `cancelSlash`, `expireSlash`: the three exits from `Pending`

Twenty-one tests were added (`test/X402Stake.slash.t.sol`; **326** in the repo, up from 305).
Same harness; the byte-exact copy is `X402Stake.T16GOOD.sol`, SHA-256 `0b0f41eb…`, diffed before
every row and restored and re-hashed after it. **Baseline before every row: `326 tests passed,
0 failed`.** Eighteen rows, **eighteen kills, no survivors.**

### The guards

| # | Guard | Mutation | Named test | Observed |
|---|---|---|---|---|
| X1 | `executeSlash`: `if (rec.status != SlashStatus.Pending) revert SlashNotPending();` | branch deleted | `test_wrongState_aTerminalRecordCannotBeExecutedCancelledOrExpired` | **DIES on 2 tests**: `324 passed; 2 failed` — `[FAIL: next call did not revert as expected]` on the named test, i.e. **an executed judgement pays twice**, plus `[FAIL: Error != expected error: SlashExecutionWindowClosed() != SlashNotPending()]` on `test_wrongState_anUnknownRequestIdIsNotPending`, where a request id nobody proposed is diagnosed by its zero clock instead of by its absence |
| X2 | `if (nowTs < rec.executableAt) revert SlashNotYetExecutable();` | branch deleted | `test_boundary_theExecutionWindowAndItsSharedInstantWithExpire`, the `-1` half | **DIES**: `325 passed; 1 failed` — `[FAIL: next call did not revert as expected]`. **The 72-hour delay evaporates**, and with it the window in which a human can revoke the key that signed |
| X3 | the same guard | `<` → `<=` | the same test, the exact half | **DIES on 14 tests**: `312 passed; 14 failed` — `[FAIL: SlashNotYetExecutable()]` on every fixture that warps to exactly `SLASH_DELAY_SECONDS`. The instant belongs to execute |
| X4 | `if (nowTs >= executableAt + GRACE) revert SlashExecutionWindowClosed();` | `>=` → `>` | the same test's shared-instant block | **DIES**: `325 passed; 1 failed` — `[FAIL: next call did not revert as expected]`. At `executableAt + GRACE` **both doors would be open at once**, which is the one thing the D-13 table exists to forbid |
| X5 | **`CONFIG.assertCanSign(rec.verifier);`** | line deleted | `test_revokingTheKeyInTheWindowVoidsTheJudgementAndReleasesTheCollateral` | **DIES on 3 tests**: `323 passed; 3 failed` — `[FAIL: next call did not revert as expected]` on that test, on `test_revocationReachesEveryJudgementThatKeySigned` and on `test_boundary_theVerifierExpiryInstantBelongsToExecute`. **This is degenerate DG8 and the single most consequential line in the three tasks**: without it revocation stops voiding what is in flight, `revokeVerifier` goes back to being a stop rather than a cleanup, and the reason the two-phase slash exists is deleted while every other test stays green |
| X6 | `if (windowRemaining == 0) revert SlashCapExceeded();` | branch deleted | `test_theProvidersRollingWindowClampsAndThenRefuses` | **DIES**: `325 passed; 1 failed` — `[FAIL: Error != expected error: PenaltyTooSmallToSplit() != SlashCapExceeded()]`. The third judgement applies zero and is refused for the wrong reason; the provider's daily ceiling stops being a ceiling and becomes an arithmetic accident |
| X7 | `if (applied > keyRemaining) applied = keyRemaining;` | the key clamp deleted | `test_theVerifierDailyCapClampsAtExecution` | **DIES**: `325 passed; 1 failed` — `[FAIL: assertion failed: 1000000 != 500000]`. r2 applies a whole judgement against a window holding half of one |
| X8 | `if (keyRemaining == 0) revert VerifierDailyCapExceeded();` | branch deleted | `test_wrongState_anExhaustedVerifierWindowRefusesTheNextJudgement` | **DIES**: `325 passed; 1 failed` — `[FAIL: Error != expected error: PenaltyTooSmallToSplit() != custom error 0x7c2fa623]` (`0x7c2fa623` is `VerifierDailyCapExceeded`). The judgement would apply zero and be refused as unsplittable — and, worse, a `taken == 0` diagnosis reads as "the penalty is dust", which is a completely different incident from "this key is out of capacity" |
| X9 | `if (taken == 0) revert PenaltyTooSmallToSplit();` | branch deleted | `test_wrongState_aPenaltyTooSmallToSplitLeavesTheRecordPending` | **DIES**: `325 passed; 1 failed` — `[FAIL: next call did not revert as expected]`. Without it a judgement of 1 base unit is EXECUTED for nothing: both bps shares floor to zero, no token moves, and the record — and its request id — is spent for ever |
| X10 | `_release`: `s.pendingSlash = s.pendingSlash > released ? s.pendingSlash - released : 0;` | the release deleted | `test_pendingSlashShieldsCollateralFromWithdrawStake` | **DIES on 9 tests**: `317 passed; 9 failed` — `[FAIL: InsufficientUnbondingStake()]` on the named test (the provider can never take the last of their own bond back) and `[FAIL: assertion failed: N != 0]` on seven more. A cancel or a reap would leave the hold standing for ever, which is exactly the outcome `expire_slash.rs` exists to prevent |
| X11 | `withdrawStake`: `if (amount > withdrawableOf(msg.sender)) revert InsufficientUnbondingStake();` | branch deleted | `test_pendingSlashShieldsCollateralFromWithdrawStake` | **DIES**: `325 passed; 1 failed` — `[FAIL: next call did not revert as expected]`. **The row deferred from the stake round**, and it needed the slash-exit round to exist: this is the only guard that makes `pendingSlash` mean anything, and until a `Pending` record could be created nothing could tell it apart from the `amount > s.unbonding` check beside it |
| X12 | **both transfers moved ABOVE the effects**, `nonReentrant` untouched | reordered | `test_everyEffectIsWrittenBeforeTheSlashTransfers` | **DIES**: `325 passed; 1 failed` — `[FAIL: totalSlashed not yet raised at payout time: 0 != 900000]`. `execute_slash.rs:243` pays BEFORE it mutates anything, and says so; that is Solana-safe and is the one place this port deliberately inverts the reference. `StakeObserverUSDG` re-enters a view from inside the first payout and reads three figures, so the proof needs nothing mutated to exist |
| X13 | `expireSlash`: `if (!verifierUnavailable && !graceElapsed) revert SlashNotExpired();` | → `if (!graceElapsed)` (the verifier half dropped) | `test_revokingTheKeyInTheWindowVoidsTheJudgementAndReleasesTheCollateral` | **DIES on 3 tests**: `323 passed; 3 failed` — `[FAIL: SlashNotExpired()]` on all three revocation/expiry tests. **This is the other half of the crux**: without it a revoked key's reservations sit on a provider's stake with no expiry at all, and the seven-day grace becomes the only way out of a hold that can never be executed |
| X14 | the `status != Pending` check removed from BOTH `expireSlash` and `_release` | branches deleted | `test_wrongState_aTerminalRecordCannotBeExecutedCancelledOrExpired` | **DIES on 2 tests**: `324 passed; 2 failed` — `[FAIL: next call did not revert as expected] test_wrongState_anUnknownRequestIdIsNotPending` and `[FAIL: Error != expected error: SlashNotExpired() != SlashNotPending()]` on the named test. **Degenerate DG9.** Read which test does the work: a record that is already terminal is usually *incidentally* refused by the time guard, so the terminal test dies on the NAME only. What is genuinely open is a request id nobody proposed — its `executableAt` is `0`, so `graceElapsed` is true at every clock, and `expireSlash` "reaps" a record that does not exist, emitting `SlashCancelled` for it and stamping `Cancelled` into a slot that had never been `Pending`. Past the grace it also flips a real `Executed` record to `Cancelled`, destroying the evidence a dispute reads |
| X15 | `agentAmount`/`platformAmount` computed from the OTHER parameter | `slashAgentBps` ↔ `slashPlatformBps` | `test_happyPath_aJudgementPaysAfterSeventyTwoHours` | **DIES on 5 tests**: `321 passed; 5 failed` — `[FAIL: assertion failed: 300000 != 600000]` on three, `[FAIL: assertion failed: 450000 != 900000]` and `[FAIL: r2 and r3 paid; r1 paid nothing: 600000 != 1200000]`. **Degenerate DG10.** It dies only because every assertion is PER RECIPIENT: `agent + platform == taken` is structurally true under the swap, and a test that checked the total would see nothing while the harmed agent got a third instead of two thirds |
| X16 | `nonReentrant` on `executeSlash` | modifier deleted | `test_wrongState_aReentrantAssetCannotRecurseIntoExecuteSlash` | **DIES**: `325 passed; 1 failed` — `[FAIL: Error != expected error: SlashNotPending() != ReentrancyGuardReentrantCall()]`. **Read the observed error**, as rows R31, B4, W12, K11 and K14 said before: the nested execution is refused anyway, by `status != Pending`, because the effects are already written when the asset calls back. **What stops the double payment on this path is X12's ordering plus the status flag**; the modifier is the belt |
| X17 | `s.slashedInWindow = providerCarried + applied;` | → `applied` (the carry dropped) | `test_theProvidersRollingWindowClampsAndThenRefuses` | **DIES**: `325 passed; 1 failed` — `[FAIL: next call did not revert as expected]`. Without the carry the rolling window resets on every execution instead of accumulating, so the provider's daily cap binds against one judgement at a time and never against the day |
| X18 | `uint64 fromUnbonding = taken < s.unbonding ? taken : s.unbonding;` | `<` → `>`, making it `max` | `test_theSlashIsTakenFromUnbondingFirst` | **DIES on 12 tests**: `314 passed; 12 failed` — `[FAIL: panic: arithmetic underflow or overflow (0x11)]` throughout, because `s.unbonding -= fromUnbonding` underflows the moment `taken` exceeds it. Every slash against a provider with a small or empty unbonding bucket reverts |

### The named degenerates

| # | Degenerate | Observed |
|---|---|---|
| DG8 | **`executeSlash` does NOT re-check the verifier** — row X5, the line `CONFIG.assertCanSign(rec.verifier);` deleted and nothing else changed | **DIES on 3 tests**: `323 passed; 3 failed`. It is worth stating what survives: the happy path, the whole execution-window boundary table, both cap tests, the split, the accounting identity, the ordering proof and all 305 pre-Task-16 tests. **Only the three tests written specifically about revocation and key expiry can see it**, which is why the test plan calls it the one control the two-phase slash exists to make usable |
| DG9 | **`expireSlash` reachable from a terminal status** — row X14 | **DIES on 2 tests**: `324 passed; 2 failed`. See X14 for which test does the real work and why the terminal case alone is not enough |
| DG10 | **`executeSlash` pays the agent and the platform from the wrong bps** — row X15 | **DIES on 5 tests**: `321 passed; 5 failed`, every one of them a per-recipient assertion. A suite that pinned `agent + platform == taken` would be completely blind to it |

---

## The upgrade door, the initializer discipline and the domain separator

Eleven tests were added (`test/Upgrade.t.sol`; **336** in the repo, up from 326). Byte-exact
copies: `X402Stake.T17GOOD.sol`, SHA-256 `0b0f41eb…`; `Upgrade.T17GOOD.sol`, SHA-256 `3a50c2c3…`.
Both diffed before every row and restored and re-hashed after it. **Baseline before every row:
`336 tests passed, 0 failed`.** Three guard rows, two degenerates, and the layout gate's own
refusals recorded verbatim below.

### Where measurement disagreed with the test plan

Four measured corrections.

| Source | What it predicted | What is actually true |
|---|---|---|
| the test plan Step 4, rows 1, 2, 5 and 6 | the three `_authorizeUpgrade` guards and the three `_disableInitializers` calls are all proved here, "deferred from the Config, deposit and stake rounds" | **Four of the six were already proved and are rows C6, C7, E7, E8 and E19 above**, brought forward by the project's no-untested-guard rule. Duplicating them would be five new rows measuring nothing. **`X402Stake` had neither proof, and no upgrade test of any kind** — rows S1–S3 below are that gap, and they are the only new guard coverage this round adds. `test_theEarlierAuthorityProofsStillHold` re-asserts the earlier four so deleting one of those tests cannot silently drop the property. |
| the test plan Step 1, `X402EscrowV2`'s header | the appended field "lands immediately after the last of them — **inside the space the parent's `__gap` reserved**" | **False, and measured.** `__gap` is `uint256[50]` starting at slot 9, so it occupies slots 9-58; a derived contract's first variable is laid out after *every* base variable, so `upgradedAt` sits at slot **59**, past the gap. `test_theAppendedFieldLandsPastTheParentsGapNotInsideIt` reads slot 59 and then walks slots 9-58 proving they are still zero. Both shapes are storage-safe, which is why the error was invisible; they differ in that appending in a derived contract is unbounded while shrinking the parent's gap is a budget. |
| the test plan Step 2, the whole listing | the test bodies as written | **Five of the ten tests failed against CORRECT code.** `vm.prank` arms the *next call*, and the test plan puts a call in the argument list six times — `escrow.upgradeToAndCall(address(new X402EscrowV2()), "")` (the `new` is a CREATE) and `escrow.redeemVoucher(v, VoucherSigner.signVoucher(buyerKey, escrow.DOMAIN_SEPARATOR(), v))` (the getter). Observed: `[FAIL: NotAdmin()]` ×4 and `[FAIL: NotRedeemer()]` ×1, `5 passed; 5 failed`. `Fixture` and `X402Escrow.deposit.t.sol` both warn about exactly this and the test plan commits it anyway. Every argument is now hoisted above its prank. |
| the test plan Step 3 | "Expected: `8 passed; 0 failed`" | `11 passed; 0 failed`. Three tests the test plan does not have: the slot-59 measurement, the EIP-712 **name** half of (d) (the test plan only covers the version), and the silent-domain degenerate below. |

### The guards

| # | Guard | Mutation | Named test | Observed |
|---|---|---|---|---|
| S1 | `X402Stake._authorizeUpgrade`: `if (msg.sender != CONFIG.admin()) revert NotAdmin();` | body deleted | `test_wrongSigner_onlyTheAdminUpgradesStake` | **DIES on 2 tests**: `334 passed; 2 failed` — `[FAIL: next call did not revert as expected]` on the named test and on `test_theStakeUpgradeAuthorityFollowsTheConfigAdmin`. Anyone replaces the logic holding every provider's collateral, and the second failure is the one that matters for D-1: with the guard gone the "one key" claim cannot even be stated. **This contract had no upgrade test at all before the upgrade round** |
| S2 | `X402Stake`'s constructor: `_disableInitializers();` | statement deleted | `test_wrongState_theStakeProxyAndItsImplementationCannotBeInitialised` | **DIES**: `335 passed; 1 failed` — `[FAIL: next call did not revert as expected]`. The attacker initialises the **implementation**, and because a UUPS implementation carries `upgradeToAndCall` in its own code it then answers to whoever did it |
| S3 | `X402Stake.initialize`: the `initializer` modifier | modifier deleted | the same test | **DIES**: `335 passed; 1 failed` — `[FAIL: next call did not revert as expected]` at a quarter the gas (25,689 vs 100,224), i.e. it dies on the **proxy** half rather than the implementation half. A second call would re-point `CONFIG` and `ASSET` on a live, funded stake vault |

### The named degenerates

The degenerate the test plan names is *"an upgrade test that would pass against an implementation
that silently changed the domain separator"*. It exists, it is measured, and its source is
`test/helpers/X402EscrowSilentDomainV2.sol`, kept in the tree because a permanent test now uses
it.

The construction matters. `X402Escrow.DOMAIN_SEPARATOR()` is `external` and **not** `virtual`, so
an implementation cannot change what that getter returns. `_hashTypedDataV4` **is** `internal view
virtual` on OZ's `EIP712`, and it is what `redeemVoucher`, `setLimitsBySig` and
`requestWithdrawBySig` build their digests from. Overriding only the second makes the *exported*
domain and the *enforced* domain disagree, with no external symptom at all.

| # | Degenerate | Observed |
|---|---|---|
| DG-U1 | the real (c) test, `test_anUpgradePreservesEveryBalanceTheDomainAndAnOutstandingVoucher`, upgraded to `X402EscrowSilentDomainV2` instead of `X402EscrowV2` | **DIES**: `[FAIL: SignerIsNotPayer()] (gas: 2959198)`, `0 passed; 1 failed`. The pre-signed voucher no longer redeems — which is the whole parity claim, failing |
| DG-U2 | **the degenerate the follow-up names**: the same test against the same silent implementation, but **truncated after the state assertions** — every balance, every counter, the pool total and `assertEq(escrow.DOMAIN_SEPARATOR(), sepBefore)` kept; the pre-signed redemption deleted | **PASSES**: `[PASS] … (gas: 2897134)`, `1 passed; 0 failed`. **This is the shape the test plan's own test would have had if the last three lines were left off**, and it is green against an implementation that has killed every outstanding voucher. The separator assertion is not the proof; redeeming a voucher signed before the upgrade is |

DG-U2 is now a permanent test in its own right —
`test_wrongState_anImplementationCanMoveTheENFORCEDDomainWithoutMovingTheGETTER` — which asserts
both halves: the getter is unchanged **and** the redemption reverts `SignerIsNotPayer`. Read that
error: an operator seeing it in production would diagnose "the backend signed with the wrong key",
which is the wrong incident entirely.

## Upgrade-safety gate

Not a Solidity mutation, and the same discipline for the same reason: **a gate whose refusal
nobody has seen is a gate nobody has tested.** Run as a shell step, not through `vm.ffi` — the
thing under test is a CI script, and putting shell execution inside the test binary for one
assertion buys nothing. Output verbatim, `FORGE=forge`.

**1. Green on the shipped layout.**

```
X402Config: layout unchanged
X402Escrow: layout unchanged
X402Stake: layout unchanged
layout OK
EXIT=0
```

**2. An INSERTION in the middle** — `uint256 public inserted;` added immediately before
`mapping(address => Escrow) internal escrows;`. This is the same class of change that broke 41 existing accounts on a
Solana devnet deployment of the Anchor program, expressed in Solidity.

```
X402Config: layout unchanged
REFUSED: <tmpdir>/X402Escrow.json is not an append-only change to snapshots/X402Escrow.storage.json
  - variable escrows moved: slot 7+0 -> 8+0
  - variable totalEscrowed moved: slot 8+0 -> 9+0
  - new variable inserted sits at slot 7, before the old gap at 9 -- appends go at the END, never in the middle
  - the gap shrank by 0 slots but the new fields consumed 1; they must be equal
X402Escrow: REFUSED — this is a redeploy, not an upgrade
X402Stake: layout unchanged
EXIT=1
```

**2b. `--update` refuses to launder it** — the case the script's own header calls out, run because
a refusal that `--update` could paper over is not a refusal.

```
X402Config: snapshot refreshed (layout unchanged)
REFUSED: … (the same four lines)
X402Escrow: --update REFUSED — this is not an append, and --update will not launder one.
     If the redeploy is deliberate: ./script/check-layout.sh --redeploy-not-an-upgrade "<reason>"
X402Stake: snapshot refreshed (layout unchanged)
EXIT=1
```

**3. The legal shape** — `uint256 public appended;` added at the end and `uint256[50] __gap`
shrunk to `uint256[49]`.

```
X402Config: layout unchanged
X402Escrow: APPEND-ONLY change, allowed. Regenerate the snapshot with --update IN THIS COMMIT.
X402Stake: layout unchanged
EXIT=1
```

Exit 1 is correct and is the point: **"allowed" is not "silent".** The gate still fails CI until a
human regenerates the snapshot with `--update` and reviews the diff in the same commit. That
review is the one the Solana side did not have.

**4. Restored**, `layout OK`, `EXIT=0`, and `git diff --stat -- src/ snapshots/` prints nothing.

---

## The boundary sweep, the pause matrix and the invariant suite

Thirty-six tests were added (`test/Boundaries.t.sol` 17, `test/Pause.t.sol` 11,
`test/invariant/Invariants.t.sol` 8; **373** in the repo, up from 337). Byte-exact copies:
`X402Escrow.T18GOOD.sol` SHA-256 `e796474e…`, `X402Stake.T18GOOD.sol` SHA-256 `0b0f41eb…`.
**Baseline before every row: `373 tests passed, 0 failed`.**

### Where measurement disagreed with the test plan

| Source | What it predicted | What is actually true |
|---|---|---|
| the test plan Step 1, B2's table row and D-13 B3 | B3's far-side error is `InvalidVoucherWindow` | `VoucherLifetimeTooLong`. `attestation.rs:477-481` raises one Anchor name for two conditions; this port splits the width bound out under the `Errors.sol` one-condition-one-name rule, and `Errors.sol` records the split with its argument. The test plan's own sample code uses the split name while the table it cites does not. |
| the test plan Step 5, `check-sizes.sh` | `forge inspect "$c" bytecode` | **The wrong bytecode.** That is the CREATION code; EIP-170 bounds the RUNTIME code, and they differ by 1,427 bytes on both money contracts here. Gating on the larger number fires early and teaches the reader that the limit applies to initcode. The shipped script measures `deployedBytecode` and prints creation beside it as information. |
| the extras list | "`.gas-snapshot` holds fuzz rows that move between runs (seed not pinned), so `forge snapshot --check` will be red at random" | **Measured over three consecutive regenerations, and it is the other way round.** The `testFuzz_*` rows are stable — μ and ~ did not move. The `invariant_*` rows churn every run through their `reverts:` counts (2,097 → 2,081 → 2,094 …), 14 diff lines each time. And `forge snapshot --check` is **green** regardless, twice, because it compares gas and an `invariant_*` row carries no gas figure. It has teeth: perturbing one `FeeTest` row by 1,000 gas gives `Diff in "FeeTest::test_aCallTooSmallToDividePaysTheProviderInFull()" … expected "(gas: 10453)"` and exit 1. So `--check` **stays** in CI; what must never be added is `git diff --exit-code -- .gas-snapshot`. |
| the extras list | the `Errors.sol` accounting gate closes "the numbers drift" | It does, and on its first run it also found **five** errors with no producer, not the one the test plan names: `AmountExceedsUint64`, `DestinationIsVault`, `EscrowLimitsRequireBuyer`, `NotBuyer`, `SignerIsNotVerifier`. Each is argued for in `docs/divergences.md`. |
| B14's expected error | — | The first spelling of `test_B14` expected `InsufficientUnbondingStake` one second early. `withdrawStake` asks the **clock** question before it asks `withdrawableOf`, so the answer is `UnbondingPeriodNotElapsed` — the truer diagnosis, and the one an operator can act on. |
| `StakeHandler.proposeSlash`'s bound | the test plan gives no bound | Bounding the penalty above `params().penaltyAmount` (1,000,000) made **every** proposal in the campaign revert `PenaltyExceedsMaximum`, leaving the entire slash lifecycle unreachable and both slash invariants vacuous. Found by `test_theHandlerCanReachEveryAction`, which is the guard that exists for exactly this. |

### The invariants, mutation-proved

An invariant that no mutation can break is a sentence, not a test. Three, each on a different
identity, each restored and re-hashed after.

| # | Mutation | Named invariant | Observed |
|---|---|---|---|
| V1 | `X402Escrow.withdraw`: `totalEscrowed -= amount;` deleted | `invariant_escrowBalancesSumToTotalEscrowed` | **DIES on 3**: `5 passed; 3 failed` — `[FAIL: assertion failed: 1323695452 != 1323700349]` on the sum identity, `[FAIL: assertion failed: 1649065902 < 1670509991]` on `theContractHoldsAtLeastWhatItOwes` (the contract now claims to owe more than it holds), and `[FAIL: 740000000 != 750000000]` on the reachability test. The solvency counter would drift up by every withdrawal ever made |
| V2 | `X402Stake._release`: `s.pendingSlash = s.pendingSlash > released ? s.pendingSlash - released : 0;` deleted | `invariant_pendingSlashEqualsTheSumOfPendingReservations` | **DIES on 2**: `6 passed; 2 failed` — `[FAIL: assertion failed: 1942784 != 1302319]`. The vault's hold and the handler's independent book diverge: a cancelled or reaped judgement leaves collateral held for ever. This is the invariant the handler's **own** bookkeeping earns — reading both sides off the contract would have compared `pendingSlash` with itself |
| V3 | `X402Stake.executeSlash`: `totalSlashed += taken;` → `+= applied;` | `invariant_stakeAccountingIdentity` | **DIES on 2**: `6 passed; 2 failed` — `[FAIL: assertion failed: 5370932740 != 5370932738]`, a two-unit drift found over 16,384 calls. `applied` is the gross judged and `taken` is what actually left the vault; the provider keeps the difference by design, so metering the identity with the gross breaks it by exactly the provider's share |

### The named degenerate

The degenerate the test plan names is *"an invariant suite whose handler never reaches a state
where the identity could break."* Built by giving every action in both handlers an early `return`,
so the campaign lands nothing at all.

| # | Degenerate | Observed |
|---|---|---|
| DG-V1 | both handlers neutered, **the guards present** | **`0 passed; 8 failed`** — every invariant fails with `[FAIL: the run landed almost nothing: the identities held over an empty state: 0 < 8]`, and the reachability test with `[FAIL: escrow action unreachable: deposit: 0 <= 0]`. Note `reverts: 0` on every row: nothing reverted because nothing was attempted |
| DG-V2 | **the degenerate suite**: the same neutered handlers with `afterInvariant` and `test_theHandlerCanReachEveryAction` **removed** | **`7 passed; 0 failed`** — `runs: 256, calls: 16384, reverts: 0`, seven green accounting identities over sixteen thousand calls that all did nothing. This is what the suite would report without its two guards, and it is why `fail_on_revert = false` needs one |

### The pause matrix

Not mutation rows — the `never` half of the matrix is proved by tests that would fail if a
`whenNotPaused` were *added*, which is the opposite direction from a deleted guard. The rows that
matter, and what each refuses:

- `test_pauseNeverClosesTheBuyersExit` — an admin key that could freeze an owner's exit would let
  the key holder hold funds hostage, which the pause rule exists to prevent. **If this test ever needs changing, the change
  is wrong.**
- `test_pauseNeverClosesTheRequestThatStartsTheExitClock` — otherwise pause merely postpones the
  exit by however long the pause lasts, which is the same hostage risk with an extra step.
- `test_pauseNeverClosesTheTwoWaysAHoldIsReleased` — the subtlest. A pause that closed
  `cancelSlash` and `expireSlash` while leaving `proposeSlash`'s reservation standing would leave a
  provider's collateral held by a judgement that can no longer be executed **or** released — a hold
  with no exit, created by the same key that paused.
- `test_pauseNeverClosesTheUpgradeDoorOnAnyOfTheThree` — pause is the first half of an emergency
  and the upgrade is usually the second. Config is upgraded last in that test on purpose: it is
  what an operator would reach for to change `paused` itself.

---

## The deploy scripts, the gates and the runbook

Five tests were added (`test/Deploy.t.sol`; **378** in the repo, up from 373). Nothing in `src/`
changed, so there are no guard mutations here — the guards this round adds are a shell script and a
deploy script, and both are proved the way `check-layout.sh` was in the upgrade round: by building the
failure and reading the output.

### Where measurement disagreed with the test plan

| Source | What it predicted | What is actually true |
|---|---|---|
| the test plan Step 1, `Deploy.s.sol` | `require(address(stake.CONFIG()) == address(config), "stake config mismatch")` and six more | **Revert strings, which this repo does not have anywhere** — the global constraint outranks the test plan's sample code. Every one is now `if (!cond) revert NamedError();`, with the errors declared in the script file rather than `src/Errors.sol` so `check-errors.sh`'s accounting against the Anchor `error.rs` is not polluted with deploy-script conditions that have no Anchor counterpart. |
| the test plan Step 8 / the runbook | the salt is `keccak256(abi.encodePacked("x402:", name, ":v2:", block.chainid))` | Correct — and **`block.chainid` is a `uint256`, so it contributes thirty-two big-endian bytes, not its decimal string.** The obvious shell spelling (`printf 'x402:%s:v2:%s' … \| cast from-utf8 \| cast keccak`) produces a different hash and would put a salt in the deployment record that the script never used, so the CREATE2 derivation an operator checks against it would fail for a reason no error message would explain. `test_theSaltFormulaMatchesTheOneTheShellScriptComputes` pins the two spellings against each other at three literals. |
| the extras list, item 3 | "`MAX_REDEEM_BATCH = 64` is not derived from anything measured … either measure the limit with a read-only `cast` call or state the cap as unvalidated" | **Measured, and the first measurement is a trap.** `cast block latest` reports `gasLimit 1125899906842624` on *both* chains — that is 2^50, the Arbitrum Orbit placeholder, and it is **not a limit**: Orbit does not meter per block. The real ceiling is per **transaction**, in the `ArbGasInfo` precompile at `0x…006C`: `getGasAccountingParams()` returns `(7000000, 32000000, 32000000)` — **`maxTxGasLimit = 32,000,000`**, identical on 4663 and 46630, both at `arbOSVersion 116`. So 64 is **validated**: the 5.18 M worst case is 16.2 % of the ceiling, a 6.18× margin, i.e. each of the 128 transfers may cost ~209,000 gas more before the cap binds. Recorded in `docs/chain-facts.md` §5. |
| the extras list, item 2 | `EscrowLimitsRequireBuyer` has no producer; decide delete-vs-keep | **Five have no producer, not one** — `check-errors.sh` found `AmountExceedsUint64`, `DestinationIsVault`, `EscrowLimitsRequireBuyer`, `NotBuyer` and `SignerIsNotVerifier`. Decision **KEEP**, argued in `docs/divergences.md` § 2, with `AmountExceedsUint64` named as the weakest case and the change that should delete it. Note also that the test plan's row 23 calls `DestinationIsEscrowAta` a *fold* into `DestinationIsVault` — true, but the thing it folds into is a name nothing raises, so the condition is structurally absent rather than renamed. |

### The named degenerate

The degenerate the test plan names: *"a `verify-deployment.sh` that checks the proxy exists but
never reads the ERC-1967 implementation slot."*

The script could not be run — there was no deployment at the time — so its three checks
are **modelled** against real proxies in memory and the weak version is run beside the strong one
on the same state, in `test_theWeakVerifierCannotSeeAnUnrecordedUpgrade`. The state is the one that
matters: a proxy that was upgraded and whose record was not updated, which is exactly what happens
when runbook §7's last checklist item is skipped.

| # | Degenerate | Observed |
|---|---|---|
| DG-D1 | `_weakCheck(proxy) = proxy.code.length > 0` — check 3 of the script, alone | **Green before AND after an unrecorded upgrade.** `assertTrue(_weakCheck(…))` passes in both states: the proxy has code either way, and an upgrade cannot change that |
| DG-D2 | `_strongCheck(proxy, recordedImpl)` — check 1, the ERC-1967 slot read | Green before, **red after**. `assertFalse` holds: the slot names an implementation the record does not |

The test then asserts by source text that the shipped `verify-deployment.sh` contains the slot
constant, a `cast storage` that reads it, and a failure message naming `implementation slot` — so
"simplifying" the script to the weak form fails a test rather than passing review.

### The other two shipped refusals, run

`script/new-deployment-record.sh`, against the real mainnet RPC, read-only:

```
$ ./script/new-deployment-record.sh 4663 https://rpc.mainnet.chain.robinhood.com
REFUSED: a mainnet record needs USDG_ADDRESS, and this repo cannot derive it.
  Mainnet USDG is NOT at the testnet address (docs/chain-facts.md §1: cast code on
  4663 returns 0x, and the same call on 46630 returns code, so the probe works).
  …
EXIT=1

$ USDG_ADDRESS=0x915Ef7c9F9f80a69e3BE47A38EE0Bb47607103ec \
    ./script/new-deployment-record.sh 4663 https://rpc.mainnet.chain.robinhood.com
REFUSED: that is the TESTNET USDG address. There is no code at it on 4663.
EXIT=1
```

And the 46630 path was run end to end (record written, inspected, **removed** — nothing is
deployed, so no record is committed).

`test_wrongState_theSplitFormIsFrontRunnable` is the third: it measures what a
deploy-then-initialise script costs, with the attacker ending as `Config.admin` and therefore as
the upgrade authority of all three contracts, and then upgrading `X402Config` to prove it.
`test_theDeployScriptUsesTheAtomicForm` is what stops a future edit reintroducing the split — a
source-text scan over the **comment-stripped** file, because this file's own header names every
pattern it counts (without the strip, `X402Escrow.initialize` counts 2).

---

## Review closure — the three lines the suite did not hold (2026-09-09)

An internal security review (not a third-party audit) ran 60 source mutations
against the 378-test tree and composed the survivors into one implementation that still passed
378/378. Six lines survived. Three of the six are provably equivalent mutants and are recorded as
such below; the other three are `executeSlash`'s metering block, and this section is the three
tests that now hold them.

Three tests were added (`test/X402Stake.slash.t.sol`; **381** in the repo, up from 378). Nothing
in `src/` changed. The byte-exact copy is `X402Stake.sol.GOOD`, SHA-256
`0b0f41eb463f9566f420e37231c57ebbbf3823e81c487653303681c059cd892a` — the same hash the review names
as its scope — diffed before every row and restored and re-hashed after it. **Baseline before
every row: `381 tests passed, 0 failed`.**

### The guards

| # | Guard | Mutation | Named test | Observed |
|---|---|---|---|---|
| A1 | `executeSlash`: `vw.slashedInWindow = keyCarried + applied;` — the **verifier key's** rolling meter | → `vw.slashedInWindow = applied;` (the carry dropped) | `test_oneKeysDailyCapBindsAcrossThreeJudgements` | **DIES**: `[FAIL: r3 must be clamped by what r1+r2 already spent of the key's cap: 400000 != 200000]`, and `test_theVerifierKeysWindowAnchorNeverMovesBackwards` dies with it (`[FAIL: a stepped-back clock must not drain the key's meter: 400000 != 200000]`). **This is the review's one real coverage gap.** X17 above is the *provider's* half of the identical line and has been caught since the slash-exit round; this half survived because both pre-existing verifier-cap tests (`test_theVerifierDailyCapClampsAtExecution`, `test_wrongState_anExhaustedVerifierWindowRefusesTheNextJudgement`) execute exactly **two** records, and with two executions "accumulate" and "remember the last one" are indistinguishable — the second execution reads a meter the first wrote either way. The divergence first appears on the **third**, which is why the new test executes three. Under the mutant a key issuing repeated judgements of `cap/2` resets itself on every execution and never exhausts: `Config.verifierDailyCap` is the only bound on a leaked verifier key short of `revokeVerifier`, and it stops existing |
| A2 | `executeSlash`: `s.slashWindowStartedAt = nowTs > s.slashWindowStartedAt ? nowTs : s.slashWindowStartedAt;` | → `= nowTs;` (unconditional) | `test_theProvidersSlashWindowAnchorNeverMovesBackwards` | **DIES**: `[FAIL: the anchor never moves back: 1760259200 != 1760269200]`. The anchor is read directly off `stakeOf(provider).slashWindowStartedAt`, the same shape as `X402Escrow.redeem.t.sol::test_theWindowAnchorNeverMovesBackwards` uses for the third anchor in this codebase |
| A3 | `executeSlash`: `vw.windowStartedAt = nowTs > vw.windowStartedAt ? nowTs : vw.windowStartedAt;` | → `= nowTs;` (unconditional) | `test_theVerifierKeysWindowAnchorNeverMovesBackwards` | **DIES**: `[FAIL: a stepped-back clock must not drain the key's meter: 292592 != 200000]`. `VerifierWindow` is internal with no getter — deliberately, for `stakeOf`'s flattened-tuple reason, and the external surface is pinned — so the anchor is observed through what it does: a third execution back at the high instant, where a meter still anchored there has drained nothing and 200 000 of the 1 000 000 cap is left, while one re-anchored ten thousand seconds earlier reads a drain that never happened and hands back 92 592 base units of capacity a stepped-back clock created out of nothing |

**On `block.timestamp` and whether A2/A3 are live.** On Arbitrum Orbit the timestamp is
sequencer-supplied and monotonic within the L1 bounds, so a stepped-back clock is not an attack
today and the impact of losing either guard is confined to the meters, not to custody. The tests
exist because the guards are stated as a property in the source comment two lines above them
("a clock that stepped back must not hand capacity to whoever noticed"), one of the three anchors
was already held by a test, and a property that holds in two places and is unenforced in the third
is how the third gets deleted by a refactor with a green suite behind it.

### The equivalent mutants

Recorded so that nobody later writes a test claiming these are load-bearing. Each was applied to
the tree and the **whole** suite run; each survived, and the reason each survives is a proof rather
than a coverage gap. Same discipline as W1a/W2a/W4, C41/C47 and S4/S5 above.

| # | Line | Mutation | Observed | Why it is equivalent |
|---|---|---|---|---|
| A4 | `X402Stake.sol:132`, `bondedOf` | `return b > type(uint64).max ? type(uint64).max : Cast.toUint64(b);` → `return uint64(b);` | **SURVIVED** — `381 tests passed, 0 failed` | The two spellings differ only for `bonded > type(uint64).max`, i.e. more than 18.4 × 10¹² USDG bonded by one provider. `bonded` is a `uint128` sum of `uint64` deposits, so reaching it needs more than 2³² maximal deposits; no test can construct it and none should pretend to. The saturation is kept because the caller (`_redeem`'s stake floor) compares the result against a `uint64` minimum, where truncation would be a **silent under-report** and the clamp is the correct direction — the argument is in its NatSpec |
| A5 | `X402Stake.sol:157`, `withdrawableOf` | `if (s.unbonding == 0) return 0;` deleted | **SURVIVED** — `381 tests passed, 0 failed` | With `unbonding == 0` the tail computes `capped = min(s.unbonding, free) = min(0, free) = 0` and returns the same `0` on every input, whichever side of the maturity branch the clock is on. The early return is a gas shortcut and a statement of intent, not a guard. It is **not** the maturity branch one line below it, which is held by K2/DG5 |
| A6 | `libraries/Sig.sol:40` | `err != NoError \|\| signer == address(0)` → `err != NoError` | **already recorded as S4** (and its mirror as S5), `17 passed; 0 failed` | `ECDSA.tryRecover(hash, v, r, s)` returns `address(0)` **iff** it returns `RecoverError.InvalidSignature`, so after guards 1–3 the two disjuncts are one predicate. The review re-derived this independently and confirms the authors' reasoning — **with the condition the authors state**: the equivalence holds only while `ECDSA.tryRecover` is the call below it. Anyone replacing it with a bare `ecrecover` owns both guards from that moment, and S6 (the pair deleted together) is the row that proves the pair is not optional |

---

## Review closure — the function surface across an upgrade (2026-09-09)

Three variables decide whether an upgrade is safe: the **storage layout**, the **EIP-712 domain**
and the **set of functions the new implementation exports**. The review found the first two gated
well and the third gated on one contract only. Four tests were added (`test/Upgrade.t.sol`;
**385** in the repo, up from 381), plus the record-side gate in `script/abi-surface.sh`,
`new-deployment-record.sh`, `check-bytecode.sh` and `verify-deployment.sh`.

### The degenerate: an implementation with a door nobody reviewed

| # | Degenerate | Observed |
|---|---|---|
| DG-A1 | `X402Escrow` gains `function sweep(address to) external { ASSET.safeTransfer(to, ASSET.balanceOf(address(this))); }` — an unguarded drain of every buyer's escrow | **DIES on the escrow's existing pin**: `[FAIL: X402Escrow's external surface changed size: 24 != 23] test_theExitPaysMsgSenderAndTheAbiHasNoOtherWithdrawDoor`. That pin has held since the `withdraw()` round and it is the one contract that had it |
| DG-A2 | **`X402Config` gains `function setAdminUnchecked(address who) external { admin = who; }`** — any caller takes the admin key, and `_authorizeUpgrade` on all three contracts resolves `CONFIG.admin()` **live**, so it is also the upgrade authority of the escrow and the stake | **SURVIVED the whole suite: `382 tests passed, 0 failed`.** This is the finding. Nothing in 382 tests, no layout gate, no domain check and no bytecode gate could see a function that hands away every contract in the system. It now dies on `test_theConfigFunctionSurfaceIsPinnedByName`: `[FAIL: X402Config's external surface changed size: 17 != 16]` |
| DG-A3 | `X402Config.slashProviderBps()` **renamed** to `providerSlashBps()` (the interface and the three call sites moved with it, so the count is unchanged at 16) | **DIES**: `[FAIL: an external function nobody pinned: providerSlashBps()]`. Run because DG-A2 only proves the count is held; a rename is the mutation a count cannot see, and the assertion is two-directional for exactly that reason. Note that a rename of a function the tests *call* is caught by the compiler first — `Error (9582): Member "slashProviderBps" not found` — so the surface pin is what covers the ones no test calls |

### The record-side gate, run end to end against 46630

`./script/new-deployment-record.sh 46630 https://rpc.testnet.chain.robinhood.com` — read-only,
record written, exercised, and **removed** (nothing is deployed, so no record is committed). The
scenario is the one the review describes: a surface change *after* the operator has done what they
always do at an upgrade, which is rewrite `implementationRuntimeKeccak`.

| # | State | Observed |
|---|---|---|
| A7 | record fresh, tree unchanged | `verify-deployment.sh` passes check 0 (function surface) and fails at check 2 on the placeholder implementation address — i.e. the surface gate is green when the surface is unchanged, and does not mask the checks behind it |
| A8 | `sweep(address)` added to `X402Escrow`, **`implementationRuntimeKeccak` rewritten to the new build** | `check-bytecode.sh`: bytecode comparison green, and `function surface drift in X402Escrow vs deployments/46630.json`, exit 1. `verify-deployment.sh` names it: `+ 01681a62 sweep(address)`. **This is the whole point** — the operator's own rewrite silences the bytecode gate and does not silence this one |
| A9 | `setAdminUnchecked(address)` added to `X402Config`, its `implementationRuntimeKeccak` likewise rewritten | `+ 1e16a625 setAdminUnchecked(address)`, exit 1, on the contract where 382 green tests saw nothing |

### A gate that had never run

Not a mutation — a defect found while wiring the above, and recorded here because it is a gate
that reported green while answering a different question from the one it was asked.

`check-bytecode.sh` computed the built hash as `$($FORGE inspect "$c" deployedBytecode | cast
keccak)`. **That pipe form fails** — `Error: odd number of digits`, from the trailing newline —
and under `set -euo pipefail` it aborts the script before it compares anything:

```
$ forge inspect X402Escrow deployedBytecode | cast keccak
Error: odd number of digits
$ cast keccak "$(forge inspect X402Escrow deployedBytecode | tr -d '\n')"
0xbb482f8c3b72d8c3bfe4b0f52a185e6e918289f7f5ae19c21d5fa25a915a3edb
```

It was invisible because the loop containing it has never executed: no deployment record has ever
carried `"status": "deployed"`, so the gate printed `no deployment records yet` and exited 0 — and
a green exit was read as a passing comparison. `new-deployment-record.sh` had used the working
spelling all along, which is what made the difference legible once both were run.
`test_theDeploymentScriptsCarryTheFunctionSurfaceGate` asserts the broken spelling is not in the
file.

---

## Review closure — the document pin, proved on both sides (2026-09-09)

`test/DocPins.t.sol` was, at the time, a gate over a *document*, so it was proved the way a guard is:
by putting the document into the state it exists to refuse. (The gas-page pin test recorded below
has since been removed; the runbook checks remain.)

| # | State | Observed |
|---|---|---|
| A10 | `docs/gas.md` as the review found it — pinned to `61ca1b53…`, three commits behind | **FAILED**: `[FAIL: docs/gas.md does not pin the X402Escrow.sol in this tree. Re-measure the page and re-pin it, or the figures on it are about a file that no longer exists. Current sha256: e796474e6727698c7fd69ba91e71a965bee76b83ca6ef1ebec0e7b87de87df40]` — the digest in the message is the one `shasum -a 256` prints, so the fix is in the failure |
| A11 | the page re-measured and re-pinned | **PASS** |
| A12 | a **comment-only** edit to `X402Escrow.sol` (the natspec corrections in this same batch), against the first single-pin version of the gate | **FAILED** on the source hash — correctly, but demanding a *re-measurement* for a change that provably cannot move a gas figure. Measured: the runtime bytecode keccak was identical before and after the edit, and re-running `test_measure_*` gave figures byte-identical to the published table. **This is why the gate now carries two pins**: a gate that demands ceremony for a no-op is a gate that gets laundered with "just update the hash", which is precisely how the pin came to name a file three commits old |
| A13 | the two-pin gate, runtime keccak removed from the page | **FAILED**: `[FAIL: docs/gas.md does not pin the X402Escrow RUNTIME BYTECODE in this tree. …]` — the red says *re-measure*, where the source-hash red says *update the pin line and stop* |

### The two natspec claims that outran the code

No mutation; both are comment corrections, recorded because the log is where this repo keeps the
things it has checked rather than assumed.

- **`X402Escrow.initialize`'s `Constants` assertion** claimed to turn a future edit to `Constants`
  into "a deployment that cannot be initialised". Under UUPS `initialize` carries `initializer` and
  never runs again, so it guards the **first** implementation of a proxy and nothing after it. What
  actually holds the invariant for every implementation after the first is CI:
  `X402Escrow.bysig.t.sol::test_theWithdrawDelayOutlivesEveryVoucherSignedBeforeTheRequest` (which
  also asserts the check's presence by source text) and
  `Types.t.sol::test_withdrawDelayOutlivesTheLongestRedeemableVoucher`. Both exist and both are now
  named at the check.
- **The pause line.** `X402Escrow.depositFor`'s natspec justified its pause gate with "money coming
  *in* is on the other side of that line", a rule that predicts `X402Stake.depositStakeFor` should
  be gated — and it deliberately is not. Both doors are tested
  (`Pause.t.sol::test_pauseClosesEveryDepositDoorOnTheEscrow`,
  `::test_pauseNeverClosesAProvidersOwnStakeTopUp`), so the *code* was right and one of the two
  *reasons* was wrong. The rule that predicts all four money doors is now written at `depositFor`
  and referenced from `depositStakeFor`: the pause closes a door whose only purpose is served by
  another door the pause has already closed, and never one that lets a party take their own money
  back or restore their own standing.
