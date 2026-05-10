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
The leading section names the transaction type from the inline intent
and the touched scope so a multisig reviewer cannot mistake a swap
for a disburse. The report does not duplicate transaction type in a
separate top-level `action` field.

To make the pipeline end-to-end stream-capable, `tx-build` accepts
`--report -` as a sibling change and writes a build-output envelope:
top-level `intent` plus top-level `result`. The result is either a
structured failure or a success object carrying `tx-cbor` and nested
mechanical `report`. The intent is pass-through context for the build
attempt; success means a transaction was created and the report
explains the relevant facts without requiring CBOR parsing, while
failure means no transaction was created and the result explains why.
The renderer has no separate intent-file argument and no degraded
rendering mode for missing intent.

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

**Storage**: filesystem only — `report.json` build-output envelope
(input), `report.md`
(default sibling output via the helper), optional `metadata.json`
(default `journal/2026/metadata.json`). No DB or persistent state.
The envelope's top-level `intent` is the only intent source used by
the renderer; success `result.tx-cbor` is the transaction-byte source
used for CBOR fingerprint/hash display.

**Testing**:

- Unit tests (Hspec) for: address-book / identity-map construction,
  resolution priority order, unresolved fallback, swap-output
  collapsing, ADA/lovelace pairing, slot→UTC derivation,
  conservation-line arithmetic, leading-section transaction-type
  classification from inline intent, CLI option parsing, and
  rejection of envelopes whose `intent`, `result`, success
  `tx-cbor`, or success nested `report` is missing or malformed.
- Golden tests (byte-identical Markdown) for the regression set
  named in FR-027 / SC-001..SC-008. Goldens live under
  `test/fixtures/swap/` (extending the existing fixture),
  `test/fixtures/disburse/`, and `test/fixtures/withdraw/`.
- Smoke test (flake `smoke` stage) for: `report-render --help`
  surface, end-to-end `tx-build --report - | report-render`
  pipeline against the swap fixture, helper-script default-on
  behaviour, helper-script opt-out behaviour.
- Schema test (existing `schema` stage) extended to assert the
  build-output envelope shape: top-level `intent`, top-level
  `result`, success `tx-cbor`, and success nested `report`.
  Unit/smoke coverage asserts that malformed envelopes are rejected.
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
- Determinism (FR-009): no wall-clock, no random, no environment
  reads beyond declared inputs, byte-identical output for identical
  inputs.
- JSON contract change is constrained (FR-005..FR-008, SC-005):
  existing mechanical report fields move under `result.report`,
  success `tx-cbor` sits beside it, top-level `intent` is required,
  and no separate transaction-type/action field is present.
- No personal-name signer labels (FR-018): role labels only.
- No bare bech32 / bare 28-byte hex anywhere in rendered output
  (FR-017, FR-018, SC-003).

**Scale/Scope**:

- One new module family under `lib/Amaru/Treasury/Report/` plus a
  small `Cli` parser module.
- One build-output envelope shape for `report.json`: `intent` plus
  `result` (`failure` or `{ tx-cbor, report }`), with duplicate
  action/type removed.
- One new helper script `scripts/ops/build-swop`.
- Two new fixture trees (disburse, withdraw) plus golden Markdown and
  invalid-report fixtures for the existing swap fixture.
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

lib/Amaru/Treasury/Report.hs         # Adds `TxBuildOutput`,
                                     # `TxBuildOutputResult`,
                                     # `TxBuildSuccess`, `TxCborHex`;
                                     # nested report removes duplicate
                                     # top-level action/type.

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
├── report.golden.json               # Existing — regenerated as build-output
                                     # envelope with success result.
├── intent.json                      # Existing.
├── report.golden.md                 # New: full-resolution Markdown golden.
├── report.no-metadata.golden.md     # New: no metadata source supplied.
├── report.missing-required-fields.json
│                                    # New: invalid report fixture.
└── report.malformed-required-fields.json
                                     # New: invalid report fixture.

test/fixtures/disburse/
├── report.golden.json               # New
└── report.golden.md                 # New

test/fixtures/withdraw/
├── report.golden.json               # New
└── report.golden.md                 # New

test/unit/Amaru/Treasury/Report/
├── IdentitySpec.hs                  # Resolution priority, fallback, label uniqueness.
├── RenderSpec.hs                    # Collapsing, ADA pairing, conservation,
                                     # slot→UTC, intent transaction-type classification.
└── CliSpec.hs                       # Parser, `--in`, `--out`,
                                     # `--metadata`, stdio aliases,
                                     # invalid required-field diagnostics.

test/golden/
├── ReportRenderSwapGoldenSpec.hs    # Byte-identical Markdown for swap fixture set.
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
   - Documented in FR-018's plan trace below and in
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
| FR-005  | `TxBuildOutput`: required top-level `intent` + `result`; schema and `ReportSpec` assert the envelope shape. |
| FR-006  | `TxBuildOutputResult`: `failure` variant or success `{ tx-cbor, report }`; schema and unit tests cover both constructors. |
| FR-007  | Decoder/schema reject missing or malformed `intent`, `result`, success `tx-cbor`, and success `report`; `CliSpec` asserts clear diagnostics. |
| FR-008  | Nested `TransactionReport` has no duplicate top-level action/type; transaction type is derived from `txoIntent`. |
| FR-009  | `Report.Cli`: no `--intent` or `--no-intent`; unknown-flag tests assert both are rejected. |
| FR-010  | `Render`: leading section prints a deterministic hash/fingerprint derived from success `tx-cbor`. |
| FR-011  | `Render` is pure after decode; no wall-clock, env, or randomness; golden test renders twice and asserts byte identity. |
| FR-012  | `Render`: group produced outputs by `(role, resolvedLabel, lovelace, asset-bag-hash)`; emit "N × <amount>" when `n > 1`, individual lines otherwise. |
| FR-013  | `Render.Markdown`: `formatLovelaceWithAda` helper; every value-table line passes through it. |
| FR-014  | `Render.Time`: slot-to-UTC from nested report era/network data; no IO. |
| FR-015  | `Render`: inline CIP-1694 rationale from nested report facts and intent fields. |
| FR-016  | `Render`: conservation line over nested report totals. |
| FR-017  | `Render`: explorer URL is pure function of network + transaction id. |
| FR-018  | `Identity.Resolve`: explicit metadata -> built-ins -> script-hash derivations -> envelope intent -> unresolved. |
| FR-019  | `Render.Address`: every printed address is labelled or wrapped as `unresolved (...)`; SC-003 scans goldens. |
| FR-020  | `Identity`: required signer hashes are role-labelled; no personal-name field exists. |
| FR-021  | `Render`: reference-input labels from script-hash derivations and metadata. |
| FR-022  | `Identity`: one address book/identity map per render; unit tests assert idempotent lookup. |
| FR-023  | `Render`: first-screen transaction type and scope come from envelope intent plus address-book classification. |
| FR-024  | `Render`: swap intent adds swap-deal summary sourced from the inline intent. |
| FR-025  | `Render`: all nested report outputs render; unknown roles use generic labels with resolved/unresolved address preserved. |
| FR-026  | `app/Main.hs`: output write failures exit non-zero and print stderr; `CliSpec` + smoke cover it. |
| FR-027  | Pure render modules under `Amaru.Treasury.Report.Render.*` and `Identity.*` have no `IO` in core signatures. |
| FR-028  | Golden set: swap success (full + no metadata) + disburse success + withdraw success; invalid-envelope tests cover required fields. |
| FR-029  | `scripts/ops/build-swop` default-on Markdown; `--no-markdown` opt-out; smoke exercises both. |
| FR-030  | `docs/report-render.md`, `docs/quickstart.md`, `docs/swap.md` document the envelope, renderer, identity sources, helper default, and opt-out. |
| SC-001  | Leading-section golden snippet per success fixture; reviewer can read transaction type + scope at a glance. |
| SC-002  | `ReportRenderSwapGoldenSpec`: render swap fixture twice; assert byte-identity; assert against `report.golden.md`. |
| SC-003  | Golden test post-condition: `T.findIndex` of any bare bech32 (`addr_*` / `addr1*`) or any naked 28-byte hex outside an `unresolved (...)` wrapper returns `Nothing` for the rendered Markdown. |
| SC-004  | Smoke stage: `tx-build --report - | report-render` asserts envelope has top-level `intent`, success `tx-cbor`, success `report`, then diffs Markdown against `report.golden.md`. |
| SC-005  | `ReportSpec` / `CliSpec`: malformed envelopes fail with clear diagnostics. |
| SC-006  | `ReportRenderSwapGoldenSpec`: parse conservation line; assert `inputs == outputs + fee + residual`. |
| SC-007  | Lint/docs check: assert presence of envelope, helper-default, and opt-out wording in `docs/report-render.md`. |
| SC-008  | Smoke stage: helper default writes both `report.json` envelope and `report.md`; `--no-markdown` writes only the envelope. |

## Contract And Proof Strategy

The renderer is bound to a build-output envelope written by
`tx-build --report`:

```json
{
  "intent": { "...": "unified intent JSON" },
  "result": {
    "tx-cbor": "84a4...",
    "report": { "...": "mechanical report JSON" }
  }
}
```

For failures after intent decoding, `result` is:

```json
{
  "failure": { "...": "structured build failure JSON" }
}
```

The schema asset is updated to validate the envelope, including the
success result's required `tx-cbor` and `report`. The nested
mechanical report keeps the issue #72 accounting/validation fields
but does not carry intent, transaction CBOR, or transaction type.

The renderer's *output* contract is a Markdown file with three
load-bearing properties:

1. **Byte determinism** — golden test compares the rendered output
   to a checked-in `report.golden.md` file.
2. **First-screen unmistakability** — the first 25 lines after the
   title + blank line must contain the transaction type and scope, and
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

1. **Slice A — Build-output envelope**
   - RED: extend `ReportSpec` to assert that encoding a successful
     build output yields top-level `intent` and success
     `result.tx-cbor` / `result.report`, and that missing or
     malformed required fields fail decode.
   - GREEN: add `TxBuildOutput`, `TxBuildOutputResult`,
     `TxBuildSuccess`, and `TxCborHex`; nest the mechanical
     `TransactionReport` under success `result.report`; update the
     schema to the envelope shape.
   - Gate: unit + schema.

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
     `renderBuildOutput :: AddressBook -> TxBuildOutput -> Text`
     against the swap success envelope (with metadata) and compares against
     `test/fixtures/swap/report.golden.md`. The golden file is
     committed in this slice. The leading-section snippet golden
     (first 25 lines) is asserted alongside. SC-003 (no bare
     bech32 / hex) is asserted as a regex post-condition on the
     rendered text.
   - GREEN: add `Amaru.Treasury.Report.Render`, glue
     identity + markdown primitives + classification, emit the full
     document from envelope intent + success `tx-cbor` + nested
     report. Add `report.golden.md`.
   - Gate: unit + golden + lint + schema.

5. **Slice E — `report-render` CLI subcommand and `--report -`**
   - RED: `CliSpec` covers `optparse-applicative` parser; smoke
     stage adds the pipeline `tx-build --report - | report-render`
     against the swap fixture, diffing the rendered Markdown
     against `report.golden.md`. The smoke stage also asserts
     `--in -` / `--out -` aliases and invalid-envelope failure
     diagnostics; parser tests assert `--intent` and `--no-intent`
     are rejected unknown flags.
   - GREEN: add `Amaru.Treasury.Report.Cli` with `ReportRenderOpts`
     and a parser; wire `report-render` into
     `app/amaru-treasury-tx/Main.hs`; teach `tx-build`'s `--report`
     parser to accept `-` and Main to write to stdout when so.
     Stdin/stdout default behaviour confirmed by smoke stage.
   - Gate: full `gate.sh` (build + unit + golden + schema + smoke
     + lint).

6. **Slice F — Coverage breadth: no-metadata + disburse + withdraw**
   - RED: additional golden specs + fixture trees; each
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
     artefact, the build-output envelope shape, the resolution
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
| `unit`  | New specs: `IdentitySpec`, `RenderSpec`, `CliSpec`. Existing `ReportSpec` extended for build-output envelope encoding/decoding and invalid-envelope failures. |
| `golden`| Three new spec modules: `ReportRenderSwapGoldenSpec`, `ReportRenderDisburseGoldenSpec`, `ReportRenderWithdrawGoldenSpec`. Existing CBOR golden fixtures untouched. |
| `schema`| `docs/assets/tx-report-schema.json` validates top-level `intent` + `result`, success `{ tx-cbor, report }`, and failure `{ failure }`. |
| `smoke` | Adds `report-render --help` surface check, the `tx-build --report - | report-render` pipeline check including assertion that the stream is a valid success envelope, invalid-envelope rejection, and `scripts/ops/build-swop` default-on / opt-out checks. |
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
- **Mixed-amount swap-order outputs**: the collapsing rule in FR-012
  groups by `(role, resolvedLabel, lovelace, asset-bag-hash)`; an
  output with a different per-output amount (the remainder chunk)
  is listed alongside the collapsed group. Covered by
  `RenderSpec`.
- **Failure envelope**: a valid failure result carries `intent` and
  `failure`, but no `tx-cbor` or `report`; renderer output must make
  clear that it is not a signable transaction review.
- **Rejected side-channel intent**: `--intent` and `--no-intent` are
  unknown flags. Unit `CliSpec`.
- **Address that is both a built-in and a metadata address**:
  resolution priority ranks `--metadata` first to allow operators
  to override the built-in, with a unit test covering the case.
- **Extremely long destination labels in CIP-1694 rationale**: the
  Markdown block prints them verbatim (no truncation); golden tests
  cover the swap fixture's existing values.

## Public Contract Changes

- `tx-build --report` now writes a build-output envelope
  `{ intent, result }`, where success result is
  `{ tx-cbor, report }` and failure result is `{ failure }`.
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
