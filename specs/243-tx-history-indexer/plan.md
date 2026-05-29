# Implementation Plan: Tx History Indexer

## Repositories

- Upstream: `/code/cardano-node-clients-issue-243-history`
  (`feat/243-tx-history-indexer`)
- Downstream: `/code/amaru-treasury-tx-issue-243`
  (`feat/243-tx-history`)

## Upstream Shape

Create `cardano-node-clients:tx-history-indexer-lib` with:

- `Cardano.Node.Client.TxHistoryIndexer.Types`
  - `TenantId`, `HistoryScope`, `TxRole`, `TxSummaryEntry`,
    `TxSummaryKey`, `BlockTx`
- `Cardano.Node.Client.TxHistoryIndexer.Columns`
  - tenant-prefixed ordered history key codecs
  - rollback/resume storage for history entries
- `Cardano.Node.Client.TxHistoryIndexer.Indexer`
  - in-memory + RocksDB handles
  - `appendBlockHistory`, `rollbackTo`, `queryHistory`
  - pluggable decoder:
    `type DecodeTx = BlockTx -> Maybe [TxSummaryEntry]`
- `Cardano.Node.Client.TxHistoryIndexer.BlockExtract`
  - Conway transaction extraction into `BlockTx`; non-Conway
    transactions may be ignored for this v0.
- A shared-follower integration that drives history from the same
  chain-sync session as UTxO indexing.

The worker may choose one of two safe cursor models, but must document
the result in Haddock and tests:

- **Shared cursor**: one rollback/cursor log stores the combined inverse.
- **Same follower, separate cursors**: one chain-sync session rolls both
  indexers, and resume starts from the oldest safe retained point across
  attached stores so history cannot miss blocks after restart.

If neither model can be made safe without broadening the public API
outside this issue, the worker must stop with a Q-file instead of using a
second chain-sync runner.

## Downstream Shape

Add:

- `Amaru.Treasury.Indexer.Decoder`
  - treasury redeemer detection
  - scope + role classification
- `Amaru.Treasury.Cli.History`
  - parser: `history --scope SCOPE [--indexer-db PATH]`
  - output: stable text rows `slot txid role`
- API indexer wiring that opens the history store beside the UTxO store
  and feeds both from the same chain-sync session.
- Devnet smoke extension that submits disburse and reorganize after
  indexer start, then asserts both history rows.

## Slices

1. **Upstream storage foundation**: tx-history types, column codecs,
   query API, tenant-isolation test.
2. **Upstream shared follower**: `BlockTx` extraction and same
   chain-sync integration with rollback + restart tests.
3. **Downstream decoder**: treasury role decoding unit tests for the six
   required transaction kinds.
4. **Downstream CLI**: `history --scope X` parser/runner and output
   tests over an in-memory/history fixture.
5. **Downstream devnet proof**: extend the indexed devnet smoke to prove
   disburse and reorganize history rows after stability-window handling.
6. **Repin and finalization**: pin ATX to the upstream PR branch until
   merged, then repin to upstream main and run both full gates.

## Gates

Upstream gate:

```bash
./gate.sh
```

Downstream gate:

```bash
./gate.sh
```

Focused devnet proof before merge:

```bash
nix develop --quiet -c just devnet-api-smoke
```

The final claim must include the devnet history rows observed after both
transactions are submitted.
