# Plan — 218 reorganize-wizard mainnet path

## Trade-offs

- **Lift vs. parameterize.** We lift the guard outright. The data
  type's `ReorganizeNonDevnetNetwork Text` becomes
  `ReorganizeUnresolvedNetwork` because the only legitimate error
  left is "the operator passed neither `--network` nor a
  recognized `--network-magic`". The variant rename forces every
  pattern-match call site to compile against the new shape.
- **Devnet bootstrap commands keep their guard.** Registry-init,
  stake-reward-init, governance-withdrawal-init each have their own
  `requireDevnet*Network` predicate in
  `lib/Amaru/Treasury/Devnet/Runner.hs`; those stay devnet-only
  because they bootstrap a fresh treasury and must not run on
  mainnet. The lift is **only** for `reorganize-wizard`.
- **Live-boundary artifact is mandatory.** Unit tests prove the lift
  compiles; only the mainnet tx body proves it works end-to-end.

## Slice plan

### S1 — Lift the guard

**Owned files:**

- `lib/Amaru/Treasury/Tx/ReorganizeWizard.hs` (data type + render).
- `lib/Amaru/Treasury/Cli/ReorganizeWizard.hs` (pattern match + exit
  code).
- `test/unit/Amaru/Treasury/Cli/ReorganizeWizardParserSpec.hs`
  and/or `test/unit/Amaru/Treasury/Tx/ReorganizeWizardSpec.hs`
  (RED + GREEN).
- Possibly `Trace.hs` if a trace event references the old
  constructor.

**RED:** add a unit test asserting `--network mainnet` (via
`resolveNetworkName` returning `Right "mainnet"`) takes the wizard
past the network gate. On `origin/main` this fails because the gate
returns `ReorganizeNonDevnetNetwork "mainnet"`. After GREEN, the
wizard proceeds to the next step (which will eventually fail at a
deeper stage if mocked chain state is missing — that's fine; the
test only asserts the gate is no longer the failure).

**GREEN:**

1. Rename `ReorganizeNonDevnetNetwork Text` →
   `ReorganizeUnresolvedNetwork` in the data type. Update the
   `Show` instance / renderer accordingly.
2. Replace the pattern match in `runReorganizeWizardEither` with:
   ```haskell
   case resolveNetworkName g of
       Right _ -> stepOut
       Left _ -> pure (Left ReorganizeUnresolvedNetwork)
   ```
3. Update the exit-code map (`exitCodeFor`) accordingly.
4. Fix any compile errors in callers / tests that referenced the
   old constructor.

**Proof commands:**

- `nix develop -c just unit "Reorganize"`
- `nix develop -c just unit "IntentJSON"`
- `./gate.sh`

**Commit:**

```
feat(reorganize-wizard): admit any resolved network (mainnet, preprod, preview, devnet)

Tasks: T001, T002
```

### S2 — Produce the live mainnet tx body (orchestrator-owned, **load-bearing**)

After S1 lands and the gate is green, run the operator command
against `/code/cardano-mainnet/ipc/node.socket`:

```bash
./dist-newstyle/.../amaru-treasury-tx \
  --node-socket /code/cardano-mainnet/ipc/node.socket \
  --network mainnet \
  reorganize-wizard \
    --metadata /code/amaru-treasury/journal/2026/metadata.json \
    --scope <chosen scope> \
    --wallet-addr <operator wallet bech32> \
    --funding-seed-txin <real funded UTxO at that wallet> \
    --out /tmp/218-mainnet-reorganize.intent.json

./dist-newstyle/.../amaru-treasury-tx \
  --node-socket /code/cardano-mainnet/ipc/node.socket \
  --network mainnet \
  tx-build \
    --intent /tmp/218-mainnet-reorganize.intent.json \
    --out /tmp/218-mainnet-reorganize.cbor.hex
```

Archive `intent.json`, `cbor.hex`, and `tx-inspect` summary in the
PR body. If the build phase fails at a deeper boundary
(insufficient fund UTxOs at the chosen scope, missing scope-owner
key hash in metadata, etc.), surface that as a separate ticket and
keep the PR draft — do not fake the artifact.

### S3 — Finalize

`./gate.sh` clean, `git rm gate.sh`, push, `gh pr ready 223`, merge.

## Live-boundary diagnostic

For S1 the unit tests assert the lift compiles. For the epic the
load-bearing check is S2: live mainnet `tx-build` succeeds against
real on-chain state.

## Risks

- **Operator inputs missing.** The wizard needs `--wallet-addr` and
  `--funding-seed-txin`. If the operator can't provide these during
  this PR's lifetime, S2 stalls. That's acceptable — the PR stays
  draft until evidence exists.
- **Scope-specific gotchas.** Each scope has its own treasury
  address and `treasuryUtxos` cardinality on-chain. We pick whichever
  scope currently has ≥2 fund UTxOs (the wizard requires `length ≥
  2`). `cardano-cli query utxo` against each treasury address can
  confirm before invoking.
- **Funding seed must remain unspent.** Between when the operator
  reads `funding-seed-txin` from chain and when `tx-build` consumes
  it as fuel, the UTxO must not have been spent elsewhere. If it has
  been, re-read and retry.
- **Validator deeper failures.** If the lift exposes a deeper
  mainnet-specific failure mode, we file a follow-up ticket and keep
  the PR draft.

## Out of scope (re-asserted)

- Submission (signing/submit handled by existing vault tooling).
- Lifting the guard on other init wizards.
- Smoke harness seed step (#222).
