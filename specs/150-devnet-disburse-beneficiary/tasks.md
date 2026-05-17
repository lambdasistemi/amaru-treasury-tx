# Tasks: DevNet Disburse Action And Beneficiary Receipt

**Input**: Design documents from
`specs/150-devnet-disburse-beneficiary/`
**Issue**: [#150](https://github.com/lambdasistemi/amaru-treasury-tx/issues/150)
**Parent**: [#151](https://github.com/lambdasistemi/amaru-treasury-tx/issues/151)
**PR**: [#155](https://github.com/lambdasistemi/amaru-treasury-tx/pull/155)

## Phase 1: Scope And Tracking

- [x] T001 Merge predecessor issue #149 after PR #154 checks passed.
- [x] T002 Confirm issue #149 closed and parent #151 remains open.
- [x] T003 Create branch `150-devnet-disburse-beneficiary` from merged
  `origin/main`.
- [x] T004 Assign issue #150 to the current GitHub user.
- [x] T005 Add temporary branch-local `gate.sh`.
- [x] T006 Open draft PR #155.

## Phase 2: Spec Kit And Orchestrator Analysis

- [x] T007 Read #151 and #150 and carry forward the command-first
  invariant.
- [x] T008 Inspect existing disburse wizard, disburse builder,
  tx-build dispatch, DevNet command wiring, and #149 handoff artifacts.
- [x] T009 Write `spec.md` with `devnet disburse-submit` as P1.
- [x] T010 Write `checklists/requirements.md`.
- [x] T011 Write `plan.md`, `research.md`, `data-model.md`,
  `quickstart.md`, and `contracts/devnet-disburse-submit.md`.
- [x] T012 Write `analysis.md` and apply analyzer fixes before any
  implementation handoff.
- [x] T013 Write this `tasks.md` with subagent handoff boundaries.
- [x] T014 Run `.specify/scripts/bash/check-prerequisites.sh --json
  --require-tasks --include-tasks` and `git diff --check`.
- [x] T015 Commit the spec/process slice.
- [x] T016 Update PR #155 body with committed phase assets.

## Phase 3: User Story 1 - Shipped Disburse Submit Command (Priority: P1)

**Goal**: `amaru-treasury-tx devnet disburse-submit` consumes #147 and
#149 artifacts, builds/signs/submits an ADA disburse, verifies treasury
state and beneficiary receipt, and emits structured #150 proof
artifacts.

**Owner**: One implementation subagent after Phase 2 review.

**Independent Test**: Focused CLI/module tests prove command shape,
DevNet-only guard, prerequisite validation, artifact rendering, and
failure projection. Focused builds prove executable/library compile.

- [x] T017 (commit: 8802a8e) [US1] RED: add CLI parser coverage for
  `devnet disburse-submit`.
- [x] T018 (commit: 8802a8e) [US1] RED: add non-DevNet guard coverage that rejects before
  reading files, keys, or sockets.
- [x] T019 (commit: 8802a8e) [US1] RED: add artifact path/value/failure projection tests.
- [x] T020 (commit: 8802a8e) [US1] Add
  `lib/Amaru/Treasury/Devnet/DisburseSubmit.hs` with config,
  prerequisite readers, result/failure types, artifact paths, JSON
  rendering, and success lines.
- [x] T021 (commit: 8802a8e) [US1] Validate #147 registry and #149 materialized artifact
  inputs, including DevNet address/network consistency.
- [x] T022 (commit: 8802a8e) [US1] Build the ADA disburse intent through production
  disburse resolver/translation or an equivalent production DevNet
  adapter.
- [x] T023 (commit: 8802a8e) [US1] Build unsigned CBOR and report through the production
  tx-build path.
- [x] T024 (commit: 8802a8e) [US1] Sign, submit, and verify treasury/beneficiary chain
  effects.
- [x] T025 (commit: 8802a8e) [US1] Wire parser/runner through DevNet CLI, top-level CLI,
  main dispatch, and Cabal exposure.
- [x] T026 (commit: 8802a8e) [US1] GREEN: run focused unit tests and lib/exe builds.
- [x] T027 (commit: 8802a8e) [US1] Commit the command slice as
  `feat(devnet): expose disburse submit command` with `Tasks:
  T017,T018,T019,T020,T021,T022,T023,T024,T025,T026,T027`.

## Phase 3B: Command Live-Submit Blocker (Priority: P1)

**Goal**: Repair the shipped command path so Phase 4 can prove it on a
fresh DevNet without bypassing the production permissions validation.

**Owner**: One implementation subagent after this blocker is recorded
and reviewed by the orchestrator.

**Independent Test**: Focused unit coverage must pin the permissions
reward-account setup or command adapter behavior. Live proof must rerun
`nix develop --quiet -c just devnet-smoke disburse-submit` and reach the
beneficiary receipt checks instead of ledger rejection.

- [x] T041 (commit: f23cee3) [US1] RED: capture live rejection from
  `just devnet-smoke disburse-submit`:
  `WithdrawalsNotInRewardsCERTS` for the permissions reward account
  with `Coin 0`, recorded at
  `runs/devnet/20260517T001935Z/disburse-submit/failure.json`.
- [x] T042 (commit: 5e11fd2) [US1] RED: add focused regression coverage for the mismatch
  between #148 permissions reward-account setup and #150 zero-withdrawal
  permissions validation.
- [x] T043 (commit: 5e11fd2) [US1] Fix the DevNet setup or command adapter so the
  production disburse path submits on live DevNet without removing the
  permissions zero-withdrawal validation.
- [x] T044 (commit: 5e11fd2) [US1] GREEN: rerun focused tests/builds plus
  `nix develop --quiet -c just devnet-smoke disburse-submit`, then
  commit the blocker fix as one bisect-safe commit with `Tasks:
  T042,T043,T044`.

## Phase 4: User Story 2 - Thin DevNet Smoke Proof (Priority: P1)

**Goal**: `just devnet-smoke disburse-submit` proves the shipped command
runner on a fresh DevNet.

**Owner**: One implementation subagent after Phase 3 review.

- [x] T028 (commit: ee7d8e8) [US2] RED: prove the current smoke rejects
  `disburse-submit` as an unknown phase.
- [x] T029 (commit: ee7d8e8) [US2] RED: add diagnostics coverage for #150 artifacts.
- [x] T030 (commit: ee7d8e8) [US2] Add `disburse-submit` phase parsing to
  `scripts/smoke/devnet-local` and `just devnet-smoke`.
- [x] T031 (commit: ee7d8e8) [US2] Update `SmokeSpec.hs` so the phase runs #147, #148,
  #149, then invokes the #150 command runner.
- [x] T032 (commit: ee7d8e8) [US2] Assert disburse-submit artifacts and observed
  treasury/beneficiary effects.
- [x] T033 (commit: ee7d8e8) [US2] GREEN: run `nix develop --quiet -c cabal build
  test:devnet-tests -O0` and `nix develop --quiet -c just devnet-smoke
  disburse-submit`.
- [x] T034 (commit: ee7d8e8) [US2] Commit the smoke proof slice as
  `test(devnet): prove disburse submit` with `Tasks:
  T028,T029,T030,T031,T032,T033,T034`.

## Phase 5: Documentation And Finalization (Priority: P2)

**Owner**: Orchestrator.

- [x] T035 [US3] Update README with manual `devnet disburse-submit`
  usage, expected artifacts, and latest live evidence.
- [x] T036 [US3] Update `docs/local-devnet-smoke.md` and
  `docs/release.md`.
- [x] T037 [US3] Update quickstart, contract, tasks, and PR body with
  accepted live evidence.
- [ ] T038 [US3] Run final prerequisites check, `git diff --check`, and
  `./gate.sh`.
- [ ] T039 [US3] Remove `gate.sh` in the final cleanup commit before
  marking PR ready.
- [ ] T040 [US3] Mark PR #155 ready only after docs, metadata, specs,
  quickstart, tasks, and PR body align.

## Subagent Handoff Contract

Each behavior-changing subagent receives only one vertical slice and
must return exactly one commit. The commit must include RED/GREEN proof,
pass `./gate.sh` or report the exact blocker, include a `Tasks:`
trailer, update this `tasks.md`, and avoid unrelated docs/process
artifacts unless explicitly assigned.
