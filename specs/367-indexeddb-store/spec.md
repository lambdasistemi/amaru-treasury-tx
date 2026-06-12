# Issue #367 — IndexedDB pending transaction store

## Goal

Provide a browser-local IndexedDB store for pending unsigned
transactions and their accumulating witnesses, keyed by txid. The
store is the persistence layer for a later Pending page and keeps all
pending transaction state out of the shared API.

## P1 User Story

As an operator, I save an unsigned transaction and its witnesses in my
browser and observe them persist across page reloads, keyed by txid.

## Requirements

- Store entries keyed by `txid`.
- Persist `{ txid, intent, unsignedTxHex, scope, requiredSigners,
  invalidHereafter, witnesses, savedAt, supersedes }`.
- Keep `intent` as opaque JSON so a later UI can rebuild the entry.
- Keep `unsignedTxHex` and witness values as opaque hex strings.
- Support `put`, `get`, `list`, and `delete`.
- Support adding and removing witnesses by key hash.
- Support supersede linking: a rebuilt entry can point at the txid it
  replaced while the replaced entry remains in history.
- Verify browser persistence across page reload with a headless browser
  harness.

## Non-Goals

- No server endpoints.
- No Pending page UI.
- No Operate page handoff.
- No client-side decode, ledger validation, signing, or cryptography.

