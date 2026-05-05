# Parity report — Haskell vs `swap.sh`

Reproducing a real on-chain swap, to the byte.

## Setup

- **Reference**: an unsigned swap CBOR built this morning by the
  Pragma operations team using
  [`journal/2026/bin/swap.sh`](https://github.com/pragma-org/amaru-treasury/blob/main/journal/2026/bin/swap.sh)
  + `cardano-cli transaction build` against mainnet. 14954 bytes,
  33 swap orders + 1 treasury leftover + 1 change output, 408,163.27
  ADA going to a SundaeSwap USDM order at rate 0.245.
- **Ours**: the Haskell stack on this PR — `Tx.Swap.swapProgram`
  feeding `Tx.SwapBuild.runSwapBuild`, run via the `swap-probe`
  executable against the local mainnet node socket
  (`/code/cardano-mainnet/ipc/node.socket`).

## Result

Same 14954 bytes. **8 bytes differ**, in 4 groups, **all in the
fee chain**:

```
diff groups: 4
diff bytes:  8

  fee:               1,009,695  vs  1,043,795   Δ -34,100
  total_collateral:  1,514,543  vs  1,565,693   Δ -51,150 (= ⌈ΔFee × 1.5⌉)
  collateral_return: wallet − 1,514,543  vs  wallet − 1,565,693
  change output:     input − fee − sundae  vs  input − fee − sundae
```

Body bytes elsewhere are byte-identical:

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

## Where the residue comes from

The 34,100-lovelace fee gap has two sources:

1. **76 byte size delta (~3,344 lovelace)**: cardano-node-clients
   `build` doesn't model the CIP-40 `total_collateral` /
   `collateral_return` body fields. The probe post-patches them, but
   the fee was estimated against the smaller body. Tracked upstream
   as
   [`cardano-node-clients#124`](https://github.com/lambdasistemi/cardano-node-clients/issues/124).
2. **The remaining ~30,756 lovelace**: the same `cardano-cli` vs
   `cardano-node-clients` fee-estimator gap we saw bash-vs-bash
   earlier — they don't iterate to the exact same fixed point. Both
   produce mempool-valid txs.

Closing the residue is not a correctness issue (both txs validate);
it's a tighter-fee-estimator question that belongs upstream.

## Validation

After the build, the probe re-runs the live evaluator against the
patched tx:

```
swap-probe: re-evaluated 2 redeemers, 0 failed
swap-probe: VALIDATION OK
```

The two redeemers are the treasury spend (Sundae `Disburse`,
constructor 3) and the permissions withdraw-zero (empty list).
Both succeed with the committed `ExUnits`, which is the strongest
script-validity check possible without signatures.

## Reproducing

```bash
export CARDANO_NODE_SOCKET_PATH=/code/cardano-mainnet/ipc/node.socket
nix run .#swap-probe > haskell-build.hex
diff haskell-build.hex /code/swap-experiment/user-final.hex
```

The probe is **immune to chain state today**, but will start failing
when either the wallet UTxO or the treasury UTxO is spent. To make
it permanently reproducible we need the frozen `ChainContext`
fixture mode — see the [ChainContext doc](chain-context.md).
