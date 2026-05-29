# Tasks: Tx History Indexer

## Slice 0 — Bootstrap

- [ ] T243-S0 Add `gate.sh` in both worktrees.
- [ ] T243-S0 Open paired draft PRs or record the upstream PR URL once
  created.

## Slice 1 — Upstream Storage Foundation

- [ ] T243-S1 Add `tx-history-indexer-lib` cabal stanza.
- [ ] T243-S1 Add history types and tenant-prefixed key codecs.
- [ ] T243-S1 Add in-memory and RocksDB open/query APIs.
- [ ] T243-S1 RED/GREEN tests prove tenant isolation and ordered
  `(tenant, scope, slot, txid)` query results.
- [ ] T243-S1 Commit:
  `feat(tx-history): add tenant-prefixed history storage`.

## Slice 2 — Upstream Shared Follower

- [ ] T243-S2 Add `BlockTx` extraction for Conway transactions.
- [ ] T243-S2 Drive history from the same chain-sync session as the UTxO
  indexer; no second chain-sync runner.
- [ ] T243-S2 Prove rollback above slot N drops entries.
- [ ] T243-S2 Prove restart/resume does not duplicate or miss history
  entries.
- [ ] T243-S2 Document the selected cursor-sharing model.
- [ ] T243-S2 Commit:
  `feat(tx-history): share chain-sync with history indexing`.

## Slice 3 — Downstream Treasury Decoder

- [X] T243-S3 Pin ATX to the upstream history branch.
- [X] T243-S3 Add `Amaru.Treasury.Indexer.Decoder`.
- [X] T243-S3 RED/GREEN unit coverage for `disburse`, `reorganize`,
  `withdraw`, `swap`, `contingency-disburse`, and mint-registry
  classification.
- [X] T243-S3 Commit:
  `feat(history): decode treasury transaction roles`.

## Slice 4 — Downstream CLI

- [ ] T243-S4 Add `history --scope X` parser and runner.
- [ ] T243-S4 Read from the local history index through the Haskell
  indexer API.
- [ ] T243-S4 Unit tests prove output rows are stable and scope-filtered.
- [ ] T243-S4 Commit:
  `feat(history): add scope history command`.

## Slice 5 — Downstream Devnet Proof

- [ ] T243-S5 Extend the indexed devnet smoke to wait more than the
  stability window before `withApiIndexer`.
- [ ] T243-S5 Submit disburse and reorganize after indexer start.
- [ ] T243-S5 Let the network advance enough for both phases to be
  detected.
- [ ] T243-S5 Assert `history --scope core_development` returns both
  roles with txids and slots.
- [ ] T243-S5 Commit:
  `test(history): prove indexed treasury history on devnet`.

## Slice 6 — Repin And Finalize

- [ ] T243-S6 Merge upstream PR after downstream proof.
- [ ] T243-S6 Repin ATX to upstream main.
- [ ] T243-S6 Run both `./gate.sh` commands at HEAD.
- [ ] T243-S6 Drop `gate.sh` before marking PRs ready.
