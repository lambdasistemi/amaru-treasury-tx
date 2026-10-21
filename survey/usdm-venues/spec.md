# USDM execution survey

## Outcome

Issue #492 produces one dated, reproducible market survey answering:

1. whether any currently executable route converts exactly
   `209424083770` lovelace into at least `40000000002` USDM base units;
2. whether any WingRiders V2 request with a script beneficiary has ever
   been batched, and how that rate compares with ordinary beneficiaries.

The result is research evidence, not product implementation or authority
to trade.

## Invariants

- `INV-ASSET`: the output asset is exactly
  `c48cbb3d5e57ed56e276bc45f99ab39abe94e6cd7ac39fb402da47ad.0014df105553444d`.
  A ticker, unlabelled name, USDCx, or any other stablecoin does not
  satisfy the target.
- `INV-VENUES`: inspect Minswap V1, Minswap V2, SundaeSwap V3,
  WingRiders V2, Splash, MuesliSwap, VyFinance, Danogo, and available
  aggregators. Each receives a proved classification: executable own
  liquidity, executable router over named underlying liquidity, or no
  executable ADA-to-USDM route. Every absence has a same-instrument
  positive control.
- `INV-NODE`: discovery may use Blockfrost, Koios, venue APIs, or public
  indexers, but every certified on-chain pool identity, outref, reserve,
  datum, and observation slot is re-queried through the fresh local
  mainnet node. Disagreements are reported.
- `INV-QUOTE`: every executable venue row names pool identity and outref,
  both reserves, fees, observed slot and UTC time, exact full-size output,
  a justified realistic clip output, and effective ADA per USDM including
  visible order overhead. Arithmetic uses integer base units and identifies
  rounding direction.
- `INV-ROUTING`: best-single and best-split results use the same market
  snapshot horizon. An aggregator contributes no independent reserves;
  its result cross-checks the split and identifies underlying pools.
  No pool, order book, or inventory is counted twice.
- `INV-BATCHING`: the WingRiders history instrument states its exact
  window and counts examined requests, batched requests, beneficiary
  credential classes, and batched script-beneficiary requests. It proves
  request/batch linkage with a known batched pubkey control and proves
  script-beneficiary classification with a known script request control.
  A zero is reported only as a bounded observation, never as an unevidenced
  cause.
- `INV-EVIDENCE`: commands, real exit codes, UTC timestamps, observed
  slots, raw captures, hashes, and positive controls are mechanically
  recorded. The verifier is demonstrated red for altered, missing, and
  vacuous evidence before accepting the real bundle.
- `INV-FRESHNESS`: every quote is marked `refresh-before-acceptance` and
  refreshed immediately before acceptance; historical facts identify
  their closed observation window.
- `INV-SAFETY`: all chain and venue access is read-only. No signing,
  submission, cancellation, staging, transaction construction, value
  movement, product code, existing test, dependency, or accepted #491
  evidence change occurs. Secrets never enter tracked files or captures.
- `INV-RECOMMENDATION`: the report gives one explicit verdict on the
  `40000000002`-unit target and one paragraph recommending proceed, re-cut,
  or abandon, without leaning toward a positive result.

## Required report shape

The report includes a per-venue table, best-single table, best-split table,
Danogo classification, route-versus-target delta, batching method/window/
counts/controls, disagreements and limitations, safety statement, and final
recommendation. It distinguishes executable quotes from spot prices,
marketing listings, screenshots, and ticker matches.

## Verdict rule

`MEETS-LIMIT` requires an evidenced executable route delivering at least
`40000000002` USDM base units for the fixed input after all visible fees and
overheads. Otherwise the verdict is `NO-ROUTE-MEETS-LIMIT`. The batching
answer is independently `BATCHED-SCRIPT-REQUEST-FOUND` or
`NO-BATCHED-SCRIPT-REQUEST-FOUND-IN-WINDOW`.

## Ceiling

This specification is limited to 130 lines and 9 KiB.
