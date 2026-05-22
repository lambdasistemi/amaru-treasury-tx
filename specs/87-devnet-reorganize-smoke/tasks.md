# Tasks — #87 DevNet reorganize smoke

**Spec**: [spec.md](./spec.md) — see acceptance criteria, scope, and out-of-scope.
**Plan**: [plan.md](./plan.md) — see owned-files and proof strategy per slice.
**Worker CLI/model**: Claude Code (`claude --dangerously-skip-permissions --effort high`) for every driver and navigator.

Owned-files boundaries and proof strategies are normative in [plan.md](./plan.md); only the task IDs and Conventional-Commits commit shapes are normative here.

## Slice S1 — reorganize phase scaffold + missing-builder guard

**Commit subject**: `feat(smoke): reorganize phase scaffold + MISSING_REORGANIZE_BUILDER guard`
**Tasks trailer**: `Tasks: T001, T002, T003, T004, T005`

- [X] **T001** — Recognize `reorganize` as a phase token in `scripts/smoke/smoke.sh` (`preflight_for_phase`, `main` `case "$phase"`, `print_help`).
- [X] **T002** — Add the boundary `MISSING_REORGANIZE_BUILDER` check (verify `amaru-treasury-tx reorganize-wizard --help` succeeds) before any DevNet bring-up; emit the diagnostic on the stderr trace and exit non-zero with a typed code documented in `spec.md`.
- [X] **T003** — Extend `app/devnet-cli-smoke-host/Main.hs` phase dispatch with a `reorganize` case that, for S1, only forwards to the smoke script and exits with whatever the smoke returned (no chain assertions yet).
- [X] **T004** — Extend `test/unit/Amaru/Treasury/Smoke/CliDevnetSmokeSpec.hs` with the new phase string in the allowed-phase list, plus a fixture-driven test that asserts the `MISSING_REORGANIZE_BUILDER` diagnostic is produced by a stub binary missing `reorganize-wizard` (shipped as the static-fixture A-001 binding form: source-level ordering + literal + phase allow-list assertions on `scripts/smoke/smoke.sh` and `app/devnet-cli-smoke-host/Main.hs`).
- [X] **T005** — Confirm `./gate.sh` runs green at HEAD; no `gate.sh` extension required if `just ci` already covers the new unit cases.

## Slice S2 — live reorganize phase body

**Commit subject**: `feat(smoke): live reorganize phase + asset preservation assertion`
**Tasks trailer**: `Tasks: T006, T007, T008, T009, T010, T011, T012`

- [ ] **T006** — Implement `reorganize_phase` in `scripts/smoke/smoke.sh`: chain it after `disburse_phase`, inspect the `core_development` treasury UTxO set, perform an in-harness setup substep when the count is < 2, and surface `INSUFFICIENT_TREASURY_UTXOS` when setup cannot reach ≥2.
- [ ] **T007** — Invoke the shipped `amaru-treasury-tx reorganize-wizard --network devnet …` runner to produce `<run-dir>/phases/reorganize/intent.json`; surface every typed `ReorganizeError` as a documented smoke diagnostic with the runner's exit code.
- [ ] **T008** — Invoke the shipped `amaru-treasury-tx tx-build --intent <intent.json> --out <…>.unsigned.cbor`; record the build log under `<run-dir>/phases/reorganize/build.log`; surface `REORGANIZE_BUILD_FAILED` on non-zero exit.
- [ ] **T009** — Write the per-phase `<run-dir>/phases/reorganize/summary.json` containing: selected input UTxOs (≥2), continuing-output value (including all native assets), epoch/tip context, asset preservation verdict (placeholder until T010 fills it), the intent and CBOR paths.
- [ ] **T010** — In `app/devnet-cli-smoke-host/Main.hs`, add a `reorganize` chain-assertion path that decodes the unsigned CBOR, derives the input UTxO values via N2C `queryUTxO`, sums them across all asset classes, sums the continuing output's value across the same asset classes, and writes the assertion verdict (and observed sums) into `summary.json`. Exits non-zero if value sums diverge.
- [ ] **T011** — Extend `full_phase` to chain `reorganize_phase` after `disburse_phase`; extend the unified `summary.json` written by `write_full_summary` with a `reorganizeSummary` key.
- [ ] **T012** — Extend `test/unit/Amaru/Treasury/Smoke/CliDevnetSmokeSpec.hs` with: (a) a fixture-driven test that the `INSUFFICIENT_TREASURY_UTXOS` diagnostic is produced when only 1 UTxO is seeded; (b) a fixture test that the asset-preservation assertion fails loudly when the continuing output's value sum diverges from input value sum. Both fixtures live alongside existing smoke fixtures; no in-process runner is reachable.

## Slice S3 — exec-units assertion

**Commit subject**: `feat(smoke): assert reorganize exec units within pparams.maxTxExecutionUnits`
**Tasks trailer**: `Tasks: T013, T014, T015, T016`

- [ ] **T013** — Add the `EXEC_UNITS_VALIDATOR_UNAVAILABLE` and `EXEC_UNITS_OVER_LIMIT` diagnostics to the smoke; on the happy path, invoke `cardano-tx-tools tx-validate --input <…>.unsigned.cbor --n2c-socket-path "$CARDANO_NODE_SOCKET_PATH" --network-magic "$CLI_SMOKE_NETWORK_MAGIC" --output json` and capture the JSON output to `<run-dir>/phases/reorganize/tx-validate.json`.
- [ ] **T014** — In the smoke host, parse the captured `tx-validate.json`, load `pparams.maxTxExecutionUnits.{memory,steps}` from the live node via N2C `queryProtocolParameters`, sum the redeemer execution units, and assert the sum is within bounds. Write `execUnitsVerdict` (observed + limit + per-redeemer breakdown) to `summary.json`. Exits non-zero with `EXEC_UNITS_OVER_LIMIT` if any axis is exceeded; non-zero with `EXEC_UNITS_VALIDATOR_UNAVAILABLE` if `tx-validate.json` cannot be parsed.
- [ ] **T015** — Extend `test/unit/Amaru/Treasury/Smoke/CliDevnetSmokeSpec.hs` with a fixture-driven test that feeds the assertion (a) a synthetic over-limit `tx-validate.json` and asserts `EXEC_UNITS_OVER_LIMIT`, (b) a synthetic in-limit `tx-validate.json` and asserts the verdict is recorded with both observed and limit values, (c) a malformed `tx-validate.json` and asserts `EXEC_UNITS_VALIDATOR_UNAVAILABLE`.
- [ ] **T016** — Re-run the live-boundary leg manually (operator follow-up owned by the orchestrator): `just devnet-cli-smoke --phase reorganize --run-dir runs/devnet-cli/<stamp>` and capture the relevant `summary.json` keys (`reorganizeInputs`, `reorganizeContinuingOutput`, `assetPreservationVerdict`, `execUnitsVerdict`) into the PR body before the PR is marked ready. **This task is orchestrator-owned and does not change repo files; it is the live-boundary evidence gate.**

## Slice S4 — finalization (orchestrator-owned)

**Commit subject**: `chore: drop gate.sh (ready for review)`
**Tasks trailer**: n/a (chore commits skip the Tasks: trailer per the commit-message gate).

- [ ] **T017** — `git rm gate.sh`; commit; `./gate.sh`-style scripted finalization audit (orchestrator runs `commit_gate` over the final commit list manually); `gh pr ready`.
- [ ] **T018** — Update the PR body with: live-boundary evidence (per T016), all merged-on-main predecessors, the four delivered diagnostics, the run-dir layout, and explicit non-claims for #188.

## Out of scope (named, not deferred to invent later)

- Operator docs / asciinema cast — #188.
- Closing #46 — the feature anchor closes against the slice that ships the operator surface; #87 does not change the operator surface.
- Mainnet/preprod submission.
- Refactoring `disburse_phase`, `governance_phase`, or the host's existing chain-assertion glue.

## Deliverable coverage check

Every artifact in spec.md `## Deliverables` has a wiring task:

| Deliverable | Task IDs |
|---|---|
| `scripts/smoke/smoke.sh` reorganize phase + diagnostics | T001, T002, T006, T007, T008, T009, T013 |
| `app/devnet-cli-smoke-host/Main.hs` phase dispatch + assertions | T003, T010, T011, T014 |
| `CliDevnetSmokeSpec.hs` allowed phases + fixtures | T004, T012, T015 |
| `specs/87-devnet-reorganize-smoke/` orchestration assets | (orchestrator-owned in the spec/plan/tasks slices and S4) |
| Live run-dir artifacts | exercised by T016 (operator follow-up) |
| Live-boundary evidence in PR body | T016, T018 |
