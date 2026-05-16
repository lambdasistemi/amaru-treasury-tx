# Tasks: DevNet Governance And Withdrawal Setup

**Input**: Design documents from `specs/149-devnet-governance-withdrawal/`
**Issue**: [#149](https://github.com/lambdasistemi/amaru-treasury-tx/issues/149)
**Parent**: [#151](https://github.com/lambdasistemi/amaru-treasury-tx/issues/151)
**PR**: [#154](https://github.com/lambdasistemi/amaru-treasury-tx/pull/154)

## Phase 1: Scope And Tracking

- [x] T001 Merge predecessor issue #148 after PR #153 checks passed.
- [x] T002 Close completed predecessor issue #148 after PR #153 merge.
- [x] T003 Create branch `149-devnet-governance-withdrawal` from
  merged `origin/main`.
- [x] T004 Assign issue #149 to the current GitHub user.
- [x] T005 Add temporary branch-local `gate.sh`.
- [x] T006 Open draft PR #154.

Evidence:

- PR #153 merged at `b525b6d`, and #148 was closed with a resolution
  comment.
- Draft PR #154 was opened with the command-recovery invariant in the
  PR body.
- Phase-review choice is `none` from the user's "merge and proceed"
  instruction.

## Phase 2: Spec Kit And Orchestrator Analysis

- [x] T007 Read #151 and #149 and carry forward the command-first
  invariant from #148.
- [x] T008 Inspect existing DevNet command wiring, #147 registry
  artifacts, #148 stake/reward artifacts, withdraw resolver, tx-build
  path, and inline governance/withdraw smoke code.
- [x] T009 Write `spec.md` with the shipped
  `governance-withdrawal-init` command as P1.
- [x] T010 Write `checklists/requirements.md`.
- [x] T011 Write `plan.md`, `research.md`, `data-model.md`,
  `quickstart.md`, and
  `contracts/devnet-governance-withdrawal-init.md`.
- [x] T012 Write `analysis.md` and apply analyzer fixes before any
  implementation handoff.
- [x] T013 Write this `tasks.md` with subagent handoff boundaries.
- [x] T014 Run `.specify/scripts/bash/check-prerequisites.sh --json
  --require-tasks --include-tasks` and `git diff --check`.
- [x] T015 Commit the spec/process slice as
  `docs(devnet): plan governance withdrawal init`.
- [x] T016 Update PR #154 body with the committed phase assets.

Evidence:

- Orchestrator analysis found that `governanceSmoke` and
  `withdrawSmoke` still construct #149 behavior inline in
  `test/devnet/Amaru/Treasury/Devnet/SmokeSpec.hs`.
- Orchestrator analysis found #148 deliberately registers only the
  treasury reward account and emits permissions as a withdraw-zero
  target; #149 must consume that result and must not re-register
  treasury.
- Orchestrator analysis selected
  `amaru-treasury-tx --network devnet --node-socket <socket> devnet
  governance-withdrawal-init ...` as the operator command contract.
- `.specify/scripts/bash/check-prerequisites.sh --json --require-tasks
  --include-tasks` reported
  `specs/149-devnet-governance-withdrawal` with `research.md`,
  `data-model.md`, `contracts/`, `quickstart.md`, and `tasks.md`
  available.
- `git diff --check` exited 0 before the spec/process commit.
- The spec/process commit added the Spec Kit/process assets to PR #154.
- PR #154 body was updated with the committed assets, command contract,
  phase-review choice, and next implementation slice boundary.

## Phase 3: User Story 1 - Shipped Governance/Withdrawal Command (Priority: P1)

**Goal**: `amaru-treasury-tx devnet governance-withdrawal-init`
consumes #147 and #148 artifacts, funds the treasury reward account
through governance, materializes the reward into a treasury UTxO, and
emits #150 handoff artifacts through production-backed code.

**Owner**: One implementation subagent. The orchestrator does not make
behavior-changing code edits for this phase.

**Independent Test**: Focused CLI/module tests prove the command shape,
DevNet-only guard, prerequisite artifact validation, success-line
contract, and artifact rendering. Focused builds prove the executable
and library compile before live smoke.

### Tests For User Story 1

- [x] T017 [US1] RED: add focused CLI parser coverage in
  `test/unit/Amaru/Treasury/Cli/DevnetSpec.hs` for
  `amaru-treasury-tx --network devnet devnet
  governance-withdrawal-init ...`. Commit: command slice.
- [x] T018 [US1] RED: add non-DevNet guard coverage proving the command
  rejects before reading nonexistent registry, stake/reward, key, or
  socket inputs. Commit: command slice.
- [x] T019 [US1] RED: add artifact path, JSON projection, success-line,
  and failure projection coverage in
  `test/unit/Amaru/Treasury/Devnet/GovernanceWithdrawalInitSpec.hs`.
  Commit: command slice.

### Implementation For User Story 1

- [x] T020 [US1] Add
  `lib/Amaru/Treasury/Devnet/GovernanceWithdrawalInit.hs` with config,
  prerequisite artifact readers, result/failure types, artifact paths,
  JSON rendering, and success lines. Commit: command slice.
- [x] T021 [US1] Implement prerequisite validation that consumes #147
  `registry-init/registry.json` and #148
  `stake-reward-init/accounts.json`, requires DevNet, requires matching
  treasury script hash, and requires the treasury account to be marked
  registered. Commit: command slice.
- [x] T022 [US1] Implement the governance proposal/vote flow in the
  production module, using the #148 treasury reward account without
  re-registering treasury or permissions reward accounts. Commit: command slice.
- [x] T023 [US1] Implement reward wait/verification with stable timeout
  diagnostics, epoch/tip recording, and reward before/after artifacts.
  Commit: command slice.
- [x] T024 [US1] Implement withdrawal intent creation through the
  existing production withdraw resolver/translator and build the
  unsigned transaction through the production tx-build path. Commit: command slice.
- [x] T025 [US1] Implement DevNet-only signing, submission, and
  materialization verification, writing signed tx, submit log, and
  `materialized.json`. Commit: command slice.
- [x] T026 [US1] Add `devnet governance-withdrawal-init` option parsing
  and runner wiring in `lib/Amaru/Treasury/Cli/Devnet.hs`,
  `lib/Amaru/Treasury/Cli.hs`, `app/amaru-treasury-tx/Main.hs`, and
  Cabal exposure as needed. Commit: command slice.
- [x] T027 [US1] GREEN: run focused unit tests for
  `governance-withdrawal-init`, `nix develop --quiet -c cabal build
  lib:amaru-treasury-tx -O0`, and `nix develop --quiet -c cabal build
  exe:amaru-treasury-tx -O0`. Commit: command slice.
- [x] T028 [US1] Commit the command slice as
  `feat(devnet): expose governance withdrawal init command` with
  `Tasks: T017,T018,T019,T020,T021,T022,T023,T024,T025,T026,T027,T028`
  in the commit body and task lines updated with the commit short SHA.
  Commit: command slice.

## Phase 4: User Story 2 - Thin DevNet Smoke Proof (Priority: P1)

### Phase 3 Review Fix

- [x] T044 [US1] Fix live command address rendering so
  `governance-withdrawal-init` emits Bech32 addresses instead of
  UTF-8-decoding serialized binary address bytes, add a regression test
  that covers a real DevNet funding/wallet address render path, and
  rerun the focused command tests/build before the smoke slice resumes.

**Goal**: `just devnet-smoke governance-withdrawal-init` proves the
shipped command runner path on a fresh governance-enabled local DevNet.

**Owner**: One implementation subagent after Phase 3 review.

**Independent Test**: The live smoke passes and the run directory
contains #147, #148, and #149 artifact sets. Smoke only prepares the
node/prerequisites, calls the production runner, and asserts observed
effects.

### Tests For User Story 2

- [x] T029 [US2] RED: run `scripts/smoke/devnet-local --phase
  governance-withdrawal-init --run-dir <tmp>` and record that the
  current branch rejects the phase as unknown.
- [x] T030 [US2] RED: add devnet diagnostics coverage in
  `test/devnet/Amaru/Treasury/Devnet/SmokeSpec.hs` for #149 command
  artifact fields before the phase exists.

### Implementation For User Story 2

- [x] T031 [US2] Add `governance-withdrawal-init` phase parsing to
  `scripts/smoke/devnet-local` and support it through
  `just devnet-smoke`.
- [x] T032 [US2] Update `test/devnet/Amaru/Treasury/Devnet/SmokeSpec.hs`
  so the phase starts a governance-enabled DevNet, runs
  `registry-init`, runs `stake-reward-init`, then invokes the #149
  production command runner.
- [x] T033 [US2] Remove or isolate inline governance proposal, vote,
  withdrawal intent, tx-build, sign/submit, and materialization
  construction from `SmokeSpec.hs` so smoke no longer owns #149
  behavior.
- [x] T034 [US2] Decide and implement `withdraw` smoke compatibility:
  either make it an alias to the same production command proof or
  remove it from documented passing phase lists.
- [x] T035 [US2] GREEN: run `nix develop --quiet -c cabal build
  test:devnet-tests -O0` and `nix develop --quiet -c just devnet-smoke
  governance-withdrawal-init`.
- [x] T036 [US2] Commit the smoke proof slice as
  `test(devnet): prove governance withdrawal init` with `Tasks:
  T029,T030,T031,T032,T033,T034,T035,T036` in the commit body and task
  lines updated with the commit short SHA.

## Phase 5: User Story 3 - Handoff And Documentation (Priority: P2)

**Goal**: #150 can consume the #149 treasury UTxO artifact, and all
user-facing docs describe the shipped command first and smoke proof
second.

**Owner**: Orchestrator. These are non-behavioral docs/metadata edits.

**Independent Test**: README, docs, release notes, contract,
quickstart, tasks, and PR body agree on command shape, smoke proof,
artifact paths, live run evidence, and #150 handoff.

- [x] T037 [US3] Update README with manual
  `devnet governance-withdrawal-init` usage, expected artifacts, and
  latest live run evidence.
- [x] T038 [US3] Update `docs/local-devnet-smoke.md` and
  `docs/release.md` so governance/withdrawal setup documentation leads
  with the shipped command and accurately names any smoke phase aliases.
- [x] T039 [US3] Update `quickstart.md`,
  `contracts/devnet-governance-withdrawal-init.md`, and this
  `tasks.md` with accepted live evidence: run directory, proposal tx id,
  action id, vote tx id, withdrawal tx id, materialized TxIn, and ADA.
- [ ] T040 [US3] Update PR #154 body with committed assets,
  implementation slices, verification evidence, docs/metadata
  alignment, and remaining risk.
- [ ] T041 [US3] Run `.specify/scripts/bash/check-prerequisites.sh
  --json --require-tasks --include-tasks`, `git diff --check`, and
  `./gate.sh`.
- [ ] T042 [US3] Remove `gate.sh` in a final
  `chore(devnet): drop #149 gate` commit before marking the PR ready.
- [ ] T043 [US3] Mark PR #154 ready only after docs, README,
  repository metadata, specs, quickstart, tasks, and PR body align with
  delivered behavior.

Accepted live evidence for T037-T039:

- run directory: `runs/devnet/20260516T231003Z`
- proposal tx id:
  `baffa774b368b1da8c3ff80be399bcf6fa63b5cff658b6889fc00109da218e23`
- governance action id:
  `baffa774b368b1da8c3ff80be399bcf6fa63b5cff658b6889fc00109da218e23#0`
- vote tx id:
  `009801303fc5cc3c3dfe474c30cc4b7d31e99b5af29467cc317072ea6b728c45`
- withdrawal tx id:
  `4a87409b52b8104d51d41df7ee562196cf33621f64c4c40985b4aef5ff21e9bd`
- materialized TxIn:
  `4a87409b52b8104d51d41df7ee562196cf33621f64c4c40985b4aef5ff21e9bd#0`
- materialized ADA: `2000000`

## Subagent Handoff Contract

Each behavior-changing subagent receives only one vertical slice and
must return exactly one commit. The commit must:

- include RED proof and GREEN proof in the final message;
- pass `./gate.sh` or explicitly state the exact command/output blocker;
- use conventional commit shape;
- include a `Tasks:` trailer listing the completed task ids;
- update this `tasks.md` to mark completed task lines with the commit
  short SHA;
- avoid editing unrelated docs/process artifacts unless the brief
  explicitly assigns them.

The orchestrator reviews every returned diff, reruns focused
verification, sends fixes back into the same commit when needed, and
updates PR metadata before dispatching the next slice.
