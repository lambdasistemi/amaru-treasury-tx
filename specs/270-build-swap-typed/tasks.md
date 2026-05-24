# Tasks: typed `buildSwapTx` + HTTP + `/operate` CBOR & Report

**Input**: Design documents from `/code/amaru-treasury-tx-issue-269/specs/270-build-swap-typed/`
**Prerequisites**: plan.md ✓, spec.md ✓, research.md ✓, data-model.md ✓, contracts/* ✓
**TDD**: tests precede implementations; every commit individually CI-green ("bisect-safe").

## Format: `[ID] [P?] [Story] Description with file path`

- **[P]**: parallel-safe (different files, no dependency on incomplete tasks)
- **[Story]**: maps to spec.md user stories: US1 (P1 — pure `buildSwapTx`), US2 (P2 — CLI byte-identity), US3 (P3 — HTTP + frontend)
- Paths are relative to `/code/amaru-treasury-tx-issue-269/`

---

## Phase 1: Setup

- [ ] T001 Inventory every `throwE` / `exitWith` / `error` / `MonadFail` exit site in `lib/Amaru/Treasury/Build/Swap.hs`. Record one row per site (line + condition + payload), reconcile against the 12-constructor list in `specs/270-build-swap-typed/data-model.md § 1`; add or de-dup constructors as needed. Record the audit in `specs/270-build-swap-typed/audit-build-swap-exits.md`.
- [ ] T002 [P] Confirm the existing CLI swap golden corpus location (likely `test/fixtures/swap/` or under `test/golden/`). Record the fixture inventory (one row per scenario: scenario name + intent.json hash + tx.cbor hash + report.json hash) in `specs/270-build-swap-typed/audit-golden-corpus.md`. Establishes the byte-identity baseline.

---

## Phase 2: Foundational (blocking prerequisites)

- [ ] T003 [P] Add `BuildEvent` sum type + `renderEvent` in `lib/Amaru/Treasury/Wizard/Event.hs` per `data-model.md § 2`. 6 constructors: `ResolvingPParams`, `SelectingWalletInputs`, `BuildingSundaeOrder`, `BalancingTx`, `SerialisingTx`, `WritingReport`. Export from the module. No call sites yet; just the type.
- [ ] T004 [P] Add `BuildFailure` sum type in `lib/Amaru/Treasury/Wizard/Failure.hs` per `data-model.md § 1`. 12 constructors with the payload shapes from the table. Derive `Eq`, `Show`, `Generic`. Export from the module. No call sites yet.
- [ ] T005 Add `sysexitsForBuild :: BuildFailure -> ExitCode` in `lib/Amaru/Treasury/Wizard/Swap.hs` (next to the existing `sysexitsFor`). Map per the CLI taxonomy (64 usage / 69 unavailable / 70 internal-software). No callers yet; export it.

---

## Phase 3: User Story 1 (P1) — REPL: pure `buildSwapTx` with typed failure

**Goal**: a Haskell engineer can call `buildSwapTx` from `ghci`; every failure mode resolves to `Left <BuildFailure ctor>`; the host process is never killed.

**Independent test**: `BuildSwapSpec.hs` — feed deliberately malformed inputs, assert every constructor is matched at least once; assert `nullTracer` vs real tracer produce identical results.

### Tests for US1 (TDD — must FAIL first)

- [ ] T006 [US1] Add `test/unit/Amaru/Treasury/Wizard/BuildSwapSpec.hs` with two property holders:
  - `prop_perVariantCoverage`: enumerate every `BuildFailure` constructor (via manual list mirroring the audit from T001); for each, construct an input that should trigger it and assert `runExceptT (buildSwapTx ...)` returns `Left ctor`.
  - `prop_tracerInformational`: same input run with `nullTracer` and a recording tracer yields the same `Right`/`Left` payload.
  Test MUST compile + FAIL (no `buildSwapTx` symbol yet).
- [ ] T007 [US1] Add a static-check entry to `gate.sh` (or `nix/checks.nix`) that greps for `abortTr|exitWith|System.Exit|error \"|undefined` in `lib/Amaru/Treasury/Wizard/Swap.hs` and `lib/Amaru/Treasury/Build/Swap.hs`. MUST fail today.

### Implementation for US1

- [ ] T008 [US1] Add the `buildSwapTx :: GlobalOpts -> Backend -> SwapIntent -> Tracer IO BuildEvent -> ExceptT BuildFailure IO (CborHex, Report)` signature in `lib/Amaru/Treasury/Wizard/Swap.hs` with a `where ...` body that copies the legacy `Build.Swap.runSwap` / `runSwapAction` flow, then walks every audit row from T001 and replaces it with `throwE <BuildFailure ctor>`. Re-uses the existing pure helpers in `Build.Swap`; the legacy `runSwap` stays in place for now (still exported, used only by CLI shim — removed in T011).
- [ ] T009 [US1] Wire the `BuildEvent` tracer at every step from `data-model.md § 2`. Tracer calls MUST be informational only; no `if`/`case` on tracer presence; control flow identical with `nullTracer`.
- [ ] T010 [US1] Make the BuildSwapSpec tests from T006 pass. `prop_perVariantCoverage` green (every constructor reachable); `prop_tracerInformational` green. The grep check from T007 green.
- [ ] T011 [US1] Delete the legacy exit-on-error paths from `lib/Amaru/Treasury/Build/Swap.hs` that are now superseded. `runSwap` keeps existing CLI signature but its body delegates to `buildSwapTx` via a `runExceptT` + `case` arm that maps `Left` to the old `IO ()` exit behaviour. Bisect-safe: the CLI shim wraps the new typed core; existing CLI callers compile unchanged.

**Checkpoint**: US1 deliverable shippable as a standalone PR (typed `buildSwapTx` + per-variant tests + static check). CLI still works (shim path) but is byte-identical to today.

---

## Phase 4: User Story 2 (P2) — CLI byte-identity

**Goal**: every existing CLI swap fixture produces byte-identical `intent.json` + `tx.cbor` + `report.json`. Sysexits 64/69/70 unchanged.

**Independent test**: `BuildSwapGoldenSpec.hs` — re-run the fixture corpus through the new `buildSwapTx` path and compare to checked-in fixtures.

### Tests for US2 (TDD — must FAIL first)

- [ ] T012 [US2] Add `test/unit/Amaru/Treasury/Wizard/BuildSwapGoldenSpec.hs`. For each fixture in the audit from T002:
  - Read the input intent + chain state fixture.
  - Run `buildSwapTx` against a fixture-backed `Backend` derived from the chain state.
  - Compare emitted `CborHex` to the checked-in `tx.cbor` byte-for-byte.
  - Compare emitted `Report` (via JSON encode) to the checked-in `report.json` byte-for-byte.
  Today the test compiles (T008 has the signature) but the comparisons will diff if `buildSwapTx`'s pure assembly subtly diverges from `runSwap`. MUST go red first if any divergence exists.
- [ ] T013 [US2] Extend `test/unit/Amaru/Treasury/Cli/SwapWizardSpec.hs` (or create) with a sysexit-roundtrip case: for one known-broken input bundle, assert `exitWith` value is 64 (or 69 / 70 as appropriate). MUST cover at least one of each code.

### Implementation for US2

- [ ] T014 [US2] Rewire `Cli.SwapWizard.runWizard` (and any `tx-build` subcommand path) to dispatch through `buildSwapTx`. The dispatch pattern is the snippet in `contracts/build-swap-tx.hs.md § CLI rewire contract`. Failure arms map via `sysexitsForBuild`. Stream `BuildEvent`s to the existing `Tracer IO Text` stderr sink via `renderEvent`.
- [ ] T015 [US2] Bring `BuildSwapGoldenSpec` (T012) to green. Resolve any byte diffs by tracing the divergence back into T008's pure rewrite — typically a missing helper call or argument ordering swap. NO drift on the fixture corpus is allowed.
- [ ] T016 [US2] Bring `SwapWizardSpec` (T013) to green. Confirm exit codes match v0.2.15.0 baseline for the known-broken inputs.

**Checkpoint**: US2 deliverable shippable. The CLI is fully on the typed path, byte-identical, exit codes preserved.

---

## Phase 5: User Story 3 (P3) — HTTP `/v1/build/swap` extension + `/operate` CBOR & Report tabs

**Goal**: one POST to `/v1/build/swap` returns intent + cborHex + report. `/operate` Intent / CBOR / Report tabs all render real data. Typed failures highlight the offending field.

### Tests for US3 (TDD — must FAIL first)

- [ ] T017 [US3] Extend `test/unit/Amaru/Treasury/Api/ServerSpec.hs` with `SwapBuildResponse` JSON round-trip coverage for all four arms (Success, IntentFailure, BuildFailure, InternalError) per the schema at `specs/270-build-swap-typed/contracts/http-build-swap.json`. MUST fail (the response type doesn't have `cborHex`/`report`/`buildFailure` fields yet).
- [ ] T018 [US3] Add `test/unit/Amaru/Treasury/Api/BuildSwapSpec.hs` (or extend existing) with an end-to-end stub: given a fixture-backed `Backend` + a well-formed `SwapBuildRequest`, run `runBuildSwap` and assert the four-arm pattern from `data-model.md § 4`. Each arm reachable via a different fixture. MUST fail today.
- [ ] T019 [US3] Add a frontend smoke test (Halogen `Test.Spec` or a Node-driven Playwright if available) that posts a stub response to the `/operate` state machine and asserts the three preview tabs become populated. If Playwright isn't wired yet, capture as a manual checklist line in `quickstart.md` and skip — DON'T block the PR on a missing test harness.

### Implementation for US3

- [ ] T020 [US3] Extend `SwapBuildResponse` in `lib/Amaru/Treasury/Api/BuildSwap.hs` per `data-model.md § 4`. Add `cborHex`, `report`, `buildFailure` (all `Maybe`). Derive `Generic`, `ToJSON`, `FromJSON`. Update the constructor at every existing call site to populate `Nothing` for the new fields — keeps the type-check green before the handler rewrite.
- [ ] T021 [US3] Add `failureTagOfBuild :: BuildFailure -> FailureTag` next to the existing `failureTag :: WizardFailure -> FailureTag` in `lib/Amaru/Treasury/Api/BuildSwap.hs`. Use the field-reference table in `data-model.md § Field reference for the frontend`.
- [ ] T022 [US3] Rewrite `runBuildSwap :: GlobalOpts -> Backend -> SwapBuildRequest -> IO SwapBuildResponse` in `lib/Amaru/Treasury/Api/BuildSwap.hs` to run `buildSwapIntent` + `buildSwapTx` in sequence on the pre-opened `Backend`. Short-circuit on intent failure (tx-build never attempted). Encode the four arms exactly per the schema. Keep the existing `try @SomeException` backstop at the boundary — populates the `internalError` arm.
- [ ] T023 [US3] Bring `ServerSpec` (T017) + `BuildSwapSpec` (T018) to green.
- [ ] T024 [US3] In `frontend/src/OperatePage.purs`, extend `State` with `cborHex :: Maybe String`, `report :: Maybe Json`, `buildFailure :: Maybe FailureTag`, `buildErrorField :: Maybe String` per `contracts/operate-tabs.purs.md`. Update `HandleBuildResponse` to populate them from the parsed JSON.
- [ ] T025 [US3] Replace the "ships in PR B" placeholders for `TabCbor` and `TabReport` in `previewBody` (in `frontend/src/OperatePage.purs`) with real renderers:
  - `TabCbor` → `copyBlockButton "Copy CBOR" cborHex` + `<pre class="cbor-hex">cborHex</pre>` when `cborHex != Nothing`, else "not built yet" caption.
  - `TabReport` → `copyBlockButton "Copy report" (stringify report)` + `JsonTree.renderWith (defaultConfig { initiallyOpen = true })` wrapped in `{ details: report }` when `report != Nothing`, else "not built yet" caption.
- [ ] T026 [US3] Wire the status banner per `contracts/operate-tabs.purs.md § Status banner`. Banner text reads `Built` / `intent: <tag>` / `build: <tag>` / `error`; `data-ok` attribute reflects state.
- [ ] T027 [US3] Wire `[data-field]` highlighting: when `buildFailure.field` or `intentFailure.field` is non-null, add a `data-error="true"` attribute to the matching `.field__input`. CSS in `style-build.css` already styles the error state from #263.
- [ ] T028 [US3] Run the frontend smoke from T019 (or follow the manual checklist if Playwright isn't wired). Deploy to dev container, exercise all four arms via curl, screenshot the three tabs.

**Checkpoint**: US3 deliverable shippable. End-to-end vertical complete.

---

## Phase 6: Polish & Cross-cutting

- [ ] T029 [P] Bump `CHANGELOG.md` `Unreleased` section with the three user stories' deliverables. Convention: one bullet per user story.
- [ ] T030 [P] Update `AGENTS.md` / `CLAUDE.md` "Recent Changes" appendix with the #269 entry (already half-done by `update-agent-context.sh`).
- [ ] T031 [P] Run `nix build .#frontend && nix build .#amaru-treasury-tx-api && just unit && just hlint && just format` from `/code/amaru-treasury-tx-issue-269/`. Every gate green.
- [ ] T032 Open PR against `main` titled `feat(269): typed buildSwapTx + HTTP + /operate CBOR & Report`. Body: one paragraph per US story, link to spec/plan/research/data-model/contracts/quickstart.

---

## Dependencies

```
Phase 1 (Setup):      T001 (audit) → T003+T004 (types depend on audit)
Phase 1 (Setup):      T002 (golden inventory) — independent

Phase 2 (Foundation): T003 ↛  ⌐
                                       ┐
                      T004  ↛  ⌐       ├→  ALL US1+
                                       │
                      T005  ↛  ⌐ ──────┘

Phase 3 (US1):        T006+T007 (TDD red) → T008 (signature) → T009 (tracer) → T010 (tests green) → T011 (legacy delete)

Phase 4 (US2):        depends on Phase 3 complete (CLI shim must exist before byte-identity check).
                      T012 (golden TDD red) → T015 (golden green)
                      T013 (sysexit TDD red) → T014 (CLI rewire) → T016 (sysexit green)

Phase 5 (US3):        depends on Phase 3 complete (buildSwapTx must exist before HTTP handler can call it).
                      Can run in parallel with Phase 4 (different modules).
                      T017+T018+T019 (TDD red) → T020 (extend response type) → T021 (failure tag) → T022 (handler rewrite) → T023 (backend tests green) → T024+T025+T026+T027 (frontend wiring) → T028 (smoke)

Phase 6 (Polish):     after all user-story phases. T029+T030+T031 parallel. T032 last.
```

## Parallel execution examples

- **Phase 1**: `T002` runs alongside `T001` (different fixtures, no shared output).
- **Phase 2**: `T003` (`Event.hs`), `T004` (`Failure.hs`), and `T005` (`Swap.hs` sysexits) all touch separate modules — run in parallel.
- **Phase 4 + Phase 5**: once Phase 3 lands, Phase 4 (CLI) and Phase 5 (HTTP + frontend) touch disjoint modules — can be developed in parallel.
- **Phase 6 polish**: `T029` (CHANGELOG), `T030` (agent context), `T031` (gate run) all parallel.

## Implementation strategy

- **MVP** = Phase 1 + Phase 2 + Phase 3 (US1 only). Ships the typed `buildSwapTx` + per-variant test coverage + the static `exitWith`-grep gate. CLI is byte-identical via the shim. The HTTP + frontend remain on placeholders. This alone closes the #259 promise for the SWAP wizard.
- **MVP + 1**: add Phase 4 (US2). CLI is now fully on the typed path; goldens green.
- **MVP + 2**: add Phase 5 (US3). End-to-end web operator surface.
- **Recommended PR shape**: ship all three in one PR since they're sequential and small; if any one phase grows unexpectedly, split US3 out as a follow-up PR (Phase 5 has clean module boundaries from Phase 4).

## Bisect-safety contract

Every task above MUST leave the tree in a state where:

- `nix build .#amaru-treasury-tx-api` succeeds.
- `nix build .#frontend` succeeds.
- `just unit` passes (subject to the per-task TDD red→green transitions noted above; once a task introduces a failing test, the IMMEDIATELY next task in sequence must turn it green).

The TDD red/green pairs are explicit (T006↔T010, T012↔T015, T013↔T016, T017+T018↔T023). Each pair lands in two commits whose total span is one PR commit chunk; bisect across the PR jumps over the red intermediate via the chunked merge.
