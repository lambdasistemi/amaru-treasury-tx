---
description: "Task list — Swap wizard pure intent producer (#259)"
---

# Tasks: Swap wizard pure intent producer

**Input**: Design documents from `/specs/259-swap-wizard-pure/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/, quickstart.md
**Tests**: REQUIRED — spec mandates byte-identity goldens (FR-006, FR-007) and per-variant failure coverage (SC-003).

**Organization**: Tasks are grouped by user story so each story can be implemented as a CI-green commit on the shared branch `259-swap-wizard-pure`. The PR is one vertical; commits are sequenced.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies on incomplete tasks)
- **[Story]**: Which user story this task belongs to (US1, US2, US3)
- Include exact file paths in descriptions

## Path Conventions

Single Haskell project rooted at the repo root. Library code under `lib/Amaru/Treasury/`; CLI app under `app/amaru-treasury-tx/`; tests under `test/unit/Amaru/Treasury/`; golden fixtures under `test/golden/swap/`.

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Branch hygiene + baseline capture of the existing CLI byte-output so subsequent commits have a frozen reference for byte-identity comparison.

- [ ] T001 Verify worktree state: branch `259-swap-wizard-pure` checked out at `/code/amaru-treasury-tx-issue-236/`, tracking `origin/259-swap-wizard-pure`, clean `git status`.
- [ ] T002 Run `just build` and `nix build --quiet .#amaru-treasury-tx` once to warm caches and confirm pre-refactor green baseline in `/code/amaru-treasury-tx-issue-236/`.
- [ ] T003 Capture pre-refactor goldens for the canonical swap fixture: copy/freeze the current `intent.json`, `tx.cbor`, and `report.json` produced by the existing CLI under `test/golden/swap/baseline-pre-refactor/` so every subsequent commit can `cmp` against them. Add a one-line `README.md` next to them explaining they are baselines, not authoritative goldens.
- [ ] T004 [P] Add `lib/Amaru/Treasury/Wizard/` to `amaru-treasury-tx.cabal` `exposed-modules` (placeholder modules `Amaru.Treasury.Wizard.Failure`, `Amaru.Treasury.Wizard.Event`, `Amaru.Treasury.Wizard.Swap`). Each placeholder exports nothing yet — they exist so the cabal file change ships in the same commit as Phase 2 type land.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Land the typed surface (failure variants, event variants) that User Stories 1, 2, and 3 all depend on. No call-graph changes yet; only new types and helpers.

**⚠️ CRITICAL**: No user-story work can begin until Phase 2 is complete and green.

### `Amaru.Treasury.Wizard.Failure`

- [ ] T005 Create `lib/Amaru/Treasury/Wizard/Failure.hs` with `FieldId` sum type per `data-model.md` (17 constructors, `Eq`, `Show`, `Generic`, `ToJSON`, `FromJSON` deriving; JSON encoding per `contracts/failures.md` — snake-case constructor name without `Field` prefix).
- [ ] T006 In the same file, add `WizardFailure` sum type with the Input/Resolve/Internal families enumerated in `data-model.md`. Each variant carries the exact payload shape specified there. Derive `Eq`, `Show`, `Generic`, `ToJSON`, `FromJSON`. JSON encoding uses Aeson's `taggedObject` with tag field `"tag"`.
- [ ] T007 In the same file, add `BuildFailure` sum type with the four families per `data-model.md`. Same deriving + JSON shape.
- [ ] T008 In the same file, add helpers: `isInput`, `fieldOf`, `renderWizardFailure`, `isInputBuild`, `fieldOfBuild`, `renderBuildFailure`. Each function gets a Haddock line. `renderWizardFailure` produces the single-line error text that the CLI prints to stderr on exit.
- [ ] T009 In the same file, add `WizardFailureTag` and `BuildFailureTag` newtype-wrapped `Text` (or sum-of-tag-only) plus `allWizardFailureTags :: [WizardFailureTag]` and `allBuildFailureTags :: [BuildFailureTag]`. Used by the coverage property test in Phase 5 to enumerate every variant at compile time.
- [ ] T010 Add `test/unit/Amaru/Treasury/Wizard/FailureSpec.hs` covering: (a) round-trip `ToJSON/FromJSON` for one representative of each family; (b) `renderWizardFailure` is non-empty for every variant; (c) `fieldOf` returns `Just` for all `Input*` and `Nothing` for `Resolve*`/`Internal*` variants. Add the file to `amaru-treasury-tx.cabal` test-suite `other-modules`.
- [ ] T011 Run `nix build --quiet .#unit-tests` and `nix build --quiet .#checks.x86_64-linux.lint` from `/code/amaru-treasury-tx-issue-236/`. Both must be exit-0 before commit.
- [ ] **COMMIT** (after T011 green): `feat(259): typed WizardFailure + BuildFailure + FieldId (closes #259 phase 2 part 1)`

### `Amaru.Treasury.Wizard.Event`

- [ ] T012 Create `lib/Amaru/Treasury/Wizard/Event.hs` with `WizardEvent` sum type covering the events listed in `data-model.md` (`WeNetwork`, `WeMetadataPath`, `WeRegistryView`, `WeResolverEnv`, `WeChunksComputed`, `WeUpperBoundResolved`, `WeIntentReady`, `WeExclusionApplied`). Derive `Eq`, `Show`.
- [ ] T013 In the same file, add `BuildEvent` sum type covering the analogous events from the `tx-build` pipeline (one constructor per current `traceWith` site in `lib/Amaru/Treasury/Build/Swap.hs`).
- [ ] T014 In the same file, add `renderWizardEvent :: WizardEvent -> Text` and `renderBuildEvent :: BuildEvent -> Text`. Each clause emits the SAME text the existing CLI's `Tracer IO Text` prints today for the corresponding `traceWith` call — discover the existing text from `lib/Amaru/Treasury/Cli/SwapWizard.hs` and mirror exactly.
- [ ] T015 Add `test/unit/Amaru/Treasury/Wizard/EventSpec.hs` with a smoke test per `WizardEvent` and `BuildEvent` constructor calling its renderer and asserting non-empty `Text`. Add to cabal `other-modules`.
- [ ] T016 Run `nix build --quiet .#unit-tests` and `nix build --quiet .#checks.x86_64-linux.lint`. Both exit-0.
- [ ] **COMMIT** (after T016 green): `feat(259): typed WizardEvent + BuildEvent + text renderers`

**Checkpoint**: Foundation complete. The typed surface exists; nothing calls it yet. CI green.

---

## Phase 3: User Story 1 — HTTP handler reuses the wizard without process exits (Priority: P1) 🎯 MVP

**Goal**: Extract `buildSwapIntent` and `buildSwapTx` so a non-CLI caller can run the wizard and tx-build paths, receive `Either …` on error, and never exit the host process.

**Independent Test**: Construct deliberately malformed inputs in a Hspec harness (unknown scope, malformed wallet bech32, missing metadata file, registry verification mismatch, wallet shortfall). For each one, call `buildSwapIntent` and assert `Left` matches the expected variant. The host process must not exit during the test run.

### `Amaru.Treasury.Wizard.Swap` — `buildSwapIntent`

- [ ] T017 [US1] Create `lib/Amaru/Treasury/Wizard/Swap.hs` exporting `buildSwapIntent` with the contract signature from `contracts/builders.md`: `GlobalOpts -> WizardOpts -> Backend -> Tracer IO WizardEvent -> IO (Either WizardFailure SwapIntent)`. Module Haddock cites #259 and links to the contract.
- [ ] T018 [US1] Port the body of `runWizard` from `lib/Amaru/Treasury/Cli/SwapWizard.hs:476` (the `withLocalNodeBackend $ \backend -> do …` block onward) into `buildSwapIntent`. Replace every `abortTr tr msg` with `pure (Left someWizardFailureVariant)` per the abort-site → variant mapping in `data-model.md`. Tracer is `Tracer IO WizardEvent` — every `traceWith tr (WeXxx …)` site translates as-is; every `traceWith textTracer "…"` site moves to the CLI wrapper (Phase 4) or is dropped if it's a duplicate of an existing typed event.
- [ ] T019 [US1] In the same file, add `ChainEnv` record per `data-model.md` (fields `ceTipSlot`, `ceParams`, `ceEra`, `ceSlotConfig`, `ceBackend`). Add `openChainEnv :: Backend -> IO ChainEnv` (or its equivalent — investigate what the existing tx-build code calls to obtain these values; reuse it).
- [ ] T020 [US1] In the same file, add `buildSwapTx` per the contract signature: `ChainEnv -> SwapIntent -> Tracer IO BuildEvent -> IO (Either BuildFailure (CborHex, Report))`. Port the body of the existing `lib/Amaru/Treasury/Build/Swap.hs` execution function. Same abort-to-`Left` translation as T018.
- [ ] T021 [US1] [P] Update `amaru-treasury-tx.cabal`: add `Amaru.Treasury.Wizard.Swap` to `exposed-modules`; ensure `cardano-tx-tools`, `contra-tracer`, `aeson`, `bytestring`, `text` are present in the library's `build-depends`.
- [ ] T022 [US1] Add `test/unit/Amaru/Treasury/Wizard/SwapSpec.hs` with one Hspec describe per variant of `WizardFailure` — each block constructs the trigger condition (malformed input, stubbed backend, or chain-state preset) and asserts `Left expectedVariant`. The describe-block also records its trigger in a top-of-file `testedTags :: [WizardFailureTag]` constant.
- [ ] T023 [US1] In `SwapSpec.hs`, add the symmetric describe-blocks for `BuildFailure`, also accumulating `testedBuildTags`.
- [ ] T024 [US1] In `SwapSpec.hs`, add the QuickCheck property `prop_every_wizard_variant_has_a_triggering_test` and `prop_every_build_variant_has_a_triggering_test` per `contracts/failures.md`. Failing either property breaks CI.
- [ ] T025 [US1] Run `nix build --quiet .#unit-tests` — all FailureSpec, EventSpec, SwapSpec green; coverage properties green.
- [ ] T026 [US1] Run `nix build --quiet .#amaru-treasury-tx-api` (the HTTP binary) to confirm the library still links under the existing API exe's deps.
- [ ] T027 [US1] Run `nix build --quiet .#checks.x86_64-linux.lint`. Green.
- [ ] **COMMIT** (after T027 green): `feat(259): buildSwapIntent + buildSwapTx — typed failures, pre-opened Backend (US1)`

**Checkpoint US1**: A non-CLI caller can invoke the wizard, receive `Either WizardFailure SwapIntent`, and never crash the host. The existing CLI is broken at this point because `runWizard` still calls the old internal sequence — Phase 4 fixes that. The break is contained because the CLI is not yet rewired; no operator-facing change has shipped.

---

## Phase 4: User Story 2 — CLI keeps producing byte-identical artefacts (Priority: P1)

**Goal**: Rewire `runWizard` (and the `tx-build` CLI entry point) to call the new `buildSwapIntent` / `buildSwapTx` while preserving byte-identical output and adopting the sysexits exit-code family mapping.

**Independent Test**: Run the existing devnet smoke recipe (`just devnet-swap-smoke` or equivalent). Compare produced `intent.json`, `tx.cbor`, `report.json` against the baselines captured in T003 via `cmp -s`. Trigger one input failure (e.g., bad wallet bech32) and assert exit code is `64` (`EX_USAGE`).

### CLI rewiring

- [ ] T028 [US2] Refactor `lib/Amaru/Treasury/Cli/SwapWizard.hs:runWizard` to the wrapper shape from `contracts/builders.md` §Compatibility: open the log handle, open the backend via `withLocalNodeBackend`, build a `Tracer IO WizardEvent` from the typed event tracer, call `buildSwapIntent g o backend tr`, then `writeOrDie` on the result.
- [ ] T029 [US2] In the same file, define `writeOrDie :: Either WizardFailure SwapIntent -> IO ()` that on `Right`: encodes via `encodeSomeTreasuryIntent (SomeTreasuryIntent SSwap i)` and writes to `wOptsOut` (stdout if `Nothing`). On `Left`: prints `renderWizardFailure failure` to stderr via the text tracer; exits with `64` / `69` / `70` per family using `System.Exit.exitWith (ExitFailure n)`. Use the sysexits codes from `contracts/failures.md` (or define them locally as `import System.Posix.Internals` if available; otherwise hard-code as `64 :: Int` etc. with a Haddock comment).
- [ ] T030 [US2] Audit and remove every `abortTr` site that has been replaced by a `Left` in Phase 3 — none should remain reachable from `buildSwapIntent`. The remaining `abortTr` calls (if any) live only in `runWizard`'s wrapper code, e.g., the option-parsing validation before the backend open; those become CLI-shell `die` calls with the sysexits family that fits.
- [ ] T031 [US2] [P] Refactor the `tx-build` CLI command's entrypoint similarly: open chain env, call `buildSwapTx`, write CBOR + report on `Right`, sysexits exit on `Left`. File is the existing `tx-build` CLI module (find via `grep -rn "tx-build" app/`).
- [ ] T032 [US2] Add `test/unit/Amaru/Treasury/Cli/SwapWizardExitCodeSpec.hs` covering: each failure family produces the expected sysexits code when the wrapper runs. Use process-level invocation or shim the wrapper into a testable function.
- [ ] T033 [US2] Add `test/golden/swap/byte-identity-spec.hs` (or wire into existing test-suite) that runs `buildSwapIntent` against the canonical fixture with a stub backend replaying recorded chain responses, then compares the encoded bytes to `test/golden/swap/baseline-pre-refactor/intent.json` via `cmp -s`. Same for `buildSwapTx` outputs.
- [ ] T034 [US2] Run `nix build --quiet .#unit-tests`. All Phase 4 tests + Phase 2/3 tests green.
- [ ] T035 [US2] Run the devnet smoke check (`nix build --quiet .#checks.x86_64-linux.smoke` or `just devnet-swap-smoke`). Verify `intent.json`, `tx.cbor`, `report.json` outputs are byte-identical to baselines. If the smoke harness is not part of the standard checks set, run it manually and record the result in the commit message.
- [ ] T036 [US2] Run `nix build --quiet .#checks.x86_64-linux.lint` and `nix build --quiet .#amaru-treasury-tx`. Green.
- [ ] **COMMIT** (after T036 green): `feat(259): rewire CLI through buildSwapIntent + sysexits exit-code mapping (US2)`

**Checkpoint US2**: CLI behaviour matches pre-refactor on the happy path (byte-identical output) and uses sysexits codes on the failure path. Operators can keep using the CLI unchanged in scripts that only check for non-zero. CI is green end-to-end.

---

## Phase 5: User Story 3 — Failures carry enough data to drive a UI (Priority: P2)

**Goal**: Prove via test corpus that every `WizardFailure` / `BuildFailure` variant exposes either a `FieldId` (for `Input*`) or a system-level marker (for `Resolve*` / `Internal*`), and that variants are independently triggerable from a structured caller.

**Independent Test**: The QuickCheck coverage properties from T024 stay green AND every variant's triggering describe-block (T022, T023) accepts at least one input that exercises it. Manual review of the failure-types module confirms 1:1 mapping between `Input*` variants and `FieldId` constructors.

- [ ] T037 [US3] Audit `lib/Amaru/Treasury/Wizard/Failure.hs`: for every `Input*` constructor, verify it names exactly one `FieldId`. For every `Resolve*` constructor, verify it carries a structured detail record (not bare `Text`). For every `Internal*`, verify it carries `Text` (per data-model invariants). Fix any drift.
- [ ] T038 [US3] [P] Add Haddock to every variant of `WizardFailure` and `BuildFailure` explaining what triggers it and how a UI should render it (highlight field / show infra banner / show bug-report prompt). Module-level Haddock cites #259 and the contracts.
- [ ] T039 [US3] Add `test/unit/Amaru/Treasury/Wizard/FieldIdSpec.hs`: a QuickCheck property that every `FieldId` constructor's JSON encoding matches the table in `contracts/failures.md`. Failing the property means a CLI flag was added or renamed without updating the field-id schema.
- [ ] T040 [US3] Add `test/unit/Amaru/Treasury/Wizard/FailureCoverageSpec.hs` (or extend SwapSpec): an Hspec describe-block `"every WizardFailure variant"` that loops over `allWizardFailureTags` and, for each tag, asserts a matching test in `testedTags`. Use `pendingWith` for any tag not yet covered to make the gap explicit (rather than silently skipping).
- [ ] T041 [US3] Run `nix build --quiet .#unit-tests`. All variant coverage + field-id schema tests green; coverage property green.
- [ ] T042 [US3] Run `nix build --quiet .#checks.x86_64-linux.lint`. Green.
- [ ] **COMMIT** (after T042 green): `test(259): per-variant failure coverage + FieldId schema property (US3)`

**Checkpoint US3**: The failure surface is provably complete: every variant has a triggering test, and every `FieldId` survives the schema test. A UI built against the schema has a contract it can rely on.

---

## Phase 6: Polish & Cross-Cutting Concerns

**Purpose**: Format, lint, Hackage-readiness, PR shape.

- [ ] T043 [P] Run `nix develop --quiet -c fourmolu -i lib/Amaru/Treasury/Wizard/*.hs lib/Amaru/Treasury/Cli/SwapWizard.hs test/unit/Amaru/Treasury/Wizard/*.hs`. Re-format any drift.
- [ ] T044 [P] Run `nix develop --quiet -c cabal-fmt -i amaru-treasury-tx.cabal`. Re-format any drift.
- [ ] T045 [P] Run `nix develop --quiet -c hlint lib/Amaru/Treasury/Wizard/ lib/Amaru/Treasury/Cli/SwapWizard.hs test/unit/Amaru/Treasury/Wizard/`. Address every hint.
- [ ] T046 Add module-level Haddock to `Amaru.Treasury.Wizard.{Failure,Event,Swap}` per Constitution §VI: copyright, license, one-line description, longer description block, cross-references to #259 and the contracts. Already present for variants from T038; this is the module-header pass.
- [ ] T047 Update the in-repo CLAUDE.md auto-generated section if it references the wizard module structure (the `update-agent-context.sh` run in Phase 1 of planning already did this; re-run if anything changed).
- [ ] T048 Run `nix flake check --no-eval-cache` from the repo root. Every check derivation passes.
- [ ] T049 Open PR against `main` with title `feat(259): swap wizard pure intent producer` and body that lists: closes #259, summary of the five-commit sequence, manual verification (devnet smoke, baseline `cmp`), risks (other wizards unchanged), follow-ups (HTTP endpoint blocked on this).
- [ ] **COMMIT** (covering T043–T046 if drift fixes are needed): `chore(259): polish — formatter + lint + Haddock`

---

## Dependencies

- **Phase 1 (Setup)** has no dependencies.
- **Phase 2 (Foundational)** depends on Phase 1.
- **Phase 3 (US1)** depends on Phase 2 (consumes `WizardFailure`, `BuildFailure`, `WizardEvent`, `BuildEvent`).
- **Phase 4 (US2)** depends on Phase 3 (CLI rewires through `buildSwapIntent` / `buildSwapTx`).
- **Phase 5 (US3)** depends on Phase 4 (adds coverage tests AFTER the CLI is rewired so the coverage runs against a working binary). US5 *could* technically land after Phase 3 since the failure types already exist, but the byte-identity check in Phase 4 is the higher-confidence MVP gate; landing US3 last ensures the test corpus is the last thing to harden, not the first.
- **Phase 6 (Polish)** depends on Phases 2–5.

```text
Phase 1 → Phase 2 → Phase 3 → Phase 4 → Phase 5 → Phase 6
                                 │
                                 └─ MVP CHECKPOINT (CLI byte-identical;
                                    HTTP layer can already consume the
                                    new functions even before US3 lands)
```

## Parallel Opportunities

Within a phase, tasks marked `[P]` operate on disjoint files and can be done in parallel:

- Phase 1: T004 in parallel with T002 / T003.
- Phase 3: T021 (cabal file) in parallel with T017–T020 (Haskell sources).
- Phase 4: T031 (tx-build CLI rewire) in parallel with T028–T030 (swap-wizard CLI rewire) once both consume the foundational types.
- Phase 5: T038 (Haddock) and T039 (FieldId spec) are independent files and can run in parallel.
- Phase 6: T043–T045 are independent tool invocations across the same file set; run sequentially in practice because each formatter may shift line numbers.

## MVP Scope

User Story 1 + User Story 2 together (Phases 1–4). At end of Phase 4 the CLI is byte-identical and the new functions are ready for an HTTP handler to consume. US3 (Phase 5) ratchets the test corpus but does not change behaviour visible to operators.

## Implementation Strategy

1. **Vertical, sequenced commits on one branch (`259-swap-wizard-pure`)**. Each commit listed under "**COMMIT**" above is a candidate for review; CI must be green at every commit.
2. **No squashing across phases.** The five commits (one per phase 2-end + one for US1 + one for US2 + one for US3 + one for polish) tell the story of the refactor; reviewers can bisect against them if a regression shows up later.
3. **Baseline capture (T003) is the load-bearing safety net.** Without it, byte-identity tests have no reference.
4. **The MVP exit point is end of Phase 4.** If session time runs out, the branch may merge at that point with US3 carved into a follow-up — but the spec's SC-003 acceptance criterion makes US3 strongly preferred for the same PR.
5. **Do not refactor other wizards** (cancel-swap, disburse, reorganize, withdraw) in this PR. They are explicitly out of scope per spec §Assumptions.

## Format validation

All 49 tasks below follow the strict checklist format: `- [ ] TXXX [P?] [Story?] Description with file path`.

- Setup tasks (T001–T004): no story label (Phase 1 convention).
- Foundational tasks (T005–T016): no story label (Phase 2 convention).
- User-story tasks (T017–T042): each carries `[US1]`, `[US2]`, or `[US3]`.
- Polish tasks (T043–T049): no story label (Phase 6 convention).
- Total: 49 tasks across 6 phases + 5 commit markers.
