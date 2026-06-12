# Issue #367 Tasks

## Slice 1 — Bootstrap

- [X] T367-S1 Create issue worktree, branch, gate, and draft PR
  scaffolding.

## Slice 2 — Store API

- [X] T367-S2 Add the `Store.PendingTx` PureScript API and IndexedDB
  FFI implementation.
- [X] T367-S2 Keep store values opaque: JSON metadata and hex strings
  only, with no decode or cryptography.

## Slice 3 — Tests And Browser Proof

- [X] T367-S3 Add PureScript tests for CRUD, witness add/remove, and
  supersede linking.
- [X] T367-S3 Add a headless browser persistence-across-reload check.
- [X] T367-S3 Run and record the frontend gate.
