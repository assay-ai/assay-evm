# Deploy runbook — for a human

**Nothing here is automated.** Every step below that touches a chain is a human action. `--broadcast`
against 46630 or 4663 and `upgradeToAndCall` from the Ledger are the two that move state, and
mainnet is gated on an external audit (precondition 0.6).

No `deployments/<chainId>.json` record is published in this repository; the runbook describes the
record that `script/new-deployment-record.sh` writes when you deploy, and the addresses and
outputs quoted below are examples from the authors' own dry runs and testnet runs.

**The next deploy is a fresh one (D-22).** The earlier testnet 46630 deployment is abandoned, not
upgraded: §3 creates new proxies at new addresses, so the backend's `EVM_DEPLOYMENTS`, the
frontend's contract config and every published address change with it. No migration from the old
proxies exists or is needed.

Read `docs/risk-register.md` first. Entries **9** and **10** are mainnet blockers and this runbook
cannot clear either of them.

---

## 0. Preconditions this runbook refuses to work around

**Every one of these is a human action.** No automation performs, simulates, or substitutes for any
of them, and no step below is reachable until the ones it names are true. They are here rather than
scattered because five of the six were previously findable only by already knowing where to look.

| # | Precondition | For | Skipping it produces |
|---|---|---|---|
| **0.1** | The **mainnet USDG address on `eip155:4663`**, from Robinhood Chain's documentation or the token issuer, verified on the explorer, `decimals()` confirmed **6** | 4663 only | `script/new-deployment-record.sh 4663` exits 1; `Deploy.s.sol` reverts `AssetHasNoCodeOnThisChain()`; the backend's `assertChainMetadata` refuses `eip155:4663` at boot. **All three refusals are deliberate. Do not weaken any of them, and never guess an address.** Risk register §10. |
| **0.2** | The **OWNER key** (a Ledger, or a Safe in production) and the **admin Ledger**, two different keys, each provisioned, its address read off the device's own screen, and control of it **proved** before it is named | both | The owner is the upgrade authority of all three contracts and appoints the admin (D-17); the admin is the operational key. `Deploy.s.sol` refuses a deployer that would keep either role. A wrong admin is repaired by the owner (`setAdmin`); a wrong owner *proposal* never takes effect (two-step), but an owner that *accepts* from a key that is then lost is total loss of upgradeability. §6.3 is the procedure. |
| **0.3** | The **treasury Ledger**, a **single-signer EOA** (design decision) | both | `TREASURY_ADDRESS` is a `ParamSet` field and the deploy will accept anything. This is an accepted custody downgrade against Solana's Squads multisig; Safe **is** deployed on 4663 (measured, `chain-facts.md` §3) so the downgrade is a choice, not a constraint. Moving to a multisig later is an `updateConfig`, not a contract change. |
| **0.4** | The **EVM verifier key**, **secp256k1**, key id `verifier-evm-<yyyy-mm>` | both | **Never the Solana ed25519 key**, and the two rotate independently on their own 180-day schedules. Enrolment is §6.4 and it is **one-shot in both directions** — `registerVerifier` refuses any address that has *ever* been registered, so a mistake here is a new keypair, not a retry. |
| **0.5** | The **environment-configuration edit** (the backend's deployment configuration, e.g. a Kubernetes Secret or env file), in the **same deploy window** as the code | every environment | An environment that still sets the legacy `SOLANA_ENABLED_CHAINS` fails the new boot, which **refuses that variable's presence outright** — even beside a valid `ENABLED_CHAINS`. Deploying the code without the edit leaves the API refusing to boot and `/health` not answering at all. See §11. |
| **0.6** | The **Solidity audit**, no unresolved high or critical findings, and verified source on `robinhoodchain.blockscout.com` matching the audited commit | 4663 only | Mainnet is gated on it. Testnet 46630 may run behind flags un-audited **provided the deployment holds no user money**, which means the testnet acceptance suite funds itself — from the token's own `claim()` faucet, 1,000 USDG per address per day (`chain-facts.md` §1a). |

**0.2, 0.3 and 0.4 are three separate keys and must never be one.** 0.2 can replace the
money-holding logic in a single transaction with no delay; 0.3 receives fees; 0.4 signs
attestations that move a provider's stake. Collapsing any two of them turns one compromise into
two.

**0.5 has a second half.** The backend's `EVM_DEPLOYMENTS` setting has two **required** fields —
`escrowImplementation` and `admin` — because `VaultPort`'s control check compares the live chain
against them, and an optional expectation is one a check cannot fail against. A configuration
carrying the older four-address form of that variable fails to boot too. It is
the same edit, in the same window, and it is one line.

---

## 1. Preflight

From the repository root, with `FOUNDRY_DISABLE_NIGHTLY_WARNING=1` exported:

```sh
forge fmt --check                                       # 1
rm -rf out cache && forge build                         #   not a gate; a precondition of 3 and 8
./script/check-vendor.sh                                # 2
./script/check-layout.sh                                # 3   must print "layout OK"
./script/check-layout-branch.sh <base-ref>              # 3b  the same question, against the MERGE BASE
./script/check-sizes.sh                                 # 4
./script/check-errors.sh                                # 5
./script/check-bytecode.sh                              # 6   see the expected line below
forge test                                              # 7
./script/check-snapshot.sh    # 8   forge snapshot --check, fork suite and path-dependent tests excluded — ci-gates.md §8
./script/check-fork-isolation.sh                        # 9   the fork suite stays out of 7 and 8
```

**Ten commands, and the block is the count** — this line said "All nine clean" over a block of
eight gates plus a build, so count what you ran rather than what a sentence claims. Nine of the ten
are gates; `rm -rf out cache && forge build` is a precondition of two of them, and 3b does its own
clean rebuild, which is why it is the slowest line here by several minutes.

**3b takes a base ref.** If the snapshots do not exist at the merge base it prints "this contract
is NEW on this branch, nothing to compare" three times and exits 0. Pass the branch you are actually
merging into, and read the three per-contract lines rather than
the exit code alone (`docs/ci-gates.md` §3).

Before a chain's first deploy, `./script/check-bytecode.sh` prints **`skipping
deployments/<chainId>.json (status: pending-deploy)`** followed by `bytecode OK`, and that is the
correct output — the record
exists, its hashes are real, and only its addresses and `.status` are waiting on a human. It stops
skipping the moment `.status` is `"deployed"`, which is where its comparison loop starts running
for real. It has been run in that state and made to fail both ways; `docs/ci-gates.md` §6 has the
outputs.

**Gate 8's `--no-match-path "test/fork/*"` is not optional.** A skipped test still emits a
`.gas-snapshot` row, so without the flag gate 8 demands the very row gate 9 refuses, and the two
gates contradict each other. A stale copy of the bare command is a red gate whose message does not
explain why (`docs/ci-gates.md` §8 and §10).

**The fork suite is not in this list, and must not gate a deploy.** `RH_TESTNET_RPC=… forge test
--match-path "test/fork/*"` is worth running before a deploy and worth reading, but it fails
transiently — `vm.createSelectFork: failed to get block for block number N; latest block number
N+4`, four times in one batch on 2026-09-09/10, cleared by a retry every time.

`docs/ci-gates.md` says what each one cannot see; read it once before trusting a green run.

**For 4663 only:** confirm `docs/chain-facts.md` §1 records the **mainnet USDG address**, measured
on chain and not assumed. **This runbook refuses to proceed on 4663 without it**, and so does the
tooling: `script/new-deployment-record.sh 4663 …` exits 1 with no `USDG_ADDRESS`, exits 1 if given
the testnet address, and probes `code`/`decimals()`/`symbol()` over RPC in every case.

`docs/chain-facts.md` §5 records the per-transaction gas ceiling — **`maxTxGasLimit = 32,000,000`**
on both chains, from `ArbGasInfo.getGasAccountingParams()`. The worst measured 64-item batch is
**5,235,730**, 16.4 % of it. That figure is against `MockUSDG`; see §9.

## 2. Environment

`Deploy.s.sol` reads exactly these:

| variable | 46630 | 4663 |
|---|---|---|
| `USDG_ADDRESS` | **operator-supplied**: the 6-decimal settlement token, e.g. a mock USD you deployed | **operator-supplied. Not derivable. Not the testnet address.** |
| `OWNER_ADDRESS` | **the cold owner** (Ledger or Safe), never the deploying key | **a Safe or a Ledger**, never the deploying key |
| `ADMIN_ADDRESS` | **a Ledger address**, never the deploying key | **a Ledger address**, never the deploying key |
| `TREASURY_ADDRESS` | a Ledger EOA | a **single-signer Ledger EOA** (multisig planned) |
| `REDEEMER_ADDRESS` | the platform's redeemer key | the platform's redeemer key |
| `UNBONDING_PERIOD_SECONDS` | ≥ 950,400 (11 d) and ≤ 2,592,000 (30 d) | same |
| `MINIMUM_STAKE`, `PENALTY_AMOUNT`, `VERIFIER_DAILY_CAP` | base units, 6 decimals | same |
| `TAKE_RATE_BPS` | ≤ 3,000 | same |
| `SLASH_AGENT_BPS`, `SLASH_PLATFORM_BPS`, `SLASH_CAP_BPS` | `SLASH_CAP_BPS` ≤ 5,000 | same |
| *the deploying key* | **not an env var.** The EOA `--broadcast` signs with. It is part of the six resulting addresses, it is recorded in `deployments/<chainId>.json.deployer`, and it is a hot key whose privilege ends at §6.3 | same |

**`OWNER_ADDRESS` and `ADMIN_ADDRESS` are two different cold keys and neither may ever be an
environment variable holding a private key, anywhere in this system.** The owner is the upgrade
authority for all three proxies and appoints the admin (D-17); the admin sets parameters, pauses
and runs the verifier registry. No role can move user funds directly: the owner's upgrade is the
one residual power (`docs/risk-register.md` §4). `Deploy.s.sol` refuses to run when the deploying
key would be the owner, the admin or the redeemer, so **after the deploy the deployer holds no
power at all**.

**The deploying key is in that table without being an environment variable, because
`Deploy.s.sol` never reads it and it still decides where the contracts land.** Each implementation
is a plain `CREATE` from the signing EOA, so its address is `CREATE(from, nonce)`; each proxy is a
salted `CREATE2` whose initcode contains that implementation address. The chain of consequences is
in §5, and the short version is: **a different key, or the same key at a different nonce, gives six
different addresses.** The key is recorded in the deployment record, and no authority follows it — the owner and the
admin are the keys named in `OWNER_ADDRESS` and `ADMIN_ADDRESS` from the first block.

**`TREASURY_ADDRESS` is a single-signer Ledger EOA**, by design decision. Say it
plainly here because it belongs in the operator's hands and not only in a decision log: **this is a
custody downgrade against the Solana side's Squads multisig, and it was accepted.** The Safe
measurement in `chain-facts.md` §3 stays as information and blocks nothing. Moving to a multisig later is a
`treasury` change through `updateConfig`, not a contract change.

## 3. Deploy

```sh
forge script script/Deploy.s.sol \
  --rpc-url https://rpc.testnet.chain.robinhood.com \
  --broadcast --verify --verifier blockscout \
  --verifier-url https://explorer.testnet.chain.robinhood.com/api/
```

For 4663, the RPC is `https://rpc.mainnet.chain.robinhood.com` and the verifier URL is
`https://robinhoodchain.blockscout.com/api/`. **With solc 0.8.38 the inline Blockscout
verification fails** (Blockscout there accepts up to 0.8.36): drop `--verify …` and verify on
Sourcify as in §4.

Each contract is deployed twice over: the implementation plainly, then an `ERC1967Proxy` in front
of it whose constructor data is the `initialize` call. **The proxy is initialised in the same
transaction that creates it and there is no window in which a third party can call `initialize`
first.** `test/Deploy.t.sol::test_wrongState_theSplitFormIsFrontRunnable` measures what the split
form costs: an attacker landing one call between the two transactions ends holding `Config.admin`
and, through it, the upgrade authority of all three contracts.
`test_theDeployScriptUsesTheAtomicForm` is what stops a future edit reintroducing it.

### Dry-run it first. It is the same command with `--broadcast` removed

```sh
forge script script/Deploy.s.sol --rpc-url https://rpc.testnet.chain.robinhood.com
```

No `--broadcast`, no `--verify`, no wallet flag. It simulates the whole sequence **against real
chain state**, runs every post-check inside `Deploy.s.sol`, and prints the six addresses, both
proxy domain separators and the three salts. Measured 2026-09-10 on 46630:

```
Estimated gas price:              0.020000001 gwei
Estimated total gas used:         9,723,087
Estimated amount required:        0.000194461749723087 ETH
SIMULATION COMPLETE. To broadcast these transactions, add --broadcast and wallet
configuration(s) to the previous command.
```

**The addresses it prints are not the addresses you will get.** They are the addresses *that
signer at that nonce* would get, and a dry run runs the default sender from nonce 0. See §5: the
implementations are `CREATE(from, nonce)` and the proxies are `CREATE2` over initcode containing
them. What the dry run does prove is that the sequence executes against the real token, that the
post-checks hold, and roughly what it costs.

`forge script` writes `broadcast/Deploy.s.sol/<chainId>/dry-run/run-latest.json` and a matching
file under `cache/`. **Both directories are gitignored and must stay untracked** — a stray
`broadcast/` reads as a deployment to the next person, and this repository's baseline is that
nothing has ever been deployed. `rm -rf broadcast` when you are done reading it.

**On 4663 the dry run refuses inside the deploy transaction itself**, before an address is
computed:

```
    └─ ← [Revert] AssetHasNoCodeOnThisChain()

Error: script failed: AssetHasNoCodeOnThisChain()
```

That is `Deploy._assertTheAssetIsReal` refusing the testnet USDG address on mainnet — the second of
the two guards between this runbook and an invented mainnet address, the first being
`new-deployment-record.sh` (§5). A call to an address with no code does not revert on EVM, it
returns empty, which is why the check has to be explicit: without it the failure would surface as
an ABI decode error naming neither the address nor the network.

**One precondition the dry run reveals and nothing else states.** Every salted proxy creation is
routed to the deterministic CREATE2 deployer `0x4e59b44847b379578588920ca78fbf26c0b4956c`
(transactionType `CREATE2`, `to` set to it, calldata = salt ++ initcode). Measured 2026-09-10: it
has 69 bytes of code on **both** 4663 and 46630. On a chain where it does not, the three proxy
transactions have nowhere to go and the deploy fails — check it before any new chain.

## 4. If `--verify` fails inline

Standalone verification, **twice per contract, because each deployment is an implementation and a
proxy**:

```sh
# the implementation
forge verify-contract <implementation> src/AssayEscrow.sol:AssayEscrow \
  --chain-id 46630 --verifier blockscout \
  --verifier-url https://explorer.testnet.chain.robinhood.com/api/ \
  --compiler-version 0.8.38 \
  --show-standard-json-input > verification/AssayEscrow.impl.standard.json

# the proxy — its constructor args are (implementation, initializer calldata)
forge verify-contract <proxy> \
  lib/openzeppelin/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy \
  --chain-id 46630 --verifier blockscout \
  --verifier-url https://explorer.testnet.chain.robinhood.com/api/ \
  --compiler-version 0.8.38 \
  --constructor-args $(cast abi-encode "constructor(address,bytes)" <implementation> <initializerArgs>) \
  --show-standard-json-input > verification/AssayEscrow.proxy.standard.json
```

**Blockscout on Robinhood Chain verifies only up to solc 0.8.36, and this build uses 0.8.38**
(SOL-2026-7, review 2026-10-23 L-3), so `--verify --verifier blockscout` in §3 is expected to fail.
Verify on **Sourcify** instead, through its v2 API with the standard-JSON input forge emits (the
forge nightly's own Sourcify client failed in testing, so do not rely on `--verifier sourcify`):

```sh
forge verify-contract <implementation> src/AssayEscrow.sol:AssayEscrow \
  --chain-id 46630 --compiler-version 0.8.38 \
  --show-standard-json-input > verification/AssayEscrow.impl.standard.json

jq -n --slurpfile std verification/AssayEscrow.impl.standard.json \
  '{stdJsonInput: $std[0], compilerVersion: "0.8.38", contractIdentifier: "src/AssayEscrow.sol:AssayEscrow"}' \
  | curl -sS -X POST -H 'content-type: application/json' --data @- \
      https://sourcify.dev/server/v2/verify/46630/<implementation>
# → {"verificationId": "..."}; poll GET https://sourcify.dev/server/v2/verify/<verificationId>
```

`compilerVersion` may need the full build string Sourcify lists for 0.8.38 (`0.8.38+commit.…`);
take it from `solc --version` of the binary forge used. Repeat for each implementation and for
each `ERC1967Proxy` (`lib/openzeppelin/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy`; Sourcify reads
constructor arguments from the creation transaction). The Blockscout commands below stay valid
for a build at or below 0.8.36.

Verification goes through **standard-JSON input**, which works whatever the metadata setting. Commit both emitted standard-JSONs beside the deployment record. Verifying the proxy is
what gives Blockscout its "Read as Proxy" tab, which is how an operator sees the live
implementation without a `cast storage`.

## 5. The deployment record

```sh
USDG_ADDRESS=0x… ./script/new-deployment-record.sh <chainId> <rpc>
```

It writes `deployments/<chainId>.json` with the commit, the compiler settings, the probed asset,
the three implementation bytecode hashes and the three CREATE2 salts, and leaves the six addresses,
the admin and the two domain separators as placeholders. Fill them from `Deploy.s.sol`'s output,
flip `.status` to `"deployed"`, then:

```sh
./script/verify-deployment.sh <chainId> <rpc>
```

**Read the record's shape, because it encodes the ruling.** `proxy` is the **identity**: what the
backend is configured with, what a voucher names as `verifyingContract`, and what never changes.
`implementation` + `implementationRuntimeKeccak` are the **current logic**, and an upgrade rewrites
exactly those two lines and nothing else — which is what makes the diff of this file a readable
history of every upgrade the contract has had. `salt` is the proxy's CREATE2 salt (D-7), and it is
`keccak256(abi.encodePacked("assay:", name, ":v2:", chainid))` where `chainid` is **32 big-endian
bytes, not its decimal string** — `test_theSaltFormulaMatchesTheOneTheShellScriptComputes` pins the
Solidity and the shell spellings against each other. `initializerArgs` is the ABI-encoded
`initialize` call passed to the proxy constructor, which is what a verifier needs to reproduce the
proxy's own bytecode-plus-args — and which, with the implementation and the salt, is what makes the
proxy address **reproducible arithmetic** rather than a number somebody copied. `domainSeparators` are read **from the proxies** — the only reading
that means anything, and the one `verify-deployment.sh` checks.

### `deployer`, and how an address here is actually determined

This page used to say the CREATE2 salt is what makes the proxy address derivable. **It is one of
three inputs, and the other two are the ones that move.** Measured 2026-09-10, from the dry run's
own broadcast file:

1. Each **implementation** is a plain `CREATE` from the signing EOA — `CREATE(from, nonce)`.
   `cast compute-address 0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38 --nonce 0` returns
   `0x5b73C5498c1E3b4dbA84de0F1833c4a029d90519`, which is exactly the AssayConfig implementation the
   dry run produced.
2. Each **proxy** is `CREATE2`, but **not from the EOA**. forge routes a salted creation to the
   deterministic deployer `0x4e59b44847b379578588920ca78fbf26c0b4956c` — transactionType `CREATE2`,
   `to` set to it, calldata = salt ++ initcode. That deployer is a constant, present on 4663 and
   46630 alike.
3. So the proxy address is
   `CREATE2(0x4e59b448…, salt, keccak(ERC1967Proxy creation bytecode ++ abi.encode(implementation,
   initializerArgs)))` — and **the signing key enters through the implementation address**, which
   is a constructor argument and therefore inside the initcode hash.

Which means the same salt under two keys lands on two addresses, for a reason one step removed
from where you would look for it:

```
sender 0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38 nonce 0
    AssayConfig impl   0x5b73C5498c1E3b4dbA84de0F1833c4a029d90519
    AssayConfig proxy  0x8c8A794e48B23Cfd23a7eE6365f89E4EE0571e6f
sender 0x1111111111111111111111111111111111111111 nonce 0
    AssayConfig impl   0x8F7a45eBDe059392E46A46DCc14AB24681A961Ea
    AssayConfig proxy  0x45a60b9e5647d2b976a28EEB702563e10e650da7
```

**And the NONCE is in it too**, which is the sharper half: a dry run signs from nonce 0 and a real
key will not, so *a dry run's addresses do not predict a broadcast's even from the same key*. Do
not pre-announce an address, pre-configure a backend with one, or pre-fund one.

`deployer` therefore records **who signed** — the audit trail, and the reason the three
implementations are where they are. It is not an input to the check.
`verify-deployment.sh`'s **check 1** recomputes each proxy from the record's own `implementation`,
`initializerArgs` and `salt` against the constant deployer, and refuses a record whose addresses do
not reproduce or that still carries a placeholder. It is arithmetic and reads nothing from the
chain, so it works on a record for a chain you cannot reach, and it ties three recorded fields to a
fourth — the one relationship in that file no `cast call` can check. `create2Deployer` is recorded
beside it so that a future chain with a different deterministic deployer can be verified without
editing the script.

A last consequence worth stating: **a redeploy produces different addresses even with an identical
salt.** That is a feature — two deployments can never be confused for each other — but it means the
backend's configuration is per-deployment, and never derivable from the chain id alone.

## 6. Post-deploy admin actions, in order

1. **`registerVerifier`** for `verifier-evm-<yyyy-mm>` — a secp256k1 key, and **never the Solana
   one**. Note that enrolment is one-shot: `registered` is never cleared by any path, so a rotation
   is always a NEW address and a mistake here cannot be undone by re-enrolling.
2. **Confirm `params()` matches the record.**
   `PROXY_CONFIG=… PROXY_STAKE=… PROXY_ESCROW=… forge script script/VerifyDeployment.s.sol --rpc-url <rpc>`
   prints every field decoded, plus the live implementation of each proxy.
3. **Prove both roles work** (§6.3): the admin pauses and unpauses, the owner calls `setAdmin`
   with the current admin (a no-op that proves the owner signs).
4. **Appoint the arbiter** (§6.5) — a person's wallet or a Safe, never a backend key.
5. **Check the redeemer is not the relayer.** `params().redeemer` must be the address of the
   backend's `EVM_REDEEMER_KEYS` key, and the `EVM_RELAYER_KEYS` address must differ from it; the
   backend fails closed at its first vault-control check otherwise.
6. **For a testnet run only**, `setCollectHold(600)` (admin) shortens the collect hold to 10
   minutes and `setSlashDelay(600)` the slash delay; production keeps the defaults (§6.5).
7. **Monitor:** page on every `ConfigUpdated` and `VerifierRegistered` from `AssayConfig`
   (`docs/risk-register.md` §4a — the admin's indirect reach over stake and fees).

### The slash lifecycle and who acts in it (D-19)

```
proposeSlash (anyone, verifier-signed) ──► Pending ──executeSlash (anyone, after executableAt)──► Executed
                                             │  ▲
          disputeSlash (provider, before     │  │ upholdSlash (arbiter, before disputedAt + 30 d;
          executableAt, once; never paused)  ▼  │   executable from max(frozen executableAt, now))
                                           Disputed
Pending or Disputed ──cancelSlash (admin or arbiter)──► Cancelled  (Withdrawn)
Pending  ──expireSlash (anyone: key unusable, or executableAt + 7 d)──► Cancelled  (VerifierUnavailable | Expired)
Disputed ──expireSlash (anyone: key unusable, or disputedAt + 30 d)──► Cancelled  (VerifierUnavailable | DisputeUnresolved)
```

`executableAt = proposedAt + slashDelaySeconds()` (72 h unless the admin set it, §6.5), frozen at
proposal; the provider's dispute window is that delay. A record is disputed at most once
(`AlreadyDisputed`). **The provider is never worse off for disputing early**: an uphold never
makes a record executable before its frozen `executableAt`, and the 7-day grace runs from the
`executableAt` the uphold leaves. At `disputedAt + 30 d` the uphold closes (`DisputeTimedOut`) in
the same instant expire opens. The reservation (`pendingSlash`) holds from
proposal until `Executed` or `Cancelled`, through a dispute. **Operator console:** an overturn or a
suspend is the ARBITER's `cancelSlash`, not the admin's; a ruling against the provider is
`upholdSlash`, after which anyone (the backend) calls `executeSlash` within 7 days. Many records
at once: `disputeSlashBatch`, `upholdSlashBatch`, `cancelSlashBatch` (≤ 64 ids, atomic — one bad or
duplicate id reverts the batch, so pre-filter with `slashRecordOf`).

### 6.5 The arbiter, the blocklist and the slash delay (D-19)

```sh
cast send <configProxy> "setArbiter(address)" <arbiter> --rpc-url <rpc> --ledger      # ADMIN; 0x0 refused: replace, never remove
cast send <configProxy> "setBlocked(address,bool)" <addr> true --rpc-url <rpc> --ledger # admin or arbiter; only the admin may send false
cast send <configProxy> "setSlashDelay(uint64)" <seconds> --rpc-url <rpc> --ledger    # ADMIN; [600, 1900800] (10 min to 22 d)
```

- [ ] The arbiter is **not** the verifier and not any key the backend holds. Config refuses an
      arbiter that is the admin, the redeemer or a live verifier (`InvalidArbiter`); nothing
      stops a backend key that holds no on-chain role, so check by hand.
- [ ] A blocked address can still `revokeDelegate` and `disputeSlash`; nothing moves its funds.
      Unblocking is the admin's alone.
- [ ] **The blocklist binds the subjects of a door** — buyer, payer, payee/provider, delegate,
      funder — **never the operators**: not relayers, the redeemer, keepers calling
      `propose`/`execute`/`expireSlash`, the slash beneficiary, the treasury, the admin, the
      arbiter or **the verifier**. Blocking a verifier does nothing to its signatures. A forging
      verifier is stopped only by `revokeVerifier`, which is ADMIN-only; the arbiter's tool against
      a forged slash is `cancelSlash`.

- [ ] The slash delay applies to NEW proposals only. **Production keeps it at 72 h or more**; the
      10-minute minimum is for testing, and a short delay is a short dispute window.
- [ ] Roles stay separate, enforced in one place (`AssayConfig._assertRolesDistinct`, run by
      `setAdmin`, `setArbiter`, `registerVerifier` and `updateConfig`): the admin is not a live
      verifier (`InvalidAdmin`); the arbiter is not the admin, the redeemer or a live verifier
      (`InvalidArbiter`); `setArbiter` refuses `0x0`.
- [ ] **A stolen admin key alone can take provider stake within the caps** (it registers a
      verifier, sets the arbiter, lowers the delay and sets params). Accepted by the owner on
      2026-10-14 because the admin wallet is held as securely as the owner wallet; risk register §4a.

### 6.6 Retiring a verifier key (F4)

A record's verifier is re-checked at `executeSlash`, and an unusable key releases the record
(`expireSlash`, `VerifierUnavailable`). A dispute can keep a record open for up to 30 days and an
uphold adds the 7-day grace, so a rotation inside that span voids a timely ruling. **Rule:** a key
retired by rotation stays **registered, not revoked, and unexpired** for at least
`slashDelaySeconds() + 30 d + 7 d` (≈ 40 days at the 72 h default) after its LAST proposal; stop
the backend signing with it, do not revoke it. **Revoke only a compromised key.** When enrolling,
set `expiresAt` far enough out to cover that tail.

### 6.7 Executing slashes, pauses and parameter changes

- **All or wait (D-20).** `executeSlash` pays a record its WHOLE reservation or nothing. When the
  provider's rolling window cannot take all of it, it refuses `SlashWindowNotDrained` (the backend
  maps it to WAIT) and the record stays Pending; retry as the window drains (it reopens linearly
  over 24 h). There is no partial payment and no last-day exception: **an honest slash crowded out
  for the whole 7-day grace expires unpaid.** There is no per-key window on chain (D-25):
  `verifierDailyCap` is not read by the contracts and is only the backend's own per-key budget.
- **A pause longer than 7 days voids slashes.** The grace and the 30-day dispute timeout keep
  running while paused; `executeSlash` is closed and `expireSlash` is open to anyone. **Before a
  long pause, and again right after the unpause**, list every Pending or upheld record whose
  `executableAt + 7 d` (or Disputed record whose `disputedAt + 30 d`) falls inside the pause, and
  execute or re-propose them. The provider's rolling window is not frozen by a pause either.
- **Recovering slashes a long pause voided — preferred, narrow (audit G G-4):** for each affected
  provider, `setBlocked(provider, true)`, then unpause, re-propose its judgements under new request
  ids, and `setBlocked(provider, false)` once they are proposed (the reservation then holds them).
  A blocked provider cannot exit, and nothing else in the system is held.
- **Only if that is impractical** (many providers): raise `unbondingPeriodSeconds` temporarily
  before the unpause (`updateConfig`), so no provider whose slashes were voided can exit before
  they are re-proposed (audit B B6). This delays every provider's exit, not just the affected ones.
- **`verifierDailyCap` must be non-zero** (`InvalidVerifierDailyCap`); nothing else bounds it since
  D-25 removed the on-chain key window and audit G G-1's `>= 2 * penaltyAmount` with it.
- **Two penalties per provider-day at the minimum.** `updateConfig` refuses
  `minimumStake * slashCapBps / 10_000 < 2 * penaltyAmount` (`InvalidMinimumStake`, review
  2026-10-15 R-1), so a provider at the minimum fits two maximal records in its capped day. Raise
  `minimumStake` (or lower `penaltyAmount`) before raising the penalty; a provider slashed below
  the minimum can still have one record fill its day.
- **Parameters re-price records in flight.** The split and the `treasury` are read at execution
  time, not at proposal: an `updateConfig` changes what every pending record
  will pay and to whom. Only `capAllowance`, `reserved`, the beneficiary and `executableAt` are
  frozen.
- **Key expiry.** The backend runs a key-expiry monitor (§6.6 gives the tail a key must cover).

### 6.3 Changing the owner or the admin (D-17)

**The admin is appointed by the owner, in one step:**

```sh
cast send <configProxy> "setAdmin(address)" <newAdmin> --rpc-url <rpc> --ledger   # signed by the OWNER
```

A wrong address here is recoverable: the owner sends `setAdmin` again. `updateConfig(ParamSet)`
never moves the admin.

**The owner moves in two steps, and only the second one moves anything:**

```sh
# 1. proposed by the CURRENT owner
cast send <configProxy> "transferOwnership(address)" <newOwner> --rpc-url <rpc> --ledger
cast call <configProxy> 'pendingOwner()(address)' --rpc-url <rpc>     # == <newOwner>
# 2. accepted by the NEW owner itself — a Ledger (--ledger) or a Safe transaction
cast send <configProxy> "acceptOwnership()" --rpc-url <rpc> --ledger
cast call <configProxy> 'owner()(address)' --rpc-url <rpc>            # == <newOwner>
```

A wrong proposal never becomes the owner (an address nobody controls cannot accept); replace it
with a second `transferOwnership`, or cancel it with `transferOwnership(0x0000…0000)`.
`renounceOwnership()` always reverts. **What is NOT recoverable is an owner that accepted from a
key that is later lost**, so before step 1:

- [ ] **Display the new owner address on the device's own screen** (or read the Safe's address
      from the Safe UI on a second device) — not from a terminal, a password manager or a chat.
- [ ] **Prove control of it.** Sign a message from that exact address and verify the recovery, or
      have it receive a dust transaction. An address you can display is not yet one you can sign
      with.
- [ ] **Paste, never type**, and compare all 40 hex characters, both ends and the middle.
- [ ] `owner()`, `pendingOwner()` and `admin()` **before**, recorded.
- [ ] After step 2, prove the new owner works at once: `setAdmin(<currentAdmin>)` from it (a
      no-op).
- [ ] Update `.owner` (and `.admin` if it moved) in `deployments/<chainId>.json` and the backend's
      `EVM_DEPLOYMENTS[<chain>].owner` / `.admin`, then re-run `./script/verify-deployment.sh`.

### 6.4 Enrolling the EVM verifier key — and it can never be undone

```sh
cast send <configProxy> "registerVerifier(address,bytes32,uint64)" \
  <verifierAddress> <keyIdBytes32> <expiryUnixSeconds> --rpc-url <rpc> --ledger
```

**Before signing:**

- [ ] The address is a **secp256k1** key generated for EVM, key id `verifier-evm-<yyyy-mm>`. **It
      is NOT the Solana ed25519 verifier key**. The two curves are not interchangeable and
      nothing on chain would tell you.
- [ ] `cast call <configProxy> 'verifierKey(address)' <addr>` **before**, and record it. An
      address that has ever been registered is refused for ever — `registered` is never cleared by
      any path, including `revokeVerifier` — so this call is how you find out that this is a
      retry rather than a first enrolment.
- [ ] Paste the address, never type it, and compare all 40 hex characters against both ends and
      the middle.
- [ ] The expiry is a real date. An expired key is also permanently retired: expiry and
      revocation both end at the same one-way door, and **rotation is always a NEW address**.
      There is no renew.

**After:**

- [ ] `cast call <configProxy> 'canSign(address)' <addr>` → `true`.
- [ ] `cast call <configProxy> 'verifierKey(address)' <addr>` — its `expiresAt` matches what you sent.

**And know what `revokeVerifier` does before you ever need it**, because it does two irreversible
things and only one of them is obvious (risk register §12): the key is retired for ever, **and**
every judgement it has in flight becomes reapable by a stranger — `expireSlash`'s condition is
`verifierUnavailable || graceElapsed` (`|| disputeTimedOut` for a `Disputed` record), and it is
permissionless. That second effect is the point
of the design (it is what makes risk register §11's grief survivable) and it is exactly what makes
a *mistaken* revocation expensive. **List the key's `Pending` and `Disputed` records first, so they can be
re-judged under the replacement key.**

## 7. The upgrade runbook

An upgrade is the normal repair and a redeploy the exception (D-1). Both are here; the redeploy
half is the last paragraph.

### Who does what (D-17)

1. **The DEPLOYER** (a hot key with no role) deploys the new implementation(s):
   `forge script script/UpgradeByOwner.s.sol --sig 'deploy()' --rpc-url <rpc> --broadcast --private-key <deployer>`
   with `UPGRADE_<NAME>=true` for each contract. A deployed implementation is inert until a proxy
   points at it.
2. **You verify**, before the owner is asked to sign: the pre-checks below — layout, bytecode,
   function surface, EIP-712 strings — and an **anvil-fork rehearsal** of the exact upgrade against
   live state: fork the chain with anvil, run `UpgradeByOwner.s.sol` `run()` with the owner
   impersonated (`--unlocked --sender <owner>`), then `script/postcheck-upgrade.sh` against the
   fork.
   If an upgrade makes Stake or Escrow call a Config function that does not exist yet, upgrade
   Config in the same session first (`_plan` always runs Config, Stake, Escrow in that order), and
   on a Safe send the `safeCalldata()` lines as ONE MultiSend transaction in that order.
3. **The OWNER signs** `upgradeToAndCall`:
   - a Ledger: `forge script script/UpgradeByOwner.s.sol --rpc-url <rpc> --broadcast --ledger --sender <owner>`
     with `IMPL_<NAME>=<address from step 1>` (and `CALL_<NAME>=<reinitialiser calldata>` if any);
     the script refuses unless the broadcaster IS `owner()` and each implementation answers
     `proxiableUUID()`, then re-asserts the domains, a sampled buyer and provider, the totals,
     the admin and the owner;
   - a Safe: `forge script script/UpgradeByOwner.s.sol --sig 'safeCalldata()' --rpc-url <rpc>` prints
     `(to, data)` per proxy for a Safe Transaction Builder proposal; the Safe's signers verify
     the calldata against that output, and you run the post-checks below by hand.

### Pre-checks, all four, before the owner is asked to sign

- [ ] `./script/check-layout.sh` is **green**, or its classifier printed `append-only: allowed` and
      the snapshot was regenerated with `--update` **and reviewed in the same commit**. A refusal
      here means the change is **not upgradeable** — go to the redeploy paragraph instead. In CI,
      classify against the **merge base**, not `HEAD`; `docs/ci-gates.md` §3 has the recipe and the
      reason (a branch can otherwise append twice and land a net reorder nobody refused).
- [ ] `forge test` green, including `test/Upgrade.t.sol`. `./script/check-sizes.sh` green — the new
      implementation is still under 22,000 bytes. `./script/check-vendor.sh` green.
- [ ] **The storage-layout snapshot diff is read by a human, out loud, field by field.** This is
      the review the Solana side did not have when a layout change left 41 devnet accounts
      unreadable.
- [ ] **`./script/check-bytecode.sh` names the function-surface change, or there is not one.**
      Storage layout and the EIP-712 domain are two of the three variables that decide whether an
      upgrade is safe; **the set of exported functions is the third**, and until 2026-09-09 it had
      no gate at all. A new implementation could add a `sweep(address)` — or, measured, a
      `setAdminUnchecked(address)` on `AssayConfig` that hands the admin key and with it the
      upgrade authority of all three contracts to any caller — and every gate stayed green while
      **all 382 tests passed**, because the layout is unchanged, the domain is unchanged, and
      `implementationRuntimeKeccak` is rewritten by *you* as part of this very upgrade.

      The gate is `abiKeccak` plus the named `abiFunctions` list in `deployments/<chainId>.json`.
      If the surface changed, `./script/verify-deployment.sh` prints the added and removed
      signatures by name:

      ```
      AssayEscrow function surface differs from deployments/46630.json (0xfb35… != 0xdab6…)
        ADDED by this build, not in the record:
          + 01681a62 sweep(address)
        REMOVED by this build, present in the record:
      ```

      **Read that list out loud, the way the storage diff is read.** Then rewrite `abiKeccak` and
      `abiFunctions` in the record in the same commit as the upgrade, and say in the commit message
      what was added and why it is safe to expose. `script/abi-surface.sh` states what the
      comparison can and cannot see.
- [ ] **The new implementation's EIP-712 constructor is still `EIP712("Assay Settlement", "2")`.**
      `grep -rn 'EIP712("' src/` must print exactly two lines, `AssayEscrow.sol` and `AssayStake.sol`,
      both with those two strings. See the warning below.

### The transaction

The deployer deploys the new implementation (no proxy, no salt); then the **owner** signs:

```sh
cast send <proxy> "upgradeToAndCall(address,bytes)" <newImplementation> 0x \
  --rpc-url <rpc> --ledger      # the OWNER; the admin is refused (NotOwner / OwnableUnauthorizedAccount)
```

With `script/UpgradeByOwner.s.sol` (`run()`, or `safeCalldata()` for a Safe), each flagged proxy
also needs `EXPECTED_CODEHASH_<NAME>` — the `extcodehash` of `IMPL_<NAME>`
(`cast keccak $(cast code $IMPL_<NAME> --rpc-url <rpc>)`), taken from the implementation that
`check-bytecode.sh` / `verify-deployment.sh` matched against the local build. The script refuses
(`ImplementationCodehashMismatch`) an `IMPL_*` whose code is not that hash, so the owner signs for
exactly the verified code and not for whatever address ended up in the env.

The `bytes` payload is `0x` unless a reinitialiser is genuinely needed; if it is, it is a
`reinitializer(n)` function — **a fresh deployment leaves all three contracts at version 1, so the
first one is `reinitializer(2)`** — it is written and reviewed as part of the same change, and its
calldata goes here so the state migration and the upgrade are one atomic transaction.

### Post-checks, immediately, in this order

- [ ] `cast storage <proxy> 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc`
      equals the new implementation.
- [ ] `cast call <proxy> 'DOMAIN_SEPARATOR()(bytes32)'` is **unchanged** from
      `deployments/<chainId>.json`. If it moved, **every outstanding voucher is already dead** and
      the correct action is to roll the implementation back in the same session and tell the
      backend to re-issue.
- [ ] **A sampled escrow balance is unchanged.** Pick a funded buyer from the backend,
      `cast call <proxy> 'escrowOf(address)' <buyer>` before and after, and compare. One real
      account beats an invariant nobody ran against live storage.
- [ ] **Redeem one real voucher that was signed before the upgrade**, or have the backend confirm
      one redeemed. This is the check the getter cannot make; see the warning.
- [ ] Rewrite `implementation`, `implementationRuntimeKeccak` and — **only if the pre-check above
      showed a change you accepted** — `abiKeccak` and `abiFunctions` in
      `deployments/<chainId>.json` — on the contract's FIRST upgrade, first copy the old
      `implementation` into `initialImplementation`, which the CREATE2 check reproduces the proxy
      from — and set the contract's `builtAt` to the commit the new implementation was built
      at (the bytecode check masks immutables at THAT build's offsets; the record's top-level
      `commit` stays the one the untouched contracts were built at) — then
      `./script/verify-deployment.sh <chainId> <rpc>` —
      **green** — and commit the record in the same change. `verify-deployment.sh`'s check 0 is
      the function surface and runs before it touches the network, so a surface you did not mean
      to change fails immediately and by name.

### The one thing an upgrade must never do: change the EIP-712 `name` or `version`

They are ShortString immutables baked into each implementation. Change either and the proxy's
domain separator moves on the next block, silently killing every voucher a buyer has already
signed. Nothing on chain refuses it — `_authorizeUpgrade` checks *who* (the owner), never *what*. It is a
checklist item and a test (`Upgrade.t.sol` (d)), and that is all it can ever be.

**And there is a quieter version of the same failure that the `DOMAIN_SEPARATOR()` check above
will not catch.** `DOMAIN_SEPARATOR()` is `external` and non-`virtual`, so it keeps returning the
old value; `_hashTypedDataV4` is `internal view virtual`, and it is what `redeemVoucher`,
`setLimitsBySig` and `requestWithdrawBySig` actually build their digests from. An implementation
that overrides only the second has an exported domain and an enforced domain that disagree, with no
external symptom at all — every pre-upgrade signature fails as `SignerIsNotPayer`, which an
operator reads as "the backend signed with the wrong key". Measured in
`test/MUTATION-LOG.md` as degenerate **DG-U2**, and it is why the redeem-a-real-voucher check is in
the list above rather than only the getter comparison.

### A redeploy is reserved for a layout change that cannot be appended

The case `check-layout.sh` refuses. Then, and only then: deploy a new proxy set, point the backend
at it, stop quoting on the old one, let buyers `withdraw()`, and treat the residue as the Solana
redeploy did. Note that `verifyingContract` invalidates every outstanding voucher against the old
deployment automatically — which is the property that makes a redeploy safe and an upgrade cheap.

## 8. Sequencer liveness

A halted Orbit sequencer freezes withdrawals; the mitigation is the parent chain's force-inclusion
path. It is not a contract concern.

**Two timing assumptions this depends on (review 2026-10-23 L-4).**

1. **The 48 h slash-delay floor (D-23) assumes a 24 h force-inclusion window.** A force-included
   transaction is timestamped `max(parent-chain enqueue time, previous L2 block time)`, so a
   censored `disputeSlash` lands with the current time; it is defended only if it can be forced in
   before `executableAt`. 48 h covers Arbitrum One's default 24 h `delaySeconds` with margin, but
   **Robinhood's own value is not measured yet**: read `SequencerInbox.maxTimeVariation()` on
   Robinhood's parent chain (see below for why it cannot be read from the L3) and confirm
   `delaySeconds` plus a margin is below `minSlashDelaySeconds()`. If it is not, raise the floor
   before mainnet.
2. **The D-24 margin is smaller than the sequencer clock drift Arbitrum allows.**
   `WITHDRAW_DELAY_SECONDS` / `TIGHTEN_DELAY_SECONDS` (10,800 s) exceed the longest redeemable
   voucher life (7,620 s) by **3,180 s**, while a sequencer may stamp blocks up to 1 h (3,600 s)
   ahead of real time. A faulty or malicious sequencer that runs the clock forward by more than
   3,180 s inside one voucher's life can mature a withdrawal, or bind a tightening, before a voucher
   signed earlier is redeemed ("signed means collectable" breaks). This needs a misbehaving trusted
   sequencer and is accepted; the backend alerts when `block.timestamp` drifts from wall-clock time.

**Still owed, and here is exactly why.** The force-inclusion window is
`SequencerInbox.maxTimeVariation()` on the **parent** chain, not a value any L3 precompile
exposes. Closing it needs two inputs this repo does not have: which chain Robinhood settles to,
and that chain's `SequencerInbox` address. Both are operator inputs, the same shape as the mainnet
USDG address (§0.1). **Commands tried, and their real output, are below** — so the next person
starts from what was ruled out rather than from nothing.

Measured 2026-09-10 against `https://rpc.mainnet.chain.robinhood.com` (4663), forge/cast
1.2.1-nightly `7e68208eaae86342998f4a713d27a538ce5a3fbb`:

```sh
# The control: these precompiles do answer, so a revert below is an absence, not a dead RPC.
cast call 0x…0064 "arbOSVersion()(uint256)"          # → 116
cast call 0x…0064 "arbChainID()(uint256)"            # → 4663
cast call 0x…006C "getGasAccountingParams()(uint256,uint256,uint256)"
                                                     # → 7000000 / 32000000 / 32000000
# Who can change this chain's own parameters — read, and worth knowing:
cast call 0x…006b "getAllChainOwners()(address[])"   # 4663  → [0x2A153c6A1B66DBc930a8d7017230ab0253005C09]
                                                     # 46630 → [0x51E1537e3462217f0Db1eb74D27Cc80cA0e3eCa4]
cast call 0x…006b "getNetworkFeeAccount()(address)"  # → 0xbC5C3a7Adecf54D34169fd90dbD1B7d3142DF067
cast call 0x…006b "getInfraFeeAccount()(address)"    # → 0x5a2B80a9b7effc06129bD5462D77BC20A8A59BE7
cast call 0x…006D "getBatchPosters()(address[])"     # → [0xA4b000000000000000000073657175656e636572,
                                                     #    0xDaa526086787d9DEbE1D7F3FFdb1fE50cf8687F4]
# And the two that do NOT answer, which is the point:
cast call 0x…00C8 "getBridge()(address)"             # → execution reverted (-32000)
cast call 0x…00C8 "maxTimeVariation()(uint256,uint256,uint256,uint256)"
                                                     # → execution reverted (-32000)
cast code 0x…00C8                                    # → 0x   (NodeInterface is a virtual
                                                     #        pseudo-contract, not deployed code)
```

**`NodeInterface` at `0x…00C8` has no code and answers only the methods the node itself
intercepts** — `findBatchContainingBlock(uint64)` returns `1` for block 1, which proves the
address is live and that the two reverts above are the absence of those methods rather than a
dead endpoint. There is no L3 precompile that names the parent chain, so the parent's
`SequencerInbox` cannot be discovered from either RPC.

**Do not write a number here that nobody read.** Two chain owners are recorded above and they are
different addresses on the two chains — that is the party who can answer this question.

The **two batch posters** are worth carrying separately: `0xA4b0…73657175656e636572` spells
`sequencer` in ASCII in its low bytes, which is the Nitro convention for the sequencer's own
address, and the second is a distinct EOA. Neither is a contract this platform can read a delay
off.

## 9. What is measured against a mock, and what that costs

Every gas figure in `docs/gas.md` — including the 5,235,730 worst-case 64-item batch — was measured
against `MockUSDG`, roughly the cheapest possible ERC-20. **Mainnet USDG is presumed to be an
upgradeable proxy with a blocklist, and there are two transfers per voucher.**

The margin, from `docs/chain-facts.md` §5: `maxTxGasLimit` is 32,000,000, so the worst case uses
16.4 % of it and each of the 128 transfers in that batch may become ~209,000 gas more expensive
before the cap binds. That is a wide margin and the cap holds — but the number that would breach it
is stated so a future reader can check it rather than trust it.

**Re-measured on 46630, and the direction was the OPPOSITE of the prediction.** The
real token's worst-case 64-item batch is **5,323,988** gas against the mock's 5,235,730 — the mock
is **cheaper** by 1.69 %, where the prediction extrapolated a single transfer and expected the mock
to be 542,000 gas dearer. **A single-transfer figure does not extrapolate to a batch.** Headroom
against the 32,000,000 cap is **6.01×**, not 6.11×. Anything that reused "the mock is
conservative" as an argument needs re-reading.

The 4663 figure is still unmeasured and unobtainable: it needs the mainnet token, which is §0.1.

There is no Permit2 deposit path: a buyer funds with `approve` + `depositFor` (D-11, D-18).

## 10. The relayer float

The relayer EOA holds a small ETH float and does three things with it: submits `setLimitsBySig`
and `requestWithdrawBySig` on a buyer's behalf, submits voucher redemptions, and — once, per
address, ever — funds a buyer who has USDG in escrow and no ETH so they can call `withdraw()`
themselves (risk register §9, the mainnet blocker; the grant is bounded by a UNIQUE INDEX on the
address, not by a rate limit).

**Target ≤ 0.05 ETH.** A leaked relayer key costs exactly the float and nothing else: the key
appears in no authorisation path in `AssayEscrow`, every `*BySig` carries `escrow.authNonce` and a
deadline inside the signed struct, and `sendValue` has no calldata parameter — so it can never
move USDG. That bound is the reason the float is small and the reason it is topped up rather than
made large.

The floor is **one number**, `EVM_RELAYER_FLOAT_LOW_WEI`, read by two things: the gas grant
refuses below it (`GasGrantRefusal.RELAYER_FLOAT_LOW`) and `EvmRelayerFloatMonitor` alerts on it
every five minutes. Two keys with one meaning drift, and the drift is silent in the worst
direction — the grant paying out below a level nobody is watching.

`withdrawsRemaining` in the alert is `floor(balance / EVM_RELAYER_GAS_GRANT_MAX_WEI)`. It is
floored against the **per-grant ceiling**, not against a live estimate, so it can under-report and
can never over-report: no grant may ever cost more than that cap.

### When `evm_relayer_float_low` fires (WARN, working hours)

1. Read `withdrawsRemaining` in the alert — that is the number that matters, not the wei.
2. `cast balance <relayer> --rpc-url <rpc>` to confirm, and `cast call <escrowProxy>
   'totalEscrowed()(uint128)' --rpc-url <rpc>` for the exposure behind it.
3. Top up to target from the funding account. **Never from the admin Ledger** — that key signs
   `updateConfig`, `setPaused`, `registerVerifier` and every `upgradeToAndCall`, and it must not
   acquire a routine reason to be plugged in.
4. The alert is `ONCE_PER_INCIDENT` with a one-hour window; it will fire again if still true.

### When `evm_relayer_float_critical` fires (CRITICAL, page)

**Two things stop, and in this order.** Voucher redemption stops first and is the expensive one:
calls have been served and cannot be collected, exactly as a `VoucherTooOld` is absorbed
(risk register §1). Gas grants stop too, so a zero-ETH buyer's only remaining route out is to
send themselves ETH from anywhere — which support can say, and which is the honest answer.

**What does NOT stop:** `withdraw()` and `withdrawStake()` are `msg.sender`-only and never
pause-gated (`test_pauseNeverClosesTheBuyersExit`). Anyone holding ETH can still exit. **Never
`setPaused(true)` because the float is dry** — pausing does not refill it, and it closes the
deposit and redemption paths for a reason unrelated to them.

### When `evm_relayer_float_unreadable` fires

The chain could not be read. It is **not** a zero balance and must not be treated as one. Check
the RPC first (`cast block-number`), then §8's sequencer note. The alert deliberately does **not**
carry the RPC error message: an RPC failure quotes the URL it failed against, and an RPC URL can
carry an API key in its path where structural redaction cannot see it. The message is in the
scheduler's log.

The same alert fires when the relayer has **no key** for an enabled `eip155` chain. In an API
replica that is a supported read-only deployment; in the scheduler — the only process that
registers this monitor — it means the process that sends redemptions and grants cannot send.

### Pre-flight, before any deploy that turns the relayer on

- [ ] `EVM_RELAYER_FLOAT_LOW_WEI` and `EVM_RELAYER_FLOAT_CRITICAL_WEI` are set, critical strictly
      below low. **Unset is a boot failure, deliberately** — an unwatched float is worse than a
      process that refuses to start.
- [ ] `EVM_RELAYER_GAS_GRANT_MAX_WEI` and `EVM_RELAYER_GAS_GRANT_DAILY_MAX_WEI` are set. Same
      rule, same reason.
- [ ] The relayer address is funded above the low mark, and `cast balance` says so.
- [ ] `EVM_RELAYER_ENABLED` and `EVM_VOUCHER_REDEMPTION_ENABLED` are flipped **after** the three
      above, not before.

**Nothing on this page has been exercised end to end against a chain.** The monitor, the grant and
both marks are unit-proved only. The backend's testnet acceptance step `a buyer withdraws with zero
ETH` is where the path is first exercised, and it reports `NOT RUN` until then.

## 11. The environment configuration and the code deploy in ONE window

In the backend, `ENABLED_CHAINS` replaced `SOLANA_ENABLED_CHAINS`, and the replacement **fails closed in
both directions**: `ENABLED_CHAINS` has no default and unset is a boot failure, and the mere
**presence** of `SOLANA_ENABLED_CHAINS` is also a boot failure — it fails even alongside a valid
`ENABLED_CHAINS`, and even when it is set to the empty string. That is deliberate: an ambiguous
alias in the one variable that decides which network is live is the mainnet/devnet mislabel the
variable exists to prevent.

Any environment configured before that change still holds `SOLANA_ENABLED_CHAINS`.

**So the configuration edit and the deploy are one action:**

1. remove `SOLANA_ENABLED_CHAINS`;
2. add `ENABLED_CHAINS=solana:EtWTRABZaYq6iMfeYKouRu166VU2xqa1` — CAIP-2 literals only, comma
   separated, from the chain ids the backend (`assay-backend` repo) documents;
3. add `eip155:46630` to that list **only when** the 46630 deployment record exists, its
   `verify-deployment.sh` is green, and §10's float pre-flight is done;
4. roll the deployment.

**Doing 4 before 1–2 leaves the API refusing to boot, and `/health` does not answer at all.** That
is the intended direction — loud beats silent, unlike a failure where scheduled jobs silently stop
while `/health` stays 200 — **but it is only useful if somebody is watching the deploy.** Watch it.

**Two more variables changed shape in the same release, and both are breaking:**

- **`EVM_DEPLOYMENTS` now requires six addresses per chain**, not four: `config`, `stake`,
  `escrow`, `asset`, **`escrowImplementation`** and **`admin`**. The last two are what
  `VaultPort.assertVaultControl` compares the live chain against, and they are required rather
  than optional because an optional expectation is one a control check cannot fail against — a
  deployment that omitted them would reconcile with two of its three control reads silently
  skipped and would look exactly like one that passed all three. Copy both from
  `deployments/<chainId>.json` in this repository. This only bites a deployment that has an eip155 chain enabled.
- **`EVM_RELAYER_FLOAT_LOW_WATER_WEI` is renamed `EVM_RELAYER_FLOAT_LOW_WEI`** (§10), because it is
  one mark read by two things and it now lives in one symbol.

**Order for the first eip155-enabled roll:** the configuration edit (all of the above, in one
save), then the image. Not the other way round.

Secrets belong in a secret store, never in a plain configuration object, and a configuration dump
must never be pasted anywhere.

`ENABLED_CHAINS` is **not a kill switch.** Stopping a live chain is `setPaused` on chain, from the
Ledger — the same on both chains.
