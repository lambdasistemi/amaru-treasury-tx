# Implementation Plan: Quote-Derived Swap Parameters

**Branch**: `070-quote-derived-swap-params` | **Date**: 2026-05-09 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from [`specs/070-quote-derived-swap-params/spec.md`](./spec.md)
**Tracking issue**: [#70](https://github.com/lambdasistemi/amaru-treasury-tx/issues/70)

## Summary

Add a `swap-quote` operator path that owns the economic parameter
filling currently done by shell history and hand arithmetic. The new
path accepts an explicit ADA/USD or ADA/USDM quote override, or a named
price source, requires explicit slippage basis points, derives the
Sundae minimum rate conservatively, reuses the existing swap wizard
resolver and `tx-build` pipeline, checks treasury affordability before
unsigned CBOR is written, and writes a `params.json` audit artifact
binding the quote pair, quote value, slippage, derived rate,
affordability inputs, and generated output paths.

The existing `swap-wizard --min-rate` path remains available as an
expert/manual override. Documentation makes `swap-quote` the primary
workflow and labels direct `--min-rate` usage as manually audited.

## Technical Context

**Language/Version**: Haskell, GHC 9.6+.

**Primary Dependencies**:

- Existing `Amaru.Treasury.Tx.SwapWizard` for registry verification,
  network constants, wallet/treasury selection, chunk counting, and
  pure `wizardToTreasuryIntent`.
- Existing `Amaru.Treasury.Build` and
  `Amaru.Treasury.Build.Trace` for unsigned CBOR generation.
- Existing `Amaru.Treasury.IntentJSON` for stable intent encoding and
  schema validation.
- `optparse-applicative`, `aeson`, `aeson-pretty`, `time`, and `text`
  already used by the executable.
- New HTTP dependency for the live named source: `http-conduit`
  (`Network.HTTP.Simple`) plus `scientific` for precise JSON numeric
  extraction. The quote source remains behind a small provider
  interface so unit tests and deterministic smoke tests do not perform
  live network calls.

**Storage**: Filesystem only. The composite command writes an
operator-selected output directory containing `intent.json`,
`swap.cbor.hex`, `params.json`, `wizard.log`, and `build.log`. No
database or long-lived cache is introduced.

**Testing**: Hspec unit tests for pure decimal/rate derivation,
slippage validation, ADA/USD and ADA/USDM quote override parsing,
quote provider parsing, affordability pass/fail, and audit JSON shape.
A deterministic CLI smoke path uses explicit quote overrides and
fixture resolver data; live quote-source tests are not required for
CI.

**Target Platform**: Existing CLI release targets: Linux x86_64 and
Apple Silicon Darwin.

**Project Type**: Haskell CLI, single executable and single library.

**Performance Goals**: The deterministic quote-override path adds no
network latency and should stay within the current swap wizard plus
tx-build runtime. The live `coingecko-ada-usd` source uses one HTTP
GET with a short timeout; failure aborts before any intent or CBOR is
written. Explicit `--ada-usdm` overrides have no network latency. A
named live ADA/USDM source is deferred until an approved provider is
selected.

**Constraints**:

- The existing pure transaction builders remain unchanged.
- Quote arithmetic must use exact decimal/rational math, not `Double`.
- Missing slippage, invalid slippage, invalid quote, and quote-source
  failure abort before intent generation.
- Derived minimum rate is rounded down to the JSON rate precision, so
  rounding never tightens the operator's explicit slippage policy.
- Requested ADA amount and chunk sizes are rounded up where conversion
  from USDM to lovelace would otherwise underfund the request.
- Treasury affordability is checked with generated values:
  `amountLovelace + chunk_count * extraPerChunkLovelace <= selected
  treasury lovelace`.
- The command still builds unsigned CBOR only; it never signs or
  submits.

**Scale/Scope**:

- Add `Amaru.Treasury.Tx.SwapQuote` for pure quote/slippage/rate
  derivation, command request types, affordability summaries, and
  audit JSON.
- Add `Amaru.Treasury.Tx.SwapQuote.Source` for the injectable quote
  provider and the production `coingecko-ada-usd` implementation.
  Explicit ADA/USDM observations are accepted through the override
  path in this issue; named ADA/USDM live fetching remains future
  work until a provider contract is approved.
- Refactor `app/amaru-treasury-tx/Main.hs` just enough to share the
  current swap wizard resolution/intent-building code with the new
  `swap-quote` subcommand, then run the existing build path on the
  produced intent.
- Add unit fixtures under `test/fixtures/swap-quote/`.
- Add tests under `test/unit/Amaru/Treasury/Tx/SwapQuoteSpec.hs`.
- Update `amaru-treasury-tx.cabal` with new modules, tests, fixtures,
  and the HTTP/scientific dependencies.
- Update `docs/quickstart.md` and `docs/swap.md` so hard-coded
  `--min-rate 0.245` is no longer the recommended path.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Faithful port of bash recipes | PASS | The build output shape remains the existing swap intent plus tx-build pipeline. This feature only derives inputs before that pipeline. |
| II. Pure builders, impure shell | PASS | New quote arithmetic and audit assembly are pure; quote fetching, file I/O, registry/node queries, and CBOR writing stay in the CLI shell. Existing `TxBuild` builders are unchanged. |
| III. Pluggable data source | PASS | The live quote source is behind an injectable provider, matching the existing backend seam. No quote-source code leaks into pure builders. |
| IV. Build, never sign or submit | PASS | The new path emits intent JSON, audit JSON, logs, and unsigned CBOR only. |
| V. Test-first with golden CBOR fixtures | PASS | Tasks must land failing unit/audit fixtures before implementation. Existing swap golden remains the CBOR regression gate because the build path is reused. |
| VI. Hackage-ready Haskell | PASS | New exports require Haddock, explicit export lists, fourmolu, hlint, `cabal check`, and the full local gate. |

No violations.

## Project Structure

### Documentation (this feature)

```text
specs/070-quote-derived-swap-params/
|-- spec.md
|-- plan.md
|-- research.md
|-- data-model.md
|-- quickstart.md
|-- contracts/
|   |-- swap-quote-cli.md
|   `-- swap-quote-audit-json.md
|-- checklists/
|   `-- requirements.md
`-- tasks.md              # Phase 2 output (/speckit.tasks)
```

### Source Code (repository root)

```text
lib/Amaru/Treasury/Tx/
|-- SwapWizard.hs                 # refactor reusable intent/resolver helpers only
|-- SwapWizard/Trace.hs           # existing wizard events; may gain quote-derived events
|-- SwapQuote.hs                  # NEW pure request, rate, affordability, audit types
`-- SwapQuote/
    `-- Source.hs                 # NEW QuoteProvider + coingecko-ada-usd source

app/amaru-treasury-tx/
`-- Main.hs                       # add swap-quote parser/runner; share swap-wizard internals

test/fixtures/swap-quote/
|-- quote.ada-usd.override.json   # deterministic ADA/USD observation
|-- quote.ada-usdm.override.json  # deterministic ADA/USDM observation
|-- params.expected.json          # audit golden
`-- source.coingecko.json         # captured provider response fixture

test/unit/Amaru/Treasury/Tx/
`-- SwapQuoteSpec.hs              # new derivation, affordability, audit tests

docs/
|-- quickstart.md                 # primary workflow becomes swap-quote
`-- swap.md                       # manual --min-rate path marked expert override
```

**Structure Decision**: Keep a single executable and single library.
The new code is a small feature module beside `SwapWizard`, because it
derives the answers that `SwapWizardQ` already represents. The live
source adapter is effectful but isolated from builders and from tests.

## Complexity Tracking

No constitution violations or extra architectural complexity.
