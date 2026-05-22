# Implementation Plan — `186-reorganize-wizard-parser`

**Feature Branch**: `186-reorganize-wizard-parser`
**Created**: 2026-05-22
**Status**: Draft (Plan phase)
**GitHub Issue**: [#186](https://github.com/lambdasistemi/amaru-treasury-tx/issues/186)
**Parent Epic**: [#189](https://github.com/lambdasistemi/amaru-treasury-tx/issues/189)
**Spec**: [`spec.md`](./spec.md) — Q-001 resolved (A1 / B1 / **C2**).
**Companion artifacts**:

- [`research.md`](./research.md) — design decisions, alternatives, and the Q-001-C1 → C2 plan-time discovery.
- [`data-model.md`](./data-model.md) — typed shapes (`ReorganizeWizardOpts`, `Answers`, `ReorganizeError`).
- [`contracts/`](./contracts/) — parser flag-set contract, exit-code contract, dispatcher-wiring contract.
- [`quickstart.md`](./quickstart.md) — operator's-eye view of the CLI surface this slice produces.

> This is the **CLI parser scaffold** slice (epic #189 child 2 of 5). It
> produces an operator-facing subcommand whose `--help` lists the
> documented flag set; invocation with valid flags surfaces a typed
> `TODO Slice C` error from the stub runner. No chain query, no UTxO
> selection, no validity-bound sampling, no intent encoding — those
> belong to #187. Sibling children #187/#87/#188 are blocked on this
> slice landing first (parser-and-runner are co-owned modules; #187
> extends what this slice scaffolds).

## Ownership split

| Role | Owns |
|---|---|
| Orchestrator (attx-186) | `spec.md`, `plan.md`, `tasks.md`, `research.md`, `data-model.md`, `contracts/`, `quickstart.md`, `gate.sh`, PR metadata, slice briefs, vertical-slice review, finalization audit, post-merge cleanup. |
| Slice executor (one paired driver+navigator per slice) | Owned files listed per slice below; produces exactly one bisect-safe commit per run with a `Tasks:` trailer. Does not push. |

## Q-001 verdicts (epic-owner-approved + plan-time refinement)

| Question | Verdict at spec time | Plan-time outcome |
|---|---|---|
| **A**: `--scope` as a required CLI flag? | A1 (yes, sibling-mirrored) | **A1 confirmed** — `--scope` is required at parse time; the parser reuses the shared `scopeReader` from siblings. |
| **B**: Sibling-mirrored shared flags (rationale + `--validity-hours` + `--metadata` + `--force`) in this scaffold? | B1 (include them now) | **B1 confirmed** — the parser exposes the full sibling-mirrored shared flag block; parser tests cover only the issue-enumerated five. |
| **C**: Where does the `--network devnet` check live? | C1 (parser-time custom `ReadM`) | **Refined to C2** — pre-flight runner check, before any chain query / file write / socket open. C1 is architecturally infeasible: `--network` is owned by the **global** parser (`globalOptsP` in `Amaru.Treasury.Cli.Common`), and a wizard-subcommand `--network` flag would shadow / conflict with the global flag. See [`research.md` §C](./research.md#q-001-c1--c2-plan-time-discovery). The behavior the issue AC requires (rejection before any work happens) is preserved verbatim; only the implementation tier changes. |

The C1 → C2 refinement requires a one-line wording amendment to
`spec.md` (User Story 5 + FR-007: "rejected at the parser" → "rejected
before any chain query, file write, or socket open"). The amendment
is captured as task **T015** below and lands in the same `docs(spec):`
commit that ships the refinement; the rest of the spec wording is
unchanged.

## Vertical slice plan (bisect-safe)

The work decomposes into **two implementation slices** plus the
mandatory `chore: drop gate.sh` finalization commit. Each implementation
slice is one paired driver+navigator run producing exactly one
bisect-safe commit. Every commit compiles, every commit's `./gate.sh`
is green at HEAD.

### S1 — types + parser + `--out` pre-flight + runner stub + parser/pre-flight/network-guard tests (RED → GREEN)

**Goal:** ship the **library-only** half of the parser scaffold —
the new modules `Amaru.Treasury.Tx.ReorganizeWizard` (Answers +
`ReorganizeError`) and `Amaru.Treasury.Cli.ReorganizeWizard`
(parser + `validateOutPath` + `runReorganizeWizard` stub), plus the
parser test spec covering User Stories 1–5. The new modules are
exposed by the cabal `library` stanza but NOT yet wired into the
top-level `Cmd` sum or `Main.hs` dispatcher — so the CLI binary's
`--help` does NOT yet list `reorganize-wizard`. This deliberate
half-step keeps the slice bisect-safe (every commit on the branch
compiles and tests pass), and leaves S2 with one focused responsibility
(CLI binding).

**Owned files (S1 only):**

- `lib/Amaru/Treasury/Tx/ReorganizeWizard.hs` (NEW) — Answers record,
  `ReorganizeError` sum, the `Opts → Answers` projection (used by
  the runner stub). See [`data-model.md` §1](./data-model.md#1-reorganizewizardanswers)
  and [`data-model.md` §2](./data-model.md#2-reorganizeerror).
- `lib/Amaru/Treasury/Cli/ReorganizeWizard.hs` (NEW) — option
  records (`ReorganizeWizardOpts`, `CommonFlags`), the
  `reorganizeWizardOptsP :: Parser ReorganizeWizardOpts` parser,
  the shared `ReadM` helpers (`txInReader`, `scopeReader`),
  `validateOutPath`, and the stub `runReorganizeWizard ::
  GlobalOpts -> ReorganizeWizardOpts -> IO ()`. See
  [`contracts/parser-flag-contract.md`](./contracts/parser-flag-contract.md)
  for the flag-set inventory and
  [`contracts/exit-code-contract.md`](./contracts/exit-code-contract.md)
  for the pre-flight + stub-runner exit-code matrix.
- `amaru-treasury-tx.cabal` — expose both new modules in the
  `library` stanza's `exposed-modules` list (alphabetically ordered,
  matching existing convention).
- `test/unit/Amaru/Treasury/Cli/ReorganizeWizardParserSpec.hs` (NEW)
  — the consolidated test spec covering User Stories 1–5 via:
  - `Options.Applicative.execParserPure reorganizeWizardOptsP` for
    User Stories 1 (`--help`), 2 (malformed `--funding-seed-txin`),
    3 (missing required flag).
  - direct calls to `validateOutPath` for User Story 4
    (`ReorganizeOutputParentMissing _`).
  - direct calls to `runReorganizeWizard` (the stub) with a
    `GlobalOpts{goNetworkName = Just "preprod"|"mainnet"|"preview"}`
    for User Story 5 (typed `ReorganizeNonDevnetNetwork` error,
    exit code 2). Pattern mirrors
    `Amaru.Treasury.Tx.RegistryInitWizardNetworkGuardSpec`.

**S1's RED:**

- The test spec file references modules
  `Amaru.Treasury.Tx.ReorganizeWizard` and
  `Amaru.Treasury.Cli.ReorganizeWizard` that do not exist yet
  → compile-time RED.

**S1's GREEN:**

- Implement both new modules. Re-running `nix develop -c just unit`
  → all five User Story scenarios pass via `execParserPure` and
  direct library calls.

**Gate evidence for S1:**

- `nix develop --quiet -c just unit --match "ReorganizeWizardParser"`
  passes.
- `nix develop --quiet -c just unit` passes (full suite — no
  regressions in sibling wizards).
- `./gate.sh` passes (full build + ci + commit-message gate).

**Commit subject:** `feat(cli): reorganize-wizard parser + stub runner`
**Tasks closed by this commit:** T001..T010 (see `tasks.md`).

---

### S2 — dispatcher wire-up + `Main.hs` runner case + dispatch test (RED → GREEN)

**Goal:** wire the new parser + runner into the top-level CLI
surface. After this slice, an operator running `amaru-treasury-tx
reorganize-wizard --help` sees the documented flag set;
`amaru-treasury-tx reorganize-wizard --funding-seed-txin <bad>` is
rejected; valid invocation surfaces the typed `ReorganizeTodoSliceC`
error.

**Owned files (S2 only):**

- `lib/Amaru/Treasury/Cli.hs` — add
  `CmdReorganizeWizard ReorganizeWizardOpts` constructor to the
  `Cmd` sum; add a `command "reorganize-wizard"` entry in `cmdP`
  with a one-line `progDesc` matching the sibling wizards' format
  (mirroring lines 191–198's `registry-init-wizard` entry); add
  the matching `import Amaru.Treasury.Cli.ReorganizeWizard
  (ReorganizeWizardOpts, reorganizeWizardOptsP)` import.
- `app/amaru-treasury-tx/Main.hs` — add a `CmdReorganizeWizard rwo
  -> runReorganizeWizard g rwo` arm (mirroring the
  `CmdRegistryInitWizard` arm at lines 106–107); add the matching
  `import Amaru.Treasury.Cli.ReorganizeWizard (runReorganizeWizard)`
  import.
- `test/unit/Amaru/Treasury/Cli/ReorganizeWizardDispatchSpec.hs` (NEW)
  — one focused spec asserting `execParserPure opts [..., "reorganize-wizard", "--help"]`
  succeeds at parse time (no `UnknownCommand` failure). Mirrors the
  shape of any sibling dispatch test if one exists, or is the first
  such spec (sibling wizards have rich runner specs but rely on
  parser-level tests for dispatch).

**S2's RED:**

- New `ReorganizeWizardDispatchSpec` is added first, referencing
  `Amaru.Treasury.Cli.opts` parsing of the `reorganize-wizard`
  subcommand. Before the `Cmd` arm + `cmdP` entry are added, the
  top-level parser rejects `reorganize-wizard` as `UnknownCommand`
  → test-time RED.

**S2's GREEN:**

- Wire the `CmdReorganizeWizard` arm in `Cli.hs` and the matching
  `Main.hs` runner case → `execParserPure opts ["reorganize-wizard",
  "--help"]` succeeds (or the parser returns a `Failure` whose
  message includes the help text — `execParserPure` returns
  `Failure` on `--help` by convention, which is asserted as a
  positive case via `renderFailure` and pattern matching).

**Gate evidence for S2:**

- `nix develop --quiet -c just unit --match "ReorganizeWizardDispatch"`
  passes.
- `nix develop --quiet -c just unit` passes (no regressions in
  sibling dispatch / runner tests).
- `nix develop --quiet -c just ci` passes (full all-up gate).
- `./gate.sh` passes.
- Acceptance scenarios from `spec.md` all hold (see "Acceptance
  scenario coverage" matrix below).

**Commit subject:** `feat(cli): wire reorganize-wizard subcommand into dispatcher`
**Tasks closed by this commit:** T011..T014 (see `tasks.md`).

---

### S3 — spec wording amendment for Q-001-C1 → C2 refinement (orchestrator-owned, docs-only)

**Goal:** amend `spec.md`'s User Story 5 and FR-007 wording from
"rejected at the parser" to "rejected before any chain query,
file write, or socket open" — capturing the C1 → C2 plan-time
refinement on the spec itself, so future readers do not see a
contradiction between `spec.md`'s User Story 5 (parser-time) and
the implementation (pre-flight tier).

**Owned files (S3 only):**

- `specs/186-reorganize-wizard-parser/spec.md` — two-line edits
  to User Story 5's heading + the Independent Test sentence, and
  one-line edit to FR-007.

**S3 is orchestrator-owned** (no driver+navigator dispatch needed
— this is a docs-only edit on a spec the orchestrator owns).
The commit is a `docs(spec):` chore exempt from the `Tasks:`
trailer requirement (per `gate.sh`'s `commit_gate` function); the
matching `tasks.md` checkbox T015 is marked checked in the same
amend before pushing.

**Commit subject:** `docs(spec): amend Q-001-C1 → C2 wording for --network rejection tier`
**Tasks closed by this commit:** T015.

---

### S4 — drop gate.sh + mark ready (orchestrator-owned, chore-only)

**Goal:** drop `gate.sh` from the worktree and mark the PR ready
for review. Final commit on the branch; no behavior change.

**Owned files (S4 only):**

- `gate.sh` — removed via `git rm gate.sh`.

**S4 is orchestrator-owned** (`chore:` exempt from `Tasks:` trailer
requirement). Before commit: run `finalization_audit` from the
`gate-script` skill; confirm every task in `tasks.md` is `[X]`;
confirm `git diff --check` is clean; confirm full `nix develop -c
just ci` passes (the same ci `gate.sh` would have run).

**Commit subject:** `chore: drop gate.sh (ready for review)`

After commit:

- `git push`
- `gh pr ready 195`
- Append `COMPLETE` + `NOTE PR #195 marked ready for review` to
  STATUS.md.

---

## Acceptance scenario coverage matrix

| Spec scenario | Slice | Test/evidence |
|---|---|---|
| US1 Acc. 1 — `reorganize-wizard --help` lists flag set | S1 (parser exists) → S2 (subcommand visible from binary) | `ReorganizeWizardParserSpec` via `execParserPure reorganizeWizardOptsP` (S1) + `ReorganizeWizardDispatchSpec` via `execParserPure opts` (S2) |
| US1 Acc. 2 — `amaru-treasury-tx --help` lists `reorganize-wizard` | S2 | `ReorganizeWizardDispatchSpec` |
| US2 Acc. 1 — malformed `--funding-seed-txin` rejected | S1 | `ReorganizeWizardParserSpec` (negative case via `execParserPure`) |
| US2 Acc. 2 — alternative malformed shapes rejected | S1 | `ReorganizeWizardParserSpec` (table of malformed strings) |
| US3 Acc. 1 — missing `--registry` rejected with `Missing:` | S1 | `ReorganizeWizardParserSpec` |
| US3 Acc. 2 — missing `--wallet-addr` rejected | S1 | `ReorganizeWizardParserSpec` |
| US3 Acc. 3 — missing `--funding-seed-txin` rejected | S1 | `ReorganizeWizardParserSpec` |
| US3 Acc. 4 — missing `--out` rejected | S1 | `ReorganizeWizardParserSpec` |
| US4 Acc. 1 — `--out` parent missing → `ReorganizeOutputParentMissing` exit 2 | S1 | `ReorganizeWizardParserSpec` (calls `validateOutPath` directly) |
| US4 Acc. 2 — valid `--out` parent → pre-flight passes; stub fires `ReorganizeTodoSliceC` | S1 | `ReorganizeWizardParserSpec` (calls `runReorganizeWizard` with valid args, captures `IO` via `try` or runs in a sandbox dir) |
| US5 Acc. 1 — `--network preprod` rejected (pre-flight tier per C2) | S1 | `ReorganizeWizardParserSpec` (calls `runReorganizeWizard` with `goNetworkName = Just "preprod"`, asserts `ReorganizeNonDevnetNetwork`) |
| US5 Acc. 2 — `--network mainnet` rejected | S1 | `ReorganizeWizardParserSpec` (same shape, different network) |
| US5 Acc. 3 — `--network devnet` accepted, stub fires `ReorganizeTodoSliceC` | S1 | `ReorganizeWizardParserSpec` |
| FR-013 — every commit passes `./gate.sh` | S1 + S2 + S3 + S4 | gate run per commit + finalization audit |

## Risks + mitigations

- **R1 — Q-001-C1 → C2 refinement requires spec amendment.**
  Detected at plan time; mitigated by S3 (docs-only spec edit
  ship in the same PR). Q-002-plan-ready will surface this for
  the epic-owner's read receipt; the autonomous-drive default is
  to proceed with C2 (the only architecturally feasible
  implementation) since C1's literal "custom ReadM in
  reorganizeWizardOptsP" would require shadowing the global
  `--network` flag, which conflicts with every other wizard.
- **R2 — Capturing `exitWith` from the stub runner inside tests.**
  Sibling wizards' runners call `exitWith (ExitFailure n)`. The
  parser spec tests for User Stories 4 + 5 must intercept this:
  either via `Control.Exception.try @ExitCode` (catches the
  `ExitException` thrown by `exitWith`) or via running the runner
  in a subprocess. The `try` approach is cleaner and matches
  what `Amaru.Treasury.Tx.RegistryInitWizardNetworkGuardSpec`
  does for the resolver-Identity pattern. The S1 brief instructs
  the slice executor to use `try` (or a typed-returning helper
  like `validateOutPath`, which is the chosen split for the
  `--out` pre-flight).
- **R3 — `optparse-applicative` version drift.** Sibling parser
  tests depend on the `Missing:` error wording. If the cabal
  freeze drifts during this PR, the assertion would break.
  Mitigation: parser tests assert that the failure's rendered
  output **contains** the flag name (not the full error string).
  This matches sibling test patterns.
- **R4 — `--metadata` flag tension.** The shared `CommonFlags` of
  every other wizard includes `--metadata` (path to
  `journal/2026/metadata.json`). Reorganize at #187 will need
  this (to extract the scope-owner signer via `build_signers`).
  Verdict B1 says ship the sibling-mirrored block now. The
  parser tests do NOT need to assert `--metadata`'s presence —
  the issue ACs don't enumerate it. If a slice executor cuts
  it as "not in the issue", the next slice (#187) would have
  to widen the parser. Mitigation: the S1 brief is explicit
  about the full sibling-mirrored flag set under verdict B1;
  the contract document
  [`contracts/parser-flag-contract.md`](./contracts/parser-flag-contract.md)
  enumerates every flag.
- **R5 — Order of `validateOutPath` vs. `--network` check.**
  Both are pre-flight tiers. The natural order is: parse →
  `validateOutPath` (cheapest, file-system only) → network
  guard (string comparison) → stub runner. Reversing has no
  observable difference at the User Story acceptance level.
  Mitigation: contract documented in
  [`contracts/exit-code-contract.md`](./contracts/exit-code-contract.md).

## Proof strategy summary

Every behavior change has a paired RED/GREEN in **the same commit**:

- **S1 — RED:** parser spec file references modules that don't
  exist → compile-time fail. **GREEN:** add the two new modules
  → spec compiles and all five User Story scenarios pass.
- **S2 — RED:** dispatch spec asserts `reorganize-wizard` is a
  recognized subcommand at the top-level parser → fails because
  the `Cmd` sum doesn't have an arm and `cmdP` doesn't have a
  `command` entry. **GREEN:** wire both → dispatch spec passes.
- **S3 — docs-only:** no proof needed; the spec amendment is
  self-evident from the diff.
- **S4 — chore-only:** no proof needed; final ci/gate run is the
  proof.

The amend-once-on-acceptance rule (mark `tasks.md` checkboxes in
the same slice commit) applies — see the `gate-script` skill's
"Stamping a reviewed slice" section.

## Live-boundary diagnostic

> "What system boundary does this exercise that the unit suite cannot?"

**Answer: none.** This slice is a pure parser + stub runner. The
unit suite covers every behavior change end-to-end via
`execParserPure` and direct library-function calls. The
live-system boundary (cardano-node N2C, real chain query, real
file write to a real `--out` path) is #187's concern; the
live-boundary smoke is #87's concern.

This is explicitly acceptable per the `live-boundary-smoke` skill:
the parser scaffold has no boundary to smoke. Sibling tickets
carry the live-boundary responsibilities:

- **#187** — DevNet N2C resolver, chain tip, treasury UTxO query,
  validity bound, intent encode, real file write.
- **#87** — live CLI invocation through DevNet, exec-units assertion.

No operator follow-up named in this PR — sibling tickets are
already filed and depend on this merging first.

## Deliverables enumeration (peer-surface coverage)

For each deliverable in `spec.md` § Deliverables, the canonical
peer artifact is the most recent sibling parser scaffold,
`Amaru.Treasury.Cli.RegistryInitWizard` (shipped under #158 in
the same "Slice 1: parser scaffold" pattern this ticket
replicates). Surface discovery via the canonical command:

```
$ git grep -l 'RegistryInitWizard\|registry-init-wizard' \
    .github/ flake.nix nix/ docs/ README.md CHANGELOG.md 2>/dev/null
.github/workflows/release.yml          # (none — verified empirically)
flake.nix                              # (none — handled via project.nix and the cabal stanza)
README.md                              # (none — siblings are documented at #188-tier)
```

No `release.yml`, `flake.nix`, README, or CHANGELOG entry exists
for the sibling `RegistryInitWizard`; it lives entirely in the
cabal `library` stanza + cabal `executable` stanza + `test-suite
unit-tests`. **Conclusion: no release / packaging / docs surfaces
beyond cabal are involved in this slice.** The asciinema cast +
operator README section + docs page live with the runner-shipping
slice in #188.

| Deliverable | Peer artifact | Peer surfaces | This slice ships? |
|---|---|---|---|
| `lib/Amaru/Treasury/Cli/ReorganizeWizard.hs` (NEW) | `lib/Amaru/Treasury/Cli/RegistryInitWizard.hs` | cabal `library` stanza | yes (S1) |
| `lib/Amaru/Treasury/Tx/ReorganizeWizard.hs` (NEW) | `lib/Amaru/Treasury/Tx/RegistryInitWizard.hs` | cabal `library` stanza | yes (S1) |
| `amaru-treasury-tx.cabal` (expose modules) | cabal `library.exposed-modules` list | cabal | yes (S1) |
| `test/unit/Amaru/Treasury/Cli/ReorganizeWizardParserSpec.hs` (NEW) | `test/unit/Amaru/Treasury/Tx/RegistryInitWizardNetworkGuardSpec.hs` (closest analog) | cabal `test-suite unit-tests` | yes (S1) |
| `lib/Amaru/Treasury/Cli.hs` (dispatch arm) | `Cli.hs` existing `CmdRegistryInitWizard` arm | cabal `library` stanza | yes (S2) |
| `app/amaru-treasury-tx/Main.hs` (runner case) | `Main.hs` existing `CmdRegistryInitWizard` case | cabal `executable amaru-treasury-tx` | yes (S2) |
| `test/unit/Amaru/Treasury/Cli/ReorganizeWizardDispatchSpec.hs` (NEW) | (no direct peer — first of its kind) | cabal `test-suite unit-tests` | yes (S2) |
| `gate.sh` removed | — | (worktree-only) | yes (S4) |

## Phase-stop assets ready

- [x] `gate.sh` committed (`b1089da9`)
- [x] `spec.md` committed (`0e201582`)
- [ ] `plan.md` committed (this commit, with `research.md`,
      `data-model.md`, `contracts/`, `quickstart.md`)
- [ ] Block on `Q-002-plan-ready` for plan-review verdict
- [ ] After verdict: `tasks.md` (`/speckit.tasks`) → analyzer pass
      → S1 dispatch → S2 dispatch → S3 spec amend → S4 finalization
