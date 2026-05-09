# Final Verification and PR Body Draft

Issue: #70
PR: #71
Branch: `070-quote-derived-swap-params`

## Completed Task Scope

Completed tasks: T001-T060.

T001-T015 were reconciled during final verification because the current
durable branch already contains the scaffold and derivation work:

- `amaru-treasury-tx.cabal` exposes `Amaru.Treasury.Tx.SwapQuote` and
  `Amaru.Treasury.Tx.SwapQuote.Source`, includes
  `Amaru.Treasury.Tx.SwapQuoteSpec` and `SwapQuoteAuditGoldenSpec`,
  tracks `test/fixtures/swap-quote/**/*.json` and `**/*.md`, and includes
  `http-conduit` plus `scientific`.
- `lib/Amaru/Treasury/Tx/SwapQuote.hs` and
  `lib/Amaru/Treasury/Tx/SwapQuote/Source.hs` exist with explicit export
  lists.
- `test/unit/Amaru/Treasury/Tx/SwapQuoteSpec.hs` covers quote/slippage
  derivation, invalid quote/slippage inputs, ADA/USDM overrides, and exact
  rounding semantics.
- `nix develop --quiet -c just ci` re-confirmed build and formatting for the
  final branch state.

## Final Verification Commands

- `nix develop --quiet -c just ci` exited 0. It ran build, schema-check,
  unit tests, golden tests, format-check, hlint, smoke, and release-check.
- `nix develop --quiet -c just cabal-check` exited 0:
  `No errors or warnings could be found in the package.`
- `bash llm/reviews/gate.sh` is the worker handoff gate for PR #71 and is
  recorded in `llm/reviews/work-review.md`.

## Documentation Consistency Review

Reviewed these files together:

- `specs/070-quote-derived-swap-params/quickstart.md`
- `docs/quickstart.md`
- `docs/swap.md`

They consistently document:

- `swap-quote` as the normal operator workflow.
- `--price-source coingecko-ada-usd` for the approved named live ADA/USD
  source.
- `--ada-usd` for deterministic ADA/USD quote overrides.
- `--ada-usdm` for explicit ADA/USDM quote overrides.
- `--slippage-bps` as required operator policy.
- Named live ADA/USDM sources as deferred until a provider contract is
  approved.
- Direct `swap-wizard --min-rate` as an expert/manual override with external
  quote, slippage, arithmetic, and affordability audit responsibility.

## PR Body Draft

### Summary

- Adds a quote-derived `swap-quote` operator path for swaps so operators no
  longer hand-compute `--min-rate`.
- Supports explicit ADA/USD and ADA/USDM quote overrides plus the named
  `coingecko-ada-usd` source.
- Requires explicit `--slippage-bps`, derives exact quote/slippage swap
  parameters, runs the existing swap wizard and unsigned builder path, checks
  treasury affordability before CBOR, and writes `params.json` audit records.
- Makes `swap-quote` the primary public swap documentation path and labels
  direct `swap-wizard --min-rate` use as expert/manual override material.

### Verification

- `nix develop --quiet -c just ci`
- `nix develop --quiet -c just cabal-check`
- `bash llm/reviews/gate.sh`
- `nix develop github:paolino/dev-assets?dir=mkdocs --quiet -c mkdocs build --strict --site-dir site`

### Deferred Follow-Up

- Named live ADA/USDM sources are deliberately deferred until a provider
  contract is approved. Explicit `--ada-usdm` overrides are supported in this
  issue.
