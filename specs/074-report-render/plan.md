# Implementation Plan: Operator-Friendly Markdown Renderer (`report-render`)

**Branch**: `074-report-render` | **Date**: 2026-05-09 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from [`specs/074-report-render/spec.md`](./spec.md)
**Tracking issue**: [#74](https://github.com/lambdasistemi/amaru-treasury-tx/issues/74)
**Pull request**: [#75](https://github.com/lambdasistemi/amaru-treasury-tx/pull/75)

## Summary

Add a `report-render` subcommand to the existing `amaru-treasury-tx`
executable that consumes a JSON `report.json` (issue [#72](https://github.com/lambdasistemi/amaru-treasury-tx/issues/72))
and emits an operator-friendly Markdown rendering. The renderer is a
pure transformation: stdin/stdout by default, deterministic, offline,
no chain access. It collapses repeated swap-order outputs, prints
lovelace alongside ADA, derives UTC validity bounds from the report's
own era/network data, prints a conservation line, links the txid to a
chain explorer, and inlines the CIP-1694 rationale when present.

The renderer additionally builds an address book and identity map from
declarative sources — treasury metadata (default
`journal/2026/metadata.json`), built-in constants, derivations from
script hashes already in the report, and the inline intent — and
labels every printed address, signer key hash, and reference input
with a semantic role tag, with an explicit `unresolved` fallback so
no bare bech32 / bare 28-byte hex ever leaves the renderer untagged.
The leading section names the action kind and touched scope so a
multisig reviewer cannot mistake a swap for a disburse.

To make the pipeline end-to-end stream-capable, `tx-build` accepts
`--report -` as a sibling change, and the JSON report additively
carries the originating intent under one new optional top-level
field. Older reports without that field still render, with the
swap-deal section omitted and a clear note explaining why.

The repository's operator-facing helper `scripts/ops/build-swop`
(created by this feature) wraps the build flow and produces the
Markdown rendering by default, with a documented opt-out flag.
Operator docs are updated to position the rendered Markdown as the
pre-signing review artefact.

## Technical Context

**Language/Version**: Haskell, GHC 9.6+ (matches `cardano-node-clients`).

**Primary Dependencies**:

- Existing `Amaru.Treasury.Report` types and `encodeReport` (issue
  [#72](https://github.com/lambdasistemi/amaru-treasury-tx/issues/72)).
- Existing `Amaru.Treasury.IntentJSON` (`SomeTreasuryIntent`,
  `decodeUnifiedIntentJSON`) for the inline-intent shape.
- Existing `Amaru.Treasury.Metadata` (`TreasuryMetadata`,
  `readMetadataFile`) for the address-book seed.
- Existing `Amaru.Treasury.Constants` (USDM, Sundae pool, Sundae fee).
- Existing `Amaru.Treasury.Registry.Derive` for script-hash
  derivations (treasury, registry, permissions).
- Existing `aeson`, `aeson-pretty`, `bech32`, `text`, `time`,
  `cardano-slotting`, `optparse-applicative`.
- No new third-party dependency. Markdown rendering is plain `Text`
  builder; explorer URLs are pure functions of `network` + `txId`.

**Storage**: filesystem only — `report.json` (input), `report.md`
(default sibling output via the helper), optional `metadata.json`
(default `journal/2026/metadata.json`), optional explicit
`intent.json` (override). No DB or persistent state.

**Testing**:

- Unit tests (Hspec) for: address-book / identity-map construction,
  resolution priority order, unresolved fallback, swap-output
  collapsing, ADA/lovelace pairing, slot→UTC derivation,
  conservation-line arithmetic, leading-section action-kind
  classification, CLI option parsing, and `--no-intent` /
  `--intent <path>` precedence.
- Golden tests (byte-identical Markdown) for the regression set
  named in FR-025 / SC-001..SC-008. Goldens live under
  `test/fixtures/swap/` (extending the existing fixture) and a new
  `test/fixtures/swap-legacy/` (older report without inline
  intent), `test/fixtures/disburse/`, `test/fixtures/withdraw/`.
- Smoke test (flake `smoke` stage) for: `report-render --help`
  surface, end-to-end `tx-build --report - | report-render`
  pipeline against the swap fixture, helper-script default-on
  behaviour, helper-script opt-out behaviour.
- Schema test (existing `schema` stage) extended only to assert the
  inline-intent field is optional and additive (no breaking change
  to the existing checked-in schema asset).
- Documentation render check via the existing `lint`/format gate.

**Target Platform**: existing CLI platforms — Linux CI, macOS dev.

**Project Type**: Haskell CLI tool plus library modules and tests.

**Performance Goals**: rendering is linear in the report's outputs +
inputs + reference inputs + signers; no node queries, no network.
Negligible relative to a real `tx-build` run.

**Constraints**:

- Pure builders, impure shell (constitution II): rendering and
  resolution are pure over decoded JSON values; only the CLI shell
  reads/writes streams.
- Build-only boundary (constitution IV): no signing, submission, or
  key material.
- Determinism (FR-007): no wall-clock, no random, no environment
  reads beyond declared inputs, byte-identical output for identical
  inputs.
- Additive JSON change only (FR-005, SC-005): existing report fields
  unchanged; new field is optional; older reports must render.
- No personal-name signer labels (FR-016): role labels only.
- No bare bech32 / bare 28-byte hex anywhere in rendered output
  (FR-015, FR-016, SC-003).

**Scale/Scope**:

- One new module family under `lib/Amaru/Treasury/Report/` plus a
  small `Cli` parser module.
- One additive field on the `report.json` contract.
- One new helper script `scripts/ops/build-swop`.
- Three new fixture trees (swap-legacy, disburse, withdraw) plus
  golden Markdown for the existing swap fixture.
- One subcommand wired through `app/amaru-treasury-tx/Main.hs`.
- Focused docs updates in `docs/swap.md`, `docs/quickstart.md`, and
  a new `docs/report-render.md`.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Faithful port of bash recipes | PASS | The renderer is a post-build review artefact; CBOR semantics, redeemer layouts, and the bash entry-point contracts are untouched. |
| II. Pure builders, impure shell | PASS | Resolution, classification, accounting display, and Markdown formatting are pure. The CLI shell reads/writes streams. |
| III. Pluggable data source, local-node default | PASS | Renderer makes no node calls. Metadata is read from a declarative file. |
| IV. Build, never sign or submit | PASS | The renderer never touches keys, signatures, or submission. |
| V. Test-first with golden CBOR fixtures | PASS | CBOR golden fixtures stay unchanged. Renderer uses byte-identical Markdown goldens layered on top. RED-first per slice. |
| VI. Hackage-ready Haskell | PASS | New exports get Haddock, explicit export lists, fourmolu 70-col, leading commas/arrows, `-Werror`. |

No violations. Complexity Tracking is intentionally omitted.

## Project Structure

### Documentation (this feature)

```text
specs/074-report-render/
├── plan.md
├── research.md
├── data-model.md
├── quickstart.md
├── contracts/
│   └── report-render-cli.md
├── checklists/
│   └── requirements.md
└── tasks.md            # Created later by /speckit.tasks
```

### Source Code (repository root)

```text
lib/Amaru/Treasury/Report/
├── Render.hs                        # Public render API, stable Markdown encoder
├── Render/
│   ├── Address.hs                   # Address-book labelling helpers
│   ├── Markdown.hs                  # Pure Markdown builder primitives
│   └── Time.hs                      # Slot → UTC derivation from era data
├── Identity.hs                      # Address book + identity map types and resolution
├── Identity/
│   ├── Resolve.hs                   # Priority-ordered resolution sources
│   └── Constants.hs                 # Built-in constants (USDM, Sundae, etc.)
└── Cli.hs                           # `report-render` subcommand options + parser

lib/Amaru/Treasury/Report.hs         # Adds `trInlineIntent :: Maybe SomeTreasuryIntent`
                                     # (additive optional field) and re-exports.

app/amaru-treasury-tx/
└── Main.hs                          # Dispatch `report-render`; extend tx-build
                                     # to accept `--report -` (stdout).

scripts/ops/
└── build-swop                       # Operator helper; default-on Markdown,
                                     # `--no-markdown` opt-out, documented.

docs/
├── report-render.md                 # New: identity sources, CLI shape,
                                     # determinism, inline-intent additivity.
├── quickstart.md                    # Updated: review step uses report.md.
└── swap.md                          # Updated: end-to-end pipeline example.

test/fixtures/swap/
├── report.golden.json               # Existing — extended additively to
                                     # carry `intent` inline (regenerated).
├── intent.json                      # Existing.
├── report.golden.md                 # New: full-resolution Markdown golden.
├── report.no-metadata.golden.md     # New: no metadata source supplied.
└── report.no-intent.golden.md       # New: `--no-intent` opt-out applied.

test/fixtures/swap-legacy/
└── report.legacy.json               # New: pre-inline-intent shape.
└── report.legacy.golden.md          # New: renders with section-omitted note.

test/fixtures/disburse/
├── report.golden.json               # New
└── report.golden.md                 # New

test/fixtures/withdraw/
├── report.golden.json               # New
└── report.golden.md                 # New

test/unit/Amaru/Treasury/Report/
├── IdentitySpec.hs                  # Resolution priority, fallback, label uniqueness.
├── RenderSpec.hs                    # Collapsing, ADA pairing, conservation,
                                     # slot→UTC, action-kind classification.
└── CliSpec.hs                       # Parser, `--in`, `--out`, `--intent`,
                                     # `--no-intent`, `--metadata`, stdio aliases.

test/golden/
├── ReportRenderSwapGoldenSpec.hs    # Byte-identical Markdown for swap fixture set.
├── ReportRenderSwapLegacyGoldenSpec.hs
├── ReportRenderDisburseGoldenSpec.hs
└── ReportRenderWithdrawGoldenSpec.hs
```

**Structure Decision**: Keep all rendering, identity resolution, and
Markdown formatting in the library under `Amaru.Treasury.Report.*`,
mirroring the existing `Report.hs` + `Report/Accounting.hs` +
`Report/Classify.hs` + `Report/Schema.hs` family. The CLI shell
(`app/amaru-treasury-tx/Main.hs`) is the only impure layer. This
preserves "pure builders, impure shell" (constitution II) and lets
unit tests exercise the renderer without a node, files, or
environment.

## Pinned Decisions (review-anchor)

These are the standing planner concerns recorded in
`llm/reviews/reviewer-notes.md`. The plan resolves each with a
concrete pin so the planner-review gate can check them mechanically.

1. **Operator helper path and behaviour**
   - Path: `scripts/ops/build-swop` (created by this feature).
   - Default: emits Markdown alongside JSON.
   - Opt-out flag: `--no-markdown` (long form only; documented in
     `docs/report-render.md` and in the script's `--help`).
   - The script is a thin POSIX-shell wrapper around
     `amaru-treasury-tx tx-build --report <path>` followed by
     `amaru-treasury-tx report-render --in <path> --out <path>.md`
     (skipped when `--no-markdown` is passed).
   - Smoke test in the flake `smoke` stage exercises both default-on
     and opt-out paths.

2. **Leading-section bound for SC-001**
   - The leading section is the **first 25 lines** of the rendered
     Markdown (after the level-1 title and the first blank line).
   - This bound is asserted in the golden test by slicing
     `take 25 . drop 2` of the rendered output and comparing it to a
     per-fixture leading-section golden snippet, in addition to the
     full-document byte-identity golden.
   - The bound is documented in `docs/report-render.md` and in the
     Haddock of `Amaru.Treasury.Report.Render` so future changes
     stay aware that SC-001 enforces it.
   - Rationale: 25 lines comfortably accommodates title (1) + action
     line (1) + scope line (1) + transaction-id + explorer link (2)
     + validity (2) + conservation line (1) + signer-roles list (≤6
     for the largest fixture) + swap-deal block (≤8 when present),
     leaving slack but staying within a reviewer's first-screen
     view.

3. **Treasury metadata default path**
   - Default metadata path: `journal/2026/metadata.json` (matching
     the upstream
     [`pragma-org/amaru-treasury/journal/2026/metadata.json`](https://github.com/pragma-org/amaru-treasury/blob/main/journal/2026/metadata.json)
     bash recipes).
   - Resolution rule: explicit `--metadata <path>` wins; otherwise,
     if `journal/2026/metadata.json` exists relative to the current
     working directory, use it; otherwise, render without metadata
     (still produces Markdown; addresses fall back to `unresolved`).
   - Documented in FR-014's plan trace below and in
     `docs/report-render.md`.

## FR / SC Traceability

Every functional requirement and success criterion maps to one or
more concrete technical decisions and test artefacts.

| ID      | Decision / Module / Test                                                                  |
|---------|--------------------------------------------------------------------------------------------|
| FR-001  | New `report-render` subcommand wired in `app/amaru-treasury-tx/Main.hs` via `Report.Cli`. |
| FR-002  | `Report.Cli`: when no `--in` / `--out`, default to `BSL.getContents` / `BSL.putStr`.      |
| FR-003  | `Report.Cli`: independent `--in PATH` / `--out PATH`; both accept `-` as stdio alias.     |
| FR-004  | `Cli.TxBuild`: extend `--report` parser to accept `-` (stdout sentinel); Main writes to stdout when sentinel matches. |
| FR-005  | `Amaru.Treasury.Report`: add `trInlineIntent :: Maybe SomeTreasuryIntent`; encoder emits field only when `Just`. Schema asset updated to declare `intent` as additive optional. |
| FR-006  | `Report.Cli`: `--intent PATH` (override) takes precedence over inline; `--no-intent` zeroes the intent before rendering. Unit test `CliSpec` asserts precedence. |
| FR-007  | `Render` is `Text -> Text` (after decode); no `IO` import; no `getCurrentTime`, `getEnvironment`, randomness. Golden test renders twice, asserts byte-identity. |
| FR-008  | `Render`: group produced outputs by `(role, resolvedLabel, lovelace, asset-bag-hash)`; emit "N × <amount>" when `n > 1`, individual lines otherwise. Unit `RenderSpec`. |
| FR-009  | `Render.Markdown`: `formatLovelaceWithAda` helper; every value-table line passes through it. Unit `RenderSpec`. |
| FR-010  | `Render.Time`: `slotToUtc :: NetworkId -> EraSummaries -> SlotNo -> UTCTime` derived from the report's era summary; no IO. Unit `RenderSpec` covers preprod and mainnet. |
| FR-011  | `Render`: when `metadataSummary.cip1694LabelPresent` is true and the inline intent supplies the rationale fields, render description, justification, destination label, event, label as a Markdown block. Unit `RenderSpec`. |
| FR-012  | `Render`: print one conservation line `inputs = outputs + fee, residual = X`; pure arithmetic over the report's totals. Unit `RenderSpec`. |
| FR-013  | `Render`: explorer URL is `cardanoscan.io/transaction/<txid>` for mainnet, `preprod.cardanoscan.io/transaction/<txid>` for preprod; pure function of `network` + `txId`. |
| FR-014  | `Identity.Resolve`: priority-ordered resolution: explicit `--metadata` → built-in constants (`Identity.Constants`) → script-hash derivations (`Registry.Derive`) → inline intent → `unresolved`. Default metadata path `journal/2026/metadata.json` (see Pinned Decisions §3). |
| FR-015  | `Render.Address`: every printed bech32 is wrapped via `formatAddress :: AddressBook -> Addr -> Text` which never returns a bare bech32 — the function returns either `<role label> (<truncated bech32>)` or `unresolved (<truncated bech32>)`. SC-003 enforces this via golden text scan. |
| FR-016  | `Identity`: `IdentityMap` carries `KeyHash -> RoleLabel`; `Render` wraps every required-signer key hash through `formatSigner` mirroring `formatAddress`. No personal-name field exists in `IdentityMap`. |
| FR-017  | `Render`: reference-input section uses the `IdentityMap` enriched by `Registry.Derive` for `scopes registry`, `permissions deployed-at`, `treasury deployed-at [<scope>]`, `registry deployed-at [<scope>]`. |
| FR-018  | `Identity`: a single `AddressBook` value is constructed once per render; the same `Map` answers every section. Unit `IdentitySpec` asserts label idempotence on repeat lookups. |
| FR-019  | `Render`: leading section emits action-kind line + scope line in the first 25 rendered lines (see Pinned Decisions §2). Action kind comes from `report.action`; scope comes from the inline intent or from address-book classification of the produced outputs (treasury / swap-order destination). |
| FR-020  | `Render`: when `action == swap` and inline intent is `Just`, leading section appends a swap-deal sub-block (target USDM, committed ADA, min rate, quote source/timestamp, slippage, treasury leftover) sourced from the swap intent fields. Unit `RenderSpec` + swap golden. |
| FR-021  | `Render`: when no intent is available (older report or `--no-intent`), the swap-deal sub-block is replaced by a one-line note: `_swap-deal summary unavailable: report did not carry the originating intent_`. Golden `report.no-intent.golden.md` and `report.legacy.golden.md`. |
| FR-022  | `Render`: outputs whose role is not in the JSON contract render under a generic `other` role with their resolved/unresolved address label preserved. Unit `RenderSpec`. |
| FR-023  | `app/Main.hs`: `report-render` exits with `ExitFailure 1` and prints to stderr when `BSL.writeFile` / `hPutStr` raises. Unit `CliSpec` (mock handle) + smoke test. |
| FR-024  | `Render` and all helpers under `Amaru.Treasury.Report.Render.*` and `Amaru.Treasury.Report.Identity.*` are written without `IO`; their signatures take `Text`/`Value`/decoded records and return `Text`. Verified by GHC type signatures. |
| FR-025  | Golden set: swap (full + no-metadata + no-intent) + swap-legacy + disburse + withdraw. The set demonstrates FR-019 disambiguation across action kinds. |
| FR-026  | `scripts/ops/build-swop` default-on Markdown; `--no-markdown` opt-out; smoke test in `nix/checks.nix` `smoke` stage exercises both. |
| FR-027  | `docs/report-render.md` (new), `docs/quickstart.md` (review step), `docs/swap.md` (pipeline example) — each documents the renderer, the inline-intent additivity, and the helper default + opt-out. Lint stage covers formatting; existing `docs/` checks cover link integrity. |
| SC-001  | Leading-section golden snippet (first 25 lines) per fixture; reviewer can read action + scope at a glance. |
| SC-002  | `ReportRenderSwapGoldenSpec`: render swap fixture twice; assert byte-identity; assert against `report.golden.md`. |
| SC-003  | Golden test post-condition: `T.findIndex` of any bare bech32 (`addr_*` / `addr1*`) or any naked 28-byte hex outside an `unresolved (...)` wrapper returns `Nothing` for the rendered Markdown. |
| SC-004  | Smoke stage: `tx-build --report - | report-render` against swap fixture; `diff` against `report.golden.md`. |
| SC-005  | `ReportRenderSwapLegacyGoldenSpec`: legacy report renders, swap-deal section is omitted, note line present. |
| SC-006  | `ReportRenderSwapGoldenSpec`: parse conservation line; assert `inputs == outputs + fee + residual`. |
| SC-007  | Lint/docs check: assert presence of the helper-default and opt-out wording in `docs/report-render.md` (grep gate). |
| SC-008  | Smoke stage: invoke `scripts/ops/build-swop` with default flags → both `report.json` and `report.md` exist; with `--no-markdown` → only `report.json` exists. |

## Contract And Proof Strategy

The renderer is bound to the existing JSON report contract from
issue [#72](https://github.com/lambdasistemi/amaru-treasury-tx/issues/72) plus one additive optional top-level field
`intent`. The schema asset
`docs/assets/tx-report-schema.json` (existing) is updated only to
add `intent` to the property set, with no `required` change. The
existing `schema` flake check picks this up.

The renderer's *output* contract is a Markdown file with three
load-bearing properties:

1. **Byte determinism** — golden test compares the rendered output
   to a checked-in `report.golden.md` file.
2. **First-screen unmistakability** — the first 25 lines after the
   title + blank line must contain the action kind and scope, and
   must not contain any unresolved address (the per-fixture
   leading-section snippet golden enforces this).
3. **No bare bech32 / no bare 28-byte hex** — a regex post-condition
   in the golden specs scans the rendered output and fails on any
   match outside an `unresolved (...)` wrapper.

The CLI surface contract is documented in
[`contracts/report-render-cli.md`](./contracts/report-render-cli.md).

## Vertical TDD Slices (bisect-safe)

Each slice is one durable commit. Each slice:

- starts with a **RED** test (unit or golden) that fails on `main`,
- adds the **GREEN** implementation that makes it pass,
- leaves `gate.sh` (build + unit + golden + schema + smoke + lint)
  green at HEAD,
- touches one observable behaviour at a time.

Slice ordering is chosen so each commit can land independently and
the bisect surface is clean.

1. **Slice A — Report carries inline intent (additive)**
   - RED: extend `ReportSpec` to assert that round-tripping a
     `TransactionReport` with `trInlineIntent = Just sampleIntent`
     yields a JSON object that contains an `intent` field equal to
     the unified-intent encoding, and that omitting it produces a
     report byte-identical to the previous golden.
   - GREEN: add `trInlineIntent :: Maybe SomeTreasuryIntent` to
     `Amaru.Treasury.Report` (additive), update encoder to emit the
     field only when `Just`, regenerate `report.golden.json` with
     the inline intent, update `docs/assets/tx-report-schema.json`
     to declare `intent` optional.
   - Gate: schema check passes; existing golden updates only one
     fixture (swap) and remains byte-stable thereafter.

2. **Slice B — Identity types and resolution priority**
   - RED: `IdentitySpec` exercises `resolveAddress` with each source
     in turn (metadata, built-in, script-hash derivation, inline
     intent, unresolved) and asserts priority order plus idempotent
     repeat lookups.
   - GREEN: introduce `Amaru.Treasury.Report.Identity`,
     `Identity.Resolve`, `Identity.Constants`. No CLI yet, no
     rendering yet — pure data + functions.
   - Gate: unit and lint stages.

3. **Slice C — Markdown primitives, slot→UTC, conservation**
   - RED: `RenderSpec` covers `formatLovelaceWithAda`, `slotToUtc`
     (mainnet + preprod against the report's era data), and the
     conservation-line formatter, including residual zero and
     residual non-zero.
   - GREEN: add `Render.Markdown`, `Render.Time`, and the pure
     conservation helper. Still no full document, no CLI.
   - Gate: unit + lint.

4. **Slice D — Pure renderer assembled, no CLI**
   - RED: `ReportRenderSwapGoldenSpec` calls a pure
     `renderReport :: AddressBook -> TransactionReport -> Maybe SomeTreasuryIntent -> Text`
     against the swap fixture (with metadata) and compares against
     `test/fixtures/swap/report.golden.md`. The golden file is
     committed in this slice. The leading-section snippet golden
     (first 25 lines) is asserted alongside. SC-003 (no bare
     bech32 / hex) is asserted as a regex post-condition on the
     rendered text.
   - GREEN: add `Amaru.Treasury.Report.Render`, glue
     identity + markdown primitives + classification, emit the full
     document. Add `report.golden.md`.
   - Gate: unit + golden + lint + schema.

5. **Slice E — `report-render` CLI subcommand and `--report -`**
   - RED: `CliSpec` covers `optparse-applicative` parser; smoke
     stage adds the pipeline `tx-build --report - | report-render`
     against the swap fixture, diffing the rendered Markdown
     against `report.golden.md`. The smoke stage also asserts
     `--in -` / `--out -` aliases and the `--no-intent` /
     `--intent <path>` flags.
   - GREEN: add `Amaru.Treasury.Report.Cli` with `ReportRenderOpts`
     and a parser; wire `report-render` into
     `app/amaru-treasury-tx/Main.hs`; teach `tx-build`'s `--report`
     parser to accept `-` and Main to write to stdout when so.
     Stdin/stdout default behaviour confirmed by smoke stage.
   - Gate: full `gate.sh` (build + unit + golden + schema + smoke
     + lint).

6. **Slice F — Coverage breadth: legacy + no-metadata + no-intent + disburse + withdraw**
   - RED: four additional golden specs + four fixture trees; each
     asserts byte-identity, the no-bare-bech32 / no-bare-hex
     post-condition, and the leading-section snippet.
   - GREEN: add the fixtures and matching `*.golden.md` files. No
     code changes expected (or only minimal classification tweaks
     surfaced by the new fixtures); any code change must be
     RED-first inside this slice.
   - Gate: full `gate.sh`.

7. **Slice G — Operator helper `scripts/ops/build-swop`**
   - RED: `nix/checks.nix` `smoke` stage gains two assertions —
     default-on emits both `report.json` and `report.md` and they
     match the goldens; `--no-markdown` emits only `report.json`.
     This is the failing condition before the script exists.
   - GREEN: add `scripts/ops/build-swop` (POSIX shell, executable),
     wire it into `flake.nix` so the smoke check has the script in
     its `runtimeInputs`, document the flag in the script's
     `--help` and in `docs/report-render.md`.
   - Gate: full `gate.sh`.

8. **Slice H — Operator docs**
   - RED: lint/docs gate (a small `grep` smoke assertion in the
     existing `lint` or `smoke` stage) requires that
     `docs/report-render.md`, `docs/quickstart.md`, and `docs/swap.md`
     mention the Markdown rendering as the pre-signing review
     artefact, the inline-intent additivity, the resolution
     sources, and the helper default + opt-out.
   - GREEN: write `docs/report-render.md`; update `docs/quickstart.md`
     to direct reviewers at the Markdown report; update `docs/swap.md`
     with the pipeline example.
   - Gate: full `gate.sh`.

Each slice is a Conventional-Commit-prefixed durable commit:
`feat(report-render): ...` or `feat(report-render-cli): ...` etc.
Slices A, E, G are externally observable boundary changes; B, C, D
are internal but each carries its own RED test. Slice F is the
regression-set breadth slice. Slice H is docs.

## Gate-Stage Coverage

The repository's local quality gate is `llm/reviews/gate.sh`, which
mirrors the GitHub Actions surface: `build`, `unit`, `golden`,
`schema`, `smoke`, `lint`. This feature does **not** add a new
flake check derivation — it extends the existing ones:

| Stage   | Change                                                                                  |
|---------|------------------------------------------------------------------------------------------|
| `build` | New library modules under `Amaru.Treasury.Report.Render.*` and `Amaru.Treasury.Report.Identity.*` build clean with `-Werror`. |
| `unit`  | New specs: `IdentitySpec`, `RenderSpec`, `CliSpec`. Existing `ReportSpec` extended for inline intent additivity. |
| `golden`| Four new spec modules: `ReportRenderSwapGoldenSpec`, `ReportRenderSwapLegacyGoldenSpec`, `ReportRenderDisburseGoldenSpec`, `ReportRenderWithdrawGoldenSpec`. Existing CBOR golden fixtures untouched. |
| `schema`| `docs/assets/tx-report-schema.json` adds optional `intent` property; the existing `schema` check picks this up unchanged. |
| `smoke` | Adds `report-render --help` surface check, the `tx-build --report - | report-render` pipeline check, and `scripts/ops/build-swop` default-on / opt-out checks. |
| `lint`  | New Haskell sources covered by the existing fourmolu / hlint / cabal-fmt loop. Docs additions covered by the existing `docs/` lint pass. |

No new flake derivation is needed.

## Risks And Edge Cases

- **Era summary drift**: slot→UTC depends on the era summaries
  carried by the report. If the report's era data is incomplete, the
  renderer must fall back to a slot-only display rather than guess.
  Tested in `RenderSpec`.
- **Sundae swap-order address derivation**: the address is
  parameterised by the treasury script hash present in the report;
  the derivation lives under `Registry.Derive` — extend it in
  Slice B if the existing helper does not yet cover the
  `swapOrderAddress` derivation explicitly.
- **Mixed-amount swap-order outputs**: the collapsing rule in FR-008
  groups by `(role, resolvedLabel, lovelace, asset-bag-hash)`; an
  output with a different per-output amount (the remainder chunk)
  is listed alongside the collapsed group. Covered by
  `RenderSpec`.
- **`--no-intent` on a fresh report**: the renderer must zero the
  inline intent before rendering, not silently ignore the flag.
  Unit `CliSpec`.
- **`--intent <path>` with a fresh report carrying inline intent**:
  the override wins; the renderer must not silently mix the two.
  Unit `CliSpec` asserts that the rendered swap-deal block reflects
  the override fields only.
- **Address that is both a built-in and a metadata address**:
  resolution priority ranks `--metadata` first to allow operators
  to override the built-in, with a unit test covering the case.
- **Extremely long destination labels in CIP-1694 rationale**: the
  Markdown block prints them verbatim (no truncation); golden tests
  cover the swap fixture's existing values.

## Public Contract Changes

- Additive optional `intent` field on `report.json` (FR-005). Old
  consumers continue to read existing fields verbatim.
- New `report-render` subcommand on `amaru-treasury-tx`. No
  existing subcommand changes shape.
- `tx-build`'s `--report` argument now also accepts `-` for stdout.
  All previous `--report PATH` invocations are unchanged.
- New helper script `scripts/ops/build-swop` (no prior public
  contract).

## Deferred / Out Of Scope

- HTML, PDF, or non-Markdown rendering (spec exclusion).
- Quote-derived swap-order parameter filling (issue
  [#70](https://github.com/lambdasistemi/amaru-treasury-tx/issues/70) — integration boundary).
- Personal-name signer labels (spec exclusion).
- Third-party `report.json` schemas.

## Open Questions

None remaining. The three planner concerns from
`llm/reviews/reviewer-notes.md` (helper path, leading-section
bound, metadata default path) are pinned in **Pinned Decisions**.
