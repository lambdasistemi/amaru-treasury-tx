# Quickstart: Swap Remaining ADA

Use `--all-ada` when the selected treasury scope has a pure ADA remainder and the operator wants to swap the maximum ledger-valid amount to USDM.

```bash
amaru-treasury-tx \
  --node-socket "$CARDANO_NODE_SOCKET_PATH" --network mainnet \
  swap-wizard \
    --wallet-addr "$WALLET_ADDR" \
    --metadata metadata-mainnet.json \
    --scope network_compliance \
    --all-ada \
    --split 1 \
    --ada-usdm 0.265 \
    --slippage-bps 100 \
    --validity-hours 28 \
    --description "Swap remaining ADA to USDM" \
    --justification "Convert remaining treasury ADA balance" \
    --destination-label "Network Compliance's treasury" \
    --extra-signer ops_and_use_cases \
| amaru-treasury-tx \
  --node-socket "$CARDANO_NODE_SOCKET_PATH" --network mainnet \
  tx-build --out /dev/null --report - \
| amaru-treasury-tx report-render --metadata metadata-mainnet.json
```

Review the `swap-wizard:` trace before signing. It names the pure ADA treasury UTxOs selected, the ADA amount spent, implied USDM target, leftover lovelace, split/chunk count, per-chunk overhead, and effective minimum rate.

All-ADA mode ignores token-bearing treasury UTxOs. Use fixed `--usdm` mode for workflows that intentionally need to include token-bearing UTxOs.
