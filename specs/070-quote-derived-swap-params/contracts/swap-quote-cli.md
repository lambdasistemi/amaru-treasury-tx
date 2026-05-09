# Contract: swap-quote CLI

**Plan**: [../plan.md](../plan.md) | **Spec**: [../spec.md](../spec.md)
**Date**: 2026-05-09

## Command

```text
amaru-treasury-tx [GLOBAL] swap-quote OPTIONS
```

`GLOBAL` keeps the existing network and node-socket options used by
`swap-wizard` and `tx-build`.

## Required options

```text
--wallet-addr BECH32
--metadata PATH
--scope NAME
--usdm DECIMAL
(--split INT | --chunk-usdm DECIMAL)
(--ada-usd DECIMAL | --ada-usdm DECIMAL | --price-source SOURCE)
--slippage-bps INT
--validity-hours HOURS
--description TEXT
--justification TEXT
--destination-label TEXT
--out-dir PATH
```

Optional options:

```text
--extra-signer SCOPE|HEX    repeatable; --signer remains an alias
--event TEXT
--label TEXT
```

## Quote inputs

Exactly one quote input must be supplied.

### Explicit override

```text
--ada-usd DECIMAL
--ada-usdm DECIMAL
```

Rules:

- DECIMAL must parse as a positive exact decimal.
- Provenance is recorded as `override`.
- The command records the observation time chosen at execution.
- `--ada-usd` creates an ADA/USD quote observation.
- `--ada-usdm` creates an ADA/USDM quote observation.

### Named source

```text
--price-source coingecko-ada-usd
```

Rules:

- The source performs one live ADA/USD quote fetch.
- Fetch failure aborts before intent JSON or unsigned CBOR is written.
- The audit artifact records source name, fetch time, quote pair, and
  raw source metadata.
- No named live ADA/USDM source is part of this plan. ADA/USDM is
  supported through explicit `--ada-usdm` overrides until a later issue
  approves a live provider contract.

## Slippage

```text
--slippage-bps INT
```

Rules:

- Required; there is no default.
- Valid range is `0 <= INT < 10000`.
- Invalid values abort before quote fetching, intent generation, or
  transaction building.

## Derived rate

The command computes:

```text
minRate = quote * (10000 - slippageBps) / 10000
```

Then it passes the derived rate into the existing swap intent
generation path as `rateNumerator / rateDenominator`.

## Outputs

`--out-dir PATH` is created if missing and receives:

```text
intent.json
swap.cbor.hex
params.json
wizard.log
build.log
```

If affordability fails, `params.json` is written with failure status,
but `swap.cbor.hex` is not produced.

## Failure ordering

The command must fail in this order:

1. Invalid CLI shape, quote value, slippage value, amount, chunking, or
   validity hours.
2. Quote-source fetch or parse failure.
3. Existing registry, wallet, treasury, or signer resolution failure.
4. Treasury affordability failure before unsigned CBOR is written.
5. Existing tx-build failure.

Earlier failures must not produce later-stage artifacts.
