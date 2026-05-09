# Tasks: Mechanical Transaction Report

**Input**: Approved design documents from
[`specs/072-mechanical-tx-report/`](.)

**Prerequisites**: [spec.md](./spec.md), [plan.md](./plan.md),
[research.md](./research.md), [data-model.md](./data-model.md),
[contracts/tx-report-json.md](./contracts/tx-report-json.md),
[quickstart.md](./quickstart.md)

**Tracking issue**:
[#72](https://github.com/lambdasistemi/amaru-treasury-tx/issues/72)

**Tracking PR**:
[#73](https://github.com/lambdasistemi/amaru-treasury-tx/pull/73)

**Scope**: This file is the task handoff only. Do not implement these
tasks until the implementation phase is explicitly started.

**Tests**: Required by the approved spec, plan, and Constitution V.
Every behavior-changing implementation task below is paired with a
preceding RED proof task in the same user-story phase. Each future
durable work commit must include the RED proof and GREEN implementation
for one vertical slice.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: parallelizable with other tasks in the same phase
- **[Story]**: user story label from [spec.md](./spec.md)
- Paths are relative to repository root

## Path Conventions

- Report library surface: `lib/Amaru/Treasury/Report.hs`
- Report internals:
  `lib/Amaru/Treasury/Report/Accounting.hs`,
  `lib/Amaru/Treasury/Report/Classify.hs`,
  `lib/Amaru/Treasury/Report/Schema.hs`
- Build integration: `lib/Amaru/Treasury/TreasuryBuild.hs` and
  `lib/Amaru/Treasury/TreasuryBuild/Trace.hs`
- CLI: `app/amaru-treasury-tx/Main.hs`
- Public schema: `docs/assets/tx-report-schema.json`
- Unit tests:
  `test/unit/Amaru/Treasury/ReportSpec.hs`,
  `test/unit/Amaru/Treasury/ReportSchemaSpec.hs`,
  `test/unit/Amaru/Treasury/TreasuryBuildSpec.hs`
- Golden tests: `test/golden/SwapGoldenSpec.hs`
- Swap report fixture: `test/fixtures/swap/report.golden.json`
- Operator docs: `docs/quickstart.md` and `docs/swap.md`

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Create the compile/test surface and public asset path for
the report feature without changing runtime behavior.

- [ ] T001 Add `Amaru.Treasury.Report`, `Amaru.Treasury.Report.Accounting`, `Amaru.Treasury.Report.Classify`, and `Amaru.Treasury.Report.Schema` to the library exposed modules in `amaru-treasury-tx.cabal`.
- [ ] T002 [P] Add `test/unit/Amaru/Treasury/ReportSpec.hs` and `test/unit/Amaru/Treasury/ReportSchemaSpec.hs` to the `unit-tests` stanza in `amaru-treasury-tx.cabal`.
- [ ] T003 [P] Add `docs/assets/tx-report-schema.json` and `test/fixtures/swap/report.golden.json` to the relevant `extra-source-files` globs in `amaru-treasury-tx.cabal`.
- [ ] T004 [P] Add a report-schema check entry point or extend the existing `schema-check` path for `docs/assets/tx-report-schema.json` in `justfile`.
- [ ] T005 Create empty module skeletons with explicit export lists in `lib/Amaru/Treasury/Report.hs`, `lib/Amaru/Treasury/Report/Accounting.hs`, `lib/Amaru/Treasury/Report/Classify.hs`, and `lib/Amaru/Treasury/Report/Schema.hs`.
- [ ] T006 Run `nix develop --quiet -c just cabal-check` and record the setup GREEN proof for `amaru-treasury-tx.cabal` in the durable commit body.

**Checkpoint**: The package discovers the new modules, test modules,
and report asset path, with no behavior change.

---

## Phase 2: Foundational Report Model (Blocking Prerequisites)

**Purpose**: Establish shared pure data types and fixtures that all
user stories depend on.

- [ ] T007 [P] Add RED JSON shape tests for `TransactionReport`, `TransactionIdentity`, `WalletAccounting`, `TreasuryAccounting`, `ProducedOutput`, `SignerRequirement`, and `ValidationFacts` in `test/unit/Amaru/Treasury/ReportSpec.hs`.
- [ ] T008 [P] Add RED schema drift tests that compare the Haskell schema source with `docs/assets/tx-report-schema.json` in `test/unit/Amaru/Treasury/ReportSchemaSpec.hs`.
- [ ] T009 [P] Add RED schema validation tests for representative report examples and `test/fixtures/swap/report.golden.json` in `test/unit/Amaru/Treasury/ReportSchemaSpec.hs`.
- [ ] T010 Implement the report data model, `ToJSON` instances, and deterministic `encodeReport` API in `lib/Amaru/Treasury/Report.hs`.
- [ ] T011 Implement the schema source and schema asset rendering path for `docs/assets/tx-report-schema.json` in `lib/Amaru/Treasury/Report/Schema.hs`.
- [ ] T012 Generate or update the checked-in report schema asset in `docs/assets/tx-report-schema.json`.
- [ ] T013 Confirm GREEN for the foundational contract with `nix develop --quiet -c just unit Report` and `nix develop --quiet -c just schema-check` covering `test/unit/Amaru/Treasury/ReportSpec.hs`, `test/unit/Amaru/Treasury/ReportSchemaSpec.hs`, and `docs/assets/tx-report-schema.json`.

**Checkpoint**: The report JSON contract is public, deterministic, and
schema-validated before story-specific behavior starts.

---

## Phase 3: User Story 1 - Save a Deterministic Build Report (Priority: P1) MVP

**Goal**: `tx-build` can optionally write a deterministic JSON report
for the exact successful transaction it built, while no-report behavior
remains unchanged.

**Independent Test**: Build the frozen swap fixture twice with a report
destination and verify the unsigned CBOR is unchanged while the two
report JSON byte strings are identical.

### RED Proof for User Story 1

- [ ] T014 [P] [US1] Add RED deterministic encoder tests in `test/unit/Amaru/Treasury/ReportSpec.hs` proving stable key order, stable array ordering, trailing newline, and no timestamp/path fields.
- [ ] T015 [P] [US1] Add RED frozen-fixture report generation tests in `test/golden/SwapGoldenSpec.hs` that build the swap fixture twice and compare `test/fixtures/swap/report.golden.json` byte-for-byte.
- [ ] T016 [P] [US1] Add RED no-report compatibility tests in `test/unit/Amaru/Treasury/TreasuryBuildSpec.hs` proving existing no-report `tx-build` result data and CBOR bytes are unchanged when no report path is supplied.

### GREEN Implementation for User Story 1

- [ ] T017 [US1] Implement deterministic report encoding details in `lib/Amaru/Treasury/Report.hs`, including stable field ordering, canonical asset-map ordering, ledger-order output arrays, and a trailing newline.
- [ ] T018 [US1] Extend `TreasuryBuildResult` in `lib/Amaru/Treasury/TreasuryBuild.hs` with the final balanced transaction body, transaction identity facts, fee/collateral facts, and validation facts needed by report construction.
- [ ] T019 [US1] Implement pure `buildTransactionReport` plumbing from parsed intent, translated intent, resolved context, final build result, and validation result in `lib/Amaru/Treasury/Report.hs`.
- [ ] T020 [US1] Generate `test/fixtures/swap/report.golden.json` from the frozen swap fixture through `test/golden/SwapGoldenSpec.hs`.
- [ ] T021 [US1] Confirm GREEN for the US1 slice with `nix develop --quiet -c just unit Report` and `nix develop --quiet -c just golden swap` covering `test/unit/Amaru/Treasury/ReportSpec.hs`, `test/golden/SwapGoldenSpec.hs`, and `test/fixtures/swap/report.golden.json`.

**Checkpoint**: US1 acceptance scenarios 1-3 and SC-001 are met.

---

## Phase 4: User Story 2 - Understand Swap Wallet and Treasury Accounting Before Signing (Priority: P1)

**Goal**: The report mechanically states wallet spend, change,
collateral, treasury input, order funding, per-chunk overhead, leftover,
net debit, and output roles for the swap success fixture.

**Independent Test**: Build the treasury-funded-overhead swap fixture
and assert `walletAccounting.netSpendLovelace ==
validation.feeLovelace`, returned collateral is not double-counted, and
every produced output appears exactly once under a mechanical role.

### RED Proof for User Story 2

- [X] T022 [P] [US2] Add RED wallet accounting tests for wallet inputs, change, fee, collateral input, collateral return, total collateral, and no double-counting in `test/unit/Amaru/Treasury/ReportSpec.hs`.
- [X] T023 [P] [US2] Add RED treasury accounting tests for treasury inputs, native assets, Sundae order totals, per-chunk overhead, treasury leftover, and treasury net debit in `test/unit/Amaru/Treasury/ReportSpec.hs`.
- [X] T024 [P] [US2] Add RED output-role coverage tests for swap-order outputs, treasury leftover, wallet change, collateral return, metadata, and unknown fallback in `test/unit/Amaru/Treasury/ReportSpec.hs`.
- [X] T025 [US2] Add RED swap golden assertions in `test/golden/SwapGoldenSpec.hs` that `walletAccounting.netSpendLovelace == validation.feeLovelace` and each final transaction output appears once in `test/fixtures/swap/report.golden.json`.

### GREEN Implementation for User Story 2

- [X] T026 [US2] Implement wallet accounting in `lib/Amaru/Treasury/Report/Accounting.hs`, including additional wallet fuel inputs and collateral-return subtraction without UTxO double-counting.
- [X] T027 [US2] Implement treasury accounting in `lib/Amaru/Treasury/Report/Accounting.hs`, including lovelace/native-asset totals, Sundae order totals, per-chunk overhead, treasury leftover, and net debit.
- [X] T028 [US2] Implement produced-output classification in `lib/Amaru/Treasury/Report/Classify.hs`, including one-role-per-output coverage and `unknown` fallback.
- [X] T029 [US2] Wire accounting and classification into `buildTransactionReport` in `lib/Amaru/Treasury/Report.hs`.
- [X] T030 [US2] Update `test/fixtures/swap/report.golden.json` through the golden update flow in `test/golden/SwapGoldenSpec.hs`.
- [X] T031 [US2] Confirm GREEN for the US2 slice with `nix develop --quiet -c just unit Report` and `nix develop --quiet -c just golden swap` covering `test/unit/Amaru/Treasury/ReportSpec.hs`, `test/golden/SwapGoldenSpec.hs`, and `test/fixtures/swap/report.golden.json`.

**Checkpoint**: US2 acceptance scenarios 1-3 and SC-002 / SC-003 are
met.

---

## Phase 5: User Story 3 - Review Signers and Validation Facts From the Same Artifact (Priority: P2)

**Goal**: The report lists every required signer key hash with its
mechanical source and records builder validation facts from the same
successful build.

**Independent Test**: Run a successful swap build with selected scope
owner and extra signer data, then verify signer sources, network match,
fee, body size, redeemer count/failures, validity interval, and selected
reference inputs in the report.

### RED Proof for User Story 3

- [X] T032 [P] [US3] Add RED signer-source tests for selected scope owner, extra signer, intent-required signer, and tx-body-required signer in `test/unit/Amaru/Treasury/ReportSpec.hs`.
- [X] T033 [P] [US3] Add RED validation-facts tests for intent network, socket network magic, network match, fee, body size, redeemer count, zero redeemer failures, validation status, and validity interval in `test/unit/Amaru/Treasury/ReportSpec.hs`.
- [X] T034 [P] [US3] Add RED reference-input and metadata-summary tests in `test/unit/Amaru/Treasury/ReportSpec.hs`.
- [X] T035 [US3] Add RED swap golden assertions for signers, validation facts, and selected reference inputs in `test/golden/SwapGoldenSpec.hs`.

### GREEN Implementation for User Story 3

- [X] T036 [US3] Implement signer requirement extraction and source labelling in `lib/Amaru/Treasury/Report.hs`.
- [X] T037 [US3] Expose any missing selected scope owner, extra signer, tx-body signer, reference input, validity interval, and validation summary data from `lib/Amaru/Treasury/TreasuryBuild.hs`.
- [X] T038 [US3] Implement validation facts, reference inputs, and metadata summary encoding in `lib/Amaru/Treasury/Report.hs`.
- [X] T039 [US3] Update `test/fixtures/swap/report.golden.json` through the golden update flow in `test/golden/SwapGoldenSpec.hs`.
- [X] T040 [US3] Confirm GREEN for the US3 slice with `nix develop --quiet -c just unit Report` and `nix develop --quiet -c just golden swap` covering `test/unit/Amaru/Treasury/ReportSpec.hs`, `test/golden/SwapGoldenSpec.hs`, and `test/fixtures/swap/report.golden.json`.

**Slice split (2026-05-09 signer sources)**: T032/T036/T039/T040
cover signer-source extraction only. The slice adds unit coverage for
selected scope owner, extra signer, intent-required signer, and tx-body
fallback source labels, plus a swap report golden refresh for selected
scope owner and extra signer output. T033/T034/T035's validation-fact
and reference-input assertions, T037's remaining build-result exposure,
and T038's validation/reference/metadata encoding stay open for later
US3 slices.

**Slice split (2026-05-09 validation/reference/metadata)**:
T033/T034/T035/T037/T038/T039/T040 cover validation facts, selected
reference inputs, and metadata summary for the swap report. Existing
`TreasuryBuildResult` exposure already carries the final tx body,
script results, CBOR bytes, and fee data needed for this slice; this
slice adds the missing auxiliary-data hash extraction from the final tx
body, tightens unit and swap-golden assertions, and refreshes only
`test/fixtures/swap/report.golden.json`. CLI report writing, operator
docs, and unrelated schema expansion remain out of scope.

**Checkpoint**: US3 acceptance scenarios 1-3 are met.

---

## Phase 6: User Story 1 CLI Writer Surface (Priority: P1)

**Goal**: The executable exposes `tx-build --report PATH`, writes the
report only on successful validation, preserves no-report behavior, and
fails clearly if the requested report cannot be written.

**Independent Test**: Run the `tx-build` CLI with and without
`--report`, and with an unwritable report destination, against existing
fixtures or smoke paths.

### RED Proof for CLI Writer

- [X] T041 [P] [US1] Add RED CLI parser tests for optional `--report PATH` in `test/unit/Amaru/Treasury/TreasuryBuildSpec.hs` or `test/unit/Amaru/Treasury/ReportSpec.hs`.
- [X] T042 [P] [US1] Add RED smoke coverage for `tx-build --report PATH`, no-report compatibility, and unwritable report path failure in `scripts/smoke/tx-build-pipe`.
- [X] T043 [P] [US1] Add RED trace-rendering tests for report-write success and report-write failure events in `test/unit/Amaru/Treasury/TreasuryBuildSpec.hs`.

### GREEN Implementation for CLI Writer

- [X] T044 [US1] Add the `--report PATH` parser field and help text for `tx-build` in `app/amaru-treasury-tx/Main.hs`.
- [X] T045 [US1] Wire report construction and filesystem writing after successful validation in `app/amaru-treasury-tx/Main.hs`, keeping file I/O outside pure report construction.
- [X] T046 [US1] Add typed report-write success and failure trace events in `lib/Amaru/Treasury/TreasuryBuild/Trace.hs`.
- [X] T047 [US1] Ensure requested report write failures exit non-zero and name the failed report path in `app/amaru-treasury-tx/Main.hs`.
- [X] T048 [US1] Confirm GREEN for the CLI writer slice with `nix develop --quiet -c just unit TreasuryBuild` and `nix develop --quiet -c just smoke` covering `test/unit/Amaru/Treasury/TreasuryBuildSpec.hs`, `scripts/smoke/tx-build-pipe`, and `app/amaru-treasury-tx/Main.hs`.

**Slice split (2026-05-09 CLI writer)**: T041-T048 cover the
`tx-build --report PATH` parser, report construction/writing after
successful validation, success/failure trace rendering, non-zero
write-failure behavior that names the failed path, smoke help coverage,
and focused parser/writer smoke calls. Operator docs T049-T054 and final
verification T055-T059 stay open for later slices.

**Checkpoint**: FR-001, FR-015, and the US1 write-failure edge case
are met through the executable path.

---

## Phase 7: User Story 4 - Document the Report as the Pre-signing Review Artifact (Priority: P3)

**Goal**: Operator docs direct users to generate and inspect the
mechanically generated report before signing.

**Independent Test**: Build the docs strictly and inspect the rendered
quickstart/swap pages for the pre-signing report step.

### RED Proof for User Story 4

- [ ] T049 [P] [US4] Add RED docs checks or review checklist entries for report-before-signing guidance in `docs/quickstart.md`.
- [ ] T050 [P] [US4] Add RED docs checks or review checklist entries for swap-specific accounting guidance in `docs/swap.md`.

### GREEN Implementation for User Story 4

- [ ] T051 [US4] Update `docs/quickstart.md` to show `tx-build --report PATH`, list expected artifacts, and direct operators to inspect the report before signing.
- [ ] T052 [US4] Update `docs/swap.md` with wallet accounting, treasury accounting, output roles, signer sources, and validation facts from `test/fixtures/swap/report.golden.json`.
- [ ] T053 [US4] Update `docs/index.md` or another existing docs entry point only if needed to expose the report workflow from `docs/quickstart.md`.
- [ ] T054 [US4] Confirm GREEN docs proof with `nix develop github:paolino/dev-assets?dir=mkdocs --quiet -c mkdocs build --strict --site-dir site` covering `docs/quickstart.md`, `docs/swap.md`, and `docs/index.md`.

**Checkpoint**: US4 acceptance scenarios 1-2 and SC-005 are met.

---

## Phase 8: Final Verification and Release Readiness

**Purpose**: Prove the completed feature preserves existing contracts
and that the new report contract is ready for downstream tooling.

- [ ] T055 Run the full local gate `bash llm/reviews/gate.sh` and record the passing output summary for `llm/reviews/work-review.md`.
- [ ] T056 Run or confirm focused report contract validation through `nix develop --quiet -c just schema-check` for `docs/assets/tx-report-schema.json`.
- [ ] T057 Run or confirm focused swap report golden proof through `nix develop --quiet -c just golden swap` for `test/fixtures/swap/report.golden.json`.
- [ ] T058 Check that existing unsigned CBOR fixtures are unchanged except for intentionally refreshed report artifacts by inspecting `test/fixtures/swap/expected.cbor` and `test/fixtures/swap/report.golden.json`.
- [ ] T059 Update the PR body or review handoff with final report contract, golden, smoke, docs, and full-gate evidence for `llm/reviews/work-review.md`.

**Checkpoint**: The feature is ready for reviewer finalization review.

---

## Dependencies & Execution Order

### Phase Dependencies

- Phase 1 must complete before any report model, tests, or schema work.
- Phase 2 blocks all user stories because it establishes the public JSON
  contract and deterministic encoder baseline.
- Phase 3 is the MVP and must complete before accounting, signer, and
  CLI writer slices can be considered useful.
- Phase 4 depends on Phase 3 report construction and completes the P1
  swap accounting surface.
- Phase 5 depends on Phase 3 and may proceed in parallel with Phase 4
  if both slices preserve the report model contract.
- Phase 6 depends on Phases 3-5 because the CLI must write the complete
  report, not a partial artifact.
- Phase 7 depends on at least Phases 3-6 so docs match the implemented
  report and CLI behavior.
- Phase 8 depends on all selected implementation slices.

### User Story Dependencies

- **US1 (P1)**: Starts after Phase 2. Phase 3 covers deterministic
  report construction; Phase 6 covers CLI writing and failure behavior.
- **US2 (P1)**: Starts after Phase 3 and depends on the report model.
- **US3 (P2)**: Starts after Phase 3 and depends on build-result facts.
- **US4 (P3)**: Starts after report behavior and CLI writer behavior are
  implemented.

### Parallel Opportunities

- T002, T003, T004, and T005 can proceed in parallel after T001.
- T007, T008, and T009 can proceed in parallel as foundational RED
  tests.
- T014, T015, and T016 can proceed in parallel as US1 RED proofs.
- T022, T023, and T024 can proceed in parallel as US2 RED proofs.
- T032, T033, and T034 can proceed in parallel as US3 RED proofs.
- T049 and T050 can proceed in parallel as docs RED checks.

## Implementation Strategy

### MVP First

1. Complete Phase 1 and Phase 2.
2. Complete Phase 3 as the first durable implementation commit:
   deterministic report model, schema, and swap golden generation.
3. Stop for review with RED/GREEN proof for US1 deterministic report
   construction before moving to accounting, signer, or CLI writer work.

### Incremental Delivery

1. Deliver one vertical durable commit per phase after Phase 2, keeping
   each commit bisect-safe.
2. Put RED tests/proof and GREEN implementation for the same slice in
   the same durable commit.
3. Refresh `test/fixtures/swap/report.golden.json` only in the slice
   whose behavior changes the report.
4. Run `bash llm/reviews/gate.sh` before every review handoff.

### Review Notes

- Do not add signing or submission behavior in any task.
- Do not generate interpretive prose or LLM-written report contents.
- Do not query the node again for report data after the successful
  build; use the already resolved build context.
- Do not change existing no-report `tx-build` behavior.
- Do not omit produced outputs; classify unknown future outputs as
  `unknown`.
