# Plan: USDM Price Source for swap-wizard

**Spec**: [spec.md](spec.md) | **Contracts**: [contracts/](contracts/) | **Date**: 2026-05-14

## Outcome

After this PR the only named live quote source is
`coingecko-ada-usdm`, which derives ADA/USDM as `(ADA/USD) ÷ (USDM/USD)` from
two CoinGecko `simple/price` calls (`ids=cardano` and `ids=usdm-2`). The
audit JSON records both upstream observations under a new
`provenance.kind = derived` shape. The old `--price-source
coingecko-ada-usd` and `--ada-usd DECIMAL` paths are removed because
they shared the silent USDM≈USD assumption.

## Design decisions

### D1 — Replace the `QuoteSource` ADT, don't extend

`QuoteSource` currently has one constructor (`CoinGeckoAdaUsd`). The
issue's recommended option (A) is to derive ADA/USDM from two
upstream ADA/USD and USDM/USD calls. Since the resulting observation
*is* a single ADA/USDM quote, the right modeling is:

```haskell
data QuoteSource = CoinGeckoAdaUsdm
```

A `QuoteSource → QuoteObservation{ qoPair = AdaUsdm, qoProvenance = DerivedQuoteProvenance … }` mapping. We do not multiplex over both
old and new constructors — keeping `CoinGeckoAdaUsd` alongside would
preserve the trap.

Trade-off: this is a breaking change for any operator script wired to
`--price-source coingecko-ada-usd`. The CLI parser surfaces a
purposeful error message pointing at the new name, and the
release notes call it out.

### D2 — Derived provenance is structural, not a string

Adding a third `QuoteProvenance` constructor (rather than encoding
"derived" as a special-cased `QuoteSourceProvenance` name) lets the
type system carry the invariant "a derived observation has ≥1
component observations." The encoder uses pattern matching, so the
golden test catches any regression in the shape.

```haskell
data QuoteProvenance
    = OperatorOverride
    | QuoteSourceProvenance     -- single-fetch source
        { qspName, qspFetchedAt, qspRaw :: !Text }
    | DerivedQuoteProvenance    -- composed source
        { dqpName       :: !Text
        , dqpComponents :: !(NonEmpty ComponentObservation)
        }

data ComponentObservation = ComponentObservation
    { coName, coFetchedAt, coRaw :: !Text
    , coValue                    :: !Rational
    }
```

`QuoteSourceProvenance` stays in the type for legacy provenance
deserialization; no code path emits it after this PR.

### D3 — `--ada-usd DECIMAL` is removed alongside the named source

The explicit override has the same silent-conversion bug as the
retired source (operator passes an ADA/USD figure, wizard treats it
as USDM/ADA). Removing both keeps the system honest: every quote
path used by the wizard is ADA/USDM by construction (override or
derived). `--ada-usdm DECIMAL` stays as the manual escape hatch.

`QuoteInput`'s `AdaUsdOverride` is removed. `QuotePair`'s `AdaUsd`
constructor stays — it is the label for one of the two component
observations inside a derived provenance.

### D4 — Two upstream fetches, single execution timestamp

The wizard's `observedAt` is computed once at run start and recorded
on the outer `QuoteObservation`. Each component carries its own
`fetchedAt` (per-request ISO-8601 timestamp). This means the audit
records both "when the wizard ran" and "when each upstream was hit",
which matters when the two upstream responses are minutes apart at
peak rate-limit pushback.

The provider issues the two fetches sequentially. We do not
parallelize: the trust-anchor stderr line must precede each call,
and serial fetches keep the trace ordering deterministic.

### D5 — Trust anchor line printed per upstream

`describeTlsTrustAnchor` is called once before each
`httpLBS`. The existing single-call wrapper becomes a two-call
wrapper inside `coingeckoAdaUsdmProvider`.

### D6 — Live boundary smoke deferred to operator follow-up

The `just ci` gate stays unit + golden + lint, exercising captured
fixtures only. A live CoinGecko fetch is not part of the gate
because:

- The public CoinGecko endpoint rate-limits aggressively (we hit 429
  during research).
- The acceptance criterion in #110 names a manual live run as the
  operator-side check, not a CI step.

We do, however, ship a runnable smoke script under
`scripts/smoke/swap-quote-live-usdm.sh` that an operator can invoke
to perform the live verification described in the issue. The script
is documented in `docs/swap.md` and is not wired into `just ci`.

## Risks & edge cases

- **R1** — `usdm-2.usd = 0` or missing field. Handled by reusing the
  existing `QuoteSourceInvalidQuote`/`QuoteSourceMissingField`
  errors, parameterized by component name so the operator sees which
  upstream failed.
- **R2** — Integer rounding drift. Derived `qoQuote = a/b` (exact
  `Rational`). `deriveSwapParameters` does the existing
  `floor(qoQuote × (1-bps/10000) × 10^6)`. The unit test asserts the
  six-decimal-floored numerator against a worked example.
- **R3** — Old fixture references. `test/fixtures/swap-quote/source.coingecko.json`
  is renamed (or replaced) to mirror the two upstream calls. Any
  hard-coded path in tests must be updated.
- **R4** — `parseCoinGeckoAdaUsdResponse` is still callable for the
  internal component path; we keep its name and signature but adjust
  the provenance returned to a `ComponentObservation` builder.
  Public API call sites: tests only — `SwapQuoteSpec.hs:251-264`.
- **R5** — Migration messaging. `parseQuoteSourceName "coingecko-ada-usd"`
  returns a typed error pointing at `coingecko-ada-usdm` / `--ada-usdm`,
  not a generic "unknown source". CHANGELOG calls this out as a
  breaking change.
- **R6** — `quote.ada-usd.override.json` fixture and the unit test
  case for `AdaUsdOverride` go away. The unit test then only covers
  `AdaUsdmOverride`.

## Vertical slices

Each slice is one bisect-safe commit. RED test and GREEN
implementation land in the same commit per the project's TDD/DDD
contract.

### Slice 1 — Derived provenance type and audit encoder

**Scope**: extend `QuoteProvenance` with a `DerivedQuoteProvenance`
constructor and the new `ComponentObservation` record. Teach
`swapQuoteAuditValue` / `quoteProvenanceValue` to emit the
`kind: "derived"` shape. Add a new golden fixture
`test/fixtures/swap-quote/params.built-derived.expected.json` and an
`it "matches the built-derived params.json golden"` case to
`SwapQuoteAuditGoldenSpec.hs`.

**No CLI / parser / provider change.** The new constructor is
unreachable from production code at the end of this slice — it is
exercised only by the golden test.

**Proof**: golden equality of the audit JSON for a sample audit
whose `dspQuote.qoProvenance` is a hand-constructed
`DerivedQuoteProvenance`. RED = new fixture is missing; GREEN =
fixture committed and encoder branch implemented.

### Slice 2 — Replace the named source: types, parser, provider, CLI, fixtures

**Scope**:

- `QuoteSource`: replace `CoinGeckoAdaUsd` with `CoinGeckoAdaUsdm`.
- `parseQuoteSourceName`: accept `coingecko-ada-usdm`; reject
  `coingecko-ada-usd` with a typed error pointing at the new name.
- `quoteSourceName`, `renderQuoteSourceError`: matching cases.
- `SwapQuote.Source`: add `coinGeckoUsdmRequest`,
  `parseCoinGeckoUsdmUsdResponse`. Rename the existing parser to
  match the component shape (`parseCoinGeckoAdaUsdComponent`?) or
  introduce a small helper that produces a `ComponentObservation`
  given (ids, USD JSON key, raw).
- `coingeckoAdaUsdmProvider :: QuoteProvider IO` performs the two
  fetches sequentially (trust-anchor line before each) and composes.
  Replaces the exported `coingeckoAdaUsdProvider`.
- `Cli/SwapOptions.hs`: drop `--ada-usd`; rename `quoteP` branches
  accordingly (`adaUsdmP <|> priceSourceP`).
- `QuoteInput`: drop `AdaUsdOverride`. `parseQuoteInput` only
  handles `AdaUsdmOverride`. `QuotePair` keeps both variants
  (component pair label).
- `Cli/SwapCommon.hs`: use new provider name.
- Test fixtures: rename `source.coingecko.json` →
  `source.coingecko-ada-usd.json`; add `source.coingecko-usdm-usd.json`;
  remove `quote.ada-usd.override.json`.
- Test code: update `SwapQuoteSpec.hs` (parser, provider, CLI parser
  cases) and any golden audit fixture references that mentioned the
  retired pair. Add a parser test that confirms the new error
  message for `coingecko-ada-usd`.

**Proof**:

- RED before: `parseSwapQuote ["--price-source", "coingecko-ada-usdm", …]` must succeed; current code rejects with `NamedAdaUsdmSourceUnavailable`.
- RED before: `parseQuoteSourceName "coingecko-ada-usd"` should fail with the new helpful-error variant.
- RED before: the new derived-provider golden (a recorded
  component-pair → derived observation, using a stub `QuoteProvider`).
- GREEN: ADT swap, parser change, provider implementation, CLI flag removal, fixture moves.

### Slice 3 — Docs and smoke script

**Scope**:

- `docs/swap.md`: replace the `--price-source coingecko-ada-usd`
  recommendation with `--price-source coingecko-ada-usdm`. Add a
  paragraph documenting the two-upstream composition.
- Add `scripts/smoke/swap-quote-live-usdm.sh` (mode 0755) that runs
  the live wizard end-to-end and prints the derived rate; document
  in `docs/swap.md` under the existing "TLS trust anchor" section.
- CHANGELOG entry under `[Unreleased]` calling the removal of
  `--price-source coingecko-ada-usd` and `--ada-usd` a breaking change.

**Proof**: docs/scripts only; no test changes. Gate runs `just ci`
unchanged. The smoke script is invoked manually and is not part of
`just smoke`.

## Gate

The author-run gate stays `nix develop --quiet -c just ci`. No new
recipes. The `just smoke` step continues to call
`scripts/smoke/tx-build-pipe`; the new live-USDM script is documented
but not wired into the gate (per D6).

## Out of scope (verbatim from spec)

- On-chain oracle integration (Option B).
- Cross-source consistency checks.
- Authenticated CoinGecko Pro tier.
- New retry/back-off policy.
