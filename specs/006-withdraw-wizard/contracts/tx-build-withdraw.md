# Contract: `tx-build` for Withdraw Intents

`tx-build` is the only release-facing builder command. For withdraw it
consumes a unified `intent.json` with `action = "withdraw"`.

## Usage

```bash
amaru-treasury-tx \
  --node-socket "$CARDANO_NODE_SOCKET_PATH" \
  tx-build \
    --intent withdraw.intent.json \
    --out withdraw.cbor.hex \
    --log build.log
```

Or as a pipe:

```bash
amaru-treasury-tx withdraw-wizard ... \
  | amaru-treasury-tx tx-build --out withdraw.cbor.hex
```

## Build behavior

Before querying chain state, `tx-build` must:

1. parse `intent.json`;
2. read `intent.network`;
3. probe the node socket network magic;
4. exit 6 on mismatch.

For a valid withdraw intent on a matching socket, `tx-build` must:

- query the wallet fuel UTxO;
- query the treasury and registry reference UTxOs;
- build a `ChainContext`;
- translate the intent to `WithdrawIntent`;
- run the withdraw build branch;
- re-evaluate the final transaction;
- write unsigned hex CBOR to stdout or `--out`.

## Body requirements

The unsigned transaction body must contain:

- one normal input: wallet fuel;
- wallet collateral input;
- treasury deployed-script reference input;
- registry reference input;
- one withdrawal from the treasury reward account;
- one output to the treasury contract address for `rewardsLovelace`;
- validity upper bound from the intent;
- metadata label 1694 with the intent rationale.

## Failure behavior

- Invalid JSON: exit non-zero, no CBOR.
- Unsupported schema: exit non-zero, no CBOR.
- Network mismatch: exit 6 before any chain query.
- Missing UTxO/reference: exit non-zero, no CBOR.
- Script evaluation failure: exit non-zero, no CBOR; trace records the
  failing redeemer.

## Trace events

Required build trace surface:

- intent source
- parsed action/network
- network handshake result
- required UTxO count
- missing UTxO failure, if any
- build summary: bytes, fee, total collateral
- re-evaluation summary
- CBOR output path
- validation OK
- abort
