# Tasks: Withdraw Wizard

**Input**: Design documents from [`specs/006-withdraw-wizard/`](.)
**Prerequisites**: [plan.md](./plan.md), [spec.md](./spec.md),
[research.md](./research.md), [data-model.md](./data-model.md),
[contracts/withdraw-wizard-cli.md](./contracts/withdraw-wizard-cli.md),
[contracts/tx-build-withdraw.md](./contracts/tx-build-withdraw.md),
[contracts/withdraw-intent-json.md](./contracts/withdraw-intent-json.md),
[quickstart.md](./quickstart.md)

**Tracking issue**: [#45](https://github.com/lambdasistemi/amaru-treasury-tx/issues/45)

**Scope**: This task list is the handoff point. Do not implement these
tasks until the implementation phase is explicitly started.

**Tests**: Required by Constitution V. Test and fixture tasks appear
before the implementation tasks they constrain.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: parallelizable with other tasks in the same phase
- **[Story]**: user story label from [spec.md](./spec.md)
- Paths are relative to repository root

## Path Conventions

- Unified intent code: `lib/Amaru/Treasury/IntentJSON.hs`,
  `lib/Amaru/Treasury/IntentJSON/Schema.hs`,
  `lib/Amaru/Treasury/IntentJSON/Common.hs`
- Builder dispatcher: `lib/Amaru/Treasury/TreasuryBuild.hs`
- Pure builder: `lib/Amaru/Treasury/Tx/Withdraw.hs`
- Wizard code: `lib/Amaru/Treasury/Tx/WithdrawWizard.hs`,
  `lib/Amaru/Treasury/Tx/WithdrawWizard/Trace.hs`
- CLI: `app/amaru-treasury-tx/Main.hs`
- Fixtures: `test/fixtures/withdraw/`
- Tests: `test/unit/Amaru/Treasury/**`,
  `test/golden/WithdrawGoldenSpec.hs`

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Create the compile/test surface for the withdraw feature.

- [x] T001 Add `Amaru.Treasury.Tx.WithdrawWizard` and `Amaru.Treasury.Tx.WithdrawWizard.Trace` to the library exposed modules in `amaru-treasury-tx.cabal`.
- [x] T002 [P] Add empty skeleton files `lib/Amaru/Treasury/Tx/WithdrawWizard.hs` and `lib/Amaru/Treasury/Tx/WithdrawWizard/Trace.hs` with module headers and explicit export lists.
- [x] T003 [P] Add `test/unit/Amaru/Treasury/Tx/WithdrawWizardSpec.hs` and `test/golden/WithdrawGoldenSpec.hs` to the relevant cabal test stanzas.
- [x] T004 Create fixture directories `test/fixtures/withdraw/synthetic/` and `test/fixtures/withdraw/zero-rewards/` with `.gitkeep` placeholders only.
- [x] T005 Add a `just golden withdraw` selector or document the existing golden selector in `justfile` so the withdraw golden can be run independently.
- [x] T006 Run `nix develop --quiet -c just cabal-check` and confirm the empty scaffolding is Hackage-clean.

**Checkpoint**: The package compiles with empty withdraw wizard/golden scaffolding and no empty cabal globs.

---

## Phase 2: Foundational Intent Contract

**Purpose**: Replace the empty withdraw placeholder in the unified intent contract.

- [x] T007 [P] Add RED parser/encoder tests for non-empty `WithdrawInputs` in `test/unit/Amaru/Treasury/IntentJSONSpec.hs`.
- [x] T008 [P] Add RED schema tests for valid withdraw payloads and action/payload mismatches in `test/unit/Amaru/Treasury/IntentJSONSchemaSpec.hs`.
- [x] T009 [P] Add RED tests for network-aware reward-account parsing in `test/unit/Amaru/Treasury/IntentJSONSpec.hs` or a new focused common-parser spec.
- [x] T010 Implement `WithdrawInputs { treasuryRewardAccount, rewardsLovelace }` in `lib/Amaru/Treasury/IntentJSON.hs`.
- [x] T011 Implement `translateIntent SWithdraw` in `lib/Amaru/Treasury/IntentJSON.hs`, mapping unified JSON to `WithdrawIntent`.
- [x] T012 Implement a network-aware reward-account parser or constructor in `lib/Amaru/Treasury/IntentJSON/Common.hs`.
- [x] T013 Extend `intentJsonSchema` withdraw definition in `lib/Amaru/Treasury/IntentJSON/Schema.hs`.
- [x] T014 Regenerate `docs/assets/intent-schema.json` with `nix develop --quiet -c just update-schema`.
- [x] T015 Run `nix develop --quiet -c just schema-check` and confirm schema asset parity.

**Checkpoint**: `action = "withdraw"` decodes, translates, and validates against the generated schema.

---

## Phase 3: User Story 1 - Positive Rewards Wizard Intent (Priority: P1) MVP

**Goal**: `withdraw-wizard` resolves a positive reward balance and emits a valid unified intent.

**Independent Test**: Fixture/stub provider with positive rewards produces schema-valid `TreasuryIntent 'Withdraw`.

### Tests for User Story 1

- [x] T016 [P] [US1] Add positive-rewards wizard fixtures in `test/fixtures/withdraw/synthetic/env.json` and `test/fixtures/withdraw/synthetic/answers.json`.
- [x] T017 [P] [US1] Add RED pure translation golden in `test/unit/Amaru/Treasury/Tx/WithdrawWizardSpec.hs` comparing wizard output to `test/fixtures/withdraw/synthetic/intent.json`.
- [x] T018 [P] [US1] Add RED resolver test in `test/unit/Amaru/Treasury/Tx/WithdrawWizardSpec.hs` proving the reward account and rewards amount are resolved from provider/registry state, not CLI input.

### Implementation for User Story 1

- [x] T019 [US1] Define `WithdrawAnswers`, `WithdrawEnv`, `WithdrawError`, and exported shared aliases in `lib/Amaru/Treasury/Tx/WithdrawWizard.hs`.
- [x] T020 [US1] Implement pure `withdrawToTreasuryIntent` in `lib/Amaru/Treasury/Tx/WithdrawWizard.hs`.
- [x] T021 [US1] Implement `WithdrawWizardEvent` and renderer in `lib/Amaru/Treasury/Tx/WithdrawWizard/Trace.hs`.
- [x] T022 [US1] Implement resolver helpers for wallet UTxO selection, treasury reward account construction, reward balance query, registry verification, and validity computation in `lib/Amaru/Treasury/Tx/WithdrawWizard.hs`.
- [x] T023a [US1] Add `withdraw-wizard` CLI parser and runner skeleton in `app/amaru-treasury-tx/Main.hs`.
- [x] T023b [US1] Wire live stake-reward query support so positive rewards emit `intent.json`.
- [x] T024 [US1] Add fixture globs for `test/fixtures/withdraw/**/*.json` and `test/fixtures/withdraw/**/*.md` to `amaru-treasury-tx.cabal` once files exist.
- [x] T025 [US1] Run `nix develop --quiet -c just unit WithdrawWizard` and confirm positive-rewards wizard tests pass.

**Checkpoint**: A positive rewards fixture produces a valid withdraw intent without invoking the builder.

---

## Phase 4: User Story 2 - Zero Rewards No-op (Priority: P1)

**Goal**: Zero rewards is a clean no-op: exit 0 and write no intent.

**Independent Test**: Zero-rewards fixture exercises the wizard runner and leaves no output file.

### Tests for User Story 2

- [x] T026 [P] [US2] Add zero-rewards resolver fixture in `test/fixtures/withdraw/zero-rewards/env.json`.
- [x] T027 [P] [US2] Add RED no-output test in `test/unit/Amaru/Treasury/Tx/WithdrawWizardSpec.hs`.
- [x] T028 [P] [US2] Add RED CLI smoke case in `scripts/smoke/withdraw-wizard-zero-rewards`.

### Implementation for User Story 2

- [x] T029 [US2] Implement typed zero-rewards result/event in `lib/Amaru/Treasury/Tx/WithdrawWizard.hs` and `lib/Amaru/Treasury/Tx/WithdrawWizard/Trace.hs`.
- [x] T030 [US2] Wire zero-rewards behavior in `app/amaru-treasury-tx/Main.hs` so `--out` targets are not created or modified.
- [x] T031 [US2] Add the zero-rewards smoke script to `just smoke` or an equivalent smoke aggregator in `justfile`.
- [x] T032 [US2] Run `nix develop --quiet -c just smoke` and confirm the zero-rewards path passes.

**Checkpoint**: Zero rewards never produces a stale or misleading intent artifact.

---

## Phase 5: User Story 3 - Synthetic Body-CBOR Golden (Priority: P1)

**Goal**: `tx-build` can build withdraw CBOR from a frozen synthetic fixture.

**Independent Test**: `nix develop --quiet -c just golden withdraw` rebuilds `test/fixtures/withdraw/synthetic/expected.cbor` byte-for-byte.

### Tests for User Story 3

- [x] T033 [P] [US3] Author synthetic frozen fixture files `test/fixtures/withdraw/synthetic/{intent,utxos,pparams,exunits}.json`.
- [x] T034 [P] [US3] Author `test/fixtures/withdraw/synthetic/provenance.md` recording why the oracle is synthetic and linking issue #17 for live preprod replacement.
- [x] T035 [US3] Add RED `test/golden/WithdrawGoldenSpec.hs` that decodes `SomeTreasuryIntent`, loads frozen `ChainContext`, and compares against `test/fixtures/withdraw/synthetic/expected.cbor`.
- [x] T036 [US3] Record the intended `withdraw.sh` parity decision in `test/fixtures/withdraw/synthetic/provenance.md`, including the `--withdrawal <stake>+0` discrepancy from research R5.

### Implementation for User Story 3

- [x] T037 [US3] Replace the `SWithdraw` fail-closed branch in `lib/Amaru/Treasury/TreasuryBuild.hs` with `runWithdraw`.
- [x] T038 [US3] Implement `runWithdraw` in `lib/Amaru/Treasury/TreasuryBuild.hs`, including required UTxO checks, metadata label 1694, build, fee/collateral handling, and re-evaluation summary.
- [x] T039 [US3] Adjust `lib/Amaru/Treasury/Tx/Withdraw.hs` only if T036 proves the existing positive withdrawal amount diverges from the bash oracle.
- [x] T040 [US3] Generate or update `test/fixtures/withdraw/synthetic/expected.cbor` through the explicit golden update flow.
- [x] T041 [US3] Add fixture globs for `test/fixtures/withdraw/**/*.cbor` to `amaru-treasury-tx.cabal` once `expected.cbor` exists.
- [x] T042 [US3] Run `nix develop --quiet -c just golden withdraw` and confirm the synthetic golden passes.

**Checkpoint**: Withdraw is no longer a `tx-build` stub and has offline body-CBOR evidence.

---

## Phase 6: User Story 4 - JSON Schema Contract (Priority: P2)

**Goal**: Published schema accepts withdraw and rejects mismatches.

**Independent Test**: Schema validates withdraw fixtures and rejects mutated payload/action pairs.

- [x] T043 [P] [US4] Add schema validation for `test/fixtures/withdraw/synthetic/intent.json` in `test/unit/Amaru/Treasury/IntentJSONSchemaSpec.hs`.
- [x] T044 [P] [US4] Add negative schema cases for `action = "withdraw"` with `swap`, `disburse`, and `reorganize` payloads in `test/unit/Amaru/Treasury/IntentJSONSchemaSpec.hs`.
- [ ] T045 [US4] Confirm `nix develop --quiet -c just schema-check` and `nix develop --quiet -c just unit IntentJSONSchema` both pass.

**Checkpoint**: The machine-readable public contract covers withdraw.

---

## Phase 7: User Story 5 - Pipe and Smoke Path (Priority: P2)

**Goal**: `withdraw-wizard | tx-build` obeys stdout/stderr/log/output contracts.

**Independent Test**: Smoke script runs the fixture path and verifies JSON/CBOR stream separation.

- [ ] T046 [P] [US5] Add `scripts/smoke/withdraw-wizard-pipe` using fixture/stub data or a deterministic fixture mode.
- [ ] T047 [US5] Wire the pipe smoke script into `just smoke`.
- [ ] T048 [US5] Add `--help` surface checks for `withdraw-wizard` in the release smoke path.
- [ ] T049 [US5] Run `nix develop --quiet -c just smoke` and confirm withdraw pipe/help smoke passes.

**Checkpoint**: The operator pipe is protected by smoke tests.

---

## Phase 8: Documentation, Follow-up, and Release Readiness

**Purpose**: Make the new withdraw path discoverable and keep known live-oracle gaps explicit.

- [ ] T050 [P] Add `docs/withdraw.md` describing existing-intent and wizard paths.
- [ ] T051 [P] Update `docs/index.md`, `docs/quickstart.md`, `docs/architecture.md`, and `README.md` to mention withdraw support only after T042/T049 are green.
- [ ] T052 [P] Update `docs/freeze-workflow.md` with the synthetic withdraw fixture refresh process.
- [ ] T053 Add a comment to issue #17 with the exact remaining live preprod oracle work after synthetic golden lands.
- [ ] T054 Run `nix develop github:paolino/dev-assets?dir=mkdocs --quiet -c mkdocs build --strict --site-dir site` and confirm strict docs pass.
- [ ] T055 Run full local gate: `nix develop --quiet -c just ci && nix develop --quiet -c just cabal-check`.

**Checkpoint**: Docs and full local gate are green; live oracle gap is tracked in #17.

---

## Dependencies & Execution Order

### Phase Dependencies

- Phase 1 must complete before code/test work.
- Phase 2 blocks all user stories because it replaces the placeholder intent contract.
- Phases 3 and 4 can proceed after Phase 2 and are independent except for shared wizard types.
- Phase 5 depends on Phase 2 and can proceed once a valid withdraw fixture intent exists.
- Phase 6 depends on Phase 2 and at least one fixture intent.
- Phase 7 depends on Phases 3 and 5.
- Phase 8 depends on implemented behavior and verification evidence.

### User Story Dependencies

- **US1**: Starts after Phase 2; no dependency on US2/US3.
- **US2**: Starts after Phase 2; shares wizard trace/types with US1.
- **US3**: Starts after Phase 2; needs a fixture intent from US1 or an equivalent hand-authored fixture.
- **US4**: Starts after Phase 2; needs fixture JSON.
- **US5**: Starts after US1 and US3.

### Parallel Opportunities

- T002/T003/T004 can run in parallel after T001.
- T007/T008/T009 can run in parallel as RED tests.
- T016/T017/T018 can run in parallel as wizard tests/fixtures.
- T026/T027/T028 can run in parallel as zero-rewards tests/fixtures.
- T033/T034 can run in parallel as synthetic fixture/provenance work.
- T043/T044 can run in parallel as schema test cases.
- T050/T051/T052 can run in parallel after behavior is verified.

## Implementation Strategy

### MVP First

1. Complete Phase 1 setup.
2. Complete Phase 2 intent contract.
3. Complete Phase 3 positive-rewards wizard intent.
4. Complete Phase 5 synthetic golden and `runWithdraw`.
5. Stop and validate: `just unit WithdrawWizard`, `just golden withdraw`,
   `just schema-check`.

### Full Feature

1. Add zero-rewards no-op behavior.
2. Add schema mismatch coverage.
3. Add pipe smoke.
4. Update docs.
5. Run full local gate and open/refresh PR evidence.
