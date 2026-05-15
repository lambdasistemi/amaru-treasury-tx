# Contract: swap-wizard All ADA CLI

## Valid Forms

Fixed USDM target, unchanged:

```bash
amaru-treasury-tx --node-socket "$CARDANO_NODE_SOCKET_PATH" --network mainnet \
  swap-wizard \
    --wallet-addr "$WALLET_ADDR" \
    --metadata metadata-mainnet.json \
    --scope network_compliance \
    --usdm 100000 \
    --split 33 \
    --ada-usdm 0.270 --slippage-bps 100 \
    --description "Swap ADA to USDM" \
    --justification "Treasury execution" \
    --destination-label "Network Compliance's treasury"
```

All-ADA target:

```bash
amaru-treasury-tx --node-socket "$CARDANO_NODE_SOCKET_PATH" --network mainnet \
  swap-wizard \
    --wallet-addr "$WALLET_ADDR" \
    --metadata metadata-mainnet.json \
    --scope network_compliance \
    --all-ada \
    --split 1 \
    --ada-usdm 0.265 --slippage-bps 100 \
    --description "Swap remaining ADA to USDM" \
    --justification "Convert remaining treasury ADA balance" \
    --destination-label "Network Compliance's treasury"
```

## Rejected Forms

- `--all-ada --usdm 100000`: target modes are mutually exclusive.
- no `--all-ada` and no `--usdm`: target mode is required.
- `--all-ada --chunk-usdm 5000`: all-ADA mode requires `--split`.
- `--all-ada --split 0`: split must be positive.

## Trace Contract

A successful all-ADA run emits a trace line containing these facts:

- selected pure ADA treasury UTxOs
- available lovelace
- amount lovelace
- implied USDM in smallest units
- leftover lovelace
- split count and produced chunk count
- per-chunk overhead and total overhead
- effective rate numerator and denominator

The exact wording may evolve, but all numeric facts must be present in one or more `swap-wizard:` trace lines.
