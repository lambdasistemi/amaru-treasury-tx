# Tasks: DevNet Stake And Reward Setup

**Input**: Design documents from `specs/148-devnet-stake-reward/`  
**Issue**: [#148](https://github.com/lambdasistemi/amaru-treasury-tx/issues/148)  
**Parent**: [#151](https://github.com/lambdasistemi/amaru-treasury-tx/issues/151)  
**PR**: [#153](https://github.com/lambdasistemi/amaru-treasury-tx/pull/153)

## Phase 1: Scope And Tracking

- [x] T001 Close completed predecessor issue #147 after PR #152 merge.
- [x] T002 Create branch `148-devnet-stake-reward` from merged
  `origin/main`.
- [x] T003 Assign issue #148 to the current GitHub user.
- [x] T004 Add temporary branch-local `gate.sh`.
- [x] T005 Open draft PR #153.

Evidence:

- #147 was closed with a resolution comment after PR #152 merged.
- Draft PR #153 was opened with the command-recovery invariant in the
  PR body.

## Phase 2: Spec Kit And Orchestrator Analysis

- [x] T006 Read #151, #148, related #32 and #86, and PR #145 WIP
  context.
- [x] T007 Inspect existing DevNet command wiring, registry artifacts,
  reward-account parsing, provider reward queries, and smoke setup code.
- [x] T008 Write `spec.md` with the shipped setup command as P1.
- [x] T009 Write `plan.md`, `research.md`, `data-model.md`,
  `quickstart.md`, and `contracts/devnet-stake-reward-init.md`.
- [x] T010 Write this `tasks.md` with subagent handoff templates.
- [x] T011 Run `.specify/scripts/bash/check-prerequisites.sh --json
  --require-tasks --include-tasks` and `git diff --check`.
- [x] T012 Commit the spec/process slice as
  `docs(devnet): plan stake reward setup` (commit: ec86c26).
- [x] T013 Update PR #153 body with the committed phase assets.

Evidence:

- Orchestrator analysis found that
  `Amaru.Treasury.IntentJSON.Common.parseRewardAccountForNetwork`
  already supports `devnet` as `Testnet`, while disburse translation
  still has Mainnet-only call sites that must be corrected in this
  ticket.
- Orchestrator analysis found existing inline `SmokeSpec.hs` governance
  setup mixes account registration, governance proposal, voting, and
  reward increase; #148 must split only reward-account setup into
  production code and leave governance funding/materialization to #149.
- `.specify/scripts/bash/check-prerequisites.sh --json --require-tasks
  --include-tasks` reported
  `specs/148-devnet-stake-reward` with `research.md`, `data-model.md`,
  `contracts/`, `quickstart.md`, and `tasks.md` available.
- `git diff --check` exited 0 before the spec/process commit.
- Commit `ec86c26` added the Spec Kit/process assets to PR #153.
- PR #153 body was updated with the committed assets, P1 command
  contract, expected artifacts, and local gate evidence.

## Phase 3: User Story 1 - Shipped Stake/Reward Setup Command (Priority: P1)

**Goal**: `amaru-treasury-tx devnet stake-reward-init` registers the
treasury script reward account and emits the permissions script reward
account as the available withdraw-zero target from #147 registry
artifacts through production-backed code.

**Owner**: One implementation subagent. The orchestrator does not make
behavior-changing code edits for this phase.

**Independent Test**: Focused CLI parser/runner tests prove the nested
command exists, rejects non-DevNet networks before effects, and renders
the success-line contract.

### Tests For User Story 1

- [x] T014 [US1] RED: add focused CLI parser coverage in
  `test/unit/Amaru/Treasury/Cli/DevnetSpec.hs` for
  `amaru-treasury-tx --network devnet devnet stake-reward-init ...`
  (commit: dfe56e6).
- [x] T015 [US1] RED: add success-line/artifact rendering coverage in
  `test/unit/Amaru/Treasury/Devnet/StakeRewardInitSpec.hs`, expecting
  the missing production module to fail before implementation
  (commit: dfe56e6).

### Implementation For User Story 1

- [x] T016 [US1] Add `Amaru.Treasury.Devnet.StakeRewardInit` in
  `lib/Amaru/Treasury/Devnet/StakeRewardInit.hs` with setup config,
  result types, artifact paths, JSON rendering, success lines, and
  typed diagnostics (commit: dfe56e6).
- [x] T017 [US1] Implement the production setup entry point that
  consumes #147 registry artifacts/projections, prepares treasury and
  permissions script reward accounts, submits the setup transaction,
  and verifies the expected setup state (commit: dfe56e6).
- [x] T018 [US1] Add `devnet stake-reward-init` parser and option
  record to `lib/Amaru/Treasury/Cli/Devnet.hs`, following the
  registry-init command pattern (commit: dfe56e6).
- [x] T019 [US1] Wire the command into `Amaru.Treasury.Cli`,
  `app/amaru-treasury-tx/Main.hs`, and Cabal exposure as needed
  (commit: dfe56e6).
- [x] T020 [US1] GREEN: run `nix develop --quiet -c just unit
  "stake-reward-init"` and `nix develop --quiet -c cabal build
  exe:amaru-treasury-tx -O0` (commit: dfe56e6).
- [x] T021 [US1] Commit the command slice as
  `feat(devnet): expose stake reward init command` with `Tasks:
  T014,T015,T016,T017,T018,T019,T020,T021` in the commit body and task
  lines updated with the commit short SHA (commit: dfe56e6).

Evidence:

- Subagent RED proof: focused `stake-reward-init` unit target failed
  before implementation because
  `Amaru.Treasury.Devnet.StakeRewardInit` did not exist.
- Orchestrator review accepted commit `dfe56e6`, whose body carries
  `Tasks: T014,T015,T016,T017,T018,T019,T020,T021`.
- `nix develop --quiet -c just unit "stake-reward-init"` passed with
  5 examples and 0 failures.
- `nix develop --quiet -c cabal build exe:amaru-treasury-tx -O0`
  exited 0.
- `git diff --check` exited 0.
- A direct non-DevNet CLI invocation using nonexistent registry,
  signing-key, and socket inputs exited 1 with
  `stake-reward-init: --network must be devnet`, proving the network
  guard runs before those effects.
- The provider API cannot strongly distinguish a registered
  zero-reward account from an absent reward row, so the command records
  the explicit diagnostic
  `RewardAccountRegistrationInferredFromAcceptedTx`.
- Live DevNet smoke later proved this first implementation overreached:
  certificate index 1 evaluates the permissions script under
  `ConwayCertifying` and fails with a Plutus `CekError`. The corrected
  contract is to register treasury only and publish permissions as the
  later withdraw-zero target.

## Phase 4: User Story 2 - Testnet-Aware Permissions Reward Parsing (Priority: P1)

**Goal**: DevNet disburse translation constructs Testnet permissions
reward accounts.

**Owner**: One implementation subagent, after Phase 3 review or folded
into the same bisect-safe commit only if the orchestrator explicitly
accepts that grouping.

**Independent Test**: A DevNet disburse intent translation test observes
the permissions reward account network as `Testnet`.

### Tests For User Story 2

- [x] T022 [US2] RED: add unified disburse intent coverage in
  `test/unit/Amaru/Treasury/IntentJSONSpec.hs` showing DevNet
  permissions reward accounts translate as `Testnet` (commit:
  602d1ed).
- [x] T023 [US2] RED: add legacy disburse intent coverage in
  `test/unit/Amaru/Treasury/Tx/DisburseSpec.hs` if the legacy parser is
  still used by any command or fixture path (commit: 602d1ed).

### Implementation For User Story 2

- [x] T024 [US2] Replace Mainnet-only disburse reward-account parsing
  with `parseRewardAccountForNetwork` in
  `lib/Amaru/Treasury/IntentJSON.hs` (commit: 602d1ed).
- [x] T025 [US2] Update `lib/Amaru/Treasury/Tx/DisburseIntentJSON.hs`
  or document an explicit removal/deprecation path if that legacy
  parser is no longer used (commit: 602d1ed).
- [x] T026 [US2] GREEN: run `nix develop --quiet -c just unit
  "reward accounts as Testnet"` and focused disburse parser tests
  (commit: 602d1ed).
- [x] T027 [US2] Commit the parser slice as
  `fix(devnet): parse disburse reward accounts by network` with
  `Tasks: T022,T023,T024,T025,T026,T027` in the commit body and task
  lines updated with the commit short SHA (commit: 602d1ed).

Evidence:

- Subagent RED proof: `nix develop --quiet -c just unit "reward
  accounts as Testnet"` failed before implementation with two
  `expected: Testnet` / `but got: Mainnet` failures.
- Orchestrator review accepted commit `602d1ed`, whose body carries
  `Tasks: T022,T023,T024,T025,T026,T027`.
- `nix develop --quiet -c just unit "reward accounts as Testnet"`
  passed with 4 examples and 0 failures.
- `nix develop --quiet -c just unit "DisburseIntentJSON"` passed with
  2 examples and 0 failures.
- `nix develop --quiet -c cabal build lib:amaru-treasury-tx -O0`
  exited 0.
- `git diff --check` exited 0.

## Phase 5: User Story 3 - Thin DevNet Smoke Proof (Priority: P2)

**Goal**: `just devnet-smoke stake-reward-init` proves the shipped
command runner path on a fresh local DevNet.

**Owner**: One implementation subagent after Phase 3 and Phase 4 are
reviewed.

**Independent Test**: The live smoke passes and the run directory
contains `stake-reward-init/summary.json`, `accounts.json`, and
`provenance.json` matching the contract.

### Tests For User Story 3

- [x] T028 [US3] RED: run `scripts/smoke/devnet-local --phase
  stake-reward-init --run-dir <tmp>` and record that the current branch
  rejects the phase as unknown (commit: b5e0a88).
- [x] T029 [US3] RED: add devnet diagnostics coverage for
  stake/reward setup artifact fields in
  `test/devnet/Amaru/Treasury/Devnet/SmokeSpec.hs` (commit: b5e0a88).

### Implementation For User Story 3

- [x] T030 [US3] Add `stake-reward-init` phase parsing to
  `scripts/smoke/devnet-local` and `just devnet-smoke` (commit:
  b5e0a88).
- [x] T031 [US3] Update `test/devnet/Amaru/Treasury/Devnet/SmokeSpec.hs`
  so the phase runs registry-init as prerequisite when needed, then
  invokes the production stake/reward setup runner (commit: b5e0a88).
- [x] T032 [US3] Verify expected treasury and permissions reward
  account state through the strongest available provider or transaction
  validation signal; emit a typed diagnostic if the pinned dependency
  cannot distinguish registered zero-reward accounts (commit:
  b5e0a88).
- [x] T033 [US3] GREEN: run `nix develop --quiet -c cabal build
  test:devnet-tests -O0` and `nix develop --quiet -c just devnet-smoke
  stake-reward-init` (commit: b5e0a88).
- [x] T034 [US3] Commit the smoke proof slice as
  `test(devnet): prove stake reward setup` with `Tasks:
  T028,T029,T030,T031,T032,T033,T034` in the commit body and task lines
  updated with the commit short SHA (commit: b5e0a88).

Evidence:

- Subagent RED proof: `scripts/smoke/devnet-local --phase
  stake-reward-init --run-dir <tmp>` exited 64 with
  `devnet-smoke: unknown phase: stake-reward-init`.
- Orchestrator review accepted commit `b5e0a88`, whose body carries
  `Tasks: T028,T029,T030,T031,T032,T033,T034`.
- `nix develop --quiet -c cabal build test:devnet-tests -O0` exited 0.
- `nix develop --quiet -c just devnet-smoke stake-reward-init` passed
  with 1 example and 0 failures in
  `runs/devnet/20260516T213258Z`.
- Live setup tx id:
  `89737f7b4439008d5aeca01789addbbbfeb2876cb4a0fab224f1c545e4076598`.
- Live artifacts confirmed `treasury.registered = true`,
  `permissions.registered = false`, both on ledger network `Testnet`.

## Phase 6: User Story 1 Correction - Permissions Is Withdraw-Zero Only (Priority: P1)

- [x] T035 [US1] RED: add focused unit coverage proving the setup
  artifacts mark treasury as registered and permissions as available but
  not registered (commit: fcb29a3).
- [x] T036 [US1] Update `Amaru.Treasury.Devnet.StakeRewardInit` so the
  setup transaction registers only the treasury script credential,
  verifies the permissions reference script handoff, and emits a typed
  diagnostic for the permissions withdraw-zero-only account (commit:
  fcb29a3).
- [x] T037 [US1] Update CLI help/success artifact wording where it
  currently claims permissions registration (commit: fcb29a3).
- [x] T038 [US1] GREEN: run `nix develop --quiet -c just unit
  "stake-reward-init"` and
  `nix develop --quiet -c cabal build exe:amaru-treasury-tx -O0`
  (commit: fcb29a3).
- [x] T039 [US1] Commit the correction slice as
  `fix(devnet): avoid certifying permissions reward account` with
  `Tasks: T035,T036,T037,T038,T039` in the commit body and task lines
  updated with the commit short SHA (commit: fcb29a3).

Evidence:

- `nix develop --quiet -c just devnet-smoke stake-reward-init` failed
  on 2026-05-16 in run directory
  `runs/devnet/20260516T211137Z`.
- The failure is
  `EvalFailure (ConwayCertifying (AsIx {unAsIx = 1})) ... CekError`.
  Certificate index 1 corresponds to the permissions script credential
  in `StakeRewardInit.submitStakeRewardSetup`.
- Existing production disburse/swap builders invoke the permissions
  script through a 0-lovelace withdrawal, not through a certificate.
- Subagent RED proof: `nix develop --quiet -c just unit
  "stake-reward-init"` exited 1 before production changes because the
  old module did not export the pure setup program needed to inspect
  certificate shape.
- Orchestrator review accepted commit `fcb29a3`, whose body carries
  `Tasks: T035,T036,T037,T038,T039`.
- `nix develop --quiet -c just unit "stake-reward-init"` passed with
  6 examples and 0 failures.
- `nix develop --quiet -c cabal build exe:amaru-treasury-tx -O0`
  exited 0.
- `./gate.sh` exited 0 with 426 unit examples, 25 golden examples,
  0 failures, 1 pending, no hlint hints, smoke scripts, and release
  check passing.

## Phase 7: Documentation, Metadata, And Finalization

- [x] T040 [US3] Update README with the shipped command, proof command,
  latest live run directory, and explicit #149/#150 exclusions.
- [x] T041 [US3] Update `docs/local-devnet-smoke.md` with command,
  expected output, artifacts, and proof evidence.
- [x] T042 [US3] Update `quickstart.md`, contract, and tasks evidence
  with final command/proof output.
- [ ] T043 [US3] Run `./gate.sh` and record exact output evidence.
- [ ] T044 [US3] Remove `gate.sh` in a final ready-for-review commit.
- [ ] T045 [US3] Update PR #153 title/body with final scope,
  verification evidence, live run evidence, and non-claims.
- [ ] T046 [US3] Mark PR #153 ready only after docs, README,
  repository metadata, specs/tasks, and PR metadata all align.

Evidence:

- README documents the shipped `devnet stake-reward-init` command, the
  proof command, run directory `runs/devnet/20260516T213258Z`, setup tx
  id
  `89737f7b4439008d5aeca01789addbbbfeb2876cb4a0fab224f1c545e4076598`,
  and the explicit #149/#150 exclusions.
- `docs/local-devnet-smoke.md` documents the stake/reward initiator
  boundary, expected output, artifact paths, registered treasury account,
  and permissions withdraw-zero account.
- `quickstart.md` and
  `contracts/devnet-stake-reward-init.md` record the latest accepted
  live proof.
- `nix develop github:paolino/dev-assets?dir=mkdocs --quiet -c mkdocs
  build --strict --site-dir site` exited 0.

## Dependencies

- Phase 2 must complete before any implementation subagent starts.
- Phase 3 must complete before the smoke proof can call the command.
- Phase 4 must complete before #150 uses DevNet disburse translation.
- Phase 5 and Phase 6 must complete before docs/finalization claim live
  proof.
- #149 starts only after #148 is reviewed, verified, documented, and PR
  #153 is ready for external review or merged.

## Subagent Protocol

- Use one subagent at a time.
- The orchestrator analyzes code and applies artifact corrections before
  every handoff.
- Subagents receive exact task ids, owned files/modules, forbidden
  scope, RED proof, GREEN proof, and commit requirements.
- Subagents do not edit specs, plan, tasks, docs, PR metadata, or issue
  metadata unless explicitly asked to apply a review correction.
- Subagents do not add #149 governance funding, #150 disburse
  submission, swap/order execution, or external-role behavior.
- The orchestrator reviews every returned diff and reruns verification
  locally.

## First Subagent Brief Template

Use only after T011-T013 are complete.

```text
Task: T014-T021 only.

Owned files:
- lib/Amaru/Treasury/Devnet/StakeRewardInit.hs
- lib/Amaru/Treasury/Cli/Devnet.hs
- lib/Amaru/Treasury/Cli.hs
- app/amaru-treasury-tx/Main.hs
- amaru-treasury-tx.cabal
- test/unit/Amaru/Treasury/Devnet/StakeRewardInitSpec.hs
- test/unit/Amaru/Treasury/Cli/DevnetSpec.hs

Required orchestrator analysis already applied:
- Parent #151 makes the shipped command the P1 story.
- Command shape is documented in contracts/devnet-stake-reward-init.md.
- #148 registers the treasury reward account and emits the permissions
  reward account as the later withdraw-zero target only.
- #149 governance funding and #150 disburse are forbidden.
- The command must reject non-DevNet before reading signing keys or
  opening the socket.

Forbidden scope:
- Do not edit specs, plan, tasks, README, docs, PR metadata, or issue
  metadata.
- Do not add governance funding, treasury withdrawal materialization,
  disburse submission, swap/order execution, or external-role behavior.
- Do not move setup transaction construction into SmokeSpec.hs.

RED proof:
- Focused CLI/parser and artifact tests fail because the command/module
  does not exist.

GREEN proof:
- nix develop --quiet -c just unit "stake-reward-init"
- nix develop --quiet -c cabal build exe:amaru-treasury-tx -O0
- git diff --check

Commit:
- One bisect-safe commit titled
  feat(devnet): expose stake reward init command
- Commit body must include Tasks: T014,T015,T016,T017,T018,T019,T020,T021.
- Do not push.
```

## Second Subagent Brief Template

Use only after T014-T021 are reviewed and pushed.

```text
Task: T022-T027 only.

Owned files:
- lib/Amaru/Treasury/IntentJSON.hs
- lib/Amaru/Treasury/Tx/DisburseIntentJSON.hs
- test/unit/Amaru/Treasury/IntentJSONSpec.hs
- test/unit/Amaru/Treasury/Tx/DisburseSpec.hs

Required orchestrator analysis already applied:
- `Amaru.Treasury.IntentJSON.Common.parseRewardAccountForNetwork`
  already maps `devnet`, `preprod`, and `preview` to ledger `Testnet`.
- Unified `translateDisburse` still calls Mainnet-default
  `parseRewardAccount` for `sjPermissionsRewardAccount`.
- Legacy `Amaru.Treasury.Tx.DisburseIntentJSON.buildFields` still has
  its own Mainnet-only `parseRewardAccount`.
- The legacy disburse JSON module is still exported and covered by
  disburse-wizard tests, so it must be fixed rather than ignored.

Forbidden scope:
- Do not edit specs, plan, tasks, README, docs, PR metadata, issue
  metadata, gate.sh, DevNet command code, smoke code, swap/order code,
  governance setup, or disburse submission behavior.
- Do not broaden this slice to #149 or #150 behavior.

RED proof:
- Add unified DevNet disburse intent coverage in
  `test/unit/Amaru/Treasury/IntentJSONSpec.hs` proving
  `difPermissionsRewardAccount` uses ledger `Testnet`.
- Add legacy DevNet disburse intent coverage in
  `test/unit/Amaru/Treasury/Tx/DisburseSpec.hs` proving
  `difPermissionsRewardAccount` uses ledger `Testnet`.
- These tests must fail before implementation because both disburse
  translation paths currently construct Mainnet reward accounts.

Implementation:
- Replace the unified disburse Mainnet-default parser call with
  `parseRewardAccountForNetwork (tiNetwork ti)`.
- Replace the legacy disburse Mainnet-only parser with network-aware
  parsing, preferably by reusing
  `Amaru.Treasury.IntentJSON.Common.parseRewardAccountForNetwork`.
- Preserve mainnet behavior and reject unknown network names with the
  existing unknown-network diagnostic shape.

GREEN proof:
- nix develop --quiet -c just unit "reward accounts as Testnet"
- nix develop --quiet -c just unit "DisburseIntentJSON"
- nix develop --quiet -c cabal build lib:amaru-treasury-tx -O0
- git diff --check

Commit:
- One bisect-safe commit titled
  fix(devnet): parse disburse reward accounts by network
- Commit body must include Tasks: T022,T023,T024,T025,T026,T027.
- Do not push.
```

## Third Subagent Brief Template

Use only after T022-T027 are reviewed and pushed.

```text
Task: T028-T034 only.

Owned files:
- scripts/smoke/devnet-local
- test/devnet/Amaru/Treasury/Devnet/SmokeSpec.hs

Required orchestrator analysis already applied:
- `scripts/smoke/devnet-local` currently accepts only
  `node|governance|withdraw|swap-ready|registry-init|all`; it rejects
  `stake-reward-init`.
- `SmokeSpec.hs` already has `registryInitSmoke` that starts the local
  DevNet, writes the genesis payment signing key, and calls
  `runDevnetRegistryInit` through the production command runner.
- The new smoke phase must call the shipped
  `runDevnetStakeRewardInit` command runner, not reimplement setup
  transaction construction inside the smoke.
- A fresh `stake-reward-init` smoke may run `registry-init` first in the
  same run directory and then consume
  `<run-dir>/registry-init/registry.json`.
- #148 proves prepared treasury and permissions reward accounts only;
  #149 governance funding and #150 disburse submission remain
  forbidden.

Forbidden scope:
- Do not edit specs, plan, tasks, README, docs, PR metadata, issue
  metadata, gate.sh, production command code, parser code, governance
  funding, withdrawal materialization, disburse submission, or
  swap/order behavior.
- Do not add `stake-reward-init` to `all` unless the current script
  structure makes that unavoidable; the required operator proof is
  `just devnet-smoke stake-reward-init`.

RED proof:
- Before implementation, run
  `scripts/smoke/devnet-local --phase stake-reward-init --run-dir <tmp>`
  or `nix develop --quiet -c just devnet-smoke stake-reward-init` and
  record that it fails because the phase is unknown.

Implementation:
- Add `stake-reward-init` to the script phase parser/allowlist.
- Add a live Hspec example for `stake-reward-init` using
  `runForPhases ["stake-reward-init"]`.
- Implement `stakeRewardInitSmoke` by following `registryInitSmoke`:
  start the local DevNet, verify magic 42, copy node log, write timing,
  write the genesis payment signing key, run `runDevnetRegistryInit`,
  then run `runDevnetStakeRewardInit` with the registry artifact path
  and the same funding address/signing key/run directory.
- Assert the command-written artifacts exist:
  `stake-reward-init/summary.json`, `accounts.json`, and
  `provenance.json`; decode enough JSON or reuse exported artifact
  helpers to assert phase/network and treasury/permissions account
  fields.
- Do not move setup construction into `SmokeSpec.hs`; the smoke owns
  DevNet setup, command invocation, and proof assertions only.

GREEN proof:
- nix develop --quiet -c just devnet-smoke stake-reward-init
- git diff --check

Commit:
- One bisect-safe commit titled
  test(devnet): prove stake reward setup
- Commit body must include Tasks: T028,T029,T030,T031,T032,T033,T034.
- Do not push.
```
