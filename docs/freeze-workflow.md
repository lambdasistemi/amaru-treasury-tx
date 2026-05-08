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

The withdraw fixture lives under
`test/fixtures/withdraw/synthetic/`:

```
test/fixtures/withdraw/synthetic/
├── intent.json       # schema-valid unified withdraw intent
├── pparams.json      # Conway pparams snapshot
├── utxos.json        # wallet + reference UTxOs named by the intent
├── exunits.json      # rewarding-purpose ExUnits for offline evaluation
├── provenance.md
└── expected.cbor     # synthetic unsigned body hex
```

This fixture is synthetic until
[`issue #17`](https://github.com/lambdasistemi/amaru-treasury-tx/issues/17)
captures a live reward-bearing preprod oracle.

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

## Refreshing the synthetic withdraw fixture

The withdraw fixture is not captured from the live `withdraw.sh`
oracle yet. It is refreshed from the checked-in synthetic intent and
frozen `ChainContext`:

```bash
# 1. Edit the fixture inputs deliberately.
$EDITOR test/fixtures/withdraw/synthetic/intent.json
$EDITOR test/fixtures/withdraw/synthetic/utxos.json
$EDITOR test/fixtures/withdraw/synthetic/pparams.json
$EDITOR test/fixtures/withdraw/synthetic/exunits.json

# 2. Regenerate the expected body from those checked-in facts.
UPDATE_GOLDENS=1 nix develop --quiet -c just golden withdraw

# 3. Re-run without UPDATE_GOLDENS to prove the checked-in oracle is stable.
nix develop --quiet -c just golden withdraw

# 4. Re-run the schema check because intent.json is a public contract input.
nix develop --quiet -c just unit IntentJSONSchema
```

Only commit the regenerated `expected.cbor` with the exact fixture facts
that produced it. Update `provenance.md` whenever the synthetic reward
amount, reward account, validity slot, or fixture source changes.

When issue #17 supplies a live preprod oracle, replace this section's
synthetic update flow with the same capture-and-compare discipline used
for swap: capture live UTxOs/ExUnits/body, compare against the
bash/cardano-cli oracle, then commit the frozen context and body hex.

## What the offline golden proves

- The Haskell builders + `runFromIntent` are deterministic given a
  fixed `ChainContext`.
- Byte-level parity against the bash/cardano-cli reference is not a
  network artefact for swap and ADA disburse: it is reproduced on
  network-less CI.
- The withdraw builder still consumes the schema-valid synthetic
  intent and frozen context to produce the committed unsigned body.
- Future code changes that drift the bytes are caught by the diff
  against `expected.cbor` / `body.cbor`.

## What it does not prove

The fixture is a moment-in-time snapshot. It proves that the Haskell
builder still emits the same unsigned body given the same chain
facts. It does not prove that the original UTxOs are still unspent
or that the body is still submitable today.

To check live parity again, refresh the fixture (steps above) and
diff with the previous fixture if you want to see what changed.
