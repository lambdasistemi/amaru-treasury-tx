# Feature Specification: USDM Price Source for swap-quote, wizard rate hardening

**Feature Branch**: `110-usdm-price-source`
**Created**: 2026-05-14
**Status**: Draft v2
**Input**: [Issue #110](https://github.com/lambdasistemi/amaru-treasury-tx/issues/110) — add a USDM price-source so operators don't need an out-of-band ADA/USDM rate.

## Background

Two commands today reach for a live ADA quote:

- `swap-wizard --price-source coingecko-ada-usd ... --slippage-bps N`
- `swap-quote  --price-source coingecko-ada-usd ... --slippage-bps N`

Both fetch ADA/USD from CoinGecko and feed the value into
`deriveSwapParameters`
([`lib/Amaru/Treasury/Tx/SwapQuote.hs:191-222`](../../lib/Amaru/Treasury/Tx/SwapQuote.hs)),
which multiplies by `(10000 − bps) / 10000` and emits `minRate`. The
Sundae order interprets `minRate` as **minimum USDM per ADA**. The
arithmetic only holds if `USDM ≈ USD`; under depeg or settlement lag
the operator silently builds a swap with the wrong limit price. The
audit even labels the pair `ADA/USD` while the math reuses the same
number as USDM/ADA.

`--ada-usd DECIMAL` (explicit override) has the same failure mode: the
operator hands in an ADA/USD figure, the wizard / swap-quote runner
treats it as USDM/ADA.

## Goal

Two orthogonal changes:

1. **Decouple quote retrieval from the wizard.** `swap-wizard` is the
   "I have a pre-validated rate" command. Live quote fetching moves
   entirely into the separate `swap-quote` command, which already
   handles the live-fetch + affordability + intent + tx-build pipeline
   end-to-end. The wizard accepts `--min-rate` (expert path) or
   `--ada-usdm DECIMAL` (with optional `--slippage-bps` applied on top
   of the override). No `--price-source` and no `--ada-usd` on the
   wizard.
2. **Fix the broken source in `swap-quote`.** Replace
   `--price-source coingecko-ada-usd` with `--price-source coingecko-ada-usdm`,
   a **derived** ADA/USDM observation computed as `(ADA/USD) ÷ (USDM/USD)`
   from two CoinGecko `simple/price` calls (`ids=cardano` and
   `ids=usdm-2`). Drop `--ada-usd` from `swap-quote`'s override set.

Both changes close the silent-conversion bug: every quote that flows
through `deriveSwapParameters` is now ADA/USDM by construction.

## User Scenarios & Testing *(mandatory)*

### User Story 1 — Wizard with a pre-validated rate (P1)

A treasury operator already has the rate (from `swap-quote`, an
oracle, or a manual calculation) and wants to build an intent
directly with `swap-wizard`.

**Independent Test**: Run the wizard with `--ada-usdm Q --slippage-bps S`
through the existing pure planner. The derived `minRate` equals
`floor(Q × (10000 − S) × 10^6 / 10000) / 10^6`.

**Acceptance Scenarios**:

1. **Given** `swap-wizard ... --ada-usdm Q --slippage-bps N`, **When** the wizard runs, **Then** it computes `minRate = Q × (1 − N/10000)`, six-decimal-floored, and uses that value through the existing swap intent generation path. No outbound HTTP.
2. **Given** `swap-wizard ... --min-rate R`, **When** the wizard runs, **Then** `minRate = R` is used as-is (expert path, no slippage applied), exactly as today.
3. **Given** `swap-wizard ... --price-source ANY` or `--ada-usd ANY`, **When** argv is parsed, **Then** parsing fails because the flags no longer exist.

### User Story 2 — Live derived rate via swap-quote (P1)

An operator wants `swap-quote` to fetch a live ADA/USDM quote (no
hand-validation) and run the affordability + build pipeline end-to-end.

**Independent Test**: Provide a `QuoteProvider IO` that returns
captured ADA/USD and USDM/USD fixtures. Run `swap-quote --price-source coingecko-ada-usdm --slippage-bps N` through that provider. The
derived `minRate` equals `(adaUsd ÷ usdmUsd) × (1 − N/10000)`,
six-decimal-floored.

**Acceptance Scenarios**:

1. **Given** `swap-quote ... --price-source coingecko-ada-usdm --slippage-bps N`, **When** both upstream fetches return positive prices, **Then** the params.json audit records the derived value and both component observations (name, value, fetchedAt, raw).
2. **Given** either upstream fetch fails or returns a non-positive price, **When** the run executes, **Then** the run aborts before emitting `intent.json` and the error names which component failed.
3. **Given** `swap-quote ... --price-source coingecko-ada-usd` (the retired path), **When** argv is parsed, **Then** parsing fails with a typed error pointing at `coingecko-ada-usdm` / `--ada-usdm`.
4. **Given** `swap-quote ... --ada-usd ANY`, **When** argv is parsed, **Then** parsing fails (flag no longer exists).

### User Story 3 — Audit records derived provenance (P1)

The `swap-quote` `params.json` records both upstream observations so a
reviewer can reconstruct the derived value from raw inputs.

**Independent Test**: Encode a `SwapQuoteAudit` whose
`dspQuote.qoProvenance` is `DerivedQuoteProvenance`. Compare to a
golden JSON containing the `derived` block with both component
entries.

**Acceptance Scenarios**:

1. **Given** a derived ADA/USDM observation, **When** the audit JSON is encoded, **Then** the `quote.provenance` object is `{ "kind": "derived", "name": "coingecko-ada-usdm", "components": [ {ada-usd…}, {usdm-usd…} ] }` and `quote.pair` is `ADA/USDM`.

### User Story 4 — TLS trust anchor remains audible (P2)

The release wrapper sets `SSL_CERT_FILE` and `SYSTEM_CERTIFICATE_PATH`
to a Mozilla NSS bundle. `swap-quote` live fetches print a
`swap-quote: TLS trust anchor …` stderr line before each request.

**Acceptance Scenarios**:

1. **Given** `swap-quote --price-source coingecko-ada-usdm`, **When** each upstream request goes out, **Then** the trust-anchor stderr line is emitted before each of the two upstream calls.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: `swap-wizard` removes the `--price-source`, `--ada-usd`
  options and the `coingecko-ada-usd` named source. It retains
  `--min-rate N`, `--ada-usdm DECIMAL`, and `--slippage-bps INT` (the
  last paired with `--ada-usdm`).
- **FR-002**: `swap-wizard` does **not** perform any outbound HTTP.
  No CoinGecko import in its module graph after this PR.
- **FR-003**: `swap-quote` accepts `--price-source coingecko-ada-usdm`
  and rejects `--price-source coingecko-ada-usd` with a typed error
  pointing at the new name.
- **FR-004**: `swap-quote` removes the `--ada-usd DECIMAL` override.
  `--ada-usdm DECIMAL` remains the only explicit override.
- **FR-005**: The derived source is computed as
  `(ada-usd ÷ usdm-usd)` from two CoinGecko `simple/price` calls
  (`ids=cardano` and `ids=usdm-2`); the result is a `QuoteObservation`
  with `qoPair = AdaUsdm` and `qoProvenance = DerivedQuoteProvenance`.
- **FR-006**: A non-positive or missing field at either component is
  a typed error naming the failing component; the run aborts before
  `intent.json` or unsigned CBOR is written.
- **FR-007**: `QuoteSource` exposes a single constructor
  `CoinGeckoAdaUsdm` (the old `CoinGeckoAdaUsd` is removed).
- **FR-008**: `QuoteProvenance` gains `DerivedQuoteProvenance { name :: Text, components :: NonEmpty ComponentObservation }`
  (delivered in slice 1).
- **FR-009**: The audit JSON `quote.provenance` for derived
  observations matches the contract in
  `contracts/swap-quote-audit-json.md`.
- **FR-010**: The trust-anchor stderr line (`describeTlsTrustAnchor`)
  is emitted before each upstream HTTP request in `swap-quote`'s
  derived provider.
- **FR-011**: Unit tests exercise the derived computation with
  captured fixtures only — no live HTTP in `just ci`.
- **FR-012**: `docs/swap.md` updates its recommended workflow:
  - the "Recommended quote-derived workflow" section uses
    `swap-quote --price-source coingecko-ada-usdm`.
  - a new "Operator-supplied rate" section shows
    `swap-wizard --ada-usdm Q --slippage-bps S` and
    `swap-wizard --min-rate R` as the rate-already-on-hand paths.

### Out of Scope

- On-chain oracle integration (issue #110 Option B).
- Cross-source consistency checks.
- Authenticated CoinGecko Pro tier.
- New retry / back-off policy.
- Any change to `swap-wizard`'s registry / treasury / signer
  resolution.

## Constraints & Decisions

### Why `usdm-2`

CoinGecko id `usdm-2` returns the Cardano-native Mehen USDM
(policy `c48cbb3d…0014df10`), matching
`Amaru.Treasury.Constants.usdmPolicyHex`. The `mehen-usdm` id cited in
the issue text returns `{}` and is **not** the canonical id.

### Why retire the wizard's live fetch entirely

`swap-wizard` and `swap-quote` previously had overlapping live-fetch
surfaces. The wizard is the lower-level "build me an intent from these
parameters" tool; live retrieval is policy (which source, which
slippage), not part of intent construction. Pushing all retrieval into
`swap-quote` reduces the wizard's blast radius and removes one of the
two places the silent-USDM≈USD bug can recur.

### Why retire `--ada-usd` everywhere

The explicit override shares the silent-conversion failure mode of
the retired source: operator passes an ADA/USD figure, wizard /
swap-quote treats it as USDM/ADA. Both commands keep `--ada-usdm`
as the manual escape hatch.

### Derived-rate ceiling rule

The existing six-decimal floor
(`rateNumerator = floor(quote × (10000 − bps) / 10000 × 1_000_000)`)
applies to the **derived** ADA/USDM quote. The intermediate
`Rational` division is exact; rounding happens once, at the floor.

## Acceptance Criteria (refined from #110)

- `swap-quote --price-source coingecko-ada-usdm --slippage-bps N ...`
  against a live node + Internet produces a `params.json` whose
  derived `minRate` matches `(ada-usd ÷ usdm-usd) × (1 − bps/10000)`
  to six decimals, and whose `quote.provenance.components` records
  both upstream observations.
- `swap-wizard ... --ada-usdm Q --slippage-bps S ...` produces the
  same `minRate` as `swap-quote ... --ada-usdm Q --slippage-bps S ...`,
  i.e. the two commands share the deriving math.
- `swap-wizard` and `swap-quote` both reject the retired flags
  (`--price-source coingecko-ada-usd`, `--ada-usd`).
- The trust-anchor stderr line continues to print before each of the
  two outbound calls (`swap-quote` only).
- Unit-test coverage for the derived computation against captured
  response fixtures (no live HTTP).
- `docs/swap.md` updated.
