# Tasks: Swap Wizard All ADA Mode

**Input**: Design documents from `/specs/009-swap-wizard-all-ada/`
**Prerequisites**: [plan.md](./plan.md), [spec.md](./spec.md), [research.md](./research.md), [data-model.md](./data-model.md), [contracts/swap-wizard-all-ada-cli.md](./contracts/swap-wizard-all-ada-cli.md), [quickstart.md](./quickstart.md)

**Tests**: Required by issue #127 and the PR/TDD gate. RED tests must be observed before production code.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: parallelizable in principle because files do not overlap.
- **[Story]**: maps to spec user stories.

## Phase 1: Setup

- [X] T001 Create Spec Kit artifacts under `specs/009-swap-wizard-all-ada/`
- [X] T002 Record baseline verification in `WIP.md`

## Phase 2: Foundational Calculation and Parser Tests

- [X] T003 [US1] Add RED unit tests for pure all-ADA max-spend calculation in `test/unit/Amaru/Treasury/Tx/SwapWizardSpec.hs`
- [X] T004 [US2] Add RED parser tests for `--all-ada`, `--all-ada --usdm`, missing target, and `--all-ada --chunk-usdm` in `test/unit/Amaru/Treasury/Tx/SwapWizardSpec.hs`
- [X] T005 [US3] Add RED trace rendering test for all-ADA calculation facts in `test/unit/Amaru/Treasury/Tx/SwapWizardSpec.hs`

## Phase 3: User Story 1 - Swap Remaining Spendable ADA (P1)

**Goal**: Resolver derives max ADA amount from live pure ADA treasury UTxOs and emits a normal swap intent.

**Independent Test**: Stub resolver UTxOs produce an intent whose swap amount, chunk size, UTxOs, and leftover match the all-ADA calculation.

- [X] T006 [US1] Implement `AllAdaPlan` and pure max-spend helpers in `lib/Amaru/Treasury/Tx/SwapWizard.hs`
- [X] T007 [US1] Extend resolver input/selection so fixed mode remains unchanged and all-ADA mode derives amount after treasury UTxO query in `lib/Amaru/Treasury/Tx/SwapWizard.hs`
- [X] T008 [US1] Wire all-ADA resolver output into `SwapWizardQ` construction in `lib/Amaru/Treasury/Cli/SwapWizard.hs`
- [X] T009 [US1] Confirm targeted all-ADA tests pass with `nix develop --quiet -c just unit SwapWizard`

## Phase 4: User Story 2 - Prevent Ambiguous Swap Targets (P1)

**Goal**: CLI rejects ambiguous target and chunk combinations before live work.

**Independent Test**: Parser tests cover every rejected combination.

- [X] T010 [US2] Add `SwapTarget` parsing and diagnostics in `lib/Amaru/Treasury/Cli/SwapWizard.hs`
- [X] T011 [US2] Keep fixed `--usdm` parser behavior and existing tests green in `test/unit/Amaru/Treasury/Tx/SwapWizardSpec.hs`

## Phase 5: User Story 3 - Explain the Derived Amount (P2)

**Goal**: Trace output explains all-ADA calculation facts.

**Independent Test**: Trace rendering test verifies amount, implied USDM, leftover, split, chunks, overhead, and rate.

- [X] T012 [US3] Add all-ADA trace event and renderer in `lib/Amaru/Treasury/Tx/SwapWizard/Trace.hs`
- [X] T013 [US3] Emit the all-ADA trace from `lib/Amaru/Treasury/Cli/SwapWizard.hs`

## Phase 6: Documentation and Gate

- [X] T014 [P] Update operator docs in `docs/swap.md`
- [X] T015 [P] Update quickstart flag table in `docs/quickstart.md`
- [X] T016 Run `nix develop --quiet -c just format`
- [X] T017 Run targeted and full gates: `nix develop --quiet -c just unit`, `nix develop --quiet -c just golden`, and `nix develop --quiet -c just ci`

## Dependencies & Execution Order

T001-T002 before implementation. T003-T005 are RED tests. T006-T013 are GREEN implementation. T014-T015 document the finished behavior. T016-T017 verify the branch.

## Implementation Strategy

Deliver one vertical PR slice: tests, pure calculation, resolver/CLI wiring, trace, docs, and review artifacts in one bisect-safe feature commit.
