# Quickstart: Quote-Derived Swap Parameters

**Plan**: [plan.md](./plan.md) | **Spec**: [spec.md](./spec.md)
**Date**: 2026-05-09

This is the intended operator path after feature 070 lands.

## Live quote source

```bash
amaru-treasury-tx \
    --node-socket "$CARDANO_NODE_SOCKET_PATH" \
    --network mainnet \
    swap-quote \
        --wallet-addr addr1q802wxt6cg6aw0nl0vdzfxavu65rxu3yzhvgayw7chfxymduzkt66uw9t5kspx5jwjecx80dz4g33htknafhdhkvzd5st4f9xu \
        --metadata metadata-mainnet.json \
        --scope network_compliance \
        --usdm 100000 \
        --split 33 \
        --price-source coingecko-ada-usd \
        --slippage-bps 100 \
        --validity-hours 28 \
        --description "Swapping ADA for USD-denominated vendor payment" \
        --justification "Required to pay Antithesis as vendor" \
        --destination-label "Network Compliance's treasury" \
        --extra-signer core_development \
        --out-dir swap-run-2026-05-09
```

Outputs:

```text
swap-run-2026-05-09/
|-- intent.json
|-- swap.cbor.hex
|-- params.json
|-- wizard.log
`-- build.log
```

## Deterministic quote override

Use this path for rehearsals, tests, or operator runs where the quote
has already been captured from an approved source.

```bash
amaru-treasury-tx \
    --node-socket "$CARDANO_NODE_SOCKET_PATH" \
    --network mainnet \
    swap-quote \
        --wallet-addr "$WALLET_ADDR" \
        --metadata metadata-mainnet.json \
        --scope network_compliance \
        --usdm 100000 \
        --split 33 \
        --ada-usd 0.8123 \
        --slippage-bps 100 \
        --validity-hours 28 \
        --description "Swapping ADA for USD-denominated vendor payment" \
        --justification "Required to pay Antithesis as vendor" \
        --destination-label "Network Compliance's treasury" \
        --out-dir swap-run-override
```

The command records the override as operator-provided provenance in
`params.json`; it is not treated as a fetched quote.

ADA/USDM observations are also accepted explicitly when the approved
operator quote is already in the direct ADA/USDM domain:

```bash
amaru-treasury-tx \
    --node-socket "$CARDANO_NODE_SOCKET_PATH" \
    --network mainnet \
    swap-quote \
        --wallet-addr "$WALLET_ADDR" \
        --metadata metadata-mainnet.json \
        --scope network_compliance \
        --usdm 100000 \
        --split 33 \
        --ada-usdm 0.8120 \
        --slippage-bps 100 \
        --validity-hours 28 \
        --description "Swapping ADA for USD-denominated vendor payment" \
        --justification "Required to pay Antithesis as vendor" \
        --destination-label "Network Compliance's treasury" \
        --out-dir swap-run-usdm-override
```

A named live ADA/USDM source is future work until an approved provider
contract is selected; the explicit override path is the supported
ADA/USDM input path for this issue.

## Review checklist

Before signing, inspect:

- `params.json`: quote source or override, fetch/observation time,
  slippage basis points, derived minimum rate, required ADA, selected
  treasury ADA, and output paths.
- `intent.json`: ordinary swap intent consumed by `tx-build`.
- `build.log`: tx-build validation and redeemer evaluation summary.
- `swap.cbor.hex`: unsigned transaction body to pass into the signing
  process.

## Manual override

Direct `swap-wizard --min-rate` remains available for expert use, but
the operator must document the quote source, slippage decision, and
affordability calculation outside the executable. It is no longer the
primary documentation path.
