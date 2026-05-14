# Tasks: USDM Price Source — wizard de-fetching + swap-quote derivation

**Plan**: [plan.md](plan.md) | **Spec**: [spec.md](spec.md) | **PR**: [#114](https://github.com/lambdasistemi/amaru-treasury-tx/pull/114)

Each numbered slice is **one bisect-safe commit**. RED-task fixtures
and tests land in the same commit as the GREEN-task implementation.

## Slice 1 — Derived provenance type and audit encoder *(DONE)*

Delivered. `ComponentObservation` + `DerivedQuoteProvenance` added in
`lib/Amaru/Treasury/Tx/SwapQuote.hs`. `quoteProvenanceValue` and
`quoteValue` handle the new constructor. New golden test in
`test/golden/SwapQuoteAuditGoldenSpec.hs` covered by fixture
`test/fixtures/swap-quote/params.built-derived.expected.json`.

Production code paths still emit `OperatorOverride` and
`QuoteSourceProvenance` at HEAD of slice 1.

## Slice 2 — De-fetch the wizard

**Goal**: `swap-wizard` no longer accepts `--price-source` or
`--ada-usd`. `WizardRate` collapses to two clean constructors. No
outbound HTTP in the wizard's module graph.

### Tasks

- **T2.1** (RED, in slice): update parser tests in
  `test/unit/Amaru/Treasury/Tx/SwapWizardSpec.hs` and
  `test/red/Amaru/Treasury/Tx/SwapWizardRedSpec.hs`:
  - reject `swap-wizard ... --price-source coingecko-ada-usd ...`.
  - reject `swap-wizard ... --ada-usd 0.27 --slippage-bps 100 ...`.
  - accept `swap-wizard ... --ada-usdm 0.27 --slippage-bps 100 ...` and
    `swap-wizard ... --min-rate 0.27 ...` (existing).
- **T2.2** (GREEN, in slice): in `lib/Amaru/Treasury/Cli/SwapWizard.hs`:
  - replace `WizardRate = WizardMinRate Double | WizardQuoteRate SwapQuoteQuoteArg SlippageBps` with `WizardMinRate Double | WizardOverrideRate Double SlippageBps`.
  - rewrite `wizardRateP` to use `--min-rate` xor `--ada-usdm + --slippage-bps`.
  - rewrite `resolveWizardSwapParameters`: the `WizardOverrideRate Q S` arm builds `QuoteObservation { qoPair = AdaUsdm, qoQuote = toRational Q, qoProvenance = OperatorOverride }` and calls `SQ.deriveSwapParameters`.
  - remove imports of `SwapQuoteQuoteArg`, `quoteP`, `resolveSwapQuoteObservation`, `currentIso8601`, `providerToResolverEnv` traces tied to quote resolution.
- **T2.3** (GREEN, in slice): drop dead imports / dead code that no
  longer compile after T2.2 (e.g. `Amaru.Treasury.Cli.SwapCommon`'s
  `resolveSwapQuoteObservation` call site from the wizard; the
  helper itself stays for `swap-quote`).
- **T2.4** (gate, in slice): `nix develop --quiet -c just ci` green;
  commit titled `feat(110): remove live quote retrieval from swap-wizard`.

**Bisect check**: `swap-wizard --price-source coingecko-ada-usd` fails parsing; existing override/min-rate paths still work; goldens unchanged for swap-quote.

## Slice 3 — Replace the named source in swap-quote

**Goal**: `swap-quote`'s only named source is `coingecko-ada-usdm`,
implemented as a derived two-component fetch. `--ada-usd` is removed.

### Tasks

- **T3.1** (RED, in slice): test fixtures:
  - add `test/fixtures/swap-quote/source.coingecko-usdm-usd.json` containing the captured `{"usdm-2":{"usd":0.996629}}`.
  - rename `source.coingecko.json` → `source.coingecko-ada-usd.json`.
  - delete `quote.ada-usd.override.json`.
- **T3.2** (RED, in slice): test cases in `test/unit/Amaru/Treasury/Tx/SwapQuoteSpec.hs`:
  - replace `"recognises coingecko-ada-usd as the named ADA/USD source"` → `"recognises coingecko-ada-usdm as the named ADA/USDM source"` asserting `quoteSourceName CoinGeckoAdaUsdm = "coingecko-ada-usdm"`.
  - replace `"accepts coingecko-ada-usd as the only named source"` with `--price-source coingecko-ada-usdm` accepted.
  - replace `"rejects named ADA/USDM live sources with a future-work error"` with `parseQuoteSourceName "coingecko-ada-usd"` returning the typed retirement error.
  - drop `"accepts an explicit ADA/USD override quote input"` and `AdaUsdOverride` cases.
  - replace `"parses a captured coingecko-ada-usd response with provenance"` with `"composes a coingecko-ada-usdm derived observation"`: drive a stub `QuoteProvider IO` that returns the two component fixtures and assert `qoPair = AdaUsdm`, `qoQuote = adaUsd/usdmUsd`, both components captured in `DerivedQuoteProvenance`.
- **T3.3** (GREEN, in slice): `lib/Amaru/Treasury/Tx/SwapQuote/Source.hs`:
  - replace `QuoteSource = CoinGeckoAdaUsd` with `CoinGeckoAdaUsdm`.
  - rename the existing parser to a component builder (or keep its
    name and have it return a `ComponentObservation`). Add
    `parseCoinGeckoUsdmUsdComponent`.
  - add `coinGeckoUsdmRequest :: IO Request` (URL ids=`usdm-2`).
  - replace `coingeckoAdaUsdProvider` with `coingeckoAdaUsdmProvider`:
    sequential fetches, trust-anchor line before each, compose
    `qoQuote = adaUsd / usdmUsd`, `qoProvenance = DerivedQuoteProvenance "coingecko-ada-usdm" …`.
  - extend `parseQuoteSourceName`: accept `coingecko-ada-usdm`;
    `coingecko-ada-usd` → typed `RetiredAdaUsdSource Text`.
  - update `quoteSourceName`, `renderQuoteSourceError`.
- **T3.4** (GREEN, in slice): in `lib/Amaru/Treasury/Tx/SwapQuote.hs`:
  - drop `AdaUsdOverride` from `QuoteInput`. `parseQuoteInput` only
    handles `AdaUsdmOverride`.
- **T3.5** (GREEN, in slice): `lib/Amaru/Treasury/Cli/SwapOptions.hs`:
  - drop `adaUsdP` branch. `quoteP` becomes `adaUsdmP <|> priceSourceP`.
  - `priceSourceP` help text updated.
- **T3.6** (GREEN, in slice): `lib/Amaru/Treasury/Cli/SwapCommon.hs`:
  - rename import `coingeckoAdaUsdProvider` → `coingeckoAdaUsdmProvider`.
  - update `resolveSwapQuoteObservation` to use the new provider.
- **T3.7** (GREEN, in slice): regenerate
  `test/fixtures/swap-quote/params.built.expected.json` and
  `params.affordability-failed.expected.json` with
  `quote.pair = "ADA/USDM"` (override provenance, numeric values
  unchanged). Update `test/golden/SwapQuoteAuditGoldenSpec.hs`
  `sampleDerivedParameters` to use `AdaUsdm`.
- **T3.8** (gate, in slice): `nix develop --quiet -c just ci` green;
  commit titled `feat(110): replace coingecko-ada-usd with derived coingecko-ada-usdm in swap-quote`.

**Bisect check**: at HEAD, `swap-quote --price-source coingecko-ada-usdm --slippage-bps N` is the only named-source path; `swap-quote --price-source coingecko-ada-usd` returns the retirement error; `swap-quote --ada-usd 0.27` fails parsing.

## Slice 4 — Docs and operator-side live smoke

- **T4.1**: rewrite "Recommended quote-derived workflow" in
  `docs/swap.md` to use `swap-quote --price-source coingecko-ada-usdm`.
- **T4.2**: add "Operator-supplied rate" subsection covering
  `swap-wizard --ada-usdm Q --slippage-bps S` and
  `swap-wizard --min-rate R`.
- **T4.3**: `scripts/smoke/swap-quote-live-usdm.sh` (0755) — one
  live invocation, prints derived rate, asserts
  `quote.value × usdmUsd ≈ adaUsd` within `1e-9`. Document env
  (`CARDANO_NODE_SOCKET_PATH`, `WALLET_ADDR`, `METADATA`).
- **T4.4**: CHANGELOG `[Unreleased]` Breaking-change entry noting
  removal of `--price-source coingecko-ada-usd`, `--ada-usd`, and the
  wizard's `--price-source`/`--ada-usd`/`--ada-usdm`-without-slippage
  surface change.
- **T4.5**: gate green; commit titled
  `docs(110): document derived ADA/USDM source and wizard rate inputs`.

## Folding map

| RED test                                                                          | GREEN impl                                       | Commit  |
| --------------------------------------------------------------------------------- | ------------------------------------------------ | ------- |
| derived golden (T1.1) *(done)*                                                    | `DerivedQuoteProvenance` + encoder (T1.2) *(done)* | slice 1 |
| wizard rejects `--price-source`, `--ada-usd` (T2.1)                               | `WizardRate` collapse + parser rewrite (T2.2)    | slice 2 |
| `quoteSourceName CoinGeckoAdaUsdm` (T3.2)                                         | `QuoteSource = CoinGeckoAdaUsdm` (T3.3)          | slice 3 |
| `swap-quote --price-source coingecko-ada-usdm` accepted, retirement error (T3.2)  | parser + CLI flag removal (T3.3, T3.5)           | slice 3 |
| derived-composition via stub provider (T3.2)                                      | `coingeckoAdaUsdmProvider` (T3.3, T3.6)          | slice 3 |
| regenerated override goldens (T3.1)                                               | `quoteValue` for ADA/USDM override path (T3.4)   | slice 3 |
| n/a (docs)                                                                        | docs + smoke + CHANGELOG (T4.1–T4.4)             | slice 4 |

## Out of scope

- On-chain oracle integration (Option B).
- Cross-source consistency checks.
- Authenticated CoinGecko Pro tier.
- New retry/back-off policy.
