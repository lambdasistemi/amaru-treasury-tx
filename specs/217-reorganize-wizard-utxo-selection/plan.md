# Plan — 217 reorganize-wizard UTxO selection

## Trade-offs

- **Boundary vs. consumer filter.** The structural place to drop
  script-deploy UTxOs is at the boundary (`queryFlat` in
  `Cli/Common.hs`). The alternative — filter in the wizard by
  subtracting `treasuryDeployedAt` / `permissionsDeployedAt` from
  the candidate set using scope metadata — works but couples the
  wizard to per-scope deploy outrefs. We pick the boundary fix.
- **In-place vs. sibling helper.** Changing `queryFlat`'s semantics
  in place would silently filter for nine call sites. Most call
  wallet-shaped addresses where reference-script UTxOs are not
  expected, but a structural surprise is still a surprise. We add a
  sibling `queryFlatFunds` and rewire only the two treasury-shaped
  call sites (`ReorganizeWizard.hs:379`, `SwapCommon.hs:170`).
- **Live-boundary proof is mandatory.** The unit test mocks the
  query result. Only the live devnet smoke proves the boundary
  filter actually drops the on-chain script-deploy UTxOs and that
  `tx-build` then assembles a phase-1-valid tx. This carries the
  acceptance.

## Slice plan

### S1 — Filter script-deploy UTxOs at the query boundary

Single bisect-safe slice. Driver + navigator pair. RED → GREEN in
one amended commit.

**Owned files (exact set):**

- `lib/Amaru/Treasury/Cli/Common.hs`
- `lib/Amaru/Treasury/Cli/ReorganizeWizard.hs`
- `lib/Amaru/Treasury/Cli/SwapCommon.hs`
- `test/unit/Amaru/Treasury/Cli/CommonSpec.hs` (create if absent;
  otherwise extend)
- `test/unit/Amaru/Treasury/Tx/ReorganizeWizardSpec.hs`
- any fixture under `test/fixtures/...` required to express a
  reference-script-bearing `TxOut` (likely a new mocked Provider /
  pure UTxO list — no on-chain golden needed).

**RED (must fail on `origin/main`):**

1. `CommonSpec.hs` — feed a pure UTxO list with both a
   reference-script-bearing `TxOut` and a plain fund `TxOut`;
   assert `queryFlatFunds` drops the former and returns only the
   latter. (If `queryFlat` is hard to test directly because it
   takes a live `Provider`, isolate the filter as a pure helper
   over `[(TxIn, TxOut era)]` and test the pure helper.)
2. `ReorganizeWizardSpec.hs` — mock `sreQueryTreasuryUtxos` so the
   row list **includes the scope's `treasuryDeployedAt` outref**
   (matching the on-disk fixture); assert `resolveReorganize`'s
   produced `riTreasuryUtxos` excludes it.

**GREEN:**

1. Add `queryFlatFunds :: Provider IO -> Text -> IO [(Text, Integer,
   Bool)]` to `Cli/Common.hs`. Internally it calls the same
   underlying `queryUTxOs`, then filters out any `(TxIn, TxOut)`
   pair whose `TxOut`'s `referenceScript` field is `SJust _` (use
   `cardano-ledger-api`'s `referenceScriptTxOutL`), then summarizes
   the survivors with the existing `queryFlat` shape.
2. Wire `Cli/ReorganizeWizard.hs:379` to `queryFlatFunds` for
   `sreQueryTreasuryUtxos`. Leave `sreQueryWalletUtxos` on plain
   `queryFlat`.
3. Wire `Cli/SwapCommon.hs:170` to `queryFlatFunds` for
   `reEnvQueryTreasuryUtxos`.
4. If the unit test path needs a pure helper exposed for testing,
   add `filterFundUtxos :: [(TxIn, TxOut era)] -> [(TxIn, TxOut
   era)]` next to `queryFlatFunds` and use it inside.

**Proof commands:**

- Unit RED: `nix develop -c just unit "Reorganize"` and `... "Common"`.
- Gate: `./gate.sh`.

**Commit shape:**

```
fix(reorganize-wizard): drop script-deploy UTxOs from treasury-fund selection

Tasks: T001, T002
```

### S2 — Live devnet smoke proof (orchestrator-owned)

- Run `nix develop -c just devnet-cli-smoke --phase reorganize --run-dir runs/devnet-cli/217-<stamp>`.
- Archive the produced reorganize tx body's `tx-inspect` summary in
  the PR body.
- If the smoke fails for an unrelated reason (devnet bring-up,
  fuel), re-run; if it fails for a related reason, reopen S1.

### S3 — Finalize (orchestrator-owned)

- Finalization audit, drop `gate.sh`, mark ready, merge.

## Live-boundary diagnostic

For S1: *"What system boundary does this exercise that the unit
suite cannot?"* — the live Provider's `queryUTxOs` returning real
on-chain UTxOs with attached reference scripts. The unit test
covers the filter on a synthetic list; only the devnet smoke
exercises the full path with real Conway-era `TxOut`s.

## Risks

- **`cardano-ledger-api` lens path.** `TxOut`'s `referenceScript`
  is `Maybe Script` in the high-level API and `SJust / SNothing`
  in the strict-maybe layer. Make sure the driver uses the right
  lens and pattern (`hasReferenceScript :: TxOut era -> Bool` is
  cleaner than open-coding the case match).
- **Swap treasury path.** Wiring `SwapCommon.hs:170` to the new
  helper might surface a latent test failure in the swap suite if
  any fixture happens to ship a reference-script-bearing TxOut. If
  so, regenerate the swap fixture (the change is the same
  structural filter; the test should be updated, not the filter
  bypassed).
- **Disburse latent path.** Out of scope. If the smoke reveals a
  related disburse failure, that's a separate ticket.

## Out of scope (re-asserted)

- Lifting the `ReorganizeNonDevnetNetwork` guard (#218).
- Mainnet artifact production (#218).
- Operator docs / asciinema (#188, blocked on #218).
- Full audit of disburse treasury selection (separate follow-up if
  the smoke surfaces a failure).
