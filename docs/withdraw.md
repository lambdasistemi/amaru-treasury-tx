# Building a withdraw transaction

`withdraw-wizard` resolves a treasury reward withdrawal and emits a
unified `intent.json`. `tx-build` consumes that intent and builds the
unsigned Conway CBOR. There is no release-facing `withdraw` builder
command.

See [Wizard input control](wizard-input-control.md) for the
`--exclude-utxo` / `--extra-tx-in` flags shared with every other
wizard.

## CLI usage

Set the node socket once:

```bash
export CARDANO_NODE_SOCKET_PATH=/path/to/cardano-node.socket
```

Fetch the 2026 treasury metadata:

```bash
curl -fsSL \
  https://raw.githubusercontent.com/pragma-org/amaru-treasury/main/journal/2026/metadata.json \
  -o metadata.json
```

The wizard treats this file as an untrusted hint. It verifies the
consumed registry fields against the on-chain anchors before emitting
an intent.

Produce an intent:

```bash
amaru-treasury-tx \
  --node-socket "$CARDANO_NODE_SOCKET_PATH" \
  --network preprod \
  withdraw-wizard \
    --wallet-addr addr_test1... \
    --metadata metadata.json \
    --scope core_development \
    --validity-hours 6 \
    --log withdraw-wizard.log \
    --out withdraw.intent.json
```

Build unsigned CBOR from that intent:

```bash
amaru-treasury-tx \
  --node-socket "$CARDANO_NODE_SOCKET_PATH" \
  tx-build \
    --intent withdraw.intent.json \
    --log withdraw-build.log \
    --out withdraw.cbor.hex
```

The intent's top-level `network` field is the source of truth.
`tx-build` probes the socket against that network before querying UTxOs
or balancing.

## Pipe form

The wizard can write JSON to stdout and traces to stderr, so the normal
operator flow can avoid an intermediate file:

```bash
amaru-treasury-tx \
  --node-socket "$CARDANO_NODE_SOCKET_PATH" \
  --network preprod \
  withdraw-wizard \
    --wallet-addr addr_test1... \
    --metadata metadata.json \
    --scope core_development \
    --validity-hours 6 \
  | amaru-treasury-tx \
      --node-socket "$CARDANO_NODE_SOCKET_PATH" \
      tx-build \
        --out withdraw.cbor.hex
```

Use `--log PATH` on either side when traces must be kept out of the
terminal. The pipe relies on stdout containing only JSON from the wizard
and only CBOR hex from `tx-build`.

## Zero rewards

If the selected treasury reward account has zero rewards,
`withdraw-wizard` exits 0 and does not create or update the `--out`
intent path. This prevents a stale positive-rewards intent from being
mistaken for a current withdrawal.

## Supported payload

The generated intent uses the shared `TreasuryIntent` envelope and the
withdraw payload:

```json
{
  "schema": 1,
  "action": "withdraw",
  "network": "preprod",
  "withdraw": {
    "treasuryRewardAccount": "32201dc1e82708364c6c42a53f89f675314bb9ad5da2734aa10baa0d",
    "rewardsLovelace": 12345678
  }
}
```

`treasuryRewardAccount` is the 28-byte treasury stake-script hash hex,
not a bech32 stake address. The schema enforces this shape.

The full intent also carries the shared `wallet`, `scope`, `signers`,
`validityUpperBoundSlot`, and `rationale` blocks described by
`docs/assets/intent-schema.json`.

## Validation

`tx-build` translates the unified intent into the typed withdraw build
record, queries the live `ChainContext`, builds the transaction, aligns
the fee with the `cardano-cli transaction build` witness estimate, and
re-runs the evaluator against the final body. A successful log ends
with:

```text
tx-build: re-evaluated 1 redeemers, 0 failed
tx-build: cbor -> withdraw.cbor.hex
tx-build: VALIDATION OK
```

The withdraw transaction spends the wallet UTxO, uses that same UTxO as
collateral, includes the treasury and registry reference inputs,
withdraws the resolved reward amount, and produces one wallet change
output.

## Golden evidence

`test/fixtures/withdraw/synthetic/` pins an offline synthetic withdraw
fixture:

- `intent.json` is the schema-valid unified withdraw intent;
- `utxos.json`, `pparams.json`, and `exunits.json` freeze the builder
  context;
- `expected.cbor` is the expected unsigned body CBOR;
- `provenance.md` records why the fixture is synthetic.

Run the focused golden with:

```bash
nix develop --quiet -c just golden withdraw
```

The golden suite decodes the fixture intent, loads the frozen
`ChainContext`, and rebuilds `expected.cbor` byte-for-byte.

Unlike swap and ADA disburse, withdraw does not yet have a live
bash/cardano-cli oracle. Mainnet rewards are currently zero, so the live
preprod replacement is tracked in
[`issue #17`](https://github.com/lambdasistemi/amaru-treasury-tx/issues/17).
