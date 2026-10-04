# Risk register

Thirteen entries. Each says what it is, who it affects, and **what the contract does not do about
it** — because the value of this page is the last column. A risk with a mitigation is engineering;
a risk that is disclosed and accepted is a decision, and the decisions are what a reader needs to
find here rather than in a commit message.

Two of these are **mainnet blockers** and are marked as such.

Entries 11-13 were added on 2026-09-09 after a review observed that three exposures the
**Anchor source states out loud** were absent here — and this is the page that holds the
accepted-and-disclosed decisions, so an exposure that is disclosed in Rust and silent here is not
disclosed at all.

---

## 1. The issuer blocklists a provider's payout address

**On 4663, and unprovable there today** — the mainnet USDG address is unknown (§10). **Unprovable on
46630 too: that token has no blocklist**, under any of five spellings, measured from its bytecode
(`chain-facts.md` §1a). So the real interaction is OWED and cannot be started; §1 and §10 unblock
together.

**What IS proved, on a fork of 46630:** a payout transfer that reverts leaves the escrow's accounting
untouched — balance, `seqHigh`, `authNonce`, the escrow's token holding, the treasury's and
`totalEscrowed`, all six read before and after — and one bad recipient takes its **whole batch of
64** with it, debiting none of the other payers.
`test/fork/Blocklist.fork.t.sol`, with `test/helpers/BlockingUSDG.sol` as the reverting token and
positive controls on both. That is the *mechanism* a blocklist produces; it is not evidence about
the issuer's token.

If the issuer blocklists a provider's payout address, `redeemVoucher` reverts and that call is
never collected. The platform absorbs it, exactly as it
absorbs a `VoucherTooOld`, with a `voucher_unredeemable` alert.

**What the contract does not do:** nothing. There is no retry, no escrow of the provider's share,
no alternative payout address. Adding one would mean holding a provider's money on their behalf,
which is a second custody relationship this system does not want.

## 2. The issuer blocklists the escrow contract itself

**On 4663 only.** There is no such control on the 46630 token — no blocklist, no pause, no supply
controller among its 19 selectors (`chain-facts.md` §1a).

If the issuer were to blocklist the escrow proxy, every buyer's money would be frozen and **there is
no contract-level remedy.**

**An upgrade is not one either**, and this is the part that is easy to get wrong: the blocked
address is the **proxy**, and the proxy is exactly what survives an upgrade. Replacing the
implementation changes nothing about which address the issuer refuses.

This is a property of choosing a permissioned stablecoin. Accepted: issuer freeze risk of a
permissioned stablecoin (design decision). **Disclosed, not fixed, and out of scope for
an audit by design** — which is a decision, not an omission.

## 3. USDG is an upgradeable proxy

**On 4663, PRESUMED — unverified, because the address is unknown** (§10). **The 46630 token is NOT
proxied:** its EIP-1967 implementation slot reads zero, so the 5,652 bytes at that address are the
token itself and cannot be swapped under us (`chain-facts.md` §1a, measured; pinned by
`test/fork/ForkFacts.t.sol` against the runtime code hash).

Nothing below changes. The four `balanceOf` reads and the never-a-solvency-assertion rule are
properties of this contract, not of the token, and they stay whichever way §10 resolves.

Today's implementation has no transfer callbacks; tomorrow's might. The reentrancy guards and the
checks-effects-interactions ordering are what make that survivable, and `X402Escrow`'s four
`balanceOf` reads are all delta halves — **no read is ever a solvency assertion, and none may be
added** (a `balanceOf`-based solvency check would refuse *every* withdrawal rather than the one
actually blocked).

Since design decision D-1 these contracts *can* be patched if a future USDG breaks something — which lowers
this risk and raises the next one.

## 4. The upgrade key is the Ledger holding `Config.admin`, and a compromised Ledger is total loss

It can replace `X402Escrow`'s logic in one transaction with no delay and take every buyer's USDG.

This is **exactly the exposure the Solana program already carries** through its
`BPFLoaderUpgradeable` upgrade authority, and parity is why it was chosen (D-1) over the
immutable design of the first draft.

**What bounds it:** the key is hardware and **never** an environment variable, so the binding
threat model — a full leak of every key held in an env var — is untouched.

**What does not bound it:** nothing on chain. No timelock, no multisig, no pending-implementation
slot, by decision (D-1). Custody of that Ledger is the control, and it is the only one.

## 5. The admin key and the upgrade key are the same key — worse than Solana here

On Solana the program's admin and its upgrade authority are separate keys, and `update_config.rs`
says so plainly: a mistyped admin is recoverable, because the upgrade authority can deploy a fixed
program. **Here they are one key by D-1**, so a mistyped `newAdmin` in `updateConfig` loses both at
once and there is nothing left to repair it with.

The exact scenario, because "unrecoverable" is too abstract to act on:

> The operator finishes the 46630 deploy from a hot key and runs the handover:
> `updateConfig(params(), 0x…)`. One hex character of the Ledger address is wrong — a
> transposition, or a character copied from a truncated display. The transaction succeeds:
> `X402Config._validate` checks the parameters, and `newAdmin` is only checked against
> `address(0)`, so any other 20 bytes is accepted. From that block:
>
> - the hot key is no longer the admin, so it cannot undo it;
> - the Ledger was never the admin, so it cannot either;
> - `_authorizeUpgrade` on all three contracts is `onlyAdmin` and resolves to `CONFIG.admin()`
>   **live**, so the mistyped address is now the upgrade authority of `X402Config`, `X402Escrow`
>   and `X402Stake`;
> - `setPaused`, `registerVerifier`, `revokeVerifier` and `updateConfig` are all gone with it;
> - buyers can still `withdraw()` and providers can still `withdrawStake()` — those are
>   `msg.sender`-only and never pause-gated (`test_pauseNeverClosesTheBuyersExit`) — so the money
>   is not lost, but nothing can ever be configured again and no defect can ever be patched.
>
> The only remaining move is a full redeploy and a migration of every buyer and provider.

**Mitigated only by procedure**, and the procedure is `docs/deploy-runbook.md` §6: read the new
address **off the Ledger's own screen**, prove control of it with a signature or a dust
transaction **before** the handover, paste rather than type, and `cast call … admin()` before and
after.

## 6. The treasury on 4663 is a 1-of-1 Ledger EOA, not a multisig

Decided as a design choice, against the Solana side's Squads multisig. It is a **custody downgrade**, it
is accepted, and it is recorded here rather than in a commit message. A multisig is the planned
direction.

Safe's presence on 4663 was measured (`chain-facts.md`) and blocks nothing. Moving to a multisig later is a
`treasury` change through `updateConfig`, not a contract change.

## 7. Sequencer liveness

A halted Orbit sequencer freezes withdrawals. The mitigation is the parent chain's force-inclusion
path, and **the delay is an Orbit configuration that must be read from the actual chain and written into the
runbook.** It is not a contract concern and there is no contract-side mitigation.

## 8. No gasless first deposit

A buyer holding zero ETH needs one funded transaction before Permit2 helps (D-11).

## 9. **A zero-ETH buyer cannot WITHDRAW — MAINNET BLOCKER**

Distinct from entry 8 and much worse. `withdraw()` is `msg.sender`-only and pays `msg.sender`, and
there is deliberately **no `withdrawBySig`**:

- a destination parameter is a place for a compromised console to redirect a withdrawal;
- `requestWithdraw` already served the one-hour delay, so by the time `withdraw` is callable the
  brake is spent and a phished signature would drain the escrow with nothing left to stop it.

Both decisions are right and neither should be softened. **Their cost is that a buyer holding USDG
in escrow and no ETH on 4663 cannot get their money out at all.**

The two answers both live outside the contract:

1. the buyer sends themselves ETH from anywhere;
2. **the relayer funds their address with exactly the gas for one `withdraw`** — bounded, logged,
   alerted, and never a way to move USDG.

**Answer 2 is now built in the backend (`assay-backend` repo), in two halves.** The first
is the grant — `EvmGasGrantService`, bounded
once-ever by `uniq_evm_gas_grants_account`, gated on a matured withdrawal, capped by
`EVM_RELAYER_GAS_GRANT_MAX_WEI` and `EVM_RELAYER_GAS_GRANT_DAILY_MAX_WEI` (neither with a
default), alerting on every grant, and reaching the chain only through `EvmRelayerPort.sendValue`,
whose type has no calldata field so it structurally cannot move USDG. The second is the
operational half — `EvmRelayerFloatMonitor`, a five-minute float read per enabled `eip155` chain with a WARN
mark, a CRITICAL mark and an `UNREADABLE` level that is neither zero nor healthy, sharing the
single symbol `EVM_RELAYER_FLOAT_LOW_WEI` with the grant's own refusal check — and
`deploy-runbook.md` §10, which says what a human does at 3am when it is dry.

**The remainder: it has not yet run against a real chain.** No buyer has been funded by it, no
`withdraw()` has been paid for by the platform, and every figure the alert prints is unit-tested
against a fake relayer.

**Built (the grant and the float), UNPROVEN on a real chain; the testnet acceptance step
`a buyer withdraws with zero ETH` is where it is proved, and that step reports NOT RUN rather than
pass until it has been.** Still a MAINNET BLOCKER.

## 10. **Mainnet USDG is unknown — MAINNET BLOCKER**

`docs/chain-facts.md` §1: `cast code 0x915Ef7…03ec` on 4663 returns `0x`, and the same call on
46630 returns 11,306 characters, so the probe works and the absence is real. **Mainnet USDG is not
at the testnet address and this repo cannot derive where it is.** It is an operator-supplied input
from Robinhood Chain's documentation or the token issuer.

**What the tooling does about it:** `script/new-deployment-record.sh` refuses to emit a record for
chain 4663 without `USDG_ADDRESS`, refuses the testnet address explicitly, and probes `code`,
`decimals()` and `symbol()` over RPC in every case. `Deploy.s.sol::_assertTheAssetIsReal` makes the
same three checks in the deploy transaction itself — because a call to an address with no code does
not revert on EVM, it returns empty, and the failure would otherwise surface as an ABI decode error
naming neither the address nor the network.

**Owner: whoever runs the mainnet deploy.** It blocks step 1 of the runbook and nothing before it.

## 11. A leaked verifier key can freeze a provider's whole exit for ten days, at no cost

`proposeSlash` is **permissionless** — anyone may submit a verifier-signed attestation, and the
signature is the whole authorisation. Each accepted proposal adds `reserved` to `s.pendingSlash`,
and `withdrawableOf` returns `min(matured unbonding, atRisk - pendingSlash)`. Reservations stack
until `pendingSlash == atRisk`, at which point `free == 0` and further proposals revert
`NothingToSlash` — so the freeze is **bounded by the stake, and it is the whole stake**.

The scenario, because "a leaked key can grief" is too abstract to act on:

> A verifier key leaks at 09:00. The holder does not execute anything — executing costs them
> nothing but would burn the key's `verifierDailyCap` and leave a `SlashExecuted` event. Instead
> they submit proposals against one provider until `pendingSlash == atRisk`, in one block, for the
> price of the gas. That provider's `withdrawStake` now returns `InsufficientUnbondingStake` for
> every amount. Release requires `cancelSlash` (admin) or `expireSlash`, and `expireSlash` is only
> open **72 h + 7 d** after each proposal, or immediately once the key is revoked. Nothing the
> provider can do shortens it.

The Anchor source states this at `propose_slash.rs`: "a leaked key can freeze a provider's exit, up
to `penalty_amount` per record, for the ten days until the records expire or the key is revoked. **It
cannot take it.**" The last sentence is the reason this is an accepted risk rather than a defect:
executing still needs `assertCanSign` at *both* phases, so revoking the key voids every reservation
it made and returns the collateral.

**What the contract does not do:** nothing. There is no per-key proposal rate limit, no bond on a
proposal and no provider-side objection. Adding any of them would need state the contract
deliberately does not hold, and would weaken the property that a judgement can be submitted by
anyone — which is what stops the platform being able to suppress one.

**The real mitigation is operational and it is `revokeVerifier`.** A provider reporting a frozen
exit with reservations they do not recognise is a key-compromise incident, and revocation both
stops the bleeding and releases what is already held.

## 12. `revokeVerifier` is doubly irreversible, and one of the two effects is not the obvious one

`revokeVerifier` is admin-only, has no confirmation step, and does two irreversible things at once:

1. **the key is retired for ever.** `registerVerifier` refuses any address that has *ever* been
   registered, so a mistaken revocation cannot be undone by re-registering — a new keypair has to
   be generated, distributed and enrolled;
2. **every judgement that key has in flight becomes reapable by a stranger.** `expireSlash`'s
   condition is `verifierUnavailable || graceElapsed`, so revocation opens the reap door
   immediately rather than after the 72 h + 7 d grace, and `expireSlash` is permissionless
   (`test_expireIsPermissionlessAcrossASweepOfCallers`). Every honest pending judgement that key
   signed is released, and the evidence for re-judging has to come from off chain.

Effect 2 is the point of the design — it is what makes entry 11's freeze survivable and it is why
`assertCanSign` is re-checked at execution — and it is exactly what makes a *mistaken* revocation
expensive: the operator who revokes the wrong key has also just cancelled every slash that key had
pending, with no record of which they were beyond the events.

**What the contract does not do:** nothing. No two-step revoke, no timelock, no undo. This is
faithful to the Anchor source and deliberate.

**Mitigated only by procedure:** treat a revocation like the `newAdmin` handover in entry 5 —
`cast call <config> 'verifierKey(address)' <key>` before, list the key's `Pending` records first so
they can be re-judged under the replacement key, and paste the address rather than typing it.

## 13. A voucher signed *after* a withdrawal request can outlive the delay

The two-step exit's guarantee — a buyer cannot withdraw out from under a voucher they have already
signed — covers **only vouchers signed before `requestWithdraw`**. That half is real, and it is what
`WITHDRAW_DELAY_SECONDS (3,600) > MAX_VOUCHER_REDEEMABLE_LIFE_SECONDS (2,220)` buys. The other half
is false, and the contract does not pretend otherwise:

> A buyer requests a withdrawal at `T`; it matures at `T + 3600`. The backend writes a 402 at
> `T + 1400` and the buyer signs a voucher with `issuedAt = T + 1400`, `expiresAt = T + 1700`. That
> voucher stays redeemable until `T + 1700 + 1800 = T + 3500`, which is fine — but a voucher signed
> at **`T + 1381` or later** is redeemable past `T + 3600`. `withdraw()` reads no
> outstanding-voucher state, pays `min(requested, balance)`, and the later redemption then fails
> `EscrowInsufficient`. **The provider has already served the request.**

**This is identical on Solana** (`withdraw.rs` has no such check either), so it is not a port defect
and no contract change is proposed: a contract-side check would need an outstanding-voucher set
that neither chain holds.

**What the contract does not do:** nothing at all. The mitigation is entirely off chain and it is a
named **backend requirement** — see `docs/gas.md` § "The operational rule", which now carries it beside
the batch pre-validation rule. Cost if it is skipped: one voucher's `amount` per affected call,
absorbed by the platform or the provider, exactly as a `VoucherTooOld` is (entry 1).
