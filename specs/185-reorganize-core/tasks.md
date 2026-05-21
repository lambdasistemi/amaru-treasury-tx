# Tasks: 185-reorganize-core

**Input**: Design documents from `/specs/185-reorganize-core/`
**Prerequisites**: `plan.md`, `spec.md`, `research.md`, `data-model.md`, `contracts/`
**Branch**: `185-reorganize-core`
**Issue**: #185, child of epic #189

**Tests**: TDD is required by the plan. Each implementation slice starts
with a RED proof, then lands GREEN in the same bisect-safe commit.

**Organization**: Tasks are grouped by the amended S1/S2/S3 vertical
slices. Each slice is dispatched to a codex driver+navigator pair loaded
with `pair-programming`; workers do not push. The orchestrator reviews
the returned commit, amends the matching checkboxes into that same commit
on acceptance, runs the gate, and then pushes.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel with another task in the same phase.
- **[Story]**: User-story coverage from `spec.md`.
- **S1/S2/S3**: Bisect-safe slice mapping from `plan.md`.

## Phase 1: Setup

No remaining setup tasks. The branch, draft PR, `gate.sh`, specification,
plan, research, data model, and contracts already exist.

## Phase 2: Foundational

No remaining foundational tasks. The amended #191 validation decision is
captured in `plan.md`, `research.md`, `data-model.md`, and `contracts/`.

## Phase 3: S1 - Typed Shapes + Intent JSON Roundtrip

**Goal**: Replace placeholder `ReorganizeInputs` and `ReorganizeIntent`
with the Q-001 A1/B2/C1 field set, wire JSON round-trip behavior, and
publish the real schema arm. `translateIntent` and the build dispatcher
remain intentionally stubbed until S3.

**Independent Test**: `nix develop --quiet -c just unit "IntentJSON"`
passes for the real reorganize payload, and `nix develop --quiet -c just
schema-check` passes with the regenerated `docs/assets/intent-schema.json`.

**Owned files**: `lib/Amaru/Treasury/Tx/Reorganize.hs`,
`lib/Amaru/Treasury/IntentJSON.hs`,
`lib/Amaru/Treasury/IntentJSON/Schema.hs`,
`docs/assets/intent-schema.json`,
`test/unit/Amaru/Treasury/IntentJSONSpec.hs`,
`amaru-treasury-tx.cabal` only if the worker proves this slice needs a
test/module stanza update.

**Commit subject**: `feat(intent): real ReorganizeInputs + ReorganizeIntent shapes`
**Commit trailer**: `Tasks: T001, T002, T003, T004, T005`

### Tests for S1

- [X] T001 [US3] Replace the placeholder reorganize round-trip generator in `test/unit/Amaru/Treasury/IntentJSONSpec.hs` with a field-populated `ReorganizeInputs` generator, including non-empty `treasuryUtxos` and an empty-array rejection case; record the expected RED failure against `lib/Amaru/Treasury/IntentJSON.hs`.

### Implementation for S1

- [X] T002 [US3] Replace the placeholder `ReorganizeIntent` in `lib/Amaru/Treasury/Tx/Reorganize.hs` with the `rgi*` record from `specs/185-reorganize-core/data-model.md`.
- [X] T003 [US3] Replace the placeholder `ReorganizeInputs` in `lib/Amaru/Treasury/IntentJSON.hs` with the `ri*` record, `FromJSON` parser, `ToJSON` encoder, and parser-level non-empty `treasuryUtxos` validation.
- [X] T004 [US3] Update schema generation for the reorganize arm in `lib/Amaru/Treasury/IntentJSON/Schema.hs` if needed, then regenerate `docs/assets/intent-schema.json` with the real `walletUtxo`, `treasuryUtxos`, `treasuryAddress`, `treasuryDeployedAt`, `registryDeployedAt`, `permissionsRewardAccount`, `permissionsDeployedAt`, `scopeOwnerSigner`, and `upperBound` fields.
- [X] T005 [US3] Verify S1 with `nix develop --quiet -c just unit "IntentJSON"`, `nix develop --quiet -c just schema-check`, and `./gate.sh`, recording evidence in `WIP.md`.

**Checkpoint**: S1 is complete when the schema diff matches
`contracts/intent-schema-delta.md`, JSON round-trip tests pass, and the
dispatcher still rejects `SReorganize` by design.

## Phase 4: S2 - Build.Reorganize Runner + Materialization Golden

**Goal**: Add `Amaru.Treasury.Build.Reorganize`, implement the pure
`reorganizeProgram`, and prove direct runner materialization against a
synthetic frozen fixture. The dispatcher remains intentionally unwired
until S3.

**Independent Test**: `nix develop --quiet -c just golden "reorganize"`
passes byte-for-byte against `test/fixtures/reorganize-core/synthetic/`,
and the constrained-pparams overflow fixture fails through the standard
`DiagnosticChecksFailed` final phase-1 path.

**Owned files**: `lib/Amaru/Treasury/Tx/Reorganize.hs`,
`lib/Amaru/Treasury/Build/Reorganize.hs`, `amaru-treasury-tx.cabal`,
`test/golden/ReorganizeGoldenSpec.hs`,
`test/fixtures/reorganize-core/synthetic/`,
`test/fixtures/reorganize-core/synthetic-overflow/`,
`test/golden/Spec.hs` only if hspec discovery or the existing test
entrypoint requires a direct edit.

**Commit subject**: `feat(tx): add Build.Reorganize runner + materialization golden`
**Commit trailer**: `Tasks: T006, T007, T008, T009, T010, T011`

### Tests for S2

- [ ] T006 [US1] Add the RED direct-runner golden harness in `test/golden/ReorganizeGoldenSpec.hs` plus fixture skeletons under `test/fixtures/reorganize-core/synthetic/` and `test/fixtures/reorganize-core/synthetic-overflow/`; record the compile-time or missing-`expected.cbor` RED failure before implementing `lib/Amaru/Treasury/Build/Reorganize.hs`.

### Implementation for S2

- [ ] T007 [US1] Add `reorganizeProgram` to `lib/Amaru/Treasury/Tx/Reorganize.hs`, following the exact spend, collateral, reference, withdraw-zero, continuing-output, signer, and validity sequence in `contracts/reorganize-program-contract.md`.
- [ ] T008 [US1] Create `lib/Amaru/Treasury/Build/Reorganize.hs` with `runReorganizeAction`, `runReorganizeBuild`, required-UTxO checks via existing `missingUtxosError`, preserved-value folding from `ChainContext.ccUtxos`, fee alignment, `validateFinalPhase1`, and standard `ccEvaluateTx` script-result collection.
- [ ] T009 [US1] Update `amaru-treasury-tx.cabal` to expose `Amaru.Treasury.Build.Reorganize` in the library stanza and list `ReorganizeGoldenSpec` under the `golden-tests` suite.
- [ ] T010 [US1] Populate `test/fixtures/reorganize-core/synthetic/` with `answers.json`, `env.json`, `intent.json`, `utxos.json`, `pparams.json`, `exunits.json`, `provenance.md`, and generated `expected.cbor`; populate `test/fixtures/reorganize-core/synthetic-overflow/` for the constrained-pparams final phase-1 failure case.
- [ ] T011 [US1] Verify S2 with `nix develop --quiet -c just unit "Reorganize"`, `nix develop --quiet -c just golden "reorganize"` or `nix develop --quiet -c just golden` if matching is not available, and `./gate.sh`, recording evidence in `WIP.md`.

**Checkpoint**: S2 is complete when `runReorganizeBuild` works directly,
the golden is byte-stable, missing UTxOs fail closed, exec-units overflow
uses `DiagnosticChecksFailed`, and `SReorganize` is still unwired by design.

## Phase 5: S3 - Dispatcher Wire-Up + End-To-End Dispatch Test

**Goal**: Replace the `SReorganize` unsupported-action path in
`Amaru.Treasury.Build` and the `translateIntent` stub in
`Amaru.Treasury.IntentJSON`, then promote the golden to the full
`intent.json -> runFromIntent -> unsigned CBOR` path.

**Independent Test**: `runFromIntentEither` returns `Right _` for the
reorganize fixture, `ReorganizeGoldenSpec` still matches the same
`expected.cbor`, and `rg 'DiagnosticUnsupportedAction +"reorganize"' lib/`
returns no shipped rejection path.

**Owned files**: `lib/Amaru/Treasury/IntentJSON.hs`,
`lib/Amaru/Treasury/Build.hs`, `lib/Amaru/Treasury/Build/Reorganize.hs`
only if the multi-scope/address-parity check cannot live in translation,
`amaru-treasury-tx.cabal`, `test/golden/ReorganizeGoldenSpec.hs`,
`test/unit/Amaru/Treasury/Build/ReorganizeDispatchSpec.hs`.

**Commit subject**: `feat(tx): wire SReorganize dispatcher arm`
**Commit trailer**: `Tasks: T012, T013, T014, T015, T016`

### Tests for S3

- [ ] T012 [US2] Convert `test/golden/ReorganizeGoldenSpec.hs` from direct `runReorganizeBuild` to `runFromIntent`, add RED dispatch coverage in `test/unit/Amaru/Treasury/Build/ReorganizeDispatchSpec.hs`, and record the `DiagnosticUnsupportedAction "reorganize"` RED failure.

### Implementation for S3

- [ ] T013 [US2] Implement `translateIntent SReorganize` and `translateReorganize` in `lib/Amaru/Treasury/IntentJSON.hs`, preserving shared rationale handling, rejecting duplicate `treasuryUtxos`, and applying the multi-scope/address-parity check at translate time; if translation cannot inspect the required `ChainContext` data, implement that parity check in `lib/Amaru/Treasury/Build/Reorganize.hs` instead.
- [ ] T014 [US2] Wire the `SReorganize` arm in `lib/Amaru/Treasury/Build.hs` to `runReorganizeAction` through `nestActionBuildError BuildActionReorganize`, and export `runReorganizeBuild` from the dispatcher module.
- [ ] T015 [US2] Update `amaru-treasury-tx.cabal` for `test/unit/Amaru/Treasury/Build/ReorganizeDispatchSpec.hs` and any dispatcher import/module changes required by `lib/Amaru/Treasury/Build.hs`.
- [ ] T016 [US2] Verify S3 with `nix develop --quiet -c just unit`, `nix develop --quiet -c just golden`, `nix develop --quiet -c just ci`, `./gate.sh`, and an `rg` check that no `DiagnosticUnsupportedAction "reorganize"` rejection remains in `lib/`, recording evidence in `WIP.md`.

**Checkpoint**: S3 is complete when the library consumes a
`SomeTreasuryIntent SReorganize` end to end, produces the same golden
bytes as S2, and all acceptance scenarios in `spec.md` hold.

## Dependencies & Execution Order

### Phase Dependencies

- **Setup / Foundational**: Already complete.
- **S1**: First implementation slice. Required before S2 because S2
  imports the real `ReorganizeIntent` shape.
- **S2**: Depends on S1. Required before S3 because S3 dispatches into
  `runReorganizeAction` and promotes the S2 golden.
- **S3**: Depends on S2. Final behavior-changing slice for #185.

### Slice Commit Boundaries

- **S1 commit**: T001-T005 only.
- **S2 commit**: T006-T011 only.
- **S3 commit**: T012-T016 only.

Every slice commit must be bisect-safe, must include its `Tasks:` trailer,
and must leave `./gate.sh` green at HEAD. Checkboxes are marked done by
amending the reviewed worker commit during orchestrator acceptance.

### Parallel Opportunities

No S1/S2/S3 slice can run in parallel because each consumes the previous
slice's exported types, fixture, or runner. Inside a slice, the navigator
may perform read-only review, run verification commands, and inspect
contracts while the driver holds the write lock.

## Pair Dispatch Notes

For each slice, the orchestrator dispatches one codex driver and one
codex navigator using `TERM=dumb codex --dangerously-bypass-approvals-and-sandbox`.
Both workers load `pair-programming` first, use the file-based
questions/answers protocol, write `WIP.md` evidence, and never push.

## Implementation Strategy

1. Complete S1 and review the JSON/schema diff.
2. Complete S2 and review the direct materialization golden plus overflow
   diagnostic behavior.
3. Complete S3 and run the all-up gate.
4. Finalize PR metadata only after docs, specs, tasks, tests, and PR body
   agree with delivered behavior.
