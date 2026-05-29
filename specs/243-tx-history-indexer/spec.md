# Feature Spec: Tx History Indexer

## User Story

As a treasury operator on devnet, after submitting treasury
transactions, I can run:

```bash
amaru-treasury-tx history --scope core_development
```

and see the confirmed treasury transaction entries as `(slot, txid,
role)` rows. The result comes from the local indexer store, not from a
node UTxO query or a second chain-sync process.

## Acceptance

- Upstream `cardano-node-clients` exposes a new public
  `tx-history-indexer-lib` sublibrary.
- The history index is RocksDB-backed, decoder-agnostic, and
  tenant-prefixed from the first commit.
- Every query takes a tenant id; tenant ids never bleed into each
  other's results.
- The minimum index shape is one ordered key:
  `(tenant_id, scope, slot, txid) -> role`.
- Upstream supplies a `BlockTx` payload and a
  `decodeTx :: BlockTx -> Maybe [TxSummaryEntry]` plug point.
- Rollback removes entries above the rollback target.
- Restart resumes without duplicating already-indexed entries.
- The history index is driven by the same chain-sync session as the
  embedded UTxO indexer. `csBlockTracer` is not an acceptable storage
  hook because it has no rollback contract.
- Downstream `Amaru.Treasury.Indexer.Decoder` maps treasury transactions
  into `(scope, role)` for:
  `disburse`, `reorganize`, `withdraw`, `swap`,
  `contingency-disburse`, and the mint-registry transaction.
- Downstream CLI adds `history --scope X` and reads the index.
- Devnet smoke waits for more than the stability-window blocks before
  starting the indexer, submits disburse and reorganize after the indexer
  is live, lets the network advance enough for both phases to be
  detected, and proves history returns both rows.

## Non-Goals

- Transaction detail beyond `(slot, txid, role)`.
- Inbound funding history.
- HTTP history endpoints.
- Role, asset, or slot-range filters.
- A second chain-sync follower.
- Node-to-client UTxO queries for history.

## Critical Shape Constraint

The current upstream handler seam is not enough by itself:

```haskell
csHandlers :: NonEmpty (IndexerHandler Cols [UtxoOp])
```

History decoding needs a full transaction payload, not only
`[UtxoOp]`, and it needs tenant-prefixed history columns, not the UTxO
`Cols`. The upstream implementation must therefore add a real shared
follower shape for history rather than appending a fake handler that
cannot see redeemers.
