# Contract: `swap-cancel`

## Command

```text
amaru-treasury-tx --node-socket PATH --network NAME \
  swap-cancel \
    --metadata PATH \
    --scope NAME \
    --wallet-txin TXHASH#IX \
    --order-txin TXHASH#IX \
    --order-script-ref TXHASH#IX \
    --validity-hours HOURS \
    --out tx.raw \
    [--report PATH]
```

## Inputs

- `--metadata PATH`: same deployment metadata consumed by existing
  wizard commands.
- `--scope NAME`: selected treasury scope.
- `--wallet-txin TXHASH#IX`: wallet fuel/collateral input.
- `--order-txin TXHASH#IX`: pending SundaeSwap order UTxO.
- `--order-script-ref TXHASH#IX`: reference input containing the
  SundaeSwap order spending script.
- `--validity-hours HOURS`: validity horizon, same policy as swap
  builders.
- `--out PATH`: unsigned transaction CBOR hex output path.
- `--report PATH`: optional JSON report output path; `-` means stdout.

## Outputs

### Unsigned CBOR

Hex-encoded unsigned Conway transaction body compatible with the
existing witness/submission flow.

### JSON Report

```json
{
  "action": "swap-cancel",
  "orderTxIn": "TXHASH#IX",
  "treasuryDestination": "addr1...",
  "returnedValue": {
    "lovelace": 0,
    "assets": []
  },
  "requiredSigners": [
    "hex28"
  ],
  "nextSteps": [
    "review",
    "sign with required owners",
    "submit signed transaction"
  ]
}
```

## Failure Contract

The command exits non-zero and emits no unsigned CBOR when:

- the order UTxO is missing or already spent;
- the order datum is missing or malformed;
- the owner policy is not the supported Amaru all-signatures policy;
- the owner policy does not match metadata owners;
- the destination does not match the selected treasury;
- wallet fuel cannot pay fees/collateral;
- script evaluation or final validation fails.

