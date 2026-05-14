# Parity report — swap golden provenance

Reproducing a real on-chain swap against a frozen chain context.

## Setup

- **Historical reference**: an unsigned swap CBOR built from the
  `journal/2026/bin/swap.sh` bash recipe at upstream commit
  `99600d8`, using the same fixed output ordering as the original
  parity artifact: 33 swap orders, then 1 treasury leftover, then 1
  change output. The current upstream script appends the treasury
  leftover before the chunk loop; the golden provenance records the
  one-line ordering shim used to preserve the intended swap-order
  layout.
- **Current target**: the Haskell stack on this PR — `Tx.Swap.swapProgram`
  feeding the unified `Build.runSwap` path against a frozen
  `ChainContext` captured from the local mainnet node socket
  (`/code/cardano-mainnet/ipc/node.socket`).

## Result

The current Haskell fixture is 14987 bytes with fee 1041155 lovelace.
It intentionally no longer matches the historical `swap.sh` oracle
because the order datum owner policy changed to `AtLeast 2` over all
four treasury owners.

```
capture: expected.cbor 14987 bytes  fee=1041155  exUnits captured: 2
swap_capture_byte_parity=ok
fixture_matches_capture=ok
haskell_target_match=ok
```

The checked-in golden asserts both:

1. `test/fixtures/swap/expected.cbor` equals
   `test/fixtures/swap/target.tx.json.cborHex`.
2. Rebuilding with `runFromIntent` against the frozen fixture produces
   that exact target CBOR.

| Field | Haskell fixture |
|---|---|
| inputs | 2 |
| reference inputs | 4 |
| outputs | 35 |
| withdrawals | 1 |
| required signers | 2 |
| validity upper bound | 186796799 |

The historical bash capture remains documented in
`test/fixtures/swap/provenance.md`; it should be regenerated once the
bash workflow adopts the same owner datum.

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
capture: expected.cbor 14987 bytes  fee=1041155  exUnits captured: 2
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
  test/fixtures/swap/expected.cbor \
  /tmp/amaru-swap-capture/expected.cbor

jq -r .cborHex test/fixtures/swap/target.tx.json \
  | tr -d '\n' \
  | cmp -s - test/fixtures/swap/expected.cbor
```

The committed `golden-tests` suite is immune to chain drift because it
uses the frozen fixture under `test/fixtures/swap/`.
