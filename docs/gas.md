# Gas — `redeemVoucherBatch`, measured

Every number on this page was **measured** locally with the pinned toolchain below. Nothing was
copied from a doc, from a plan, or from the Anchor program. Each table names the command that
produced it, so any of it can be re-run and disagreed with.

- **Measured:** 2026-09-09 (first measured 2026-09-08; every figure re-measured, see below).
- **Tool:** `forge` **1.2.1-nightly**, commit `7e68208eaae86342998f4a713d27a538ce5a3fbb`, built
  2025-05-30 — the same pin `docs/chain-facts.md` records, and **not** to be upgraded, including to
  re-measure. If a re-measurement happens on a different build, record that build here rather than
  silently replacing these numbers.
- **Build settings the numbers depend on:** solc 0.8.24, `evm_version = "shanghai"`, `via_ir = true`,
  optimizer on at 200 runs. A different optimizer setting is a different number.
- **Source:** the figures were measured against `src/X402Escrow.sol` as it is in this repository.
  Re-run the commands in each table to reproduce or dispute them.

---

## The caveat that comes before every number on this page

**These figures are measured against `test/helpers/MockUSDG.sol`. They are not USDG's numbers.**

`MockUSDG.transfer` is two `SSTORE`s and a mapping read. The real USDG **on 4663** is presumed to be
an upgradeable proxy with a blocklist: every transfer would pay a `DELEGATECALL`, a blocklist read on both
parties, and whatever else its implementation does on the day. That is a per-transfer difference, and
there are **two transfers per redeemed voucher**, so it scales with the batch rather than washing out
in it. **On 4663 that remains unverified, because the mainnet USDG address is unknown** (risk
register §10, `chain-facts.md` §1).

**The token deployed on 46630 is not that.** Measured 2026-09-10: 5,652 bytes of plain Ownable ERC-20
plus a faucet, EIP-1967 slot zero, no blocklist under any of five spellings
(`chain-facts.md` §1a). So the sentence above is a warning about mainnet, and the paragraph below is
the measurement on testnet.

**Re-measure against the live token on 4663 before any of this is used for capacity planning,
block-fill estimates, or a decision about `MAX_REDEEM_BATCH`.** A measured number on a mock is not a
measured number on the chain, and treating it as one is exactly the error this caveat exists to
prevent.

### Re-measured on a fork of 46630 — and the direction is NOT what was predicted

`test/fork/MoneyPaths.fork.t.sol` re-runs this suite with the fixture's token pointed at the real
46630 deployment. Both figures below are `test_measure_distinctPayerBatchOfSixtyFour`, from the same
tree and the same commit, so they differ **only** in the token:

| token | `redeemVoucherBatch(64)`, distinct payer + distinct provider | per voucher |
|---|---|---|
| `MockUSDG` | **5,235,730** | 81,808 |
| real 46630 USDG | **5,323,988** | 83,187 |
| difference | **+88,258 (+1.69 %)** — the real token is the MORE expensive one here | +1,379 |

Read at a recent fork block (the run spans blocks; `latest` moved under it).
**A fork run has no pinned block, so this is an observation with a block beside it and not a pin** —
`chain-facts.md` §6. It may never enter `.gas-snapshot`; gate 9 refuses it if it does.

**Two things this corrects.** The prediction made before this measurement was that the fork figure
would come back roughly **540,000 LOWER**, extrapolating from a single-transfer comparison: `MockUSDG`
30,506 gas against the real token's 26,253 (measured here as
`ForkFacts.t.sol::test_measure_realTransferGas`, a recent fork block). It came back **88,258
higher**. So:

1. **A single-transfer figure does not extrapolate to a batch.** The 128 transfers in a worst-case
   batch differ in warm/cold slot mix, recipient-slot initialisation and account-access state from an
   isolated `transfer` between two fresh addresses, and the sign of the difference reverses. Quote
   the batch figure, never 128 × a transfer figure.
2. **The "real USDG is more expensive" instinct is right for 46630 in the shape that matters**, but
   by 1.69 %, not by the order of magnitude a proxy-plus-blocklist would cost. Nothing here says
   anything about 4663.

Recomputed against `maxTxGasLimit = 32,000,000`: **16.6 %** of the ceiling, **6.01×** headroom,
~417,000 gas of room per voucher. `MAX_REDEEM_BATCH = 64` still holds, now against a real token.

---

## The operational rules — read these before the numbers

**Two things the chain cannot enforce and the backend must.** They are here, in a document about
gas, because this is where the first of them has always been written and a second copy of a rule is
worse than an odd home for it. Both are **backend requirements**, both are stated in the imperative, and
neither has any contract-side enforcement — by design in both cases.

### Backend requirement 1 — the router must stop quoting a buyer with a standing withdrawal request

> **When a buyer has a `WithdrawRequested` in flight, the router MUST NOT quote them and MUST NOT
> ask them to sign a voucher, until the request is either withdrawn or cancelled** (`amount == 0`
> retracts it in one call). A voucher signed after the request can outlive the delay, and the
> provider serves the request for nothing.

The arithmetic, because the boundary is not where it looks: a withdrawal requested at `T` matures
at `T + WITHDRAW_DELAY_SECONDS (3,600)`. A voucher is redeemable until
`expiresAt + REDEEM_GRACE_SECONDS (1,800)`, and `expiresAt` may be up to
`VOUCHER_MAX_LIFETIME_SECONDS (300)` past `issuedAt`. So a voucher signed at **`T + 1381` or later**
can still be redeemable after the withdrawal has matured and been taken. `withdraw()` reads no
outstanding-voucher state and pays `min(requested, balance)`; the redemption then fails
`EscrowInsufficient`.

The contract's own guarantee is the other half and it is real: a voucher signed **before** the
request cannot outlive the delay, because `3,600 > 2,220`. That half is asserted at deployment and
tested (`X402Escrow.bysig.t.sol::test_theWithdrawDelayOutlivesEveryVoucherSignedBeforeTheRequest`,
`Types.t.sol::test_withdrawDelayOutlivesTheLongestRedeemableVoucher`). The half above cannot be:
it would need an outstanding-voucher set the contract deliberately does not hold, and **Solana's
`withdraw.rs` has no such check either**, so this is parity rather than a port defect.
`docs/risk-register.md` §13 carries it as an accepted, disclosed risk.

### Backend requirement 2 — the batch is atomic, so pre-validate

`redeemVoucherBatch` is **atomic**. One bad voucher reverts the whole batch: the good vouchers in
front of it do not settle, and neither do the ones behind it.

That is a decision, not an oversight. Skip-and-continue would need a per-item `try`/`catch` — an
external self-call per item — it would leave an event stream that no longer says which vouchers
actually settled, and it would let one malformed item quietly drop 63 good ones into a state nobody
reconciles.

The cost of that decision lands on the backend:

> The redemption job MUST pre-validate every voucher before putting it in a batch, and when a batch
> reverts it MUST retry the items **singly** rather than re-submitting the batch.

Pre-validation is the same list `_redeem` applies, evaluated off chain against current state: the
voucher window (`expiresAt > issuedAt`, lifetime ≤ 300 s, issued no more than 120 s ahead, redeemed
no more than 1 800 s late), `seq > seqHigh` **for that payer**, the payer's per-call and
rolling-window ceilings, the provider's `bonded` stake against `minimumStake`, and the payer's
balance.

Three rules bite specifically in the batch shape, and a job that does not know them will build
batches that revert:

- **`seq` is per payer, not per batch.** Two payers' sequences constrain each other in no way at
  all; one payer's items must be ordered among themselves. Sorting a batch by `seq` globally is
  wrong.
- **The same voucher twice in one batch reverts the batch.** The second copy fails `seq > seqHigh`,
  because the first copy already advanced it.
- **The parameter set is read once for the whole batch.** Every item settles against the treasury
  and take rate that were current when the batch started, even if a Config update lands mid
  transaction. That is deliberate, and pinned by
  `test_theParameterSetIsReadOnceForTheWholeBatch`.

---

## `redeemVoucherBatch`, one payer, one provider

The uniform shape: `n` vouchers of 1 000 base units from one buyer to one provider, take rate
1 000 bps, so each item pays a provider 900 and the treasury 100.

| batch size | total gas | per voucher | 2026-09-08 edition |
|---|---|---|---|
| 1 | **171 268** | 171 268 | 165 912 (+3.2 %) |
| 8 | **330 995** | 41 374 | 320 211 (+3.4 %) |
| 64 | **1 623 055** | 25 360 | 1 569 237 (+3.4 %) |

`redeemVoucher` — the single-voucher entry point, same voucher, same cold state — is **170 452**. So
a batch of one costs 816 gas more than not batching at all, and everything past the first item is
marginal cost rather than entry cost: the 2nd through 64th vouchers average about **23 044** each.

The right-hand column is kept for one release so the drift is legible rather than silent: the three
commits between the two measurements moved `_redeem`'s call path, and the 816-gas batch-of-one
premium is unchanged across them.

```sh
forge test --match-contract X402EscrowBatchTest --match-test 'test_measure_' -vv
```

**On the single-transaction measurement loop.** `test_measure_batchGasAtOneEightAndSixtyFour` measures the
same three sizes inside ONE transaction, separated by `vm.snapshotState()` / `vm.revertToState()`,
and reports **171 268 / 331 027 / 1 624 558**. The EVM's warm/cold access list is a per-transaction
thing, so sizes 8 and 64 measured after size 1 *could* have been reading slots the size-1 run had
already warmed — which would have made the loop's figures too low. Measured, they are within 0.1 %
of the one-size-per-test figures (+32 at size 8, +1 503 at size 64, i.e. +0.09 %) and if anything
slightly **higher**, so the effect is not present at this scale. The table above quotes the one-test-per-size figures because those are unambiguous;
the loop is kept because it is the shape originally proposed and because this comparison is the evidence
that the shape does not matter here.

### What `--gas-report` says, and why it is not the number to quote

`forge test --gas-report` on the same tree reports, for `X402Escrow`:

| function | min | avg | median | max | calls |
|---|---|---|---|---|---|
| `redeemVoucher` | 866 | 104 914 | 125 550 | 229 540 | 1 791 |
| `redeemVoucherBatch` | 963 | 437 235 | 397 686 | 5 152 672 | 290 |

**Every one of those columns is an average over the whole suite, reverts included** — the 963 and
the 866 minima are calls that reverted on the first guard, and the maxima are the 64-item
distinct-payer fixtures. It is a regression signal, not a cost. The tables above are single calls
of a stated shape, and they are what to quote.

**And it is not even a stable regression signal.** Two consecutive runs of the same command on the
same tree, measured 2026-09-09, disagree: `redeemVoucher` reports `1 791` calls / avg `104 914` in
one and `1 787` / `105 162` in the next. The invariant campaign contributes calls through randomly
generated sequences that are not seeded run to run, so both the call count and every average that
divides by it move. Do not diff this table between runs and read the difference as a change to the
code.

## Same payer versus distinct payers — the number that decides how a batch is grouped

The variable that matters is how many **cold** storage slots a batch touches. A second voucher for a
buyer the batch has already touched writes warm slots; a voucher for a fresh buyer pays the cold
surcharge on that buyer's escrow. The same is true of the recipient's token balance — and the two
are measured **apart**, because the obvious fixture moves both at once and a figure that conflates
them answers a question nobody asked.

At **8 items**:

| shape | total gas | per voucher | vs the uniform baseline |
|---|---|---|---|
| one payer, one provider | 330 995 | 41 374 | — |
| **distinct payers**, one provider | 551 138 | 68 892 | **+27 518** per voucher |
| one payer, **distinct providers** | 512 243 | 64 030 | **+22 656** per voucher |
| distinct payers **and** distinct providers | 732 371 | 91 546 | +50 172 per voucher |

At **64 items**:

| shape | total gas | per voucher |
|---|---|---|
| one payer, one provider | 1 623 055 | 25 360 |
| **distinct payers**, one provider | 3 604 365 | 56 318 |
| one payer, **distinct providers** | 3 254 596 | 50 853 |
| distinct payers **and** distinct providers | **5 235 730** | 81 808 |

The two effects are **additive to within 2 gas per voucher** at size 8 (27 517.875 + 22 656.000 =
50 173.875, against 50 172.000 measured together — 15 gas across the whole batch), which is what
makes it legitimate to attribute them separately.

**What the backend should take from this.**

- Grouping a batch **by payer** is worth about **27 500 gas per voucher** at these sizes, which is
  roughly two thirds of the entire marginal cost of a same-payer item. It dominates every other
  batching heuristic.
- It does **not** follow that a batch may be reordered to achieve it. `seq` is per payer and
  strictly increasing, so one payer's items must keep their relative order whatever else the
  grouping does.
- The **distinct-provider** column is the smaller half and it is mostly a *first payment* cost:
  paying a provider whose settlement-token balance is zero writes a zero → non-zero slot. It is not
  recoverable by batching and it does not repeat for that provider.

## Calldata

Measured off the real ABI encoding, not counted off the struct by hand
(`test_measure_calldataBytesPerVoucher`):

| encoding | bytes |
|---|---|
| `redeemVoucher(v, sig)` | 420 |
| `redeemVoucherBatch`, 1 item | 548 |
| `redeemVoucherBatch`, 8 items | 3 460 |
| `redeemVoucherBatch`, 64 items | 26 756 |
| **marginal per voucher** | **416** |

416 bytes is 256 for the eight `Voucher` words plus 160 for the signature — an offset word, a length
word, and 65 bytes padded to three words. The batch's own envelope — selector, two array offsets,
two array lengths — is 132 bytes, and it is paid **once** instead of once per voucher.

**Why this matters more here than on L1.** Robinhood Chain is an Orbit L2
(`docs/chain-facts.md`), so a transaction's cost has an L1 data component that is a function of its
calldata, on top of the L2 execution gas tabled above. Batching does **not** reduce the per-item 416
bytes — that is paid either way. What it removes is the per-*transaction* envelope: one signature,
one nonce, one 21 000 intrinsic gas, one L1 fixed overhead, amortised across up to 64 redemptions
instead of paid 64 times. That, and the warm-slot effect above, is the whole of why batching pays.

## `MAX_REDEEM_BATCH = 64`

**Not copied from Solana.** `REDEEM_PER_TRANSACTION = 1` in the Anchor program is an artefact of
Solana's 1 232-byte packet limit and the account list a CPI token transfer needs. Neither constraint
exists on EVM, so neither the number nor any Solana gas figure travels; the bound had to be chosen
here and written down, and it is declared at `src/Constants.sol`.

What 64 costs, measured: about **1.62 M gas** for a full same-payer batch and **5 235 730** for
the distinct-payer/distinct-provider worst case, against a mock token — and **5 323 988** for that
same worst case against the token actually deployed on 46630 (see the fork table at the top of this
page). Take the larger: that is 16.6 % of the 32,000,000 `maxTxGasLimit` both chains report, a
6.01× headroom — `docs/chain-facts.md` §5 derives
the validation of `MAX_REDEEM_BATCH = 64` from exactly this figure, so the two pages move together
and a re-measurement here is not finished until §5 is redone. The worst case is the figure
to re-check against the live USDG before the cap is raised — see the caveat at the top of this page,
which applies to that 5.24 M more strongly than to anything else here, because it is the number
closest to a block limit.

## Re-measuring

```sh
forge test --match-contract X402EscrowBatchTest --match-test 'test_measure_' -vv
forge snapshot                 # writes .gas-snapshot
forge test --gas-report
```

`.gas-snapshot` is committed beside this file. It is a **per-test** figure, not a per-function one,
so it includes each test's own fixture work and is useful for spotting a regression rather than for
quoting a cost; the tables above are the per-call `gasleft()` deltas and are the numbers to quote.

**Correcting what this paragraph used to say about the fuzz rows.** It claimed they "move between
runs by construction — the fuzzer's seed is not pinned", and offered that as a reason not to read a
diff there. Measured 2026-09-09 over four consecutive runs: the `testFuzz_*` μ and ~ figures are
**byte-identical run to run**, and a diff on one of them *is* evidence. What is not pinned is the
`runs:` count, and it is not the seed that moves it — it is `cache/fuzz/failures`, proptest's
persisted failure corpus, which is gitignored, machine-local, appended to whenever any fuzz test has
ever failed on that machine, and replayed **before** the configured runs. Three saved seeds turn
`runs: 512` into `runs: 515` and shift that row's μ. `docs/ci-gates.md` §8 has the measurement and
the consequence for the gate; the short version is that `rm -rf out cache` before a regeneration is
not optional.

## Contract sizes (EIP-170)

Measured by `script/check-sizes.sh`, with CBOR metadata enabled (about 54 bytes of each runtime
figure is the metadata trailer). **Runtime** is the figure EIP-170 bounds —
the `ERC1967Proxy` in front of each implementation is ~50 bytes and irrelevant to the limit.

| Contract | runtime bytes | % of the 24,576 limit | creation bytes |
|---|---:|---:|---:|
| `X402Config` | 5,202 | 21.2% | 5,411 |
| `X402Escrow` | 11,881 | 48.3% | 13,308 |
| `X402Stake` | 13,023 | 53.0% | 14,450 |

The gate fires at **22,000**, leaving room for an auditor's remediation round and for the append a
future upgrade adds. If a contract ever goes over it, **the gate does not move** — the contract
splits, and the reason is recorded in the pull request that does it.

The creation column is information only. EIP-3860 bounds initcode at 49,152 bytes and nothing here
is within a factor of three of it. The two columns differ by 1,427 bytes on both money contracts:
constructor code plus the EIP-712 ShortString immutables, which are returned as part of neither.
