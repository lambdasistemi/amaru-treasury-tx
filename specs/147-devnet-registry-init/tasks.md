# Tasks: DevNet Registry Initiator

**Input**: Design documents from `specs/147-devnet-registry-init/`  
**Issue**: [#147](https://github.com/lambdasistemi/amaru-treasury-tx/issues/147)  
**Parent**: [#151](https://github.com/lambdasistemi/amaru-treasury-tx/issues/151)

## Phase 1: Scope And Tracking

- [x] T001 Create branch `147-devnet-registry-init` from current `origin/main`.
- [x] T002 Assign issue #147 to the current GitHub user.
- [x] T003 Open draft PR #152 for issue #147.
- [x] T004 Update PR #152 metadata after the Spec Kit artifacts are committed.

## Phase 2: Spec Kit And Solo Review Gate

- [x] T005 Write `specs/147-devnet-registry-init/spec.md`.
- [x] T006 Write `specs/147-devnet-registry-init/plan.md`, `research.md`, `data-model.md`, `quickstart.md`, and `contracts/devnet-registry-init.md`.
- [x] T007 Write `specs/147-devnet-registry-init/tasks.md`.
- [x] T008 Write `llm/reviews/local-147-devnet-registry-init/gate.sh` and `state.md`.
- [x] T009 Locally review the plan against the PR skill plan gate and record the verdict in `llm/reviews/local-147-devnet-registry-init/plan-review.md`.
- [x] T010 Locally review the tasks against the PR skill tasks gate and record the verdict in `llm/reviews/local-147-devnet-registry-init/tasks-review.md`.
- [x] T011 Verify the process slice with `.specify/scripts/bash/check-prerequisites.sh --json --require-tasks --include-tasks` and `git diff --check`.
- [x] T012 Commit the process slice as `docs(devnet): plan registry initiator`.

## Phase 3: User Story 1 - Publish Registry State From Production Code (Priority: P1)

**Goal**: A production-backed registry initiator publishes registry and
reference-script state; smoke only calls it and verifies chain effects.

**Owner**: One implementation subagent. The orchestrator must not make
the behavior-changing code edits for this phase except to apply a
review correction explicitly requested by the subagent brief.

**Independent Test**: `nix develop --quiet -c just devnet-smoke registry-init`
passes and the diff shows registry publication builders under `lib/`.

### Tests For User Story 1

- [x] T013 [US1] RED: run `scripts/smoke/devnet-local --phase registry-init --run-dir <tmp>` and record that the current branch rejects `registry-init` as an unknown phase.
- [x] T014 [US1] RED: add focused unit coverage for registry artifact rendering in `test/unit/Amaru/Treasury/Devnet/RegistryInitSpec.hs`, expecting the missing production module to fail before implementation.

### Implementation For User Story 1

- [x] T015 [US1] Add `Amaru.Treasury.Devnet.RegistryInit` in `lib/Amaru/Treasury/Devnet/RegistryInit.hs` with explicit exports for registry publication types, artifact paths, artifact rendering, and the production-backed publication entry point.
- [x] T016 [US1] Expose `Amaru.Treasury.Devnet.RegistryInit` and the unit spec in `amaru-treasury-tx.cabal`.
- [x] T017 [US1] Move reusable registry script derivation, NFT publication, reference-script publication, anchor rendering, and registry-view projection out of `test/devnet/Amaru/Treasury/Devnet/SmokeSpec.hs` into the production module.
- [x] T018 [US1] Replace the inline `SmokeSpec.hs` registry construction with calls into `Amaru.Treasury.Devnet.RegistryInit`.
- [x] T019 [US1] GREEN: run `nix develop --quiet -c just unit "Amaru.Treasury.Devnet.RegistryInit"`.
- [x] T020 [US1] Commit the production initiator slice as `feat(devnet): add registry initiator`.

Evidence:

- RED: `scripts/smoke/devnet-local --phase registry-init --run-dir /tmp/tmp.gbzyVXpWqB` exited 64 with `devnet-smoke: unknown phase: registry-init`.
- RED: focused unit coverage initially failed before production wiring because `Amaru.Treasury.Devnet.RegistryInit` did not exist.
- GREEN: local orchestrator verification of `b9106a5d1641601536604dae409851708165516b` passed `git diff --check`, `nix develop --quiet -c cabal build lib:amaru-treasury-tx -O0`, `nix develop --quiet -c just unit "Amaru.Treasury.Devnet.RegistryInit"` with 3 examples and 0 failures, `nix develop --quiet -c cabal build test:devnet-tests -O0`, focused `fourmolu -m check`, `cabal-fmt -c amaru-treasury-tx.cabal`, and the commit message gate.

## Phase 4: User Story 2 - Emit Bootstrap Artifacts For Later Slices (Priority: P1)

**Goal**: Registry-init writes durable artifacts with every anchor needed
by #148, #149, and #150.

**Owner**: One implementation subagent, started only after Phase 3 is
reviewed and the orchestrator has rerun the relevant local verification.

**Independent Test**: The registry-init run directory contains
`registry-init/registry.json`, `summary.json`, and `provenance.json`
with the contract fields in `contracts/devnet-registry-init.md`.

### Tests For User Story 2

- [x] T021 [US2] RED: add a devnet diagnostics expectation in `test/devnet/Amaru/Treasury/Devnet/SmokeSpec.hs` for the `registry-init` summary and registry artifact fields before the phase exists.

### Implementation For User Story 2

- [x] T022 [US2] Add `registry-init` phase parsing to `scripts/smoke/devnet-local` and `just devnet-smoke`.
- [x] T023 [US2] Add `registry-init` Hspec phase dispatch in `test/devnet/Amaru/Treasury/Devnet/SmokeSpec.hs`.
- [x] T024 [US2] Write `registry-init/summary.json`, `registry-init/registry.json`, and `registry-init/provenance.json` from the production artifact projection.
- [x] T025 [US2] Verify anchor UTxOs through `Provider.queryUTxOByTxIn` and reference-script hashes before reporting success.
- [x] T026 [US2] GREEN: run `nix develop --quiet -c just devnet-smoke registry-init` and record the run directory, tx ids, and anchor TxIns.
- [x] T027 [US2] Commit the live registry-init slice as `test(devnet): prove registry initiator`.

Evidence:

- RED: `nix develop --quiet -c just unit "Amaru.Treasury.Devnet.RegistryInit"` exited 1 before implementation because the production module did not export the richer registry publication type or registry-init artifact helpers.
- GREEN: local orchestrator verification of `a5e74d83ff46474f125d0501a9ab357d01785f2a` passed `git diff --check`, `nix develop --quiet -c just unit "Amaru.Treasury.Devnet.RegistryInit"` with 5 examples and 0 failures, `nix develop --quiet -c cabal build test:devnet-tests -O0`, focused `fourmolu -m check`, `cabal-fmt -c amaru-treasury-tx.cabal`, and the commit message gate.
- LIVE GREEN: `nix develop --quiet -c just devnet-smoke registry-init` passed with 2 devnet examples and 0 failures in `runs/devnet/20260516T184944Z`; seed split tx `f31917b80a3649c90bead84e5aea925d68945021a811f0dc68bd7dcce372a90b`, registry mint tx `8dbb8d18e1814ee733ace77c5c7e59e17bb70c22382c69637e6a154729ec3912`, reference scripts tx `f730f2360b82a8a8fd0a4e071110bb78223d5c09eb2413d32eb48d5e54acb44c`.
- LIVE ANCHORS: scopes `8dbb8d18e1814ee733ace77c5c7e59e17bb70c22382c69637e6a154729ec3912#0`, registry `8dbb8d18e1814ee733ace77c5c7e59e17bb70c22382c69637e6a154729ec3912#1`, permissions `f730f2360b82a8a8fd0a4e071110bb78223d5c09eb2413d32eb48d5e54acb44c#0`, treasury `f730f2360b82a8a8fd0a4e071110bb78223d5c09eb2413d32eb48d5e54acb44c#1`.

## Phase 5: User Story 3 - Keep DevNet Smoke Thin (Priority: P2)

**Goal**: Documentation and review evidence make the boundary clear.

**Owner**: Orchestrator for docs/PR metadata after subagent code
changes are reviewed. A subagent may be used only for a narrow docs
patch if the orchestrator supplies exact files and forbidden scope.

**Independent Test**: Reviewers can see that production code owns
registry transaction construction and docs describe only registry-init
evidence.

### Implementation For User Story 3

- [x] T028 [US3] Update `docs/local-devnet-smoke.md` with registry-init usage, artifact paths, and the verified run directory.
- [x] T029 [US3] Update `README.md` with registry-init command usage and clear boundaries for #148, #149, and #150.
- [x] T030 [US3] Update PR #152 title/body with verified commands and run artifacts.
- [x] T031 [US3] Run `./llm/reviews/local-147-devnet-registry-init/gate.sh`.

Evidence:

- DOCS/GATE GREEN: `./llm/reviews/local-147-devnet-registry-init/gate.sh` passed with Spec Kit prerequisites, `git diff --check`, build, schema-check, 415 unit examples with 0 failures, 25 golden examples with 0 failures and 1 pending, format-check, hlint, smoke scripts, and release version check.
- [x] T032 [US3] Commit docs and PR metadata as `docs(devnet): document registry initiator`.

Metadata:

- PR #152 title/body updated with #147 scope, live `registry-init` evidence, local verification commands, and process notes.
- Docs slice committed as `fa60cc3`.

## Phase 6: Command Gap Correction - Shipped DevNet Registry Init Command (Priority: P1)

**Goal**: #147 exposes a real `amaru-treasury-tx` command for the
registry-init bootstrap action. `just devnet-smoke registry-init`
remains the live proof harness, but it cannot be the only command
surface.

**Owner**: One implementation subagent. The orchestrator owns this
analysis and spec/task correction, then reviews the returned code and
runs verification locally.

**Independent Test**: A focused CLI parser/runner test proves the
command is present, and the live DevNet smoke proves the command path
publishes and verifies registry/reference-script UTxOs.

### Orchestration Correction

- [x] T033 [US1] Reclassify the missing shipped command as a blocking
  #147 acceptance gap against parent #151.
- [x] T034 [US1] Update `spec.md`, `plan.md`, `research.md`,
  `quickstart.md`, and `contracts/devnet-registry-init.md` so the
  production CLI command is required, not a follow-up.

### Tests For Command Slice

- [ ] T035 [US1] RED: add focused CLI parser coverage showing
  `amaru-treasury-tx --network devnet devnet registry-init ...` parses
  as the registry-init command and that non-DevNet networks are rejected
  before submission.
- [ ] T036 [US1] RED: add command-runner or smoke coverage that fails
  before the shipped command path exists.

### Implementation For Command Slice

- [ ] T037 [US1] Add the DevNet registry-init command parser and option
  record under `lib/Amaru/Treasury/Cli/`, using the existing top-level
  `GlobalOpts` for `--network` and `--node-socket`.
- [ ] T038 [US1] Wire the command into `Amaru.Treasury.Cli`, the
  `amaru-treasury-tx` executable dispatch, and Cabal exposure as needed.
- [ ] T039 [US1] Implement the command runner as a thin wrapper around
  `Amaru.Treasury.Devnet.RegistryInit`: parse explicit funding address,
  signing key file, and run directory; open the local node
  provider/submitter; publish registry init; verify the expected anchors;
  write the existing artifact contract; and print command-prefixed
  success lines.
- [ ] T040 [US1] Ensure `just devnet-smoke registry-init` proves the
  same production command path rather than a smoke-only transaction
  construction path.
- [ ] T041 [US1] GREEN: run focused parser/unit tests,
  `nix develop --quiet -c cabal build exe:amaru-treasury-tx -O0`,
  `nix develop --quiet -c cabal build test:devnet-tests -O0`, and
  `nix develop --quiet -c just devnet-smoke registry-init`.
- [ ] T042 [US1] Commit the command slice as
  `feat(devnet): expose registry init command`.

### Docs And Metadata Follow-Up

- [ ] T043 [US1] Update README and local DevNet docs with the shipped
  command invocation, smoke proof command, artifact paths, and the new
  verified run directory.
- [ ] T044 [US1] Rerun the local gate and update PR #152 metadata before
  returning it to external review.

## Dependencies

- Phase 2 must complete before any implementation subagent starts.
- Phase 3 must complete before Phase 4 because the smoke phase must call
  the production entry point.
- Phase 4 must complete before Phase 5 because docs need verified run
  artifacts.
- Phase 6 is a blocking correction discovered after initial
  finalization. Issue #148 starts only after the shipped command slice is
  reviewed, verified, documented, and PR #152 is ready for external
  review or merged.

## Subagent Protocol

- Start subagents only after `spec.md`, `plan.md`, and `tasks.md` are
  written and locally reviewed.
- For #148, #149, and #150, make the shipped operator command the
  paramount P1 user story before any implementation handoff. A smoke
  phase is proof, not a substitute for the command.
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

## Second Subagent Brief Template

Use only after T013-T020 is reviewed and accepted.

```text
Task: T021-T027 only.
Owned files:
- lib/Amaru/Treasury/Devnet/RegistryInit.hs
- test/unit/Amaru/Treasury/Devnet/RegistryInitSpec.hs
- test/devnet/Amaru/Treasury/Devnet/SmokeSpec.hs
- scripts/smoke/devnet-local
- amaru-treasury-tx.cabal only if the focused tests require a metadata
  update

Required orchestrator analysis already applied:
- The T013-T020 extraction preserves final registry anchors but does
  not preserve the seed-split tx id required by
  contracts/devnet-registry-init.md.
- Extend the production module with a registry-init publication result
  that records seed-split, registry-mint, and reference-script tx ids
  plus the final anchors.
- Keep `prepareDevnetWithdrawalRegistry` available for the existing
  withdraw path by projecting from the richer publication result.
- Add registry-init artifact rendering helpers under `lib/`; do not
  render registry-init artifacts ad hoc in `SmokeSpec.hs`.
- `SmokeSpec.hs` owns phase dispatch, calling the production entry
  point, querying `Provider.queryUTxOByTxIn`, checking the expected
  registry/reference-script UTxOs exist, and writing the production
  artifact values.

Forbidden scope:
- Do not edit spec.md, plan.md, tasks.md, README.md, docs, PR metadata,
  or issue metadata.
- Do not add staking setup, governance funding, treasury withdrawal
  materialization, disburse action submission, swap/order execution, or
  external-role behavior.
- Do not move registry transaction construction back into SmokeSpec.hs.

RED proof:
- Add a devnet diagnostics/unit expectation for registry-init summary
  and registry artifact fields before the implementation satisfies it.

GREEN proof:
- nix develop --quiet -c just unit "Amaru.Treasury.Devnet.RegistryInit"
- nix develop --quiet -c cabal build test:devnet-tests -O0
- nix develop --quiet -c just devnet-smoke registry-init
```

## Third Subagent Brief Template

Use only after T033-T034 are committed by the orchestrator.

```text
Task: T035-T042 only.

Owned files:
- lib/Amaru/Treasury/Cli.hs
- app/amaru-treasury-tx/Main.hs
- lib/Amaru/Treasury/Cli/Devnet.hs, or the closest existing CLI module
  pattern if a different name fits better
- lib/Amaru/Treasury/Devnet/RegistryInit.hs, only for reusable
  command-line rendering or anchor-verification helpers
- lib/Amaru/Treasury/Backend/N2C.hs, only if a shared
  provider+submitter helper is needed
- amaru-treasury-tx.cabal
- test/unit/Amaru/Treasury/Cli/EnvelopeSpec.hs, or a new focused CLI
  parser spec if that matches existing test organization better
- test/unit/Amaru/Treasury/Devnet/RegistryInitSpec.hs
- test/devnet/Amaru/Treasury/Devnet/SmokeSpec.hs

Required orchestrator analysis already applied:
- Parent #151 is command recovery, so a smoke-only `just` command is not
  enough for #147.
- The existing production module already owns registry transaction
  construction and artifact values; the new CLI command must be a thin
  wrapper around it.
- The command should be scoped as `amaru-treasury-tx --network devnet
  --node-socket <socket> devnet registry-init ...` unless the existing
  parser shape makes a top-level `devnet-registry-init` materially
  simpler. Keep the command documented and discoverable either way.
- Require explicit `--funding-address`, `--signing-key-file`, and
  `--run-dir` options. Reject non-DevNet networks before any signing or
  submission.
- Reuse existing N2C provider/submitter patterns from
  `Amaru.Treasury.Tx.Submit` and `Amaru.Treasury.Backend.N2C`.
- Reuse existing signing-key decoding patterns from
  `Amaru.Treasury.Tx.Witness` rather than inventing an ad hoc parser.
- The smoke proof must exercise the same production command path or
  command runner. It must not reconstruct registry transaction
  construction inside `SmokeSpec.hs`.

Forbidden scope:
- Do not edit spec.md, plan.md, tasks.md, research.md, quickstart.md, or
  contracts; the orchestrator owns those corrections.
- Do not add staking setup, governance funding, treasury withdrawal
  materialization, disburse action submission, swap/order execution, or
  external-role behavior.
- Do not move registry transaction construction back into `SmokeSpec.hs`
  or CLI glue.
- Do not update PR metadata, merge, close issues, or declare #147 done.

RED proof:
- Add focused parser coverage that fails before the command is wired.
- Add runner/smoke coverage that fails before the command path exists.

GREEN proof:
- nix develop --quiet -c just unit "registry-init command"
- nix develop --quiet -c cabal build exe:amaru-treasury-tx -O0
- nix develop --quiet -c cabal build test:devnet-tests -O0
- nix develop --quiet -c just devnet-smoke registry-init
```
