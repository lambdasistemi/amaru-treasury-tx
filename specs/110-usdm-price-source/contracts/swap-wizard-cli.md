# Contract: swap-wizard / swap-quote price-source CLI

**Spec**: [../spec.md](../spec.md) | **Date**: 2026-05-14

## Source list

After #110 the named-source surface is:

```text
--price-source coingecko-ada-usdm
```

- `coingecko-ada-usdm` is the only accepted value.
- `coingecko-ada-usd` is rejected with a parse error pointing at
  `coingecko-ada-usdm` or `--ada-usdm`.
- Any other name is rejected with the existing `unknown quote source`
  error.

## Override surface (unchanged in scope)

```text
--ada-usdm DECIMAL
```

- Same shape as today: positive exact decimal, `OperatorOverride`
  provenance, pair `ADA/USDM`.
- `--ada-usd DECIMAL` is removed; it shares the silent USDM≈USD
  failure mode of the retired source. Operators with a pre-computed
  rate use `--ada-usdm`.

## Derived computation

```text
adaUsd  = fetch(https://api.coingecko.com/api/v3/simple/price?ids=cardano&vs_currencies=usd).cardano.usd
usdmUsd = fetch(https://api.coingecko.com/api/v3/simple/price?ids=usdm-2&vs_currencies=usd)["usdm-2"].usd
adaUsdm = adaUsd / usdmUsd                    -- exact Rational, no rounding
minRate = floor(adaUsdm × (10000 - bps) × 1_000_000 / 10000) / 1_000_000
```

`adaUsd` and `usdmUsd` must be positive; a zero or negative value at
either component is a `QuoteSourceInvalidQuote` naming the component.

## Failure ordering (additive over #70 contract)

1. CLI shape, slippage, amount, chunking, validity hours.
2. ADA/USD upstream fetch or parse failure (component identified in the error).
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

## User-Agent (unchanged)

Both upstream requests carry the existing CoinGecko User-Agent
derived from `Paths_amaru_treasury_tx`. No new headers.
