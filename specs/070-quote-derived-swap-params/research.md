# Phase 0 Research: Quote-Derived Swap Parameters

**Plan**: [plan.md](./plan.md) | **Spec**: [spec.md](./spec.md)
**Date**: 2026-05-09

## D1. Composite CLI path

**Decision**: Add a new `swap-quote` subcommand that performs quote
resolution, slippage derivation, existing swap intent generation,
treasury affordability validation, existing unsigned build, and audit
artifact writing in one operator command.

**Rationale**: Issue #70 explicitly says the prototype shell workflow
belongs in the Haskell executable, not in an external shell wrapper.
Keeping `swap-wizard --min-rate` as-is preserves the expert/manual
override while giving operators a primary command that cannot skip the
quote and slippage steps.

**Alternatives considered**:

- Mutate `swap-wizard` to replace `--min-rate`. Rejected because the
  manual override remains useful and should stay separately auditable.
- Add a wrapper script. Rejected by the issue: the executable must own
  the supported path.

## D2. Quote source shape

**Decision**: Support exactly one of:

- `--ada-usd RATE` for explicit deterministic operator override.
- `--ada-usdm RATE` for explicit deterministic operator override.
- `--price-source coingecko-ada-usd` for a live quote provider.

The provider interface returns `QuoteObservation` with source name,
base/quote pair, numeric value, observation/fetch time, and raw
provider metadata. Tests use explicit ADA/USD and ADA/USDM overrides,
a stub provider, and a captured JSON fixture; CI never depends on live
CoinGecko availability.

**Rationale**: The explicit override satisfies deterministic offline
operation and testability for both quote domains approved by the spec:
ADA/USD and ADA/USDM. A named live source satisfies the issue's "fetch
ADA/USD quote" path. CoinGecko's documented `/simple/price` endpoint
supports querying one or more coin IDs against target currencies, and
`cardano`/`usd` maps directly to the required ADA/USD quote domain. A
named live ADA/USDM source is not selected in this plan because the
project does not yet have an approved USDM price provider contract;
operators can still supply audited ADA/USDM observations explicitly
with `--ada-usdm`.

**Alternatives considered**:

- Only support override in v1. Rejected because the issue asks for a
  quote source or override and describes fetching as part of the
  desired command.
- Treat ADA/USDM as out of scope. Rejected because the approved spec
  explicitly accepts ADA/USDM quote observations for this issue.
- Add a provisional live ADA/USDM source. Rejected for v1 because a
  source name without an approved provider contract would produce weak
  provenance. The explicit override path preserves the required
  ADA/USDM input domain without implying unsupported live-source
  trust.
- Support arbitrary URL sources. Rejected for v1 because it expands
  validation and audit semantics without improving the operator's
  immediate safe path.

Source checked: CoinGecko API reference for `/simple/price`
(https://docs.coingecko.com/v3.0.1/reference/simple-price).

## D3. Exact decimal and conservative rounding

**Decision**: Parse operator decimals into exact rationals from text.
Compute:

```text
derivedMinRate = quote * (10000 - slippageBps) / 10000
rateNumerator  = floor (derivedMinRate * 1_000_000)
rateDenominator = 1_000_000
amountLovelace = ceiling (requestedUsdm * 1_000_000 / derivedMinRate)
chunkSizeLovelace = ceiling (chunkUsdm * 1_000_000 / derivedMinRate)
```

For `--split N`, reuse the current split behavior over the derived
`amountLovelace`: `amountLovelace div N` plus the existing remainder
chunk behavior.

**Rationale**: Current `Double` parsing plus `round` is acceptable for
the manual path but not for the audited quote-derived path. Flooring
the rate numerator prevents rounding upward beyond the explicit
slippage policy. Ceiling ADA conversions prevents underfunding the
operator's requested USDM amount.

**Alternatives considered**:

- Reuse `Double` and `round`. Rejected because it can drift in the
  exact failure mode this issue is trying to make auditable.
- Preserve arbitrary rational denominators in intent JSON. Rejected
  because the existing schema and fixtures already use integer
  numerator/denominator fields and six decimal USDM precision is the
  stable contract.

## D4. Affordability source of truth

**Decision**: Reuse the existing `resolveWizardEnv` selection path and
`chunkCountFor` helper, then audit:

```text
required = amountLovelace + chunk_count * extraPerChunkLovelace
selectedTreasury = required + treasuryLeftoverLovelace
affordable = selectedTreasury >= required
shortfall = max 0 (required - selectedTreasury)
```

The command aborts before writing unsigned CBOR if affordability
fails. The audit artifact is still written for both pass and
affordability-fail cases.

**Rationale**: The generated intent values are the only trustworthy
inputs for chunk count and per-chunk overhead. Existing resolver code
already knows how to select treasury inputs and report typed
shortfalls; the new command should not reimplement selection.

**Alternatives considered**:

- Estimate chunk count from CLI flags before intent generation.
  Rejected because the spec requires generated chunk count, not an
  operator estimate.

## D5. Audit artifact contract

**Decision**: Write `params.json` as a stable JSON object with:
schema, command, quote observation, slippage policy, derived rate,
request parameters, generated swap inputs, affordability summary,
selected treasury totals, output paths, and timestamps.

**Rationale**: Signers and reviewers need a durable record that
explains why the limit price and ADA amount were chosen. Keeping the
artifact separate from `intent.json` avoids changing the public
TreasuryIntent schema for this feature.

**Alternatives considered**:

- Embed quote metadata into `intent.json`. Rejected for v1 because it
  would require an intent schema contract change even though the
  on-chain transaction shape does not need quote provenance.

## D6. Test and proof strategy

**Decision**: Implement in vertical slices:

1. Red tests for slippage/rate derivation and invalid quote/slippage.
2. Red tests for affordability exact-pass and one-lovelace-short fail.
3. Red audit golden for `params.json`.
4. CLI/parser tests and docs after the pure core is green.

**Rationale**: The risky behavior is economic arithmetic and artifact
shape, both of which can be tested without live network access. The
existing swap golden remains the proof that the reused build pipeline
continues to produce the known CBOR shape.

**Alternatives considered**:

- Start with end-to-end live-node tests. Rejected for CI because live
  quote and node availability would make regression proof flaky.
