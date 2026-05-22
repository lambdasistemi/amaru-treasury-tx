# Tasks: 186-reorganize-wizard-parser

**Input**: Design documents from `/specs/186-reorganize-wizard-parser/`
**Prerequisites**: `plan.md`, `spec.md`, `research.md`, `data-model.md`, `contracts/`, `quickstart.md`
**Branch**: `186-reorganize-wizard-parser`
**Issue**: #186, child of epic #189
**Depends on**: #185 (real `ReorganizeIntent` shapes) — merged at `da9d65b5`

**Tests**: TDD is required by the plan. Each implementation slice
starts with a RED proof, then lands GREEN in the same bisect-safe
commit.

**Organization**: Tasks are grouped by the four vertical slices
from `plan.md`. S1 and S2 are dispatched to claude driver+navigator
pairs (per the brief: `claude --dangerously-skip-permissions` +
`/effort xhigh`). S3 and S4 are orchestrator-owned (no
driver+navigator dispatch). Workers do not push. The orchestrator
reviews the returned commit, amends the matching checkboxes into
that same commit on acceptance, runs the gate, and then pushes.

## Format: `[ID] [P?] [Story?] Description`

- **[P]**: Can run in parallel with another task in the same phase.
- **[Story]**: User-story coverage from `spec.md` (US1..US5).
- **S1/S2/S3/S4**: Bisect-safe slice mapping from `plan.md`.

## Phase 1: Setup

No remaining setup tasks. The branch, draft PR (#195), `gate.sh`,
specification, plan, research, data model, contracts, and quickstart
already exist on the branch.

## Phase 2: Foundational

No remaining foundational tasks. #185 already shipped the real
`ReorganizeIntent` shape and the `Build.Reorganize` runner that #187
will eventually wire. This slice builds on top of those library
shapes without modifying them.

## Phase 3: S1 — Parser + Stub Runner + Parser/Pre-flight/Network-Guard Tests

**Goal**: Ship the library-only half of the parser scaffold — two
new modules under `Amaru.Treasury.{Cli,Tx}.ReorganizeWizard`, the
cabal exposure, and the consolidated parser/pre-flight/network-guard
test spec covering all five User Stories. After this slice, the
new modules are usable from `cabal repl` but the binary's `--help`
does NOT yet list `reorganize-wizard` (that wiring is S2).

**Independent Test**: `nix develop --quiet -c just unit
"ReorganizeWizardParser"` passes; `nix develop --quiet -c just
unit` passes (no regressions in sibling wizards); `./gate.sh`
passes.

**Owned files**:

- `lib/Amaru/Treasury/Tx/ReorganizeWizard.hs` (NEW)
- `lib/Amaru/Treasury/Cli/ReorganizeWizard.hs` (NEW)
- `amaru-treasury-tx.cabal` (expose both new modules)
- `test/unit/Amaru/Treasury/Cli/ReorganizeWizardParserSpec.hs` (NEW)

**Commit subject**: `feat(cli): reorganize-wizard parser + stub runner`
**Commit trailer**: `Tasks: T001, T002, T003, T004, T005, T006, T007, T008, T009, T010`

### Tests for S1

- [ ] T001 [US1] [US2] [US3] [US4] [US5] Add the RED parser spec skeleton at `test/unit/Amaru/Treasury/Cli/ReorganizeWizardParserSpec.hs` that imports `Amaru.Treasury.Cli.ReorganizeWizard (ReorganizeWizardOpts, reorganizeWizardOptsP, validateOutPath, runReorganizeWizardEither, CommonFlags (..))` and `Amaru.Treasury.Tx.ReorganizeWizard (ReorganizeError (..), ReorganizeWizardAnswers)`; record the compile-time RED failure (modules do not yet exist) in `WIP.md`. The spec must be discoverable by hspec auto-discovery (matching sibling specs' naming + `module ... ( spec ) where` shape).

### Implementation for S1

- [ ] T002 [P] [US4] [US5] Create `lib/Amaru/Treasury/Tx/ReorganizeWizard.hs` with the `ReorganizeWizardAnswers` record and the `ReorganizeError` sum (`ReorganizeOutputParentMissing FilePath`, `ReorganizeOutputExistsNoForce FilePath`, `ReorganizeNonDevnetNetwork Text`, `ReorganizeTodoSliceC`) per `data-model.md` §2 and §3. Both types `deriving stock (Eq, Show)`. Include the `optsToAnswers :: ReorganizeWizardOpts -> ReorganizeWizardAnswers` projection (forward-declared signature is fine; body folds the `CommonFlags` + `rwoFundingSeedTxIn` into the answers record). Add the module header + Haddocks per project style.
- [ ] T003 [US1] [US2] [US3] Create `lib/Amaru/Treasury/Cli/ReorganizeWizard.hs` with: (a) the `CommonFlags` and `ReorganizeWizardOpts` records from `data-model.md` §1, (b) the `reorganizeWizardOptsP :: Parser ReorganizeWizardOpts` parser exposing every flag in `contracts/parser-flag-contract.md`'s flag inventory, (c) the local `txInReader`/`scopeReader` ReadM helpers (copy-mirror from `Amaru.Treasury.Cli.RegistryInitWizard` — sibling convention per `research.md` §3), (d) the module's exposed exports per `contracts/parser-flag-contract.md`. The parser MUST reuse `Amaru.Treasury.LedgerParse.txInFromText` via `eitherReader` for `--funding-seed-txin` (FR-006).
- [ ] T004 [US4] [US5] Extend `lib/Amaru/Treasury/Cli/ReorganizeWizard.hs` with the pre-flight + stub-runner shell per `contracts/exit-code-contract.md`: (a) `validateOutPath :: FilePath -> Bool -> IO (Either ReorganizeError ())` (mirrors sibling), (b) `runReorganizeWizardEither :: GlobalOpts -> ReorganizeWizardOpts -> IO (Either ReorganizeError ())` performing the pre-flight ordering (Step 1 `--network devnet` guard → Step 2 `validateOutPath` → Step 3 `ReorganizeTodoSliceC`), (c) `exitCodeFor :: ReorganizeError -> Int` returning 2 for pre-flight variants and 3 for `ReorganizeTodoSliceC`, (d) `runReorganizeWizard :: GlobalOpts -> ReorganizeWizardOpts -> IO ()` as the `hPrint stderr` + `exitWith (ExitFailure (exitCodeFor _))` shim around `runReorganizeWizardEither`.
- [ ] T005 [P] Update `amaru-treasury-tx.cabal` to expose `Amaru.Treasury.Cli.ReorganizeWizard` and `Amaru.Treasury.Tx.ReorganizeWizard` in the `library` stanza's `exposed-modules` list, alphabetically ordered per `data-model.md` §7. Do not list the new test module (hspec auto-discovery picks it up).
- [ ] T006 [US1] Implement the US1 acceptance scenarios in `ReorganizeWizardParserSpec`: `execParserPure (info reorganizeWizardOptsP fullDesc) defaultPrefs ["--help"]` returns `Failure pf` whose `renderFailure pf "reorganize-wizard"` output contains every required flag name (`--wallet-addr`, `--metadata`, `--out`, `--scope`, `--funding-seed-txin`) and the optional rationale flags (`--description`, `--justification`, ...). Substring-style assertions (`isInfixOf`), not exact-string equality.
- [ ] T007 [US2] Implement the US2 acceptance scenarios in `ReorganizeWizardParserSpec`: a table-driven test that runs `execParserPure ... [..., "--funding-seed-txin", malformed, ...]` for each malformed shape (no `#`, short hex, non-hex, index out of `Word16` range) and asserts `Failure pf` with `renderFailure pf "..."` containing "funding-seed-txin" or the `txInFromText` rejection text. Use shared positive-fixture argv plus the substituted bad flag value.
- [ ] T008 [US3] Implement the US3 acceptance scenarios in `ReorganizeWizardParserSpec`: four cases, each omitting one required flag (`--wallet-addr`, `--metadata`, `--funding-seed-txin`, `--out`, `--scope`) from the positive-fixture argv and asserting `Failure pf` with `renderFailure pf "..."` containing `"Missing:"` and the omitted flag's long name. Substring assertion only.
- [ ] T009 [US4] Implement the US4 acceptance scenarios in `ReorganizeWizardParserSpec`: (a) call `validateOutPath "/tmp/nonexistent-186-parent-<unique>/foo.json" False`, assert `Left (ReorganizeOutputParentMissing parent)` where `parent` is the missing directory; (b) call `runReorganizeWizardEither` with `goNetworkName = Just "devnet"`, a `--out` whose parent exists (use `withSystemTempDirectory`), and assert `Left ReorganizeTodoSliceC` (proves the pre-flight ran before the stub).
- [ ] T010 [US5] Implement the US5 acceptance scenarios in `ReorganizeWizardParserSpec`: three cases — `goNetworkName = Just "preprod"`, `Just "mainnet"`, `Just "preview"` — each calling `runReorganizeWizardEither` and asserting `Left (ReorganizeNonDevnetNetwork name)` with the matching network text; plus one positive case `Just "devnet"` asserting `Left ReorganizeTodoSliceC` (confirms devnet passes step 1). Mirror the sibling `RegistryInitWizardNetworkGuardSpec` strict-mock pattern: the `goSocketPath` is `Nothing` and no I/O backend is constructed, so the network guard fires before any chain query.

**Checkpoint**: S1 is complete when `nix develop --quiet -c just
unit "ReorganizeWizardParser"` is green, `nix develop --quiet -c
just unit` is green (no regressions in sibling wizard specs), and
`./gate.sh` is green. The binary's `--help` does NOT yet list
`reorganize-wizard` by design (S2 wires that).

## Phase 4: S2 — Dispatcher Wire-Up + `Main.hs` Runner Case + Dispatch Test

**Goal**: Wire the new parser + runner into the top-level CLI
surface. After this slice, `amaru-treasury-tx reorganize-wizard
--help` works; `amaru-treasury-tx reorganize-wizard
--funding-seed-txin <bad>` is rejected at parse time; valid
invocation surfaces `ReorganizeTodoSliceC` and exits with code 3.

**Independent Test**: `nix develop --quiet -c just unit
"ReorganizeWizardDispatch"` passes; `nix develop --quiet -c just
unit` passes (no regressions); `nix develop --quiet -c just ci`
passes (full all-up gate); `./gate.sh` passes.

**Owned files**:

- `lib/Amaru/Treasury/Cli.hs` (add `CmdReorganizeWizard` arm + import)
- `app/amaru-treasury-tx/Main.hs` (add runner case + import)
- `test/unit/Amaru/Treasury/Cli/ReorganizeWizardDispatchSpec.hs` (NEW)

**Commit subject**: `feat(cli): wire reorganize-wizard subcommand into dispatcher`
**Commit trailer**: `Tasks: T011, T012, T013, T014`

### Tests for S2

- [ ] T011 [US1] Add the RED dispatch spec at `test/unit/Amaru/Treasury/Cli/ReorganizeWizardDispatchSpec.hs` per `contracts/dispatcher-wiring-contract.md`'s "Dispatch test" block: (a) one test asserts `execParserPure defaultPrefs opts ["reorganize-wizard", "--help"]` returns `Failure pf` whose rendered output contains the `progDesc` substring "reorganize intent.json"; (b) one test asserts `execParserPure defaultPrefs opts ["reorganize-wizard"]` returns `Failure pf` whose rendered output contains `"Missing:"` and one required flag (substring-only, no exact string). Record the "Unknown command 'reorganize-wizard'" RED failure in `WIP.md` (the spec compiles but fails until S2's Cli.hs edit lands).

### Implementation for S2

- [ ] T012 [P] [US1] Extend `lib/Amaru/Treasury/Cli.hs` per `contracts/dispatcher-wiring-contract.md`'s "`lib/Amaru/Treasury/Cli.hs`" block: (a) add the `import Amaru.Treasury.Cli.ReorganizeWizard (ReorganizeWizardOpts, reorganizeWizardOptsP)` import, (b) add the `CmdReorganizeWizard ReorganizeWizardOpts` constructor to the `Cmd` sum at the family-grouped position (after `CmdGovernanceWithdrawalInitWizard`, before `CmdTxBuild`), (c) add the `command "reorganize-wizard"` entry to `cmdP` adjacent to the other wizard families with the exact `progDesc` from the contract.
- [ ] T013 [P] [US1] Extend `app/amaru-treasury-tx/Main.hs` per `contracts/dispatcher-wiring-contract.md`'s "`app/amaru-treasury-tx/Main.hs`" block: (a) add the `import Amaru.Treasury.Cli.ReorganizeWizard (runReorganizeWizard)` import, (b) add the `CmdReorganizeWizard rwo -> runReorganizeWizard g rwo` case (no `withSocket g` wrapper — the stub runner never opens a socket; #187 widens this). Place the case adjacent to the other wizard cases.
- [ ] T014 [US1] Verify S2 with `nix develop --quiet -c just unit "ReorganizeWizardDispatch"`, `nix develop --quiet -c just unit`, `nix develop --quiet -c just ci`, and `./gate.sh`; record evidence in `WIP.md`. The verification step also confirms `nix run .#default -- reorganize-wizard --help` (or `cabal run -O0 amaru-treasury-tx -- reorganize-wizard --help`) prints the documented flag set and exits 0 — this is the operator-perspective acceptance proof for User Story 1 Acc. 1.

**Checkpoint**: S2 is complete when the binary's
`reorganize-wizard --help` lists the documented flag set, missing
or malformed flags are rejected by `optparse-applicative` before
any work, the pre-flight surfaces typed `ReorganizeError` values
at exit code 2, the stub runner surfaces `ReorganizeTodoSliceC`
at exit code 3, and all acceptance scenarios in `spec.md` hold.

## Phase 5: S3 — Spec Wording Amendment for Q-001-C1 → C2 Refinement (Orchestrator-Owned)

**Goal**: Amend `spec.md` so future readers do not see a
contradiction between User Story 5's "rejected at the parser"
wording and the C2 pre-flight runner check implementation. This
slice is **orchestrator-owned** — no driver+navigator dispatch;
docs-only edit on a spec the orchestrator owns.

**Independent Test**: not applicable (docs-only edit; the
implementation already shipped in S1 + S2 already satisfies the
amended wording).

**Owned files**:

- `specs/186-reorganize-wizard-parser/spec.md`

**Commit subject**: `docs(spec): amend Q-001-C1 → C2 wording for --network rejection tier`
**Commit trailer**: `Tasks: T015` (optional — `docs:` commits are
exempt from the gate's Tasks-trailer requirement, but the trailer
is included for traceability).

### Implementation for S3

- [ ] T015 Amend `specs/186-reorganize-wizard-parser/spec.md` per `research.md` §5: (a) edit User Story 5's heading from "rejected at parse time" to "rejected before any chain query, file write, or socket open"; (b) edit User Story 5's Independent Test sentence to remove "at parse time" wording and replace with "before any chain query, file write, or socket open"; (c) edit FR-007 to read "The runner pre-flight MUST reject `--network` values other than `\"devnet\"` before any chain query, file write, or socket open. The check is implemented in `runReorganizeWizardEither` and surfaces a typed `ReorganizeNonDevnetNetwork Text` error at exit code 2."; (d) add a one-line "Q-001-C verdict: refined to C2 at plan time — see plan.md and research.md §5" note under the Clarifications section's Q-001-C entry. Do NOT touch any other section. The amend leaves SC-005's grep-based assertion untouched (the implementation already matches).

**Checkpoint**: S3 is complete when the amended spec text matches
the implementation shipped in S1 + S2, and a reviewer reading
`spec.md` end-to-end does not see "rejected at the parser" for
the `--network` flag.

## Phase 6: S4 — Drop `gate.sh` + Mark PR Ready (Orchestrator-Owned)

**Goal**: Final commit on the branch. Drop the worktree-local
`gate.sh` and mark the PR ready for review. No behavior change;
the `nix develop -c just ci` invocation reviewers run reproduces
the same checks `gate.sh` was running locally.

**Independent Test**: not applicable (chore commit). The
`finalization_audit` bash function from the `gate-script` skill
confirms every `tasks.md` checkbox is `[X]` before the drop.

**Owned files**:

- `gate.sh` (removed via `git rm`)

**Commit subject**: `chore: drop gate.sh (ready for review)`
**Commit trailer**: none (`chore:` commits are exempt from the
gate's Tasks-trailer requirement).

### Implementation for S4

S4 has no `T-` task because the gate-drop is a chore exempt from
the Tasks: trailer requirement and is documented in the
`gate-script` skill rather than as a discrete coding task.

After all S1 + S2 + S3 commits land and have been pushed:

1. Run `finalization_audit` from the `gate-script` skill against
   `specs/186-reorganize-wizard-parser/tasks.md` — every checkbox
   `[X]`, every commit's `Tasks:` trailer present, every
   behavior-changing commit has a Conventional Commit subject.
2. Run `nix develop --quiet -c just ci` and confirm green.
3. Run `git rm gate.sh && git commit -m "chore: drop gate.sh (ready for review)"`.
4. Run `git push`.
5. Run `gh pr ready 195`.
6. Append `COMPLETE` and `NOTE PR #195 marked ready for review`
   to `/tmp/epic-189/attx-186/STATUS.md`.

## Dependencies & Execution Order

### Phase Dependencies

- **Setup / Foundational**: Already complete.
- **S1**: First implementation slice. Ships the new modules + parser
  tests. Required before S2 because S2 imports the new modules.
- **S2**: Depends on S1. Wires the new parser into the top-level
  CLI dispatcher. Required before S3 (the spec amendment refers
  to behavior already shipped).
- **S3**: Depends on S1 + S2. Docs-only spec amendment so spec text
  matches shipped behavior.
- **S4**: Depends on S1 + S2 + S3. Final chore (drop gate.sh, mark
  PR ready).

### Slice Commit Boundaries

- **S1 commit**: T001..T010 only.
- **S2 commit**: T011..T014 only.
- **S3 commit**: T015 only.
- **S4 commit**: no `T-` tasks (chore).

Every slice commit must be bisect-safe, must include its `Tasks:`
trailer (or be exempt per `chore:`/`docs:` rule), and must leave
`./gate.sh` green at HEAD until S4 drops the script. Checkboxes
are marked `[X]` by amending the reviewed commit during
orchestrator acceptance — see the `gate-script` skill's
"Stamping a reviewed slice" section.

### Parallel Opportunities

Within S1: T002 and T005 are `[P]` (different files, no
dependencies after T001's RED is in place). T003 depends on T002
(needs the types). T004 depends on T003 (extends the same Cli
module). T006..T010 depend on T003+T004 (need the parser + the
`*Either` helper) and can be implemented sequentially by the
driver; they may also be folded into a single Hspec spec body
written in one pass.

Within S2: T012 and T013 are `[P]` (different files). T014 is the
final verification step and must run last.

No slices can run in parallel — each consumes the previous
slice's owned files.

## Pair Dispatch Notes (S1 + S2 only)

For S1 and S2, the orchestrator dispatches one claude driver and
one claude navigator using
`claude --dangerously-skip-permissions` + `/effort xhigh`, per the
ticket-orchestrator brief. Both workers load `pair-programming`
first, use the file-based questions/answers protocol, write
`WIP.md` evidence, and never push. The orchestrator tails
STATUS.md from `/tmp/epic-189/attx-186/<slice-slug>-driver/STATUS.md`
+ `<slice-slug>-navigator/STATUS.md` via Monitor, and reviews the
returned commit before pushing.

S3 + S4 are orchestrator-owned with no driver+navigator dispatch.
The orchestrator edits `spec.md` (S3) and runs `git rm gate.sh`
(S4) directly.

## Implementation Strategy

1. **Dispatch S1 pair**: brief includes the contracts, owned-files
   list, forbidden scope, RED proof requirement, and the
   `feat(cli): reorganize-wizard parser + stub runner` commit
   subject + Tasks trailer. Tail STATUS.md until COMMIT + REVIEW.
2. **Review S1 commit**: amend T001..T010 checkboxes into the
   commit, run `./gate.sh` locally, push.
3. **Dispatch S2 pair**: brief includes the dispatcher-wiring
   contract, owned-files list, the `feat(cli): wire ...` commit
   subject + Tasks trailer.
4. **Review S2 commit**: amend T011..T014 checkboxes, run
   `./gate.sh` locally, push. After this push, manually verify
   `nix run .#default -- reorganize-wizard --help` prints the
   documented flag set.
5. **Run S3 orchestrator-owned amendment**: edit `spec.md`, mark
   T015 `[X]`, commit as `docs(spec): amend Q-001-C1 → C2 wording
   for --network rejection tier`, push.
6. **Run S4 orchestrator-owned finalization**: `finalization_audit`,
   `git rm gate.sh`, commit, push, `gh pr ready 195`, log COMPLETE
   in STATUS.md.

## Acceptance scenario coverage matrix (mirrored from plan.md)

| Spec scenario | Slice | Test/evidence |
|---|---|---|
| US1 Acc. 1 — `reorganize-wizard --help` lists flag set | S1 (via `execParserPure reorganizeWizardOptsP`) + S2 (via `execParserPure opts`) | T006 (S1) + T011 (S2) + manual verify in T014 |
| US1 Acc. 2 — `amaru-treasury-tx --help` lists `reorganize-wizard` | S2 | T011 + manual verify in T014 |
| US2 Acc. 1 — malformed `--funding-seed-txin` rejected | S1 | T007 |
| US2 Acc. 2 — alternative malformed shapes rejected | S1 | T007 (table-driven) |
| US3 Acc. 1 — missing `--registry` (= `--metadata`, verdict α) rejected | S1 | T008 |
| US3 Acc. 2 — missing `--wallet-addr` rejected | S1 | T008 |
| US3 Acc. 3 — missing `--funding-seed-txin` rejected | S1 | T008 |
| US3 Acc. 4 — missing `--out` rejected | S1 | T008 |
| US4 Acc. 1 — `--out` parent missing → `ReorganizeOutputParentMissing` exit 2 | S1 | T009 |
| US4 Acc. 2 — valid `--out` parent → pre-flight passes; stub fires `ReorganizeTodoSliceC` | S1 | T009 |
| US5 Acc. 1 — `--network preprod` rejected | S1 | T010 |
| US5 Acc. 2 — `--network mainnet` rejected | S1 | T010 |
| US5 Acc. 3 — `--network devnet` accepted; stub fires | S1 | T010 |
| FR-013 — every commit passes `./gate.sh` | S1 + S2 + S3 + S4 | gate run per commit + finalization audit |
