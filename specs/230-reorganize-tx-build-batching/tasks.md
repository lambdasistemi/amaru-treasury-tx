# Tasks — 230 reorganize tx-build auto-batching

Owning doc: `specs/230-reorganize-tx-build-batching/{spec,plan}.md`.

## Bootstrap

- [X] T000 — Bootstrap worktree + `gate.sh` + draft PR. Commit
  `564b5603`.

## S1 — Pure math: scaler + unit tests

Commit subject:

```
feat(reorganize/batch): pure scaler picks largest N that fits maxTxExUnits
```

- [X] T001 — RED: unit tests in
  `test/unit/Amaru/Treasury/Build/Reorganize/BatchSpec.hs` covering
  `nStarFromMeasured` and `decideBatch` (boundary cases listed in
  `plan.md` → S1).
- [X] T002 — GREEN: new module
  `lib/Amaru/Treasury/Build/Reorganize/Batch.hs` exports the pure
  scaler; cabal updated.

## S2 — Wire into build path

Commit subject:

```
feat(reorganize): tx-build auto-truncates to largest fitting subset
```

- [X] T003 — RED: build-path test with a synthetic ChainContext +
  inflated exec units asserts the runner truncates and surfaces a
  non-empty `brResidualTreasuryInputs`.
- [X] T004 — GREEN: refactor `runReorganizeAction` into
  `pickInputs` + `buildOnce`; iteration cap = 3; new typed error
  `ReorganizeBatchUnconverged`.

## S3 — CLI residue surfacing

Commit subject:

```
feat(tx-build): log selected vs residual treasury UTxOs on reorganize
```

- [X] T005 — Print the residue trace line on
  `Cli/TxBuild.hs`. Optional `--residue-out PATH` if time allows;
  decide at implementation.

## S4 — Live mainnet verification

- [X] T006 — Run the operator command on `network_compliance` against
  `/code/cardano-mainnet/ipc/node.socket`. Inline evidence in the PR
  body (trace line, tx-inspect, cbor blake2b).
- [X] T007 — Inline a synthetic "second batch" demo against the
  residue subset (no need to actually settle the first batch —
  just re-run the wizard on the chain state minus the selected
  inputs to confirm idempotence shape).

## S5 — Finalize (gated on operator approval)

- [X] T008 — `./gate.sh`, `git rm gate.sh`, push, `gh pr ready 231`.
  **HOLD HERE.** Operator must explicitly approve the live-mainnet
  evidence before merge. Do not repeat #218's unilateral merge.

## Cross-references

- pparams lenses:
  `ppMaxTxExUnitsL :: Lens' (PParams era) ExUnits`,
  `ppMaxTxSizeL :: Lens' (PParams era) Word32`.
- Evaluator: `ccEvaluateTx :: ChainContext -> ConwayTx -> IO (Map
  ScriptPurpose (Either err ExUnits))` already wired into
  `Build/Reorganize.hs:196`.
- Validation gate: `validateFinalPhase1` at `Build/Common.hs:121`
  — wraps the ledger's `ExUnitsTooBigUTxO` check among others.
- Math derivation: `spec.md` §Math.
