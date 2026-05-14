# Contract: swap-wizard and swap-quote CLI (post-#110)

**Spec**: [../spec.md](../spec.md) | **Date**: 2026-05-14 (v2)

After #110 the two operator-facing commands have **disjoint** rate
surfaces.

## swap-wizard

```text
swap-wizard
  (--min-rate DECIMAL | --ada-usdm DECIMAL --slippage-bps INT)
  ...other unchanged flags...
```

Rules:

- Exactly one of:
  - `--min-rate DECIMAL` — pre-validated minimum USDM per ADA. No
    slippage applied.
  - `--ada-usdm DECIMAL --slippage-bps INT` — ADA/USDM quote (override
    provenance); the wizard applies `minRate = quote × (1 − bps/10000)`.
- `--price-source`, `--ada-usd`, and any quote-source name are
  **rejected** by the parser (flag does not exist). The error
  message points the operator at `swap-quote` for live retrieval and
  at `--ada-usdm` for an explicit pre-validated rate.
- No outbound HTTP. The wizard never imports `httpLBS` after this
  PR.

## swap-quote

```text
swap-quote
  (--ada-usdm DECIMAL | --price-source coingecko-ada-usdm)
  --slippage-bps INT
  ...other unchanged flags...
```

Rules:

- Exactly one of:
  - `--ada-usdm DECIMAL` — explicit override; `OperatorOverride`
    provenance.
  - `--price-source coingecko-ada-usdm` — live derived ADA/USDM, see
    "Derived computation" below.
- `--ada-usd DECIMAL` is **removed**. `--price-source coingecko-ada-usd`
  is **removed** and replaced with a typed retirement error pointing
  at `coingecko-ada-usdm` / `--ada-usdm`.
- Any other name is rejected with the existing `unknown quote source`
  error.

### Derived computation

```text
adaUsd  = fetch(https://api.coingecko.com/api/v3/simple/price?ids=cardano&vs_currencies=usd).cardano.usd
usdmUsd = fetch(https://api.coingecko.com/api/v3/simple/price?ids=usdm-2&vs_currencies=usd)["usdm-2"].usd
adaUsdm = adaUsd / usdmUsd                                    -- exact Rational, no rounding
minRate = floor(adaUsdm × (10000 − bps) × 1_000_000 / 10000) / 1_000_000
```

`adaUsd` and `usdmUsd` must be positive; a zero or negative value at
either component is a `QuoteSourceInvalidQuote` naming the component.

### Failure ordering (additive over #70 contract)

1. CLI shape, slippage, amount, chunking, validity hours.
2. ADA/USD upstream fetch or parse failure (component identified).
3. USDM/USD upstream fetch or parse failure (component identified).
4. Derived-rate floor producing `rateNumerator = 0` (existing `ZeroMinimumRate`).
5. Existing registry / wallet / treasury / signer failure.
6. Treasury affordability failure before unsigned CBOR.
7. Existing tx-build failure.

The trust-anchor stderr line precedes each upstream HTTP request:

```text
swap-quote: TLS trust anchor SSL_CERT_FILE=... SYSTEM_CERTIFICATE_PATH=...
swap-quote: TLS trust anchor SSL_CERT_FILE=... SYSTEM_CERTIFICATE_PATH=...
```

### User-Agent (unchanged)

Both upstream requests carry the existing CoinGecko User-Agent
derived from `Paths_amaru_treasury_tx`. No new headers.
