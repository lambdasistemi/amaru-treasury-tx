# Quickstart: Unified `tx-build`

**Plan**: [plan.md](./plan.md) · **Spec**: [spec.md](./spec.md)
**Date**: 2026-05-06

This is the operator-facing walkthrough. It supersedes feature
002's quickstart (`swap-wizard | swap`) and feature 004's planned
quickstart (`disburse-wizard | disburse`). After this feature
lands, every action ends with `| tx-build`.

## 1. Prerequisites

- A running cardano-node socket reachable by the local-node
  `Provider` (preprod or mainnet).
- Your wallet bech32 address.
- A local `journal/2026/metadata.json`-shaped file (used by every
  wizard; verified against the connected node before any intent
  is produced).

Set `EXE` once and reuse it:

```bash
EXE='nix run github:lambdasistemi/amaru-treasury-tx#amaru-treasury-tx --'
```

## 2. The shape — one builder, many wizards

After this feature lands the matrix is:

| Wizard | Pipe shape |
|---|---|
| `swap-wizard ... \| tx-build > tx.cbor` | swap |
| `disburse-wizard ... \| tx-build > tx.cbor` | disburse |
| `withdraw-wizard ... \| tx-build > tx.cbor` | withdraw (after [#45](https://github.com/lambdasistemi/amaru-treasury-tx/issues/45)) |
| `reorganize-wizard ... \| tx-build > tx.cbor` | reorganize (after [#46](https://github.com/lambdasistemi/amaru-treasury-tx/issues/46)) |

The `tx-build` invocation is **identical** for every action — it
reads the action from the intent and dispatches.

## 3. Swap, end to end (post-unification)

```bash
$EXE \
    swap-wizard \
        --network mainnet \
        --node-socket /code/cardano-mainnet/ipc/node.socket \
        --wallet-addr addr1q802wxt6cg6aw0nl0vdzfxavu65rxu3yzhvgayw7chfxymduzkt66uw9t5kspx5jwjecx80dz4g33htknafhdhkvzd5st4f9xu \
        --metadata metadata-mainnet.json \
        --scope network_compliance \
        --usdm 100000 \
        --split 33 \
        --min-rate 0.245 \
        --validity-hours 28 \
        --description "Swapping ADA for \$100k at a rate of \$0.245 per ADA" \
        --justification "Required to pay Antithesis as vendor" \
        --destination-label "Network Compliance's treasury" \
        --extra-signer core_development \
        --log wizard.log \
  | $EXE \
        tx-build \
            --node-socket /code/cardano-mainnet/ipc/node.socket \
            --log build.log \
            --out swap.cbor.hex
```

Differences from feature 002's quickstart:

- The build subcommand is `tx-build`, not `swap`.
- **No `--network` on the `tx-build` invocation.** The intent
  carries it; the build derives the handshake magic.
- The wizard's `--network` flag is unchanged (the wizard still
  needs it to pick the right `metadata.json` row and the right
  `NetworkConstants`).

## 4. Disburse, end to end (post-unification)

```bash
$EXE \
    disburse-wizard \
        --network mainnet \
        --node-socket /code/cardano-mainnet/ipc/node.socket \
        --wallet-addr addr1q802... \
        --metadata metadata-mainnet.json \
        --scope core_development \
        --beneficiary-addr addr1q9vendor... \
        --unit ada \
        --amount 50000000 \
        --validity-hours 6 \
        --description "Q2 vendor invoice — translation services" \
        --justification "Per CIP-1694 budget allocation" \
        --destination-label "ACME Translations Ltd." \
        --extra-signer ops_and_use_cases \
        --log wizard.log \
  | $EXE \
        tx-build \
            --node-socket /code/cardano-mainnet/ipc/node.socket \
            --log build.log \
            --out disburse.cbor.hex
```

Same `tx-build` invocation as the swap example. The intent JSON
flowing through the pipe declares `"action": "disburse"`, so
`tx-build` runs the disburse build path.

## 5. Reading the trace

`tx-build` emits typed events on `--log` (or stderr):

```
tx-build: intent <- stdin
tx-build: parsed action=swap network=mainnet
tx-build: connecting to /code/cardano-mainnet/ipc/node.socket
tx-build: handshake ok (magic 764824073 matches intent)
tx-build: required utxos: 6
tx-build: built 15240 bytes  fee=1025037  total_collateral=1537556
tx-build: re-evaluated 2 redeemers, 0 failed
tx-build: cbor -> swap.cbor.hex
tx-build: summary -> swap.summary.json
tx-build: VALIDATION OK
```

The `parsed action=… network=…` line is new — it's the build's
declaration of what kind of tx it's about to construct, sourced
from the intent.

## 6. When something goes wrong

| Exit | Action |
|------|--------|
| 1 (`tx-build`) | One or more redeemers failed re-evaluation. The summary captures the per-script failure detail; CBOR is still emitted. |
| 3 (`tx-build`) | Intent JSON parse failure. The trace's `ABORT` line names the field (e.g. `unknown intent schema: 99`, `action 'frob' not in ['swap','disburse','withdraw','reorganize']`, `action='swap' but no 'swap' block in intent`). |
| 4 (`tx-build`) | Translation error. Typed message identifies the field. |
| 5 (`tx-build`) | Build / balance failure. Often insufficient ADA after fee estimation. |
| 6 (`tx-build`) | **Network mismatch**. The trace says `intent declares mainnet (magic 764824073), socket reports magic 1 (preprod)`. Check `--node-socket` matches the wizard's `--network`. |

## 7. What changed for operators following the old quickstart?

If you used the feature 002 quickstart (`swap-wizard | swap`):

1. Replace `| swap` with `| tx-build` in your pipeline.
2. Drop `--network` from the build side. The wizard still takes it.
3. If you have hand-curated `intent.json` files saved on disk:
   re-run the wizard. The old format (no `network`, no `schema`,
   no `action`) is rejected at parse time.

If you used feature 004's planned `disburse-wizard | disburse`:
that subcommand never shipped — feature 004's resumed PR will
adopt `| tx-build` directly.

## 8. Verifying the build (developer)

```bash
just unit                 # round-trip property + parse-error tests
just golden               # swap + ada-disburse byte-identical
just smoke tx-build-pipe  # end-to-end pipe smoke
```

The byte-identity gate (SC-004) is on `expected.cbor`: the swap
golden and the ada-disburse golden re-record byte-for-byte
against the new intent shape. Any diff is a regression and blocks
merge.
