# Parity report — Haskell vs `swap.sh`

Reproducing a real on-chain swap, to the byte.

## Setup

- **Reference**: an unsigned swap CBOR built from the
  `journal/2026/bin/swap.sh` bash recipe at upstream commit
  `99600d8`, using the same fixed output ordering as the original
  parity artifact: 33 swap orders, then 1 treasury leftover, then 1
  change output. The current upstream script appends the treasury
  leftover before the chunk loop; the golden provenance records the
  one-line ordering shim used to preserve the intended swap-order
  layout.
- **Ours**: the Haskell stack on this PR — `Tx.Swap.swapProgram`
  feeding the unified `Build.runSwap` path against a frozen
  `ChainContext` captured from the local mainnet node socket
  (`/code/cardano-mainnet/ipc/node.socket`).

## Result

Same 14954 bytes. **Byte-for-byte identical.**

```
capture: expected.cbor 14954 bytes  fee=1039703  exUnits captured: 2
swap_capture_byte_parity=ok
fixture_matches_capture=ok
oracle_body_match=ok
```

The checked-in golden asserts both:

1. `test/fixtures/swap/expected.cbor` equals
   `test/fixtures/swap/bash.oracle.tx.json.cborHex`.
2. Rebuilding with `runFromIntent` against the frozen fixture produces
   that exact oracle CBOR.

| Field | Haskell | bash | Match |
|---|---|---|---|
| inputs (2) | identical | identical | ✓ |
| reference inputs (4) | identical | identical | ✓ |
| outputs (35) | identical | identical | ✓ |
| inline datums (33) | identical | identical | ✓ |
| withdrawals (1) | identical | identical | ✓ |
| required signers (2) | identical | identical | ✓ |
| validity upper bound | identical | identical | ✓ |
| `script_data_hash` | identical | identical | ✓ |
| `aux_data_hash` | identical | identical | ✓ |

`script_data_hash` matching means the redeemer values **and** the
committed `ExUnits` are byte-equal. `aux_data_hash` matching means
the rationale metadatum at label 1694 is byte-equal.

## Fee Alignment

`cardano-cli transaction build` prices the unsigned body using its
default key-witness estimate when `--witness-override` is absent. For
this swap that is seven witnesses. The generic balancer starts from a
single dummy witness, so the unified build path now re-prices the final
body with the same conservative witness count and adjusts the fee,
total collateral, collateral return, and wallet change output before
serialization.

## Validation

After the build, the golden path re-runs the evaluator against the
settled tx:

```
capture: expected.cbor 14954 bytes  fee=1039703  exUnits captured: 2
```

The two redeemers are the treasury spend (Sundae `Disburse`,
constructor 3) and the permissions withdraw-zero (empty list).
Both succeed with the committed `ExUnits`, which is the strongest
script-validity check possible without signatures.

## Reproducing

```bash
export CARDANO_NODE_SOCKET_PATH=/code/cardano-mainnet/ipc/node.socket
nix develop -c cabal run -O0 exe:capture-swap-context -- \
  --intent /tmp/amaru-swap-fixed-bash-provenance/intent.fixed.json \
  --out-dir /tmp/amaru-swap-capture \
  --node-socket /code/cardano-mainnet/ipc/node.socket \
  --network-magic 764824073

cmp -s \
  /tmp/amaru-swap-fixed-bash-provenance/bash.fixed.cbor \
  /tmp/amaru-swap-capture/expected.cbor

cmp -s \
  test/fixtures/swap/expected.cbor \
  /tmp/amaru-swap-capture/expected.cbor

jq -r .cborHex test/fixtures/swap/bash.oracle.tx.json \
  | tr -d '\n' \
  | cmp -s - test/fixtures/swap/expected.cbor
```

The committed `golden-tests` suite is immune to chain drift because it
uses the frozen fixture under `test/fixtures/swap/`.
