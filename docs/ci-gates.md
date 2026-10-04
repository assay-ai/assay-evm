# The CI gate set, and what each one cannot see

**Ten** commands — count the block below rather than trusting this line. It said "seven" while the
block listed eight once already, which is the same class of rot as everything else on this page.
(The numbered sections run to §10 and do NOT map one-to-one onto the commands: §3 covers **two** —
the per-commit layout gate and the branch-level one, which answer different questions — and §9 is
not a command at all, it is a test that lives inside gate 7.) Every one of them has a blind spot, and the
blind spots are written down here because a gate whose limit nobody has stated gets read as covering
more than it does.

**No `deployments/` record is published in this repository.** `script/new-deployment-record.sh`
writes `deployments/<chainId>.json` when you deploy, and gate 6 skips cleanly when there is none.
Every mention of `deployments/46630.json` below describes a record the authors generated for their
own testnet runs; it is not part of this repository, and the outputs quoted are what such a record
produces.

The GitHub Actions workflow (`.github/workflows/ci.yml`) runs the core subset on every push and pull
request: `forge fmt --check`, `forge build`, `forge test` (non-fork) and `./script/check-snapshot.sh`. The full set below is the
local pre-merge sequence.

Run from the repository root, with `FOUNDRY_DISABLE_NIGHTLY_WARNING=1` exported. **Run them in this order**: the
`rm -rf out cache` on line 2 is a precondition of gates 3 and 8 both, for two unrelated reasons
(§3 and §8 below).

```sh
forge fmt --check                  # 1
rm -rf out cache && forge build    #   (see check-layout.sh's header: a partial out/ renumbers astIds)
./script/check-vendor.sh           # 2
./script/check-layout.sh           # 3   — the per-commit question
./script/check-layout-branch.sh    # 3b  — the same question asked against the MERGE BASE
./script/check-sizes.sh            # 4
./script/check-errors.sh           # 5
./script/check-bytecode.sh         # 6   — "skipping deployments/46630.json (status: pending-deploy)"
forge test                         # 7
./script/check-snapshot.sh         # 8   — forge snapshot --check; see §8 (fork suite and path-dependent tests excluded)
./script/check-fork-isolation.sh   # 9   — the fork suite stays out of 7 and 8
```

---

## 1. `forge fmt --check`

`foundry.toml`'s `[fmt] line_length = 100` is set so that `forge fmt` agrees with code already
written at a 100-column width; without it
the gate would have been a permanent red at forge's default 120 and would have been ignored.

Blind to everything except layout. It has never caught a defect here and is not expected to; it is
in the list so that a diff never contains a reformatting the author did not intend.

## 2. `./script/check-vendor.sh`

Pins `lib/openzeppelin/` to v5.1.0 = `69c8def5f222ff96f2b5beff05dfba996368aa79`, 31 files.

**Cannot see** a dependency added outside `lib/openzeppelin/`. `auto_detect_remappings = false`
plus an explicit `remappings.txt` is what stops a second spelling of one dependency compiling
beside the first; the vendor gate assumes that is still true.

## 3. `./script/check-layout.sh` — and the merge-base problem

The upgrade-safety gate (D-7). Its refusals are recorded verbatim in
`test/MUTATION-LOG.md` § *Upgrade-safety gate*, including that `--update` refuses
to launder a non-append.

**The blind spot, and it is the one that matters: it compares the WORKING TREE's snapshot with the
working tree's source.** One commit can move both together, and then there is nothing left to
disagree with. `--update`'s classify-before-write refuses a non-append — but `--update` is not the
only way a snapshot gets written, and a plain `forge inspect … > snapshots/X.json` in the same
commit as the source edit leaves this gate reporting `layout unchanged` over a reorder. Measured
below.

(This paragraph used to end *"…it does not stop two legal appends from adding up to a change nobody
reviewed as a whole."* **That is false, and it was the premise of the branch gate's design.**
Appends compose: two legal appends net to a legal append. The hole is the hand-written snapshot,
not the arithmetic.)

**CI must classify against the MERGE BASE**, not against `HEAD`. That recipe sat on this page as
PROSE for three commits and nothing ran it; it is now `./script/check-layout-branch.sh [base-ref]`
(the default base ref is set at the top of the script), and it is command **3b** in the block above. The per-commit script
stays exactly as it is; the two answer different questions and both are wanted.

### `check-layout.py`'s exit code is READ, not tested for truthiness

The prose version of this recipe ended `python3 script/check-layout.py … || { echo "not an
append"; exit 1; }` and claimed the `||` "catches only the refusal". **It does not.** Shell `||`
and `if !` fire on **any** non-zero status, and the classifier exits **2 for a legal append** — the
ordinary case on every upgrade branch. Measured 2026-09-10 while proving the new script, on a probe
branch carrying one appended `uint256` on `X402Stake`:

```
classifying against merge base 3f56c11 (<base-ref>)
X402Stake: the BRANCH is not an append against the merge base.
branch EXIT=1                      <- and the change was a LEGAL APPEND
```

A gate that refuses the change it exists to permit is a gate somebody switches off. The script
reads `$?` and refuses on **1 only**; an unrecognised code fails **closed**, because a classifier
that has started answering a fourth thing is not one this gate may pass over.
`test/GateSelfTest.t.sol::test_theBranchLevelLayoutGateExists` pins both halves.

### What the branch gate catches, and what it took to produce a refusal

**Two legal appends cannot net to a refusal.** Appends compose: if HEAD is an append of commit 1
and commit 1 is an append of the base, HEAD is an append of the base. So the two-appends story is
not the hole, and the real one is narrower and worse — **a commit that regenerates the snapshot
WITHOUT `--update`.** `--update` classifies before it writes and refuses a non-append; a plain
`forge inspect X402Stake storageLayout --json > snapshots/X402Stake.storage.json` does not, and the
per-commit gate then diffs the new snapshot against the new source, finds them identical, and
prints `layout unchanged`. Measured 2026-09-10, two commits, each green on `./script/check-layout.sh`:

```
commit 1  append `uint256 public branchProbeA`, gap 49->48, snapshot via --update
          ./script/check-layout.sh --update  ->  "X402Stake: snapshot updated (append-only change)"
          ./script/check-layout.sh           ->  layout OK,  EXIT 0
          ./script/check-layout-branch.sh    ->  "APPEND-ONLY against the merge base", EXIT 0

commit 2  INSERT `uint256 public branchProbeB` in the middle of the base layout, gap 48->47
          ./script/check-layout.sh --update  ->  REFUSED, "appends go at the END, never in the middle"
          snapshot regenerated by hand instead
          ./script/check-layout.sh           ->  "X402Stake: layout unchanged", layout OK, EXIT 0
          ./script/check-layout-branch.sh    ->  REFUSED: stakes 5+0 -> 6+0, verifierWindows 6+0 ->
                                                 7+0, totalStaked/Deposited/Withdrawn/Slashed and
                                                 slashRecords all moved,  EXIT 1
```

The per-commit gate is **green on the branch tip** while the branch gate refuses it. That gap is
the whole reason 3b exists.

**Its default base ref can be vacuous.** If the snapshots do not exist at the merge base,
`./script/check-layout-branch.sh` prints *"no snapshot at the merge base — this contract is NEW on
this branch, nothing to compare"* for all three contracts and exits 0. That is the correct answer to
the question asked, and it is also a gate comparing nothing: pass the ref you actually mean
(`./script/check-layout-branch.sh <base-ref>`). Read the three per-contract lines, not just the exit
code.

**Cannot see** a layout change made by a commit that is already on the base branch — it classifies
this branch's net effect, nothing else — and it cannot run without the base ref present locally.
A missing merge base is a refusal, not a skip: fetch the base ref first, because a stale local ref
would make the gate compare against the wrong commit.

## 4. `./script/check-sizes.sh`

EIP-170, per implementation, gated at 22,000 of the 24,576 hard limit. Measured today:
X402Config 5,202 · X402Escrow 11,881 · X402Stake 13,023 (runtime bytes, CBOR metadata included).

It measures **`deployedBytecode`**, not `bytecode`. Creation bytecode is the wrong number: EIP-170 bounds runtime only, and the two differ by 1,427 bytes on both
money contracts here. Creation size is printed **beside** the runtime one as information, which is
why the pin cannot be spelled "the file must not contain the word `bytecode`" — that string is
present in a correct file. `test/GateSelfTest.t.sol::test_theSizeGateMeasuresRuntimeBytecodeAndNotCreation`
pins the two things that actually matter: the `runtime=` assignment reads `deployedBytecode`, and
the `-gt "$CEILING"` comparison is made against `$runtime`. Both were proved to fail by mutation on
2026-09-10 (`check-sizes.sh stopped measuring runtime`, and `check-sizes.sh no longer GATES on the
runtime figure it measures`).

**Cannot see** a proxy's size (irrelevant, ~50 bytes) or EIP-3860's 49,152-byte initcode limit
(nothing is close). If a contract ever goes over, **the gate does not move** — the contract splits.

## 5. `./script/check-errors.sh`

Recomputes `src/Errors.sol`'s header accounting against the Anchor program's `error.rs` (from a
local checkout of the `assay-solana` repo, passed as `RUST_ERRORS=<path>/programs/x402-payment/src/error.rs`;
without it the script exits 2) — 55 variants, 50 ported under the same name, 21
EVM-only, 5 deliberately absent — and fails when the prose and the measurement disagree. Before
this gate existed those four numbers were hand-maintained, nothing imported the
file and no test counted its declarations, so the next error added would have made them quietly
wrong.

It also lists **errors declared with no `revert` producer in `src/`**. Today that list has five
entries and every one of them is argued for in `docs/divergences.md`. It is deliberately a report
and not a failure: `InvalidAdmin` has exactly one producer and the `address(0)` sentinel on the
`updateConfig` path is the refusal, so a selector-table comparison against the deployed ABI will
always show an intentional gap there. **A name appearing on that list for the first time is a
review item** — either it needs a producer or it needs deleting.

**Cannot see** an error produced through a path the line scanner misses (a `revert` assembled in
assembly, or re-thrown from a `try/catch`). It is a source-text scan, like gate 7's `ecrecover`
check below, and inherits the same limit.

## 6. `./script/check-bytecode.sh`

Implementation-bytecode **and function-surface** drift against `deployments/<chainId>.json`.
Reports `skipping` for a record whose `"status"` is not `"deployed"`, which is correct before a
chain's first deploy rather than a failure.

The two comparisons answer different questions and both are wanted. Bytecode drift says *the code
changed*; surface drift says *the code changed shape*, and only the second can hand a live proxy a
door nobody reviewed. They separate because `implementationRuntimeKeccak` is rewritten by the
operator as part of every upgrade — so it confirms the deployed code matches the **new** source,
never that the new source's shape matches the old. `script/abi-surface.sh` carries the argument and
the limits; `docs/deploy-runbook.md` §7 carries the checklist item.

**A defect this gate had until 2026-09-09, worth recording because of its shape.** The bytecode
comparison was written `got=$($FORGE inspect "$c" deployedBytecode | cast keccak)`. That pipe form
fails — `Error: odd number of digits`, from the trailing newline — and under `set -euo pipefail` it
aborted the gate before it compared anything. It had never been noticed because no record has ever
reached `"status": "deployed"`, so the loop containing it had never executed: the gate printed
`no deployment records yet` and exited 0, and that was read as *passing*. It is fixed (the argument
form with `tr -d '\n'`, which `new-deployment-record.sh` had always used) and pinned by
`Upgrade.t.sol::test_theDeploymentScriptsCarryTheFunctionSurfaceGate`. Same family as everything
else on this page — a gate that answers a different question than the one it is read as answering.

> **Note for this public copy:** no deployment record is published, so the gate prints
> `no deployment records yet` and exits 0 here. The walkthrough below was recorded against a
> record that is not part of this repository; to exercise the gate yourself, generate one with
> `script/new-deployment-record.sh` and set its `status` to `"deployed"`.

### It has now run, and it has now been seen to fail — both ways (2026-09-10)

`deployments/46630.json` was first written with real hashes and placeholder addresses. The
gate never reads an address, so its `"deployed"` branch is fully exercisable before a deploy, and
that is how the loop body was executed for the first time in this repository's history:

```
status "pending-deploy"   ->  skipping deployments/46630.json (status: pending-deploy)
                              bytecode OK                                        EXIT 0
status "deployed"         ->  bytecode OK                                        EXIT 0
                              and NO "skipping" line — the loop body ran
```

Then, twice, made to fail on the two different questions it answers:

```
(a) one hex digit of .contracts.X402Escrow.implementationRuntimeKeccak changed
    implementation bytecode drift in X402Escrow vs deployments/46630.json
      built  0x<runtime keccak of the current build>
      record 0xdeadbeef00000000000000000000000000000000000000000000000000000000
      -> this is an UPGRADE (runbook §7) or a redeploy. Say which in .status.   EXIT 1

(b) `setAdminUnchecked(address)` appended to X402Config — the mutation that handed the admin
    key, and with it the upgrade authority of all three contracts, to any caller while 382 tests
    stayed green. With the record's bytecode hash refreshed so that ONLY the surface is violated:
    function surface drift in X402Config vs deployments/46630.json
      built  0x7860aa586c7af215c99fa3360643f2f1075519af1af18d7706f1e4f4cb6d20ba
      record 0xb69c05d8e1f74cb03c2357cc1b22f57989d8b6894c6546b508bf95048d11dc47
      -> a function was ADDED or REMOVED. ./script/verify-deployment.sh names which.  EXIT 1
    and verify-deployment.sh named it:  + 1e16a625 setAdminUnchecked(address)
    and `forge test` was red on the surface pin:
      [FAIL: X402Config's external surface changed size: 17 != 16]
      test_theConfigFunctionSurfaceIsPinnedByName()
```

A record stays at **`pending-deploy`** until the deployment exists, because the committed state must
not claim a deployment that does not exist. Once `deployments/46630.json` was flipped to
`"deployed"`, the comparison loop runs on every invocation.

**Cannot see** anything about a deployment that has not happened: with every record at
`pending-deploy` it compares nothing, exactly as it did before. It also **cannot compare the record
against the chain** — an EVM account exposes bytecode, not an ABI. It compares the record against
the local build; the record-to-chain link is the bytecode hash, and `verify-deployment.sh` is where
that comparison is made.

## 7. `forge test`

Three limits worth stating.

**The "no `ecrecover` outside `Sig`" gate is a SOURCE-TEXT SCAN.**
`X402Escrow.domain.t.sol::test_recoveryHappensAtExactlyOneCallSiteInSrc` walks every `.sol` file
under `src/`, skips comment lines, and counts three spellings of a recovery call. It catches every
spelling a human would write, and **it cannot see a raw `staticcall` to precompile `0x01`** — the
address is a number, not a name, so no textual scan can distinguish it from any other
`staticcall(gas(), 1, …)`. It also cannot see a recovery reached through an `address(lib).call`
into a contract outside `src/`. Say so out loud, because the four EIP-2 guards in `Sig.recover`
are only guards if every recovery goes through them, and this gate is the *only* thing enforcing
that.

**The ABI gate pins 23 function names on the escrow, 16 on the config and 24 on the stake.**
`X402Escrow.withdraw.t.sol` asserts `keys.length == 23` and every name over the escrow's external
surface; `Upgrade.t.sol::test_theConfigFunctionSurfaceIsPinnedByName` and
`::test_theStakeFunctionSurfaceIsPinnedByName` do the same for the other two, both directions, so
a rename with an unchanged count is caught as well as an addition. **Any later addition makes them
red on purpose** — growing the surface of a contract that holds money, or of the one that holds
the admin key, is a reviewed act and not a side effect. A reader who meets it without knowing that
will read it as broken. The fix when the addition is intended is to change the list *and* say in
the commit message what was added.

Until 2026-09-09 only the escrow had this. Measured: adding `setAdminUnchecked(address)` to
`X402Config` left **all 382 tests passing**.

**These pins ship in the same commit that would change them**, which is their limit and always
was. The half that does not is `abiKeccak` in `deployments/<chainId>.json` — see gate 6.

**`fail_on_revert = false`** is set for the invariant profile, which is correct for a handler that
explores refusals and is also how an invariant suite becomes worthless: an all-reverts campaign
reports every identity green over an untouched state. `Invariants.t.sol`'s `afterInvariant` floor
and `test_theHandlerCanReachEveryAction` are the two halves that refuse it, and the degenerate is
measured in `test/MUTATION-LOG.md` — **7 green invariants over 16,384 calls that all did nothing.**

## 8. `forge snapshot --check`

**The snapshot check is path-independent by construction.** Twenty tests read the repository's
own files through `vm.readFile(string.concat(vm.projectRoot(), ...))` or otherwise depend on the
checkout path, and their gas follows the path: the same tree, built and run in two directories,
gives different figures for them (measured by running `forge snapshot` in three differently named
and differently long directories and diffing the outputs; the nineteen are exactly the rows that
differed, apart from the invariant rows below, and all other rows were identical). The invariant
runs are path-dependent as well: their `reverts` counts differ between directories, so every
`invariant_*` function is excluded from the snapshot too. `./script/check-snapshot.sh` therefore
excludes exactly those tests by name (`--no-match-test`) as well as `test/fork/*`, and `.gas-snapshot`
carries no row for them. They still run, with every assertion intact, in `forge test`. The
excluded tests are: `testFuzz_onlyTheNamedBuyersOwnKeyAuthorisesEitherDoor`,
`test_boundary_theDeadlineAdmitsItsOwnInstant`, `test_wrongState_oneNonceServesBothDoors`,
`test_theWithdrawDelayOutlivesEveryVoucherSignedBeforeTheRequest`,
`test_everyBytes32ConstantInTypesSolIsNamedATypehash`,
`test_everyRegisteredTypehashMatchesItsCompiledStruct`,
`test_everyTypehashDeclaredInTypesSolIsRegistered`,
`test_paramSetCarriesItsDeclaredWidthsAndOrder`,
`test_probeArtifactsAreEmittedBecauseTheProbesAreReferenced`,
`test_theAbiDerivationReproducesTheFullTypeString`, `test_theConfigFunctionSurfaceIsPinnedByName`,
`test_theStakeFunctionSurfaceIsPinnedByName`, `test_theDeployScriptUsesTheAtomicForm`,
`test_theDeploymentScriptsCarryTheFunctionSurfaceGate`,
`test_theWeakVerifierCannotSeeAnUnrecordedUpgrade`,
`test_theBatchDelegatesToTheOneRedeemPathInTheSource`,
`test_recoveryHappensAtExactlyOneCallSiteInSrc`,
`test_theSignatureComparisonIsUnconditionalInTheSource`,
`test_noProviderAddressIsExemptFromTheSignatureGuard` and
`test_theExitPaysMsgSenderAndTheAbiHasNoOtherWithdrawDoor`, plus every `invariant_*` run. Regenerate with
`./script/check-snapshot.sh --write`. The sections below were written before this exclusion, and
quote the plain `forge snapshot --check`.

**This section previously asserted the gate was green. It was not, and had not been for three
commits.** A review ran it and got exit 1, and so did a re-run. What follows is measured on
2026-09-09 rather than remembered, and the section is kept in the shape it had because its
*conclusion* — keep the gate — survived the correction. Its evidence did not.

### What it actually did, before the fix

```
$ FOUNDRY_DISABLE_NIGHTLY_WARNING=1 forge snapshot --check ; echo EXIT=$?
EXIT=1
Diff in "X402EscrowBatchTest::testFuzz_everyItemInABatchPaysItsOwnRecipientsExactly(uint64,uint64,uint64,uint64)": consumed "(runs: 515, μ: 529111, ~: 529652)" gas, expected "(runs: 512, μ: 529122, ~: 529665)" gas
Diff in "X402EscrowBySigTest::testFuzz_onlyTheNamedBuyersOwnKeyAuthorisesEitherDoor(uint256,uint256,uint64,uint64,uint64)": consumed "(runs: 515, μ: 165436, ~: 166010)" gas, expected "(runs: 512, μ: 165361, ~: 165939)" gas
Diff in "X402EscrowBySigTest::test_wrongSigner_everySignedFieldOfRequestWithdrawIsBoundIntoTheSignature()": consumed "(gas: 102882)" gas, expected "(gas: 102939)" gas
```

Byte-identical over three consecutive runs, so it was **deterministic and red**, not flaky. Three
causes, and separating them is the point of this section. The reviewer who first ran this gate got
**five** diff lines where the re-run got three, on the same tree and the same forge — the third cause below
is why, and it is the one worth reading.

**Cause 1 — real drift.** `.gas-snapshot` was written at an earlier commit and `X402Escrow.sol` moved three
times after it, the last of those through `_redeem`'s own call path. Two of the three
diffs are that: a deterministic non-fuzz row 57 gas low, and one fuzz row's μ 75 low. Same root
cause as the `docs/gas.md` pin, and both are fixed in the same commit.

**Cause 2 — `cache/fuzz/failures`, and this one is the trap.** The third diff is not drift. It says
`runs: 515` against a configured `[fuzz] runs = 512`, and 515 = 512 + **3**, the number of saved
seeds in `cache/fuzz/failures` — proptest's persisted failure corpus, which it re-runs *before* any
novel case. Measured directly: move that file aside and the diff count drops from three to two, and
`testFuzz_everyItemInABatchPaysItsOwnRecipientsExactly` matches the committed row exactly.

That file is **gitignored, machine-local, and append-only in practice**. It gains an entry every
time any fuzz test fails on that machine — which is every mutation-testing round this repo's method
requires — and it is never cleaned up. So the gate reads red on a developer's machine for a reason
that has nothing to do with the code, while naming gas figures, which is the worst possible way for
a gate to be wrong.

**`rm -rf out cache` before the run clears it**, and the run block at the top of this page already
does that — but nothing said *why*, so anyone running gate 8 on its own hits the phantom. That is
the connection this paragraph exists to make. On CI it does not arise: a fresh checkout has no
cache. A green run writes nothing to `cache/fuzz/`, so the gate stays clean once it is clean.

**Cause 3 — an INCREMENTAL `out/`, and this one is the reason the same tree gives different
answers to different people.** Editing a source file, building, reverting the edit and building
again leaves the tree byte-identical to the committed one — and the gate red:

```
$ shasum -a 256 src/X402Stake.sol
d48d81a4042d873d3b6138364eb685804a1928339963632bd7e6ce726c5a6506   # the committed file
$ forge snapshot --check ; echo EXIT=$?
EXIT=1
Diff in "X402EscrowBySigTest::test_pauseDoesNotCloseTheSafetyDirection()": consumed "(gas: 139269)" gas, expected "(gas: 139279)" gas
Diff in "X402EscrowBySigTest::test_wrongSigner_everySignedFieldOfSetLimitsIsBoundIntoTheSignature()": consumed "(gas: 123457)" gas, expected "(gas: 123382)" gas
$ rm -rf out cache && forge build && forge snapshot --check ; echo EXIT=$?
EXIT=0
```

Reproducible, and **nothing that ships is affected**. Measured across the two `out/` states:

| artifact | incremental `out/` | clean `out/` |
|---|---|---|
| `X402Escrow` runtime | `6d8fda51…` | `6d8fda51…` |
| `X402Stake` runtime | `e3c4f386…` | `e3c4f386…` |
| `X402Config` runtime | `70c8917a…` | `70c8917a…` |
| **`X402EscrowBySigTest` runtime** | **`ec22be1c…`** | **`cc905290…`** |

All three production contracts are byte-identical; the **test** contract is not. A partial
recompile compiles a *smaller compilation unit*, and under `via_ir` with the optimizer that unit
generates slightly different code for the test contract — whose own execution is part of what a
per-test gas figure measures. Tens of gas, on the tests that do the most work in Solidity.

This is the same mechanism `foundry.toml`'s `extra_output` comment already documents for the layout
gate, where a partial `out/` renumbers `astId`s: *"`forge inspect` compiles a SMALLER unit than
`forge build` does"*. Two gates, one cause, and the same precondition fixes both — which is why
line 2 of the run block is `rm -rf out cache && forge build` and why it is now called out at the
top of this page as a precondition of gates 3 **and** 8.

**So: gate 8 measures the tests, not the product.** A row moving is a signal to look, not a defect
in itself, and the first thing to check is whether the run was against a clean `out/`.

### What it does now, measured

`.gas-snapshot` regenerated 2026-09-09 after `rm -rf out cache && forge build`:

```
$ FOUNDRY_DISABLE_NIGHTLY_WARNING=1 forge snapshot --check ; echo EXIT=$?
EXIT=0
```

Three consecutive runs, then again after another full `rm -rf out cache && forge build`: exit 0
every time, no diff lines. **The gate can be green deterministically, and the condition is exact:
run it against a clean `out/` and an absent `cache/fuzz/failures`, which is one command.** The
answer to "if it cannot be green deterministically, what should it be instead" is that the question
does not arise — but the *precondition* is not optional and was not written down, which is how a
section asserting the gate was green survived three commits of it being red.

- the **`testFuzz_*` μ and ~ are byte-stable** run to run — the earlier edition of this section said
  so and that part was right, but it drew the wrong conclusion from it. A μ diff *is* evidence. What
  is not pinned is `runs:`, and what moves `runs:` is the failure corpus above, not the seed;
- the **`invariant_*` rows still churn** — their `reverts:` counts differ from the committed file on
  every run (2,083 / 2,097 / 2,099 … against the committed values) and `--check` reports **none of
  them**, because it compares *gas* and an `invariant_*` row carries no gas figure. That is a blind
  spot, not a feature: an invariant campaign that started reverting on 90 % of its calls would move
  those counts enormously and gate 8 would not notice. `Invariants.t.sol`'s `afterInvariant` floor
  is what covers it, and gate 7 is where that lives;
- **a test added anywhere in a test contract moves every row in that contract** by a few tens of
  gas, because the contract's own dispatch changes. Adding three tests to `X402StakeSlashTest` moved
  its 20 existing rows by ~54 gas each. Expect a snapshot regeneration in any commit that adds a
  test, and read that churn as normal.

And it has teeth: perturbing one `FeeTest` row by 1,000 gas produced
`Diff in "FeeTest::test_aCallTooSmallToDividePaysTheProviderInFull()": consumed "(gas: 9453)" gas,
expected "(gas: 10453)"` and exit 1.

### …and the fork suite, which must never reach this gate

`--no-match-path "test/fork/*"` is **load-bearing**, and it was added on measurement, against an
earlier argument that it should not be needed.

The argument for leaving it off was: the fork contracts skip themselves when `RH_TESTNET_RPC` is
unset, and *a skipped test emits no gas row*. The first half is true; **the second half is false.**
A contract whose `setUp` calls `vm.skip(true)` still produces a snapshot entry, and `forge snapshot`
writes it:

```
$ forge snapshot && grep -n '^Fork' .gas-snapshot
35:ForkFactsTest:setUp() (gas: 0)
$ forge snapshot --check ; echo EXIT=$?
No matching snapshot entry found for "ForkFactsTest::setUp()" in snapshot file
EXIT=1
```

So without the flag the two gates contradict each other: gate 8 demands a `Fork…Test:` row in
`.gas-snapshot`, and gate 9 (`check-fork-isolation.sh`, §10) refuses one. With the flag, no fork
row is ever written, gate 9's rule is an invariant rather than a race, and gate 8 keeps measuring
exactly the deterministic offline suite it was built for.

**The reason gate 9 still exists on top of the flag** is that the flag is a filter, not a proof. It
stops a fork row being *written*; it says nothing about whether a fork test reached the network
during a bare `forge test`. Gate 9 checks that separately, and checks the snapshot file for the
rows the flag is supposed to have prevented — a filter and an assertion about the filter's effect,
which is one mechanism and its check, not two mechanisms doing one job.

### Adding a file to `test/` moves other test contracts' gas — and that is not drift

Measured 2026-09-10, adding `test/fork/ForkFixture.sol` + `test/fork/ForkFacts.t.sol` and nothing
else:

```
Diff in "X402EscrowBySigTest::test_wrongSigner_everySignedFieldOfRequestWithdrawIsBoundIntoThe…()":
  consumed "(gas: 102882)" gas, expected "(gas: 102939)" gas
X402EscrowBySigTest deployedBytecode keccak   without test/fork  0xcc905290ef82b9a9…
                                              with    test/fork  0x3f94ca6c2e8608e5…
X402Config / X402Escrow / X402Stake           BYTE-IDENTICAL in both
  (identical runtime keccaks for each contract in both builds)
```

This is the same `via_ir` phenomenon §8 already records for an incremental `out/`, reached from the
other direction: the source **unit** changed size, so the IR optimiser emitted different code for a
*test* contract. `cc905290…` is the exact clean-build hash this page names.

**Before regenerating the snapshot for this reason, prove the production contracts did not move** —
the three keccaks above, from `cast keccak "$(forge inspect <c> deployedBytecode | tr -d '\n')"`.
Regenerating without that proof is how a real drift gets laundered into a green gate, which is what
`check-layout.sh --update` once did (see `test/MUTATION-LOG.md`).

**The consequence for CI:** keep `forge snapshot --check`, run it after `rm -rf out cache`, and
**never** add `git diff --exit-code -- .gas-snapshot` after a `forge snapshot`. The file churns on
every regeneration through its invariant rows, so a git-cleanliness check on it would be the gate
that is red at random — which is the one thing worse than a gate that is red for a real reason and
documented as green.

## 9. `forge test` again — the document checks inside it

`test/DocPins.t.sol` runs inside gate 7. It reads `docs/deploy-runbook.md` and fails if one of the
human-only preconditions, or the refusal to name a mainnet USDG address, disappears from it. It
gates a document rather than code, so it is called out here.

## 10. `./script/check-fork-isolation.sh` — the fork suite stays out of gates 7 and 8

`test/fork/` runs the money-path suites against the token actually deployed on 46630. Those runs
are **non-deterministic by construction**: the public RPC serves ~15 minutes of state and the depth
itself moves, so a fork block cannot be pinned and every run is against `latest`
(`docs/chain-facts.md` §6). Gate 7 is a determinism contract and gate 8 is a gas pin. A fork test
in either would make both red at random.

Two things are asserted, and the second is not the first:

1. **Offline, every contract under `test/fork/` SKIPS.** With `RH_TESTNET_RPC` unset the gate runs
   `forge test --match-path "test/fork/*"` and refuses on `[PASS]` (a fork test that ran without a
   fork proves nothing but looks green), on `[FAIL]` (offline it must skip, not run and lose), and
   on **no skip at all** — an empty `test/fork/` would otherwise make this gate pass over nothing,
   which is the shape this repo keeps hitting.
2. **`.gas-snapshot` carries no fork row.** The contract names are read out of `test/fork/*.sol`
   and each is looked for at the start of a snapshot line.

### Three things measured while building it, each of which had been assumed the other way

- **A skipped test DOES emit a snapshot row.** `forge snapshot` writes
  `ForkFactsTest:setUp() (gas: 0)`, so a bare `forge snapshot --check` demands a fork row and gate 9
  refuses one. Gate 8 therefore carries `--no-match-path "test/fork/*"` (§8), and this gate is the
  check that the flag worked — a filter plus an assertion about the filter, not two mechanisms.
- **Prefix-matching the contract names is not enough.** `^Fork[A-Za-z0-9]*Test:` catches
  `ForkEscrowDepositTest` and misses `Permit2ForkTest` and `BlocklistAccountingForkTest`. Measured:
  with a `Permit2ForkTest` row in the snapshot the prefix regex matched **0** rows and would have
  passed. The names are enumerated from source instead.
- **`out=$(forge test …)` under `set -e` aborts the script at the assignment** when forge exits
  non-zero, giving exit 1 with **no message** — right by accident, useless to a reader. The
  assignment carries `|| true` and the output is classified explicitly.

### The five ways it was proved to fail

Each fixture is wrong in exactly one way, and each failure message was read from the run, not
assumed.

| fixture | message |
|---|---|
| gate 8 regenerated without `--no-match-path` | `FAIL: .gas-snapshot carries fork rows for: ForkBoundariesTest …` (12 rows listed) |
| a `Permit2ForkTest` row — the one the prefix regex missed | `FAIL: .gas-snapshot carries fork rows for: Permit2ForkTest` |
| `vm.skip(true)` deleted from `ForkFixture._selectForkOrSkip` | `FAIL: a fork test FAILED with RH_TESTNET_RPC unset.` + 5 `[FAIL]` lines |
| `vm.skip(true)` deleted from `Fixture.setUp`'s fork branch | same, over the `MoneyPaths` half |
| a trivially-passing contract added under `test/fork/` | `FAIL: a fork test RAN with RH_TESTNET_RPC unset.` + `[PASS] test_thisPassesWithoutAFork()` |
| `mv test/fork /tmp` | `FAIL: test/fork/ declares no concrete contract.` |

**Cannot see** a fork test that reaches the network from `setUp` *before* the skip — nothing
textual can, and the only defence is that `_selectForkOrSkip` and `Fixture.setUp` both test the env
var first. It also cannot see a **non**-fork test handed a fork URL by an environment nobody
audited: it checks that `test/fork/` stays offline, not that the rest of the suite does.

And it says nothing about whether the fork tests are any good. It is an isolation gate. What the
fork suite proves, and what it explicitly does not, is `docs/chain-facts.md` §1a and §1b.
