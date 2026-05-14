# Feature Specification: USDM Price Source for swap-wizard

**Feature Branch**: `110-usdm-price-source`
**Created**: 2026-05-14
**Status**: Draft
**Input**: [Issue #110](https://github.com/lambdasistemi/amaru-treasury-tx/issues/110) — add a USDM price-source so operators don't need an out-of-band ADA/USDM rate.

## Background

The named-source surface today is `--price-source coingecko-ada-usd`. It
fetches one live ADA/USD quote and feeds it into `deriveSwapParameters`
([`lib/Amaru/Treasury/Tx/SwapQuote.hs:191-222`](../../lib/Amaru/Treasury/Tx/SwapQuote.hs))
where the value is multiplied by `(10000 - bps) / 10000` and emitted as
`minRate`. The Sundae order interprets `minRate` as
**minimum USDM per ADA**.

That arithmetic only makes sense if `USDM ≈ USD`. Under depeg or
settlement-lag, the operator silently builds a swap with the wrong
acceptable rate; the audit `quote.pair` still says `ADA/USD` while the
math reuses the same number as USDM/ADA. The current named-source path
is therefore a latent operational hazard, not a feature gap.

The explicit `--ada-usdm DECIMAL` override works, but pushes the
fetch-and-validate burden onto the operator, who in practice is back
to copying a number out of band.

## Goal

Make the only named live source a **correct ADA/USDM quote** derived
from two upstream CoinGecko calls — ADA/USD ÷ USDM/USD — preserving
the full provenance of both upstream observations in the audit
artifact.

Retire the standalone `--price-source coingecko-ada-usd` path because
its operational meaning is wrong: ADA/USD alone is not a valid input
to a USDM swap. The operator either uses the new derived source or an
explicit override.

## User Scenarios & Testing *(mandatory)*

### User Story 1 — Operator runs a swap with a live ADA/USDM quote (P1)

A treasury operator wants to build a USDM swap intent against a live
ADA/USDM quote without copying numbers out of band.

**Independent Test**: Provide a `QuoteProvider IO` whose responses are
captured ADA/USD and USDM/USD fixtures. Run swap-wizard / swap-quote
through that provider. The derived `minRate` equals
`(ada-usd ÷ usdm-usd) × (10000 - bps) / 10000`, rounded with the
existing six-decimal floor.

**Acceptance Scenarios**:

1. **Given** an operator runs `swap-wizard ... --price-source coingecko-ada-usdm --slippage-bps N`, **When** both upstream fetches return positive prices, **Then** the wizard derives `minRate = (ada-usd / usdm-usd) × (1 - N/10000)`, six-decimal-floored, and uses that value through the existing swap intent generation path.
2. **Given** either upstream fetch fails or returns a non-positive price, **When** the wizard runs, **Then** it aborts before emitting an intent and the trace identifies which component failed.
3. **Given** the operator passes `--price-source coingecko-ada-usd` (the old, retired path), **When** the CLI parses arguments, **Then** parsing fails with a message pointing at `coingecko-ada-usdm` or `--ada-usdm`.

### User Story 2 — Quote provenance survives into the audit (P1)

The intent audit must record both upstream quotes so a reviewer can
reconstruct the derived value from raw inputs.

**Independent Test**: Encode a `SwapQuoteAudit` whose quote provenance
is the new derived shape. Compare to a golden JSON containing the
`derived` block with both component entries (name, value, fetchedAt,
raw).

**Acceptance Scenarios**:

1. **Given** a derived ADA/USDM observation, **When** the audit JSON is encoded, **Then** the `quote.provenance` object is `{ "kind": "derived", "name": "coingecko-ada-usdm", "components": [ {ada-usd…}, {usdm-usd…} ] }` and `quote.pair` is `ADA/USDM`.
2. **Given** the same observation in the wizard log, **When** the trace line announces the resolved quote, **Then** the line names both components and the derived value.

### User Story 3 — TLS trust anchor remains audible (P2)

The release wrapper sets `SSL_CERT_FILE` and `SYSTEM_CERTIFICATE_PATH`
to a Mozilla NSS bundle; live quote fetches print a `swap-quote: TLS trust anchor …` stderr line before the request. The derived source must keep this contract for both upstream fetches.

**Acceptance Scenarios**:

1. **Given** the derived source runs both fetches, **When** each request goes out, **Then** the trust-anchor stderr line is emitted before each upstream call.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The CLI accepts `--price-source coingecko-ada-usdm` and
  rejects `--price-source coingecko-ada-usd` with a parse error.
- **FR-002**: The derived source name is `coingecko-ada-usdm`.
- **FR-003**: The derived observation has `qoPair = AdaUsdm` and
  `qoQuote = adaUsd / usdmUsd` exactly (as `Rational`).
- **FR-004**: The derived source uses two upstream CoinGecko `simple/price` calls: `ids=cardano&vs_currencies=usd` and `ids=usdm-2&vs_currencies=usd`.
- **FR-005**: A non-positive `usdmUsd` value aborts the derivation with a typed error that names the failing component.
- **FR-006**: The `QuoteSource` ADT replaces `CoinGeckoAdaUsd` with `CoinGeckoAdaUsdm` (the old constructor is removed; no deprecated alias).
- **FR-007**: The `QuoteProvenance` type gains a `DerivedQuoteProvenance` constructor carrying `name :: Text` and an ordered list of component observations (`name`, `value`, `fetchedAt`, `raw`).
- **FR-008**: The audit JSON `quote.provenance` for derived observations matches the contract in `contracts/swap-quote-audit-json.md`.
- **FR-009**: The trust-anchor stderr line (`describeTlsTrustAnchor`) is emitted before each of the two upstream HTTP requests, not once for the pair.
- **FR-010**: Unit tests exercise the derived computation with captured fixtures only — no live HTTP.
- **FR-011**: `docs/swap.md`'s recommended quote-derived workflow uses `--price-source coingecko-ada-usdm`.

### Out of Scope

- On-chain oracle integration (issue #110 Option B).
- Cross-source consistency checks (e.g. CoinGecko vs SundaeSwap pool quote).
- Authenticated CoinGecko Pro tier; the public API path stays.
- New retry/back-off policy; same `responseTimeout = 5_000_000 µs` as today.

## Constraints & Decisions

### Why `usdm-2`

CoinGecko id `usdm-2` returns the Cardano-native Mehen USDM
(policy `c48cbb3d…0014df10`), matching
`Amaru.Treasury.Constants.usdmPolicyHex`. The `mehen-usdm` id cited in
the issue text returns `{}` and is **not** the canonical id — the spec
uses `usdm-2`.

### Why retire `coingecko-ada-usd`

The standalone ADA/USD path silently treats ADA/USD as USDM/ADA, which
the issue explicitly flags as wrong by orders of magnitude under
depeg. Keeping it alongside the new source would preserve the trap
under a friendlier name. We remove the named source; explicit
`--ada-usd DECIMAL` override is also removed because it has the same
silent-conversion failure mode. Explicit `--ada-usdm DECIMAL` remains
the manual escape hatch.

### Derived-rate ceiling rule

The existing six-decimal floor (`rateNumerator = floor(quote × (10000 - bps) / 10000 × 1_000_000)`) applies to the **derived** ADA/USDM quote. The intermediate `Rational` division is exact; rounding happens once, at the floor.

## Acceptance Criteria (from #110)

- `swap-wizard --price-source coingecko-ada-usdm --slippage-bps N ...` against a live node + Internet produces an intent.json whose derived `minRate` matches `(ada-usd ÷ usdm-usd) × (1 - bps/10000)` to six decimals.
- The trust-anchor stderr line continues to print before the outbound calls.
- Unit-test coverage for the derived computation against captured response fixtures (no live HTTP).
- `docs/swap.md` updates the quote-derived workflow snippet to use the new source.

## Open Questions

None — `usdm-2` confirmed live; provenance shape pinned in contract.
