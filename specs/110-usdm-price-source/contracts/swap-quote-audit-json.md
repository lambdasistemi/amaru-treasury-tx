# Contract: swap-quote Audit JSON (derived USDM source)

**Spec**: [../spec.md](../spec.md) | **Date**: 2026-05-14

This contract extends the audit JSON shape defined for #70
([specs/070-quote-derived-swap-params/contracts/swap-quote-audit-json.md](../../070-quote-derived-swap-params/contracts/swap-quote-audit-json.md))
with a third `quote.provenance.kind` for derived sources.

## Quote fragment for `coingecko-ada-usdm`

```json
{
  "quote": {
    "pair": "ADA/USDM",
    "value": "0.270048",
    "provenance": {
      "kind": "derived",
      "name": "coingecko-ada-usdm",
      "components": [
        {
          "name": "coingecko-ada-usd",
          "value": "0.270971",
          "fetchedAt": "2026-05-14T09:59:58Z",
          "raw": "{\"cardano\":{\"usd\":0.270971}}\n"
        },
        {
          "name": "coingecko-usdm-usd",
          "value": "1.001234",
          "fetchedAt": "2026-05-14T09:59:59Z",
          "raw": "{\"usdm-2\":{\"usd\":1.001234}}\n"
        }
      ]
    },
    "observedAt": "2026-05-14T10:00:00Z"
  }
}
```

## Field rules (derived only)

- `quote.pair` is `ADA/USDM` for any derived observation.
- `quote.value` is the derived value `(ada-usd ÷ usdm-usd)` formatted
  by the existing `formatRationalDecimal` (six-decimal truncation when
  the denominator is `10^k`-friendly; otherwise the `numerator/denominator` fallback).
- `quote.provenance.kind` is `"derived"`.
- `quote.provenance.name` is the derived source name (`coingecko-ada-usdm`).
- `quote.provenance.components` is a **non-empty, ordered** array; for
  this source it is exactly two entries in the order
  `coingecko-ada-usd`, `coingecko-usdm-usd`.
- Each component object has the four fields `name`, `value`, `fetchedAt`, `raw` — the same fields used by `QuoteSourceProvenance` today.
- `fetchedAt` on each component is the per-component fetch timestamp;
  the outer `quote.observedAt` remains the wizard's single execution
  timestamp.
- Numeric quote values are JSON strings (existing convention).

## Backwards compatibility

The `override` and `source` provenance kinds remain valid for explicit
`--ada-usdm` overrides. The previous `source` kind no longer appears
because the only retained source is the derived one.

## Schema integration

The audit `schema` field stays at `1`. The `derived` provenance is an
additive case under the existing `quote.provenance` discriminator —
existing fields are not renamed. JSON Schema is not currently emitted
for the audit; if it later is, `quote.provenance` becomes a sum type
of `override | source | derived` with the shapes above.
