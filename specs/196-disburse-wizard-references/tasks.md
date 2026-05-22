---
description: "Task list for #196 disburse-wizard references[]"
---

# Tasks: `disburse-wizard --reference` flags + `RationaleBody.references`

**Input**: Design documents under `specs/196-disburse-wizard-references/`
**Prerequisites**: [spec.md](spec.md), [plan.md](plan.md), [research.md](research.md), [data-model.md](data-model.md), [contracts/cli.md](contracts/cli.md), [contracts/intent-schema.md](contracts/intent-schema.md), [quickstart.md](quickstart.md)

**Tests**: explicitly required per Constitution Principle V
(test-first golden CBOR, NON-NEGOTIABLE). Each behaviour-changing
slice ships RED + GREEN folded into the same bisect-safe commit.

**Organization**: tasks are grouped by **slice** (per [plan.md
"Vertical slice breakdown"](plan.md#vertical-slice-breakdown)). Each
slice maps to **one** driver+navigator pair run producing **one**
bisect-safe commit with a `Tasks: T###[, T###]` trailer.

## Format

`[T###] [Slice] Description`

The numbering is monotonic across slices; the `[Slice]` tag
identifies the slice the task lands in. Task IDs cited in commit
`Tasks:` trailers MUST match.

---

## Slice S1 — Library shape change + golden CBOR test

**Goal**: introduce `RationaleReference` + `RationaleBody.rbReferences`
and serialise to `body.references[]` matching the d6c14625 mainnet
precedent byte-for-byte.

**Driver+navigator brief**: see "Paired worker brief — Slice S1" at
the bottom of this file.

**Spec acceptance**:
[FR-001](spec.md#functional-requirements),
[FR-002](spec.md#functional-requirements),
[FR-006](spec.md#functional-requirements),
[SC-001](spec.md#success-criteria),
[SC-002](spec.md#success-criteria).

**Owned files**:
- `lib/Amaru/Treasury/AuxData.hs`
- `test/fixtures/disburse/d6c14625-references/intent.json` (NEW)
- `test/fixtures/disburse/d6c14625-references/rationale.cbor` (NEW)
- `test/unit/ReferencesSpec.hs` (NEW)
- `amaru-treasury-tx.cabal` (test module wiring only — version bump deferred to S5)

### Tasks

- [ ] **T001 [S1]** Fetch the d6c14625 rationale metadatum from
  Blockfrost (`/txs/d6c14625…/metadata`), encode label-1694
  metadatum to canonical CBOR, write to
  `test/fixtures/disburse/d6c14625-references/rationale.cbor`. Add a
  `README.md` next to it naming the source tx, block, fetch date, and
  the Blockfrost call. (Fixture is the golden contract — must be
  byte-equal to chain.) See [research.md R7](research.md#r7-golden-cbor-provenance-for-d6c14625).
- [ ] **T002 [S1]** Write
  `test/fixtures/disburse/d6c14625-references/intent.json` with the
  inputs that match the d6c14625 rationale verbatim: two references
  (RCA `bafybei…dbls2l4` labelled "Remunerated Contributor
  Agreement - Rust optimisations" + Invoice `bafkrei…ytotu`
  labelled "Invoice - January February March Rust optimisation"),
  same `description` / `destination.label` / `justification` text as
  on chain.
- [ ] **T003 [S1]** Add `test/unit/ReferencesSpec.hs` with the golden
  CBOR test: load the intent, build the rationale metadatum
  in-process, encode to canonical CBOR, assert byte equality against
  `rationale.cbor`. RED expected (function doesn't exist yet).
- [ ] **T004 [S1]** Wire `ReferencesSpec` into
  `amaru-treasury-tx.cabal` test stanza (alongside existing
  `*Spec` modules).
- [ ] **T005 [S1]** Confirm RED: `nix develop --quiet -c just unit
  ReferencesSpec` fails with "rbReferences not in scope" (or
  equivalent). Capture the failing output in `./WIP.md` per the
  pair-programming brief.
- [ ] **T006 [S1]** Add `data RationaleReference = RationaleReference
  { rrUri, rrType, rrLabel :: !Text }` to
  `lib/Amaru/Treasury/AuxData.hs` (export list updated).
- [ ] **T007 [S1]** Add `rbReferences :: ![RationaleReference]` to
  `RationaleBody`. Default `[]` for every existing helper
  (`swapRationaleMetadatum`, `disburseRationaleMetadatum`, and any
  other internal constructor) so existing fixtures stay byte-equal.
- [ ] **T008 [S1]** Implement `splitUri :: Text -> Either String [Text]`
  per [research.md R2](research.md#r2-uri-chunking-strategy).
- [ ] **T009 [S1]** Implement `splitLabel :: Text -> Either String [Text]`
  per [research.md R3](research.md#r3-label-chunking-strategy).
- [ ] **T010 [S1]** Implement `rationaleMetadatum` to emit
  `body.references = List [Map …]` from `rbReferences`, using
  `splitUri` and `splitLabel`. When `rbReferences` is `[]`, emit
  `List []` (preserves prior bytes).
- [ ] **T011 [S1]** Confirm GREEN: `nix develop --quiet -c just unit
  ReferencesSpec` passes; `nix develop --quiet -c just unit` passes
  end-to-end (every prior `*Spec` still green).
- [ ] **T012 [S1]** Run `./gate.sh` from worktree root; must be green.
- [ ] **T013 [S1]** Commit one bisect-safe slice: subject
  `feat(auxdata): add RationaleBody.rbReferences with d6c14625 golden`,
  body explains the golden contract, trailer `Tasks: T001, T002, T003,
  T004, T005, T006, T007, T008, T009, T010, T011, T012`. No push.
- [ ] **T014 [S1]** (orchestrator-only, on acceptance) Mark T001–T013
  `[X]` in `tasks.md`, amend HEAD to include the checkbox updates
  (per resolve-ticket § "Reviewing Worker Pair Output").

**Checkpoint S1**: library can emit `body.references[]` matching the
d6c14625 precedent. No CLI exposure yet.

---

## Slice S2 — Schema entry for `references`

**Goal**: `intent.json` schema accepts optional `references` field on
the disburse rationale block; existing intents continue to validate.

**Spec acceptance**:
[FR-004](spec.md#functional-requirements),
[SC-002](spec.md#success-criteria).

**Owned files**:
- `lib/Amaru/Treasury/IntentJSON/Schema.hs`
- `lib/Amaru/Treasury/IntentJSON.hs` (FromJSON/ToJSON for
  `RationaleJSON` only — to add the new field round-trip)
- `assets/schema/intent.schema.json` (regenerated by `just update-schema`)
- `test/unit/SchemaSpec.hs` (or `IntentJSONSpec.hs` — extend existing)

### Tasks

- [ ] **T015 [S2]** Add the schema entry per
  [contracts/intent-schema.md](contracts/intent-schema.md). Field
  optional, default `[]`, items require `uri` + `label`, `@type`
  defaults to `"Other"`, `additionalProperties: false`.
- [ ] **T016 [S2]** Update `RationaleJSON` (and the FromJSON/ToJSON
  instances) to round-trip `references`. `ToJSON` MUST emit
  `"references": []` when empty (not omit the field) so schema and
  emitted JSON stay symmetric.
- [ ] **T017 [S2]** Add a QuickCheck round-trip property:
  `decode (encode r) == Just r` for every well-formed
  `RationaleReferenceJSON`. Lives in the existing JSON test module.
- [ ] **T018 [S2]** Add a round-trip test for the intent.json fixture
  from T002 (parse → re-emit → re-parse equals).
- [ ] **T019 [S2]** Confirm RED on T017/T018 before T015/T016 edits
  land (the new property/test fails — field doesn't round-trip yet).
- [ ] **T020 [S2]** Run `nix develop --quiet -c just update-schema`,
  commit the regenerated `assets/schema/intent.schema.json` diff in
  the same slice commit.
- [ ] **T021 [S2]** Run `nix develop --quiet -c just schema-check`
  green; `nix develop --quiet -c just unit` green; `./gate.sh` green.
- [ ] **T022 [S2]** Commit one bisect-safe slice: subject
  `feat(intent-json): allow references on disburse rationale (schema + round-trip)`,
  trailer `Tasks: T015–T021`. No push.
- [ ] **T023 [S2]** (orchestrator-only) Mark T015–T022 `[X]`, amend
  HEAD.

**Checkpoint S2**: intent.json with `references[]` round-trips
cleanly and validates against the published schema.

---

## Slice S3 — CLI flags on `disburse-wizard`

**Goal**: `disburse-wizard` accepts repeatable `--reference-uri /
--reference-type / --reference-label` flags per
[contracts/cli.md](contracts/cli.md). No other wizard touched.

**Spec acceptance**:
[FR-003](spec.md#functional-requirements),
[FR-006](spec.md#functional-requirements),
[SC-004](spec.md#success-criteria),
[Acceptance Scenarios 1–5](spec.md#acceptance-scenarios).

**Owned files**:
- `app/amaru-treasury-tx/Main.hs` OR the wizard parser module
  (worker pair locates the disburse-wizard parser; existing
  per-wizard module structure already exists in the repo)
- `test/unit/DisburseWizardSpec.hs` (or extend the existing
  wizard-parser test module)

### Tasks

- [ ] **T024 [S3]** Locate the `disburse-wizard` parser in
  `app/amaru-treasury-tx/Main.hs` (or the per-wizard module the
  current codebase uses). Record its location in `./WIP.md`.
- [ ] **T025 [S3]** Write parser tests covering the matrix in
  [contracts/cli.md#slot-opening-rule](contracts/cli.md#slot-opening-rule):
  zero flags, one slot with default `@type`, two slots, stray
  `--reference-label` (must exit 2 with named error), stray
  `--reference-type` (same), later `--reference-type` wins.
- [ ] **T026 [S3]** Confirm RED: parser tests fail (flags don't exist
  / errors aren't raised). Capture in `./WIP.md`.
- [ ] **T027 [S3]** Implement the three flags using
  `optparse-applicative`. The slot-opening model uses a custom
  accumulating parser; the simplest shape is a tagged sum
  `ReferenceFragment = OpenUri Text | SetType Text | SetLabel Text`
  parsed with `many` then folded into `[RationaleReferenceJSON]`,
  raising a parse error when a `SetType` / `SetLabel` appears before
  any `OpenUri`.
- [ ] **T028 [S3]** Thread the parsed `[RationaleReferenceJSON]` into
  the existing `RationaleJSON` value the wizard writes to
  `intent.json`. Default `[]` when no `--reference-uri` flags are
  present (preserves Acceptance Scenario 1).
- [ ] **T029 [S3]** Add a CLI smoke test: invoke the wizard via the
  test harness with the four-reference Cyber Castellum input from
  [quickstart.md](quickstart.md), parse the resulting
  `intent.json`, assert `references` has four entries with the
  expected uris and labels.
- [ ] **T030 [S3]** Confirm GREEN: all parser + smoke tests pass;
  `nix develop --quiet -c just unit` green; `./gate.sh` green.
- [ ] **T031 [S3]** Commit one bisect-safe slice: subject
  `feat(disburse-wizard): add repeatable --reference-uri/-type/-label flags`,
  trailer `Tasks: T024–T030`.
- [ ] **T032 [S3]** (orchestrator-only) Mark T024–T031 `[X]`, amend
  HEAD.

**Checkpoint S3**: operator can invoke `disburse-wizard` with
references and get them into `intent.json`. End-to-end build (S4)
still pending.

---

## Slice S4 — End-to-end integration

**Goal**: feeding the S3-emitted `intent.json` through `tx-build`
yields a tx whose rationale metadatum equals the S1 golden.

**Spec acceptance**:
[SC-001](spec.md#success-criteria),
[SC-002](spec.md#success-criteria).

**Owned files**:
- `test/unit/DisburseReferencesIntegrationSpec.hs` (NEW), or extend
  the existing integration suite if there is one for disburse

### Tasks

- [ ] **T033 [S4]** Write an integration test that:
  (a) loads the d6c14625-references intent.json fixture from T002;
  (b) invokes the in-process build pipeline (the same path
  `tx-build` uses) to produce the unsigned tx body;
  (c) extracts the aux-data label-1694 metadatum from the body and
  encodes to canonical CBOR;
  (d) asserts byte equality against the S1 `rationale.cbor` golden.
- [ ] **T034 [S4]** Confirm RED if T033 was written before S1+S3
  landed (it would have, but in this slice ordering S1/S2/S3 already
  passed; the test should pass on first run). Document the result
  in `./WIP.md` regardless (the test landing in a *new* commit on a
  clean tree is still meaningful — it proves the wiring works
  end-to-end at this slice's HEAD).
- [ ] **T035 [S4]** Run `./gate.sh` green.
- [ ] **T036 [S4]** Commit: subject
  `test(integration): cli→intent→build round-trip equals d6c14625 golden`,
  trailer `Tasks: T033–T035`.
- [ ] **T037 [S4]** (orchestrator-only) Mark T033–T036 `[X]`, amend
  HEAD.

**Checkpoint S4**: end-to-end proof. The wizard's emitted intent
builds into an unsigned tx whose rationale matches the on-chain
precedent.

---

## Slice S5 — Release wiring, docs, asciinema

**Goal**: ship a cabal version bump, CHANGELOG entry, README section,
and asciinema cast per the vertical-deliverables rule.

**Spec acceptance**:
[FR-005](spec.md#functional-requirements),
all [Deliverables](spec.md#deliverables) rows that haven't shipped in
S1–S4.

**Owned files**:
- `amaru-treasury-tx.cabal`
- `CHANGELOG.md`
- `README.md` (or `docs/disburse.md` — pick the file where
  `disburse-wizard` is already documented)
- `docs/assets/asciinema/disburse-wizard-references.cast` (NEW)
- `mkdocs.yml` (only if the asciinema-player plugin is not already
  registered — the worker pair must check and bootstrap if missing,
  per [reference_dev_assets_asciinema](https://github.com/paolino/dev-assets))

### Tasks

- [ ] **T038 [S5]** Bump `amaru-treasury-tx.cabal` `version`
  (patch-position bump, per [research.md R8](research.md#r8-cabal-version-bump-semver)).
- [ ] **T039 [S5]** Append a bullet under `CHANGELOG.md`'s
  `## Unreleased > ### Features` describing the new flags and the
  on-chain audit-chain capability.
- [ ] **T040 [S5]** Add a `disburse-wizard --reference-*` section to
  `README.md` (or `docs/disburse.md`), with a worked example matching
  [quickstart.md](quickstart.md). Reference the d6c14625 precedent
  for shape reasoning. Embed the asciinema cast via the
  `asciinema-player` mkdocs plugin block.
- [ ] **T041 [S5]** Record the asciinema cast against fixture/preprod
  data (per the recording-scope rule — no real secrets, no mainnet
  treasury addresses), post-process via the dev-assets `compress` /
  `resize` flow, and write to
  `docs/assets/asciinema/disburse-wizard-references.cast`.
- [ ] **T042 [S5]** If `mkdocs.yml` does not already register the
  `asciinema-player` plugin, register it now (one-line config) and
  bootstrap `docs/assets/asciinema/` if absent. Confirm
  `MKDOCS_SITE_URL` env-override is in place per the preview-URL
  defensive pattern; if not, add it in `mkdocs.yml` + the docs PR
  workflow.
- [ ] **T043 [S5]** Run `nix develop --quiet -c mkdocs build --strict`
  green.
- [ ] **T044 [S5]** Run `./gate.sh` green (includes
  `cabal-check`, `release-check`, `format-check`, `hlint`).
- [ ] **T045 [S5]** Commit: subject
  `docs: announce --reference-* flags + release wiring + asciinema`,
  trailer `Tasks: T038–T044`.
- [ ] **T046 [S5]** (orchestrator-only) Mark T038–T045 `[X]`, amend
  HEAD. Push the branch and verify the docs-preview build renders
  the cast (per the preview-verification rule).

**Checkpoint S5**: every spec deliverable is wired. PR is one slice
away from ready.

---

## Slice S6 — Finalize

**Goal**: drop `gate.sh`, mark PR ready for external review.

### Tasks

- [ ] **T047 [S6]** Run the resolve-ticket finalization audit
  (specs match delivered behaviour, every commit carries `Tasks:`
  trailer, all checkboxes `[X]`, README + docs aligned, PR body
  current, CI green).
- [ ] **T048 [S6]** `git rm gate.sh`; commit subject
  `chore: drop gate.sh (ready for review)`; empty `Tasks:` trailer
  (finalization is not a Tasks-tracked slice).
- [ ] **T049 [S6]** Push branch; `gh pr ready 197`; confirm PR moves
  to ready.
- [ ] **T050 [S6]** (orchestrator-only) Final PR body update naming
  the merged-ready state, the release version, and the deliverables
  rundown for the reviewer.

**Checkpoint S6**: PR ready for human review + merge.

---

## Dependencies & execution order

- **S1 first.** Library shape change is the foundation; nothing else
  can compile without it.
- **S2 in parallel with S3?** S2 (schema) and S3 (CLI) both touch
  JSON-side code; per the resolve-ticket invariants they are
  separate slices in separate commits, but they can be dispatched
  back-to-back by the ticket-owner without contention because they
  edit different files (S2: `Schema.hs` + `IntentJSON.hs`; S3:
  parser module + parser test). Dispatch sequentially — same pair,
  fresh brief per slice — to keep the WIP.md log clean.
- **S4 depends on S1 + S3** (it's the integration test that
  exercises both).
- **S5 depends on S1–S4** (release notes describe the shipped
  behaviour).
- **S6 depends on S5** and is the very last commit.

## Parallel opportunities

Within S1, T001 (fetch the on-chain CBOR) and T002 (write the
matching intent.json fixture) can be prepared in parallel — both
are reference-data setup. The remaining S1 tasks (T003 onward) are
sequential because each builds on the previous.

S5's T040 (README/docs) and T041 (cast recording) can be drafted in
parallel inside the same slice — the navigator can be reviewing the
prose while the driver records the cast.

## Paired worker brief — Slice S1

The ticket-owner dispatches the driver+navigator pair with this
brief (subsequent slices use parallel briefs with their own owned
files / RED / GREEN). Per
[feedback_agent_effort_levels](https://github.com/paolino/llm-settings):
**always Opus, effort `medium` for both pair workers**.

```text
Task: T001, T002, T003, T004, T005, T006, T007, T008, T009, T010,
      T011, T012, T013

Pair:
- Driver: <operator-named, e.g. "Claude pane 1">. Opus, effort
  medium. Holds the write lock until the next orchestrator-approved
  role swap.
- Navigator: <operator-named, e.g. "Claude pane 2">. Opus, effort
  medium. Read-only observer/reviewer.
- Shared worktree: /code/amaru-treasury-tx-issue-196
- Communication: workers do not talk directly. All questions /
  objections / role-swap requests go through the orchestrator via
  STATUS.md.

Shared context:
- Bisect-safe vertical slice; exactly one commit; no push.
- Conventional Commits subject; non-empty body; `Tasks: T001, T002,
  T003, T004, T005, T006, T007, T008, T009, T010, T011, T012`
  trailer.
- Maintain `./WIP.md` per the resolve-ticket invariants — see
  /code/llm-settings/shared/skills/resolve-ticket/SKILL.md
  "Dispatch and Live Tail" + "Paired Worker Brief".
- Constitution Principle V is NON-NEGOTIABLE: golden CBOR ships
  before the implementation. T003 (the failing ReferencesSpec) lands
  in the same commit as the implementation, but the WIP.md must show
  RED → GREEN order.
- Constitution Principle I + VII govern shape parity. The d6c14625
  metadatum is the authoritative on-chain contract; existing
  goldens must stay byte-equal.

Owned files:
- lib/Amaru/Treasury/AuxData.hs
- test/fixtures/disburse/d6c14625-references/{intent.json,rationale.cbor,README.md}
- test/unit/ReferencesSpec.hs
- amaru-treasury-tx.cabal (test stanza only)

Forbidden scope:
- specs/ (orchestrator owns)
- gate.sh (orchestrator owns)
- README, CHANGELOG, docs/, mkdocs.yml (S5 owns)
- app/amaru-treasury-tx/Main.hs (S3 owns)
- lib/Amaru/Treasury/IntentJSON/* (S2 owns)
- cabal version bump (S5 owns — only test stanza wiring here)

Required orchestrator analysis already applied:
- d6c14625 tx is a mainnet ops_and_use_cases disburse to Jacob
  Finkelman. Use Blockfrost mainnet API
  /txs/d6c14625…/metadata to fetch the rationale, encode label
  1694 to canonical CBOR, check in as fixture.
- The bash recipe at pragma-org/amaru-treasury/journal/2026/bin/
  disburse.sh emits the same shape via $RATIONALE_JSON, so this
  golden is also bash-parity (Constitution Principle I).

RED proof:
- test/unit/ReferencesSpec.hs golden test FAILS before any
  AuxData.hs edit lands (no rbReferences field, no
  RationaleReference type). Capture the failing output.

GREEN proof:
- `nix develop --quiet -c just unit ReferencesSpec` green.
- `nix develop --quiet -c just unit` green (every other *Spec
  unaffected).
- `./gate.sh` green.

Commit subject:
- feat(auxdata): add RationaleBody.rbReferences with d6c14625 golden

Report back to the orchestrator (STATUS.md):
- changed files (`git diff --name-only HEAD~1..HEAD`)
- RED evidence (failing-run tail before the AuxData.hs edit)
- GREEN evidence (passing-run tail + `./gate.sh` output)
- navigator observations and how each was handled
- role swaps performed, if any
- pointer to ./WIP.md
- residual risks
```

Subsequent slice briefs (S2/S3/S4/S5/S6) follow the same template,
swapping owned files / RED proof / GREEN proof / commit subject /
Tasks trailer per the slice. The ticket-owner constructs each brief
fresh and live-tails `WIP.md` for the full run.
