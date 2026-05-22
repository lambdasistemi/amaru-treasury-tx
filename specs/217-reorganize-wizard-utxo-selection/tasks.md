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

- [ ] T001 — RED: add unit tests asserting (a) the new
  `queryFlatFunds` / `filterFundUtxos` helper drops
  reference-script-bearing UTxOs and (b) `resolveReorganize` mocked
  with a list including `treasuryDeployedAt` excludes that outref
  from `riTreasuryUtxos`. Both must fail on `origin/main`.
- [ ] T002 — GREEN: add `queryFlatFunds` (and pure
  `filterFundUtxos` helper) to `Cli/Common.hs`; wire
  `sreQueryTreasuryUtxos` (`Cli/ReorganizeWizard.hs:379`) and
  `reEnvQueryTreasuryUtxos` (`Cli/SwapCommon.hs:170`) to it. RED
  tests pass at HEAD. `./gate.sh` green.

## S2 — Live devnet smoke proof (orchestrator-owned)

- [ ] T003 — Run `just devnet-cli-smoke --phase reorganize
  --run-dir runs/devnet-cli/217-<stamp>` to completion (build,
  submit, on-chain confirmation of merged treasury UTxO). Archive
  the run dir and the `tx-inspect` summary in the PR body.

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
