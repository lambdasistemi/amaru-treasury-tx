# Building an ADA disburse transaction

`tx-build` can build a unified ADA disburse `intent.json` into
unsigned Conway CBOR. There is no release-facing `disburse-wizard`
command yet, so this page assumes the intent already exists.

## CLI usage

```bash
export CARDANO_NODE_SOCKET_PATH=/path/to/cardano-node.socket

amaru-treasury-tx \
  --node-socket "$CARDANO_NODE_SOCKET_PATH" \
  tx-build \
    --intent disburse.intent.json \
    --out disburse.cbor.hex \
    --log disburse.log
```

The intent's top-level `network` field is the source of truth.
`tx-build` probes the socket against that network before querying
UTxOs or balancing.

## Supported payload

The shipped disburse branch supports ADA disburse intents:

```json
{
  "schema": 1,
  "action": "disburse",
  "network": "mainnet",
  "disburse": {
    "unit": "ada",
    "amount": 50000000,
    "beneficiaryAddress": "addr1..."
  }
}
```

The full intent also carries the shared `wallet`, `scope`,
`signers`, `validityUpperBoundSlot`, and `rationale` blocks
described by `docs/assets/intent-schema.json`.

## Validation

The build path queries a live `ChainContext`, builds the tx,
aligns the fee with the bash/cardano-cli oracle behaviour, and
re-runs the evaluator against the final body. A successful log ends
with:

```text
tx-build: re-evaluated 2 redeemers, 0 failed
tx-build: cbor -> disburse.cbor.hex
tx-build: VALIDATION OK
```

## Golden evidence

`test/fixtures/disburse/ada/` pins an ADA disburse
bash/cardano-cli oracle:

- `body.cbor` is the expected body hex;
- `bash.oracle.tx.json` is the original cardano-cli JSON wrapper;
- `pparams.json`, `utxos.json`, and `exunits.json` freeze the
  chain context used to rebuild it offline.

The golden suite asserts both `body.cbor ==
bash.oracle.tx.json.cborHex` and `runFromIntent` against the
frozen fixture rebuilds that same oracle byte-for-byte.
