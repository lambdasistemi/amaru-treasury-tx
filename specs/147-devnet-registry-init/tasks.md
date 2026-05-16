# Tasks: DevNet Registry Initiator

**Input**: Design documents from `specs/147-devnet-registry-init/`  
**Issue**: [#147](https://github.com/lambdasistemi/amaru-treasury-tx/issues/147)  
**Parent**: [#151](https://github.com/lambdasistemi/amaru-treasury-tx/issues/151)

## Phase 1: Scope And Tracking

- [x] T001 Create branch `147-devnet-registry-init` from current `origin/main`.
- [x] T002 Assign issue #147 to the current GitHub user.
- [x] T003 Open draft PR #152 for issue #147.
- [ ] T004 Update PR #152 metadata after the Spec Kit artifacts are committed.

## Phase 2: Spec Kit And Solo Review Gate

- [x] T005 Write `specs/147-devnet-registry-init/spec.md`.
- [x] T006 Write `specs/147-devnet-registry-init/plan.md`, `research.md`, `data-model.md`, `quickstart.md`, and `contracts/devnet-registry-init.md`.
- [x] T007 Write `specs/147-devnet-registry-init/tasks.md`.
- [x] T008 Write `llm/reviews/local-147-devnet-registry-init/gate.sh` and `state.md`.
- [x] T009 Locally review the plan against the PR skill plan gate and record the verdict in `llm/reviews/local-147-devnet-registry-init/plan-review.md`.
- [x] T010 Locally review the tasks against the PR skill tasks gate and record the verdict in `llm/reviews/local-147-devnet-registry-init/tasks-review.md`.
- [x] T011 Verify the process slice with `.specify/scripts/bash/check-prerequisites.sh --json --require-tasks --include-tasks` and `git diff --check`.
- [ ] T012 Commit the process slice as `docs(devnet): plan registry initiator`.

## Phase 3: User Story 1 - Publish Registry State From Production Code (Priority: P1)

**Goal**: A production-backed registry initiator publishes registry and
reference-script state; smoke only calls it and verifies chain effects.

**Owner**: One implementation subagent. The orchestrator must not make
the behavior-changing code edits for this phase except to apply a
review correction explicitly requested by the subagent brief.

**Independent Test**: `nix develop --quiet -c just devnet-smoke registry-init`
passes and the diff shows registry publication builders under `lib/`.

### Tests For User Story 1

- [ ] T013 [US1] RED: run `scripts/smoke/devnet-local --phase registry-init --run-dir <tmp>` and record that the current branch rejects `registry-init` as an unknown phase.
- [ ] T014 [US1] RED: add focused unit coverage for registry artifact rendering in `test/unit/Amaru/Treasury/Devnet/RegistryInitSpec.hs`, expecting the missing production module to fail before implementation.

### Implementation For User Story 1

- [ ] T015 [US1] Add `Amaru.Treasury.Devnet.RegistryInit` in `lib/Amaru/Treasury/Devnet/RegistryInit.hs` with explicit exports for registry publication types, artifact paths, artifact rendering, and the production-backed publication entry point.
- [ ] T016 [US1] Expose `Amaru.Treasury.Devnet.RegistryInit` and the unit spec in `amaru-treasury-tx.cabal`.
- [ ] T017 [US1] Move reusable registry script derivation, NFT publication, reference-script publication, anchor rendering, and registry-view projection out of `test/devnet/Amaru/Treasury/Devnet/SmokeSpec.hs` into the production module.
- [ ] T018 [US1] Replace the inline `SmokeSpec.hs` registry construction with calls into `Amaru.Treasury.Devnet.RegistryInit`.
- [ ] T019 [US1] GREEN: run `nix develop --quiet -c just unit "Amaru.Treasury.Devnet.RegistryInit"`.
- [ ] T020 [US1] Commit the production initiator slice as `feat(devnet): add registry initiator`.

## Phase 4: User Story 2 - Emit Bootstrap Artifacts For Later Slices (Priority: P1)

**Goal**: Registry-init writes durable artifacts with every anchor needed
by #148, #149, and #150.

**Owner**: One implementation subagent, started only after Phase 3 is
reviewed and the orchestrator has rerun the relevant local verification.

**Independent Test**: The registry-init run directory contains
`registry-init/registry.json`, `summary.json`, and `provenance.json`
with the contract fields in `contracts/devnet-registry-init.md`.

### Tests For User Story 2

- [ ] T021 [US2] RED: add a devnet diagnostics expectation in `test/devnet/Amaru/Treasury/Devnet/SmokeSpec.hs` for the `registry-init` summary and registry artifact fields before the phase exists.

### Implementation For User Story 2

- [ ] T022 [US2] Add `registry-init` phase parsing to `scripts/smoke/devnet-local` and `just devnet-smoke`.
- [ ] T023 [US2] Add `registry-init` Hspec phase dispatch in `test/devnet/Amaru/Treasury/Devnet/SmokeSpec.hs`.
- [ ] T024 [US2] Write `registry-init/summary.json`, `registry-init/registry.json`, and `registry-init/provenance.json` from the production artifact projection.
- [ ] T025 [US2] Verify anchor UTxOs through `Provider.queryUTxOByTxIn` and reference-script hashes before reporting success.
- [ ] T026 [US2] GREEN: run `nix develop --quiet -c just devnet-smoke registry-init` and record the run directory, tx ids, and anchor TxIns.
- [ ] T027 [US2] Commit the live registry-init slice as `test(devnet): prove registry initiator`.

## Phase 5: User Story 3 - Keep DevNet Smoke Thin (Priority: P2)

**Goal**: Documentation and review evidence make the boundary clear.

**Owner**: Orchestrator for docs/PR metadata after subagent code
changes are reviewed. A subagent may be used only for a narrow docs
patch if the orchestrator supplies exact files and forbidden scope.

**Independent Test**: Reviewers can see that production code owns
registry transaction construction and docs describe only registry-init
evidence.

### Implementation For User Story 3

- [ ] T028 [US3] Update `docs/local-devnet-smoke.md` with registry-init usage, artifact paths, and the verified run directory.
- [ ] T029 [US3] Update `README.md` with registry-init command usage and clear boundaries for #148, #149, and #150.
- [ ] T030 [US3] Update PR #152 title/body with verified commands and run artifacts.
- [ ] T031 [US3] Run `./llm/reviews/local-147-devnet-registry-init/gate.sh`.
- [ ] T032 [US3] Commit docs and PR metadata as `docs(devnet): document registry initiator`.

## Dependencies

- Phase 2 must complete before any implementation subagent starts.
- Phase 3 must complete before Phase 4 because the smoke phase must call
  the production entry point.
- Phase 4 must complete before Phase 5 because docs need verified run
  artifacts.
- Issue #148 starts only after #147 artifacts are available and PR #152
  is ready for external review or merged.

## Subagent Protocol

- Start subagents only after `spec.md`, `plan.md`, and `tasks.md` are
  written and locally reviewed.
- Before every handoff, the orchestrator analyzes the relevant code,
  architecture, and task slice, then applies any needed corrections to
  the artifacts or brief locally.
- Use one subagent at a time for #147.
- Give each subagent exact task ids, owned files/modules, forbidden
  scope, RED proof, GREEN proof, and the gate command.
- Do not ask subagents to discover or repair orchestration mistakes; the
  handoff brief must already reflect the orchestrator's analysis and
  fixes.
- Subagents do not edit `spec.md`, `plan.md`, or `tasks.md` unless asked
  to apply a review correction.
- Subagents do not update final PR metadata, merge, close tickets, or
  declare #147 complete.
- The orchestrator reruns verification locally; subagent-reported
  success is not enough.

## First Subagent Brief Template

Use one subagent at a time, only after Phase 2 review is complete.

```text
Task: T013-T020 only.
Owned files:
- lib/Amaru/Treasury/Devnet/RegistryInit.hs
- amaru-treasury-tx.cabal
- test/unit/Amaru/Treasury/Devnet/RegistryInitSpec.hs
- test/devnet/Amaru/Treasury/Devnet/SmokeSpec.hs
- scripts/smoke/devnet-local, only if needed for the RED unknown-phase proof

Forbidden scope:
- Do not edit spec.md, plan.md, tasks.md, README.md, or docs.
- Do not add staking, governance funding, treasury withdrawal, or
  disburse behavior.
- Do not move transaction construction back into SmokeSpec.hs.

RED proof:
- scripts/smoke/devnet-local --phase registry-init --run-dir <tmp>
  fails with the current unknown-phase contract before the phase is added.
- The new unit spec fails before the production module exists.

GREEN proof:
- nix develop --quiet -c just unit "Amaru.Treasury.Devnet.RegistryInit"
- git diff must show reusable registry publication builders under lib/.
```
