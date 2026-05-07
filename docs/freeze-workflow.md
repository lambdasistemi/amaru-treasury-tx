# Freezing a `ChainContext`

How to capture a `ChainContext` snapshot so golden parity checks
stay reproducible when the on-chain inputs are spent or protocol
parameters shift.

## Why

Live builds call `liveContext` against a local node. That is the
right operator path, but it is not a stable regression test: wallet
and treasury UTxOs can be spent, hard forks can change cost models,
and governance can move fee parameters.

A frozen `ChainContext` pins everything the build reads from the
chain: protocol parameters, resolved UTxOs (values and reference
scripts), and the ExUnits the node returned for each redeemer
purpose. From then on, the golden is a pure regression test against
checked-in data.

## Where the fixture lives

```
test/fixtures/swap/
├── pparams.json     # Conway pparams snapshot (already exists)
├── utxos.json       # 6 UTxOs (TxIn → TxOut with value + ref script)
├── exunits.json     # per-redeemer-purpose ExUnits map
├── bash.oracle.tx.json
├── provenance.md
└── expected.cbor    # the 14954-byte hex CBOR the build must produce
```

The ADA disburse fixture follows the same shape under
`test/fixtures/disburse/ada/`, with `body.cbor` as the expected
hex file.

## Refreshing the fixture

When a new on-chain reference is captured:

```bash
# 1. Point at a node that has the inputs unspent + the right pparams
export CARDANO_NODE_SOCKET_PATH=/path/to/cardano-node.socket

# 2. Capture live UTxOs, ExUnits, and the rebuilt CBOR
rm -rf /tmp/amaru-swap-capture
nix run .#capture-swap-context -- \
  --intent test/fixtures/swap/intent.json \
  --out-dir /tmp/amaru-swap-capture \
  --node-socket "$CARDANO_NODE_SOCKET_PATH" \
  --network-magic 764824073

# 3. Compare the capture with the bash oracle
jq -r .cborHex test/fixtures/swap/bash.oracle.tx.json \
  | tr -d '\n' \
  | cmp -s - /tmp/amaru-swap-capture/expected.cbor

# 4. Copy the refreshed fixture only after parity holds
cp /tmp/amaru-swap-capture/utxos.json test/fixtures/swap/utxos.json
cp /tmp/amaru-swap-capture/exunits.json test/fixtures/swap/exunits.json
cp /tmp/amaru-swap-capture/expected.cbor test/fixtures/swap/expected.cbor

# 5. Run the offline golden to confirm parity
just golden swap
```

The capture command writes `utxos.json`, `exunits.json`, and the
rebuilt body hex. Keep `pparams.json` as the protocol-parameter
snapshot that matches the oracle capture. The offline golden then
loads the fixture via `frozenContext` and rebuilds the body
deterministically.

## What the offline golden proves

- The Haskell builders + `runFromIntent` are deterministic given a
  fixed `ChainContext`.
- Byte-level parity against the bash/cardano-cli reference is not a
  network artefact: it is reproduced on network-less CI.
- Future code changes that drift the bytes are caught by the diff
  against `expected.cbor` / `body.cbor`.

## What it does not prove

The fixture is a moment-in-time snapshot. It proves that the Haskell
builder still emits the same unsigned body given the same chain
facts. It does not prove that the original UTxOs are still unspent
or that the body is still submitable today.

To check live parity again, refresh the fixture (steps above) and
diff with the previous fixture if you want to see what changed.
