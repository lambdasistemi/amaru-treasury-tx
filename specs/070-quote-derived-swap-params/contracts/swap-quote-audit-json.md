# Contract: swap-quote Audit JSON

**Plan**: [../plan.md](../plan.md) | **Spec**: [../spec.md](../spec.md)
**Date**: 2026-05-09

`swap-quote` writes `params.json` for successful runs and for
affordability failures. The artifact is separate from `intent.json`;
it does not change the TreasuryIntent schema.

## Shape

```json
{
  "schema": 1,
  "command": "swap-quote",
  "status": "built",
  "quote": {
    "pair": "ADA/USD",
    "value": "0.8123",
    "provenance": {
      "kind": "source",
      "name": "coingecko-ada-usd"
    },
    "observedAt": "2026-05-09T10:00:00Z",
    "fetchedAt": "2026-05-09T10:00:00Z",
    "raw": {}
  },
  "slippage": {
    "basisPoints": 100
  },
  "derived": {
    "minRate": "0.804177",
    "rateNumerator": 804177,
    "rateDenominator": 1000000,
    "amountLovelace": 124350736421,
    "chunkSizeLovelace": 3768204133
  },
  "request": {
    "network": "mainnet",
    "scope": "network_compliance",
    "requestedUsdm": "100000",
    "chunking": { "kind": "split", "count": 33 },
    "validityHours": 28,
    "extraSigners": ["core_development"]
  },
  "affordability": {
    "amountLovelace": 124350736421,
    "chunkCount": 34,
    "extraPerChunkLovelace": 3280000,
    "requiredLovelace": 124462256421,
    "selectedTreasuryLovelace": 1450000000000,
    "availableLovelace": 1450000000000,
    "shortfallLovelace": 0,
    "affordable": true
  },
  "outputs": {
    "intentJson": "swap-run-2026-05-09/intent.json",
    "unsignedCborHex": "swap-run-2026-05-09/swap.cbor.hex",
    "wizardLog": "swap-run-2026-05-09/wizard.log",
    "buildLog": "swap-run-2026-05-09/build.log"
  }
}
```

## Field rules

- `schema` is `1` for the first audit contract.
- `quote.pair` is `ADA/USD` for `--ada-usd` and
  `coingecko-ada-usd`, and `ADA/USDM` for `--ada-usdm`.
- `quote.provenance.kind` is `override` for explicit `--ada-usd` and
  `--ada-usdm` inputs, and `source` for named providers.
- Numeric decision values that came from user decimals or exact
  rationals are encoded as strings to avoid JSON number precision
  ambiguity.
- `rateNumerator`, `rateDenominator`, lovelace values, chunk counts,
  and basis points are JSON integers.
- `status` is one of:
  - `built`
  - `affordability_failed`
  - `aborted`
- `unsignedCborHex` is omitted or `null` when status is
  `affordability_failed`.
- `raw` may be omitted for explicit overrides.

## Affordability failure example

```json
{
  "schema": 1,
  "command": "swap-quote",
  "status": "affordability_failed",
  "affordability": {
    "requiredLovelace": 124462256421,
    "selectedTreasuryLovelace": 124462256420,
    "availableLovelace": 124462256420,
    "shortfallLovelace": 1,
    "affordable": false
  },
  "outputs": {
    "intentJson": "swap-run/intent.json",
    "unsignedCborHex": null,
    "wizardLog": "swap-run/wizard.log",
    "buildLog": null
  }
}
```

The implementation may include additional diagnostic fields, but the
fields above are required and must be covered by a golden fixture.

## ADA/USDM override quote fragment

Explicit ADA/USDM runs use the same artifact shape and differ only in
the quote pair and override provenance:

```json
{
  "quote": {
    "pair": "ADA/USDM",
    "value": "0.8120",
    "provenance": {
      "kind": "override"
    },
    "observedAt": "2026-05-09T10:00:00Z"
  }
}
```
