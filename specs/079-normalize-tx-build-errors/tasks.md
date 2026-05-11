# Tasks: Normalize tx-build Builder Errors

**Input**: Design documents from `/specs/079-normalize-tx-build-errors/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/tx-build-failure-contract.md

## Phase 1: Setup

- [X] T001 Read issue #79, PR #77, and current `lib/Amaru/Treasury/TreasuryBuild.hs` failure paths.
- [X] T002 Run baseline focused tests: `nix develop --quiet -c just unit "TreasuryBuild"` and record output in the PR body.

## Phase 2: Foundational

- [X] T003 [P] Add RED unit tests in `test/unit/Amaru/Treasury/TreasuryBuildSpec.hs` for stable codes/messages for each normalized build diagnostic.
- [X] T004 [P] Add RED report-envelope test in `test/unit/Amaru/Treasury/ReportSpec.hs` or `TreasuryBuildSpec.hs` proving `BuildFailure` receives normalized code/message.
- [X] T005 [P] Add RED unit tests in `test/unit/Amaru/Treasury/TreasuryBuildSpec.hs` proving structured context can be added to `TreasuryBuildException` with `mapException` for pure exception expressions and with the project helper for `IO` exceptions.
- [X] T006 Add `TreasuryBuildError`, `BuildDiagnostic`, `BuildErrorContext`, code renderer, and message renderer in `lib/Amaru/Treasury/TreasuryBuild.hs` or a new `lib/Amaru/Treasury/TreasuryBuild/Error.hs`.
- [X] T007 Add conversion from upstream `BuildError ()` and local runner failures into `TreasuryBuildError`.
- [X] T008 Add `withBuildErrorContext`, `mapTreasuryBuildExceptionContext`, and an IO wrapper/catcher helper for structured context enrichment.

## Phase 3: User Story 1 - Operator Gets a Stable Build Failure (P1)

**Goal**: non-report `tx-build` failures print normalized diagnostics, not internal exception strings.

**Independent Test**: a forced swap build failure exits non-zero and stderr does not contain `runSwap: build failed`, `user error`, or `Uncaught exception`.

- [X] T009 [US1] Add RED runner or CLI test for a swap build failure in `test/unit/Amaru/Treasury/TreasuryBuildSpec.hs`.
- [X] T010 [US1] Add `runFromIntentEither :: ChainContext -> SomeTreasuryIntent -> IO (Either TreasuryBuildError TreasuryBuildResult)` in `lib/Amaru/Treasury/TreasuryBuild.hs`.
- [X] T011 [US1] Refactor `runSwap` to use nested `ExceptT ActionBuildError IO`, lifted with `withExceptT`, internally for expected failures.
- [X] T012 [US1] Keep `runFromIntent` as a compatibility wrapper that throws a typed `TreasuryBuildException` with normalized `displayException`.
- [X] T013 [US1] Use `mapException` where pure exception mapping applies, and the IO wrapper/catcher helper where a `throwIO` boundary adds action/phase/context to `TreasuryBuildException`.
- [X] T014 [US1] Switch `app/amaru-treasury-tx/Main.hs` `runTxBuild` to consume the typed `Either` path for expected builder failures.

## Phase 4: User Story 2 - Reports Preserve Structured Failure Semantics (P2)

**Goal**: report failure envelopes carry stable codes and normalized messages.

**Independent Test**: `TxBuildOutputFailure` for representative failures has stable code/message and no raw Haskell constructor prose.

- [X] T015 [US2] Update `writeFailureReport` call sites in `app/amaru-treasury-tx/Main.hs` to use `TreasuryBuildError` code/message for expected build failures.
- [X] T016 [US2] Add/adjust tests proving `--report -` failure output uses normalized code/message.
- [X] T017 [US2] Ensure final validation failures keep all validation messages in deterministic order.

## Phase 5: User Story 3 - Shared Normalization Across Actions (P3)

**Goal**: swap, disburse, and withdraw use one normalization path.

**Independent Test**: direct normalizer tests cover all actions or action labels, and runner code no longer repeats raw `runX: build failed` rendering.

- [X] T018 [US3] Refactor `runDisburse` to use the same `ExceptT`/normalization helpers as `runSwap`.
- [X] T019 [US3] Refactor `runWithdraw` to use the same `ExceptT`/normalization helpers as `runSwap`.
- [X] T020 [US3] Add tests or static assertions that no `runSwap: build failed`, `runDisburse: build failed`, or `runWithdraw: build failed` strings remain in source.

## Phase 6: Polish

- [X] T021 Update docs if CLI/report failure wording changes in `docs/swap.md` or tx-build docs.
- [X] T022 Run `nix develop --quiet -c just format`.
- [X] T023 Run focused GREEN tests from T003/T004/T005/T009/T016.
- [X] T024 Run full gate: `nix develop --quiet -c just ci`.

## Dependencies

- T003-T008 block all user stories.
- US1 is the MVP and should land first.
- US2 depends on the typed error model from US1 but can be reviewed as a separate slice.
- US3 depends on the shared helpers proven by US1.

## Implementation Strategy

1. Build the normalizer and renderers with RED/GREEN unit tests.
2. Add the typed `Either` runner path and convert swap first.
3. Wire CLI/report output to consume typed failures.
4. Extend the same helpers to disburse and withdraw.
5. Run the full gate before opening the PR.
