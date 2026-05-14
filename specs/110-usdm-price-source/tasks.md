# Tasks: USDM Price Source for swap-wizard

**Plan**: [plan.md](plan.md) | **Spec**: [spec.md](spec.md) | **PR**: [#114](https://github.com/lambdasistemi/amaru-treasury-tx/pull/114)

Each numbered slice is **one bisect-safe commit**. RED-task fixtures
and tests land in the same commit as the GREEN-task implementation.
"RED before commit" means the test must be authored to fail against
the current production code; "GREEN in same commit" means the
implementation that makes it pass is folded in before the commit is
finalized.

## Slice 1 — Derived provenance type and audit encoder

**Goal**: introduce the new `QuoteProvenance` constructor and the
audit-JSON encoder branch behind it, exercised only by a new golden
test. Production code paths still emit `OperatorOverride` /
`QuoteSourceProvenance` after this slice; no CLI or provider change.

### Tasks

- **T1.1** (RED, in slice): add fixture `test/fixtures/swap-quote/params.built-derived.expected.json` containing the derived-audit shape from `contracts/swap-quote-audit-json.md`. Pair a new `it "matches the built-derived params.json golden"` case in `test/golden/SwapQuoteAuditGoldenSpec.hs` that builds a `SwapQuoteAudit` whose `dspQuote.qoProvenance` is a hand-constructed `DerivedQuoteProvenance` with two `ComponentObservation` entries. The new case must fail to compile before T1.2 lands (the constructor does not yet exist).
- **T1.2** (GREEN, in slice): in `lib/Amaru/Treasury/Tx/SwapQuote.hs`, add `data ComponentObservation = ComponentObservation { coName, coFetchedAt, coRaw :: !Text, coValue :: !Rational }` and the `DerivedQuoteProvenance { dqpName :: !Text, dqpComponents :: !(NonEmpty ComponentObservation) }` constructor on `QuoteProvenance`. Extend `quoteProvenanceValue` to emit the contracted shape and `quoteValue` to expose `pair`, `value`, `provenance`, `observedAt`. Export `ComponentObservation(..)`.
- **T1.3** (gate, in slice): `nix develop --quiet -c just ci` green; commit titled `feat(110): derived quote provenance type and audit encoder`.

**Bisect check**: at HEAD of slice 1, `cabal test golden-tests` passes (including the new built-derived case) and the existing override/source golden cases still pass — slice 1 is type-additive only.

## Slice 2 — Replace the named source

**Goal**: swap `CoinGeckoAdaUsd` for `CoinGeckoAdaUsdm`, implement the derived provider, prune the silent-USDM≈USD CLI surface, and update tests + fixtures.

### Tasks

- **T2.1** (RED, in slice): add fixture `test/fixtures/swap-quote/source.coingecko-usdm-usd.json` containing a captured `{"usdm-2":{"usd":0.996629}}`-shaped response. Rename `source.coingecko.json` → `source.coingecko-ada-usd.json` (content unchanged). Remove `quote.ada-usd.override.json`. Update `SwapQuoteSpec.hs`:
  - replace the `"recognises coingecko-ada-usd as the named ADA/USD source"` case with one that asserts `quoteSourceName CoinGeckoAdaUsdm = "coingecko-ada-usdm"`.
  - replace the `"accepts coingecko-ada-usd as the only named source"` case with `--price-source coingecko-ada-usdm` accepted.
  - replace the `"rejects named ADA/USDM live sources with a future-work error"` case with `parseQuoteSourceName "coingecko-ada-usd"` returning a typed retirement error pointing at `coingecko-ada-usdm` / `--ada-usdm`.
  - remove the `"accepts an explicit ADA/USD override quote input"` case and the unhappy-path cases that referenced `AdaUsdOverride`.
  - replace `"parses a captured coingecko-ada-usd response with provenance"` with `"composes a coingecko-ada-usdm derived observation"` that drives a stub `QuoteProvider IO` returning two component fixtures, builds the derived `QuoteObservation`, and asserts `qoPair = AdaUsdm`, `qoQuote = adaUsd / usdmUsd`, both components captured in `DerivedQuoteProvenance`.
- **T2.2** (GREEN, in slice): in `lib/Amaru/Treasury/Tx/SwapQuote/Source.hs`:
  - replace `QuoteSource = CoinGeckoAdaUsd` with `CoinGeckoAdaUsdm`.
  - rename the existing parser to `parseCoinGeckoAdaUsdComponent :: Text -> Text -> Either QuoteSourceError ComponentObservation` (or keep `parseCoinGeckoAdaUsdResponse` and have it return a `ComponentObservation`-yielding helper). Add the analogous `parseCoinGeckoUsdmUsdComponent` that reads `{"usdm-2":{"usd":N}}`. Both helpers reuse `decodeUtf8Lenient` and produce `ComponentObservation` with `coName`, `coFetchedAt`, `coRaw`, `coValue`.
  - add `coinGeckoUsdmRequest :: IO Request` mirroring `coinGeckoRequest`, hitting `https://api.coingecko.com/api/v3/simple/price?ids=usdm-2&vs_currencies=usd`, same timeout and User-Agent.
  - replace `coingeckoAdaUsdProvider` with `coingeckoAdaUsdmProvider :: QuoteProvider IO` that:
    1. calls `describeTlsTrustAnchor >>= hPutStrLn stderr` and `httpLBS` against `coinGeckoRequest`, parses into a `ComponentObservation` named `coingecko-ada-usd`,
    2. repeats the trust-anchor line and `httpLBS` against `coinGeckoUsdmRequest`, parses into a component named `coingecko-usdm-usd`,
    3. composes into a `QuoteObservation { qoPair = AdaUsdm, qoQuote = adaUsd / usdmUsd, qoProvenance = DerivedQuoteProvenance "coingecko-ada-usdm" (adaUsdComp :| [usdmUsdComp]) }`.
  - update `parseQuoteSourceName` to map `coingecko-ada-usdm` → `CoinGeckoAdaUsdm` and `coingecko-ada-usd` → typed retirement error `RetiredAdaUsdSource Text` (rendered as `coingecko-ada-usd retired: use coingecko-ada-usdm or --ada-usdm`).
  - update `quoteSourceName`, `renderQuoteSourceError`.
- **T2.3** (GREEN, in slice): in `lib/Amaru/Treasury/Tx/SwapQuote.hs`:
  - drop `AdaUsdOverride` from `QuoteInput`. `parseQuoteInput` becomes a single-arm function over `AdaUsdmOverride`. `QuotePair` keeps both `AdaUsd` and `AdaUsdm` for component labeling.
- **T2.4** (GREEN, in slice): in `lib/Amaru/Treasury/Cli/SwapOptions.hs`:
  - remove the `--ada-usd` branch from `quoteP` (`adaUsdmP <|> priceSourceP`).
  - update `priceSourceReader` help text to mention `coingecko-ada-usdm`.
- **T2.5** (GREEN, in slice): in `lib/Amaru/Treasury/Cli/SwapCommon.hs`:
  - rename the import `coingeckoAdaUsdProvider` → `coingeckoAdaUsdmProvider` and update `resolveSwapQuoteObservation` to pass it.
- **T2.6** (GREEN, in slice): update golden fixtures touched by removed pairs:
  - `test/fixtures/swap-quote/params.built.expected.json` and `params.affordability-failed.expected.json` currently encode `quote.pair = "ADA/USD"`. Two options:
    - regenerate them with `qoPair = AdaUsdm` and an explicit-override provenance, since the test data builder used `AdaUsd + OperatorOverride`, and update `SwapQuoteAuditGoldenSpec.hs` `sampleDerivedParameters` to use `AdaUsdm`.
    - **Chosen**: regenerate. The fixtures represent the "override path" survivor; after #110 that path is `--ada-usdm`, so the audit pair is `ADA/USDM`. Keep numeric values identical (the override decimal is the same).
- **T2.7** (gate, in slice): `nix develop --quiet -c just ci` green; commit titled `feat(110): replace coingecko-ada-usd with derived coingecko-ada-usdm`.

**Bisect check**: at HEAD of slice 2, `--price-source coingecko-ada-usdm --slippage-bps N` is the only named-source path; `--price-source coingecko-ada-usd` rejects with the retirement error; `--ada-usd DECIMAL` fails parser (unknown flag). All unit + golden tests pass.

## Slice 3 — Docs and operator-side live smoke

**Goal**: align user-facing docs with the new surface and ship a runnable live smoke an operator can invoke. No code under `lib/` or `app/` changes.

### Tasks

- **T3.1** (docs): rewrite the "Recommended quote-derived workflow" section of `docs/swap.md`:
  - command snippet uses `--price-source coingecko-ada-usdm`.
  - one paragraph documenting the two-upstream composition (ADA/USD ÷ USDM/USD) and the per-component trust-anchor stderr lines.
  - update the second paragraph about overrides to remove `--ada-usd DECIMAL`.
- **T3.2** (docs): add CHANGELOG entry under `[Unreleased]` calling the removal of `--price-source coingecko-ada-usd` and `--ada-usd DECIMAL` a **Breaking change**, citing the silent USDM≈USD bug, and pointing at the new flag.
- **T3.3** (smoke): add `scripts/smoke/swap-quote-live-usdm.sh` (mode 0755):
  - runs the wizard against a real socket with `--price-source coingecko-ada-usdm --slippage-bps 100 --usdm 100`, captures `params.json`,
  - extracts `quote.value` (derived) and the two component values,
  - asserts `quote.value × usdmUsd ≈ adaUsd` (within `1e-9`), proving the composition,
  - documents the env it needs (`CARDANO_NODE_SOCKET_PATH`, `WALLET_ADDR`, `METADATA`).
- **T3.4** (docs): under "TLS trust anchor" in `docs/swap.md`, add a one-line cross-reference to `scripts/smoke/swap-quote-live-usdm.sh` for the operator-side live check.
- **T3.5** (gate, in slice): `nix develop --quiet -c just ci` green; commit titled `docs(110): document derived ADA/USDM source and ship operator smoke`.

## Folding map

| RED test                                                                                       | GREEN impl                                                                              | Commit                                                                                |
| ---------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------- |
| `built-derived params.json` golden (T1.1)                                                      | `DerivedQuoteProvenance` + encoder (T1.2)                                               | slice 1                                                                               |
| `quoteSourceName CoinGeckoAdaUsdm` (T2.1)                                                      | `QuoteSource = CoinGeckoAdaUsdm` (T2.2)                                                 | slice 2                                                                               |
| `--price-source coingecko-ada-usdm` accepted, `coingecko-ada-usd` rejected with retirement (T2.1) | parser changes (T2.2) + CLI flag removal (T2.4)                                         | slice 2                                                                               |
| `coingecko-ada-usdm` derived-composition test against stub `QuoteProvider` (T2.1)              | derived provider (T2.2) + wizard wiring (T2.5)                                          | slice 2                                                                               |
| n/a (docs)                                                                                     | `docs/swap.md` + CHANGELOG + smoke script (T3.1–T3.4)                                   | slice 3                                                                               |

## Out of scope (verbatim from spec)

- On-chain oracle integration (Option B).
- Cross-source consistency checks.
- Authenticated CoinGecko Pro tier.
- New retry/back-off policy.
