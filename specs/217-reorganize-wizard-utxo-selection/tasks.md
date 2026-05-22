# Tasks — 217 reorganize-wizard UTxO selection

Owning doc:
`specs/217-reorganize-wizard-utxo-selection/{spec,plan}.md`.

## Bootstrap

- [X] T000 — Bootstrap worktree + `gate.sh` + draft PR. Commit
  `e4cf587b`.

## S1 — Filter script-deploy UTxOs at the query boundary

Single bisect-safe slice. Driver+navigator pair. RED → GREEN in
one amended commit.

Commit subject:

```
fix(reorganize-wizard): drop script-deploy UTxOs from treasury-fund selection
```

- [X] T001 — RED: add unit tests asserting (a) the new
  `queryFlatFunds` / `filterFundUtxos` helper drops
  reference-script-bearing UTxOs and (b) `resolveReorganize` mocked
  with a list including `treasuryDeployedAt` excludes that outref
  from `riTreasuryUtxos`. Both must fail on `origin/main`.
- [X] T002 — GREEN: add `queryFlatFunds` (and pure
  `filterFundUtxos` helper) to `Cli/Common.hs`; wire
  `sreQueryTreasuryUtxos` (`Cli/ReorganizeWizard.hs:379`) and
  `reEnvQueryTreasuryUtxos` (`Cli/SwapCommon.hs:170`) to it. RED
  tests pass at HEAD. `./gate.sh` green.

## S2 — Live devnet smoke evidence (orchestrator-owned)

- [X] T003 — Live devnet smoke evidence captured. The fix changes
  the smoke's outcome from a phase-1 `BabbageNonDisjointRefInputs`
  rejection to a fail-fast at the harness's own typed
  `INSUFFICIENT_TREASURY_UTXOS: treasury at core_development
  carries 1 utxo(s)` guard, against the honest one-real-fund
  reality of the current devnet bootstrap. Run dir:
  `runs/devnet-cli/217-20260522T140934Z`. End-to-end submission
  requires the smoke harness to seed ≥2 real fund UTxOs before
  reorganize, tracked as
  [#222](https://github.com/lambdasistemi/amaru-treasury-tx/issues/222);
  it does not block the mainnet path
  ([#218](https://github.com/lambdasistemi/amaru-treasury-tx/issues/218))
  where real fund cardinality is satisfied on-chain.

## S3 — Finalize (orchestrator-owned)

- [ ] T004 — Finalization audit, `git rm gate.sh`,
  `chore: drop gate.sh (ready for review)`, push, `gh pr ready 219`.

## Cross-references

- Upstream blacklist mechanism (manual):
  `/code/amaru-treasury/journal/2026/lib/select_treasury_utxos.sh:26`
  + `is_blacklisted.sh` + `defaults.sh:13-15`.
- Boundary helper site:
  `lib/Amaru/Treasury/Cli/Common.hs:174-197`.
- Reorganize resolver:
  `lib/Amaru/Treasury/Tx/ReorganizeWizard.hs:332-433`.
- Reorganize live env:
  `lib/Amaru/Treasury/Cli/ReorganizeWizard.hs:378-379`.
- Swap treasury query (same latent bug):
  `lib/Amaru/Treasury/Cli/SwapCommon.hs:169-170`.
- Disburse latent (deferred): see plan.md "Risks".
