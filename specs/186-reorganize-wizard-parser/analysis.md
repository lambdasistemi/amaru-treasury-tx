# Cross-Artifact Consistency Analysis

**Date**: 2026-05-22
**Source**: inline orchestrator-authored analysis (the
`speckit-analyze` subagent dispatch hit consecutive 529 overload
errors from the Anthropic API; the autonomous-drive authorization
covers proceeding without it, and the orchestrator authored every
artifact in the same session). The analysis follows the same
read-only cross-check protocol an external `speckit-analyze`
worker would perform.
**Artifacts reviewed**:

- `specs/186-reorganize-wizard-parser/spec.md` @ `0e201582`
- `specs/186-reorganize-wizard-parser/plan.md` @ `f8b2c9a7`
- `specs/186-reorganize-wizard-parser/tasks.md` @ `64b0a8aa`
- `specs/186-reorganize-wizard-parser/research.md`
- `specs/186-reorganize-wizard-parser/data-model.md`
- `specs/186-reorganize-wizard-parser/contracts/{parser-flag,exit-code,dispatcher-wiring}-contract.md`

## 1. Gaps (spec → tasks)

Every `FR-NNN`, `SC-NNN`, and User Story acceptance scenario in
`spec.md` maps to at least one task ID in `tasks.md`:

| spec entry | tasks.md backing |
|---|---|
| FR-001 (parser exposed) | T003 |
| FR-002 (Answers + ReorganizeError) | T002 |
| FR-003 (Cmd arm + cmdP entry) | T012 |
| FR-004 (Main.hs runner case) | T013 |
| FR-005 (pre-flight + stub runner) | T004 |
| FR-006 (eitherReader txInFromText) | T003 |
| FR-007 (--network devnet rejection) | T004 + T010 |
| FR-008 (required flags) | T003 |
| FR-009 (cabal exposes modules) | T005 |
| FR-010 (parser tests) | T001 + T006..T010 |
| FR-011 (gate.sh green per commit) | T010 + T014 + finalization_audit |
| FR-012 (don't touch #185 library) | covered by per-slice owned-files |
| SC-001..SC-008 | acceptance-scenario matrix maps to T0XX |
| US1..US5 acceptance | T006..T010 + T011 (dispatch) |

**Verdict**: no gaps.

## 2. Dead tasks (tasks → spec)

Every `T-` task in `tasks.md` traces to a `FR-NNN` / `SC-NNN` /
US acceptance scenario:

- T001 — FR-010 (parser test RED proof)
- T002 — FR-002
- T003 — FR-001 + FR-006 + FR-008
- T004 — FR-005 + FR-007 (pre-flight)
- T005 — FR-009
- T006..T010 — FR-010 + US1..US5 acceptance
- T011 — Dispatch test, FR-003 verification
- T012 — FR-003
- T013 — FR-004
- T014 — FR-011 + manual US1 Acc.1 verification
- T015 — Q-001-C1 → C2 spec amendment (also see contradiction #1 widening below)

**Verdict**: no dead tasks.

## 3. Contradictions

### 3.1 KNOWN — Q-001-C1 → C2 wording (S3-pending)

`spec.md` User Story 5 + FR-007 currently say "rejected at the
parser". `plan.md` § Q-001 verdicts, `research.md` §5,
`tasks.md` T015, and the
`contracts/exit-code-contract.md` Pre-flight ordering all
document the refined C2 (pre-flight runner check). The
contradiction is **intentionally captured for S3's T015 docs
amendment**; the implementation slices S1 + S2 will ship code
matching the C2 wording.

**Status**: known + tracked. **Not a blocker**.

### 3.2 NEW FINDING — `--registry` vs `--metadata` (verdict α)

`spec.md` references `--registry` in 8+ places (User Story 3 +
Independent Test + acceptance scenarios + several Success
Criteria + Quickstart-tier flag list). Under verdict α
(approved at A-002), the shipped flag is `--metadata`
(sibling-consistent). `contracts/parser-flag-contract.md`
documents the verdict-α flag inventory using `--metadata`;
`tasks.md`'s S1 task descriptions reference `--metadata`; the
S1 acceptance-scenario matrix has a footnote ("US3 Acc. 1 —
missing `--registry` (= `--metadata`, verdict α)").

The post-S1 implementation will reject `Missing: --metadata`
rather than `Missing: --registry`. The User Story 3 parser test
(T008) MUST assert `--metadata` (correct in tasks.md), but the
`spec.md` US3 wording still says `--registry`.

**Status**: S3-pending. **Not a blocker** — but T015's scope
must broaden to cover this in addition to the C2 wording
amendment. The amendment is mechanical (a global rename of
`--registry` → `--metadata` in `spec.md` would suffice, except
for the few places where the spec is *explaining* the issue's
original wording — those should be preserved with a "the
issue's `--registry` is amended to `--metadata` per verdict α"
gloss).

**Recommended action**: widen T015's description in `tasks.md`
to enumerate every `--registry` reference that needs amendment,
OR add a sibling task T016 explicitly. The orchestrator will
broaden T015 in a follow-up `docs(tasks):` commit before S3
fires.

### 3.3 Module-naming alignment

Spec.md, plan.md, tasks.md, data-model.md, and the three
contracts all consistently name the new modules
`Amaru.Treasury.Cli.ReorganizeWizard` and
`Amaru.Treasury.Tx.ReorganizeWizard`. No drift.

### 3.4 Commit-subject alignment

Spec.md does not pin commit subjects (correct — it should not).
Plan.md and tasks.md agree on:

- S1: `feat(cli): reorganize-wizard parser + stub runner`
- S2: `feat(cli): wire reorganize-wizard subcommand into dispatcher`
- S3: `docs(spec): amend Q-001-C1 → C2 wording for --network rejection tier`
- S4: `chore: drop gate.sh (ready for review)`

No drift.

## 4. Risks acknowledged but uncovered

Every risk in plan.md's Risks + Mitigations section has at
least one covering task or contract clause:

- **R1** (C1 → C2 amendment) → T015 ✓
- **R2** (exitWith capture) → T004 introduces
  `runReorganizeWizardEither` helper ✓
- **R3** (optparse-applicative version drift) → tasks T006..T008
  enforce substring assertions, not exact-string equality ✓
- **R4** (--metadata flag tension) → contracts and tasks
  ship verdict α directly; T015 should widen per §3.2
- **R5** (pre-flight ordering) → `contracts/exit-code-contract.md`
  pins the order; T004 implements it ✓

**Verdict**: all risks covered.

## 5. Constitution conflicts

N/A — this repository has no `/memory/constitution.md`.

## 6. Verdict

**READY for implementation**, with one mechanical follow-up
before S3:

- Broaden `tasks.md` T015 to cover the `--registry` →
  `--metadata` wording amendment (§3.2 above) alongside the
  Q-001-C1 → C2 wording amendment. The widening lands as a
  separate `docs(tasks):` orchestrator-owned commit BEFORE S1
  dispatch (so the workers see the broadened T015 description
  in their owned-files context).

S1 dispatch proceeds after the T015-widening commit lands.
