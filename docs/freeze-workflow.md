# Freezing a `ChainContext`

How to capture a `ChainContext` snapshot so the swap-probe parity
check stays reproducible when the on-chain inputs are spent or
pparams shift.

> **Status**: skeleton. Implementation lands on
> `feat/001-phase4-frozen-context`. This page documents the target
> workflow.

## Why

The probe today calls `liveContext` against the local mainnet node.
That works *now* because the original swap was built but not
submitted, so its wallet and treasury UTxOs still exist. The moment
either is spent — or a hard fork bumps cost models, or
`minFeeRefScriptCostPerByte` changes by governance vote — the probe
cannot reproduce the byte sequence anymore, even though the Haskell
code is unchanged.

A frozen `ChainContext` pins everything the build reads from the
chain: pparams, the 6 UTxOs (values + reference scripts), and the
ExUnits the node returned for each redeemer purpose. From then on,
the probe is a pure regression test against a checked-in fixture.

## Where the fixture lives

```
test/fixtures/swap/
├── pparams.json     # Conway pparams snapshot (already exists)
├── utxos.json       # 6 UTxOs (TxIn → TxOut with value + ref script)
├── exunits.json     # per-redeemer-purpose ExUnits map
└── expected.cbor    # the 14954-byte hex CBOR the build must produce
```

## Refreshing the fixture

When a new on-chain reference is captured:

```bash
# 1. Point at a node that has the inputs unspent + the right pparams
export CARDANO_NODE_SOCKET_PATH=/path/to/cardano-node.socket

# 2. Capture
nix run .#capture-swap-context -- \
  --intent test/fixtures/swap/intent.json \
  --out-dir test/fixtures/swap/

# 3. Re-run the live probe to regenerate expected.cbor
nix run .#swap-probe > test/fixtures/swap/expected.cbor

# 4. Run the offline golden to confirm parity
just unit --match "swap golden"
```

The capture command writes `pparams.json`, `utxos.json`, and
`exunits.json` (snapshot of one `evaluateTx` call against a
draft tx). The offline golden then loads them via `frozenContext`
and rebuilds `expected.cbor` deterministically.

## What the offline golden proves

- The Haskell builders + `runSwapBuild` are deterministic given a
  fixed `ChainContext`.
- Byte-level parity against the on-chain reference is not a
  network-flake artefact: it is reproduced on a network-less CI.
- Future code changes that drift the bytes are caught by the diff
  against `expected.cbor`.

## What it does not prove

The fixture is a moment-in-time snapshot. If real-world pparams
change (e.g. `minFeeA`, `collateralPercent`), the *new* live build
will diverge from the frozen one — and that's the point: the
divergence is now visible and intentional, not a failure of the
build pipeline.

To check live parity again, refresh the fixture (steps above) and
diff with the previous fixture if you want to see what changed.
