# Quickstart: Cancel Pending SundaeSwap Orders

## Explicit Order Path

Use this path before #109 inspect integration is complete.

```bash
amaru-treasury-tx \
  --node-socket "$CARDANO_NODE_SOCKET_PATH" \
  --network mainnet \
  swap-cancel \
    --metadata mainnet.json \
    --scope network_compliance \
    --wallet-txin "$WALLET_TXIN" \
    --order-txin "$ORDER_TXIN" \
    --validity-hours 2 \
    --out cancel.tx \
    --report cancel.report.json
```

On mainnet, the Sundae order reference-script UTxO is built in. On
non-mainnet networks, pass `--order-script-ref TXHASH#IX` explicitly.

Review `cancel.report.json`:

- the order UTxO is the one intended for cancellation;
- the returned value matches the pending order value;
- the treasury destination matches the selected scope;
- all four treasury owner signers are listed.

Then use the existing witness/submission workflow outside this command.

## Inspect-Driven Path

After #109 lands, the intended flow is:

```bash
amaru-treasury-tx treasury-inspect \
  --metadata mainnet.json \
  --scope network_compliance \
  --format json \
  --out inspect.json

amaru-treasury-tx swap-cancel \
  --metadata mainnet.json \
  --scope network_compliance \
  --from-inspect inspect.json \
  --order-txin "$ORDER_TXIN" \
  --out cancel.tx \
  --report cancel.report.json
```

The exact inspect input option may change once #109 finalizes its JSON
contract.
