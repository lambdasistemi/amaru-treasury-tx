# Plan: USDM Price Source — wizard de-fetching, swap-quote derivation

**Spec**: [spec.md](spec.md) | **Contracts**: [contracts/](contracts/) | **Date**: 2026-05-14 (v2)

## Outcome

After this PR:

- `swap-wizard` accepts only pre-validated rates (`--min-rate R` or
  `--ada-usdm Q [--slippage-bps S]`). No outbound HTTP, no
  `--price-source`, no `--ada-usd`.
- `swap-quote` performs live quote retrieval against
  `--price-source coingecko-ada-usdm`, which is derived from two
  CoinGecko `simple/price` calls (`ids=cardano` and `ids=usdm-2`). The
  audit JSON records both upstream observations under a new
  `provenance.kind = derived` shape. `--ada-usd` is removed.
- The retired flags fail parsing with a typed error pointing at their
  replacement.

## Design decisions

### D1 — Decouple retrieval from the wizard

`swap-wizard` becomes "given a rate (and optionally a slippage policy
to apply on top), build an intent". Live HTTP, source selection,
slippage policy gating, audit JSON, and affordability checks belong to
`swap-quote`. The wizard's quote-derived path goes away.

Trade-offs:

- Pro: removes one of the two places the silent-USDM≈USD bug could
  recur, halves the live-fetch surface.
- Pro: wizard tests no longer need `IO`/network mocks.
- Pro: the `WizardRate` ADT collapses from two- to two-clean
  constructors (`WizardMinRate Double | WizardOverrideRate Double SlippageBps`).
- Con: an operator who used to invoke just `swap-wizard --price-source ...`
  must now run `swap-quote` (which already exists and does end-to-end).
  CHANGELOG flags this.

### D2 — Replace the `QuoteSource` ADT, don't extend

`QuoteSource = CoinGeckoAdaUsdm` (single constructor). The old
`CoinGeckoAdaUsd` is removed. `parseQuoteSourceName` rejects
`coingecko-ada-usd` with a typed retirement error pointing at the
new name (or `--ada-usdm`).

### D3 — Derived provenance is structural

(Delivered in slice 1.) `QuoteProvenance` gains a
`DerivedQuoteProvenance { name :: Text, components :: NonEmpty ComponentObservation }`
constructor. `ComponentObservation { coName, coValue, coFetchedAt, coRaw }`
is a new record. The encoder emits the `kind: "derived"` shape
contracted in `contracts/swap-quote-audit-json.md`.

### D4 — Drop `--ada-usd` and `AdaUsdOverride`

Both commands lose the `--ada-usd DECIMAL` flag. The `QuoteInput.AdaUsdOverride`
constructor goes too. `QuotePair.AdaUsd` stays — it is the label for
one of the two component observations inside a derived provenance.

### D5 — Two upstream fetches, single execution timestamp

`swap-quote`'s `coingeckoAdaUsdmProvider` issues two sequential
`httpLBS` calls, each preceded by the trust-anchor stderr line. The
wizard's `observedAt` is computed once at run start; each component
carries its own per-request `fetchedAt`.

### D6 — Live boundary smoke is an operator script

`just ci` keeps unit + golden + lint + smoke (`tx-build-pipe`). A
live CoinGecko fetch is not in the gate (rate-limited public API,
operator-side acceptance check per #110). We ship
`scripts/smoke/swap-quote-live-usdm.sh` as a manual operator
verification and document it in `docs/swap.md`.

## Risks & edge cases

- **R1** — `usdm-2.usd = 0` or missing. Reuse
  `QuoteSourceInvalidQuote`/`QuoteSourceMissingField` parameterized by
  component name.
- **R2** — Wizard's existing intent goldens use the quote-derived
  path with `--ada-usdm` + `--slippage-bps` (no live HTTP); these
  goldens stay valid because the wizard's derivation math is
  unchanged. We remove only the `--price-source` / `--ada-usd` parser
  branches and their tests.
- **R3** — `swap-quote` goldens for `params.built.expected.json` and
  `params.affordability-failed.expected.json` currently use
  `qoPair = AdaUsd + OperatorOverride`. After this PR the only
  reachable override pair is ADA/USDM, so these goldens are
  regenerated with `qoPair = AdaUsdm`. Numeric values stay identical
  (the override decimal is the same).
- **R4** — `parseCoinGeckoAdaUsdResponse` becomes a component-level
  helper. The test that asserted the old top-level shape gets
  updated to assert a `ComponentObservation` build instead.
- **R5** — `fetchQuoteSource` signature (`QuoteSource → Text → m (Either …)`)
  stays the same; only the implementation under the hood changes.
  Tests that exercise the provider via `qpFetchQuote` keep their
  shape.
- **R6** — `WizardOpts` import surface shrinks (no quote provider,
  no `SwapQuoteSource`, no `SwapQuoteQuoteArg`). Removed imports and
  removed names from `Cli/SwapWizard.hs`, `Cli/SwapCommon.hs`, and
  `Cli/SwapOptions.hs` must be cleaned up to satisfy
  `-Wunused-imports`.

## Vertical slices

### Slice 1 — Derived provenance type and audit encoder *(DONE)*

`DerivedQuoteProvenance` constructor + `ComponentObservation` record
added to `QuoteProvenance` in `lib/Amaru/Treasury/Tx/SwapQuote.hs`.
`quoteProvenanceValue` and `quoteValue` emit the contracted shape.
Helper `formatRationalDecimalAt :: Int -> Rational -> Text` added so
non-2/5 denominators (typical for derived ratios) format cleanly at a
fixed scale. New golden test
`test/golden/SwapQuoteAuditGoldenSpec.hs` + fixture
`test/fixtures/swap-quote/params.built-derived.expected.json` cover
the new shape. Production code paths still emit
`OperatorOverride`/`QuoteSourceProvenance` at the end of this slice.

### Slice 2 — De-fetch the wizard

**Scope** (`lib/Amaru/Treasury/Cli/SwapWizard.hs` and friends):

- Drop `quoteP`-based parsing from `wizardRateP`. `WizardRate` becomes
  `WizardMinRate Double | WizardOverrideRate Double SlippageBps`.
- Remove imports of `SwapQuoteQuoteArg`, `quoteP`, `resolveSwapQuoteObservation`.
- `resolveWizardSwapParameters` collapses to two arms — `WizardMinRate`
  (existing math) and `WizardOverrideRate` (call `deriveSwapParameters`
  with a hand-rolled `QuoteObservation { qoPair = AdaUsdm, qoQuote = Q, qoProvenance = OperatorOverride }`).
- `Cli/SwapWizard.hs` no longer reads `currentIso8601` (no provenance
  fetched-at), and no longer pulls `Cli/SwapCommon`'s quote helpers.
- Unit / red tests for the wizard:
  - update `SwapWizardSpec` / `SwapWizardRedSpec` parser cases that
    referenced `--ada-usd`, `--ada-usdm`-without-slippage, or
    `--price-source` to use the new surface.
  - add a parser-rejection case for `--price-source` (no longer valid)
    and `--ada-usd` (no longer valid) on the wizard.

**Proof**: parser tests for accept/reject, plus a derive-math test
that `--ada-usdm 0.27 --slippage-bps 100` produces `minRate = 0.2673`
(the existing math, exercised through the new wizard rate path).

**Commit message**: `feat(110): remove live quote retrieval from swap-wizard`

### Slice 3 — Replace the named source in swap-quote

**Scope** (`lib/Amaru/Treasury/Tx/SwapQuote/Source.hs`,
`lib/Amaru/Treasury/Cli/SwapOptions.hs`,
`lib/Amaru/Treasury/Cli/SwapCommon.hs`,
`lib/Amaru/Treasury/Cli/SwapQuote.hs`):

- `QuoteSource`: replace `CoinGeckoAdaUsd` with `CoinGeckoAdaUsdm`.
- `parseQuoteSourceName`: map `coingecko-ada-usdm` → `CoinGeckoAdaUsdm`;
  map `coingecko-ada-usd` → typed retirement error
  (`RetiredAdaUsdSource Text`, rendered as
  `"coingecko-ada-usd retired: use coingecko-ada-usdm or --ada-usdm"`).
- `quoteSourceName`, `renderQuoteSourceError`: matching cases.
- Add `coinGeckoUsdmRequest :: IO Request`,
  `parseCoinGeckoUsdmUsdComponent`, and turn
  `parseCoinGeckoAdaUsdResponse` into the analogous component
  builder. Both build `ComponentObservation`.
- `coingeckoAdaUsdmProvider :: QuoteProvider IO` performs two
  sequential fetches (trust-anchor line before each) and composes
  `qoQuote = adaUsd / usdmUsd`, `qoPair = AdaUsdm`, `qoProvenance = DerivedQuoteProvenance "coingecko-ada-usdm" (adaUsdComp :| [usdmUsdComp])`.
- `QuoteInput`: drop `AdaUsdOverride`. `parseQuoteInput` only
  `AdaUsdmOverride`.
- `Cli/SwapOptions.hs::quoteP` becomes `adaUsdmP <|> priceSourceP`;
  help text updated to mention `coingecko-ada-usdm`.
- `Cli/SwapCommon.hs`: `resolveSwapQuoteObservation` keeps its shape
  but passes the new provider.
- Test fixtures:
  - rename `source.coingecko.json` → `source.coingecko-ada-usd.json`;
  - add `source.coingecko-usdm-usd.json` containing
    `{"usdm-2":{"usd":0.996629}}`;
  - drop `quote.ada-usd.override.json`.
- Tests (`SwapQuoteSpec`):
  - parser tests: accept `--price-source coingecko-ada-usdm`; reject
    `--price-source coingecko-ada-usd` and `--ada-usd …`; the
    `quoteSourceName` test changes to the new constructor; remove the
    `"recognises coingecko-ada-usd as the named ADA/USD source"` case;
    remove `AdaUsdOverride` round-trip cases.
  - provider test: drive `coingeckoAdaUsdmProvider` through a stub
    `QuoteProvider` that returns the two captured fixtures; assert
    the composed observation.
- Goldens: regenerate `params.built.expected.json` and
  `params.affordability-failed.expected.json` with
  `qoPair = AdaUsdm + OperatorOverride` (numeric values unchanged).

**Proof**: RED is the new parser-rejection test for
`coingecko-ada-usd`, the new provider-composition test, and the
regenerated goldens. GREEN folds in the ADT swap, parser change,
provider impl, CLI flag removal, and fixture migration.

**Commit message**: `feat(110): replace coingecko-ada-usd with derived coingecko-ada-usdm in swap-quote`

### Slice 4 — Docs and operator-side live smoke

- `docs/swap.md`: replace the "Recommended quote-derived workflow"
  snippet with `swap-quote --price-source coingecko-ada-usdm`; add an
  "Operator-supplied rate" subsection covering
  `swap-wizard --ada-usdm Q --slippage-bps S` and
  `swap-wizard --min-rate R`.
- `scripts/smoke/swap-quote-live-usdm.sh` (mode 0755): one live
  invocation, asserts `quote.value × usdmUsd ≈ adaUsd` within `1e-9`.
- `CHANGELOG.md`: `[Unreleased]` entry calling
  `--price-source coingecko-ada-usd` and `--ada-usd` removal a
  Breaking change, and noting that `swap-wizard` no longer accepts
  `--price-source`.

**Proof**: docs-only; no test changes. Gate runs `just ci` unchanged.

**Commit message**: `docs(110): document derived ADA/USDM source and wizard rate inputs`

## Gate

`nix develop --quiet -c just ci` for every slice. No new recipes.

## Out of scope (verbatim from spec)

- On-chain oracle integration (Option B).
- Cross-source consistency checks.
- Authenticated CoinGecko Pro tier.
- New retry/back-off policy.
