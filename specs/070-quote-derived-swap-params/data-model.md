# Phase 1 Data Model: Quote-Derived Swap Parameters

**Plan**: [plan.md](./plan.md) | **Spec**: [spec.md](./spec.md)
**Date**: 2026-05-09

This model defines the new values crossing the quote source, pure
derivation, existing swap wizard, existing build path, and audit
artifact. It deliberately does not change `TreasuryIntent`.

## Quote Observation

```haskell
data QuotePair = AdaUsd | AdaUsdm

data QuoteProvenance
    = QuoteOverride
    | QuoteSource Text

data QuoteObservation = QuoteObservation
    { qoPair :: !QuotePair
    , qoValue :: !Rational
    , qoProvenance :: !QuoteProvenance
    , qoObservedAt :: !UTCTime
    , qoFetchedAt :: !(Maybe UTCTime)
    , qoRawSource :: !(Maybe Aeson.Value)
    }
```

Validation:

- `qoValue > 0`.
- Overrides record `QuoteOverride` and an observation time.
- Live sources record `QuoteSource <name>` and `fetchedAt`.
- Supported v1 pairs are ADA/USD and ADA/USDM only.

## Slippage Policy

```haskell
newtype SlippageBps = SlippageBps Word16
```

Validation:

- Must be provided explicitly.
- `0 <= bps < 10000`.
- Negative text and non-numeric text fail at parse time.

## Derived Swap Parameters

```haskell
data DerivedSwapParameters = DerivedSwapParameters
    { dspObservedQuote :: !QuoteObservation
    , dspSlippageBps :: !SlippageBps
    , dspMinRate :: !Rational
    , dspRateNumerator :: !Integer
    , dspRateDenominator :: !Integer
    , dspAmountLovelace :: !Integer
    , dspChunkSizeLovelace :: !Integer
    }
```

Rules:

- `dspMinRate = quote * (10000 - bps) / 10000`.
- `dspRateNumerator = floor (dspMinRate * 1_000_000)`.
- `dspRateDenominator = 1_000_000`.
- ADA amount and chunk ADA amount are rounded up from USDM amounts.
- `dspRateNumerator` must remain positive after flooring.

## Swap Quote Request

```haskell
data SwapQuoteRequest = SwapQuoteRequest
    { sqrWalletAddress :: !Text
    , sqrMetadataPath :: !FilePath
    , sqrScope :: !ScopeId
    , sqrRequestedUsdm :: !Rational
    , sqrChunking :: !ChunkingRequest
    , sqrQuoteInput :: !QuoteInput
    , sqrSlippageBps :: !SlippageBps
    , sqrValidityHours :: !Word8
    , sqrRationale :: !RationaleAnswers
    , sqrExtraSigners :: ![Text]
    , sqrOutDir :: !FilePath
    }

data ChunkingRequest
    = SplitCount Int
    | ChunkUsdm Rational

data QuoteInput
    = ExplicitAdaUsd Rational
    | ExplicitAdaUsdm Rational
    | PriceSource Text
```

Validation:

- Exactly one quote input constructor is accepted by the CLI.
- `ExplicitAdaUsd` creates an ADA/USD `QuoteObservation` with override
  provenance.
- `ExplicitAdaUsdm` creates an ADA/USDM `QuoteObservation` with
  override provenance.
- `PriceSource "coingecko-ada-usd"` creates an ADA/USD
  `QuoteObservation` with source provenance. A named ADA/USDM live
  source is future work until an approved provider contract exists.
- `SplitCount >= 1`.
- `ChunkUsdm > 0`.
- Existing `SwapWizardQ` validation still owns validity hours,
  signer resolution, positive amounts, and chunk size bounds.

## Affordability Summary

```haskell
data AffordabilitySummary = AffordabilitySummary
    { asAmountLovelace :: !Integer
    , asChunkCount :: !Integer
    , asExtraPerChunkLovelace :: !Integer
    , asRequiredLovelace :: !Integer
    , asSelectedTreasuryLovelace :: !Integer
    , asAvailableLovelace :: !Integer
    , asShortfallLovelace :: !Integer
    , asAffordable :: !Bool
    }
```

Rules:

- `asRequiredLovelace = amount + chunk_count * extra_per_chunk`.
- Exact equality is affordable.
- One lovelace short is not affordable.
- `asSelectedTreasuryLovelace` is derived from the selected treasury
  inputs, not from operator estimates.

## Audit Artifact

```haskell
data SwapQuoteAudit = SwapQuoteAudit
    { sqaSchema :: !Int
    , sqaCommand :: !Text
    , sqaQuote :: !QuoteObservation
    , sqaSlippageBps :: !Word16
    , sqaDerived :: !DerivedSwapParameters
    , sqaRequest :: !SwapQuoteRequestSummary
    , sqaAffordability :: !AffordabilitySummary
    , sqaOutputs :: !SwapQuoteOutputs
    , sqaStatus :: !SwapQuoteStatus
    }

data SwapQuoteStatus
    = SwapQuoteBuilt
    | SwapQuoteAffordabilityFailed
    | SwapQuoteAborted Text
```

The JSON encoding is specified in
[`contracts/swap-quote-audit-json.md`](./contracts/swap-quote-audit-json.md).
