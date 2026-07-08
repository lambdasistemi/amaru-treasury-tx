# Issue #460: Avoid Double Provider Tracing Through `indexerProvider`

## User Story

As an operator debugging API build requests, I need each logical
`Provider IO` or acquired `QueryHandle IO` call to emit at most one
trace start/finish pair, so provider boundary logs identify the real
call sequence without duplicate noise.

## Problem

The live API server receives a `Provider IO` from
`withLocalNodeBackend`, which already applies `tracedProvider`. The API
then passes that provider through `indexerProvider`, which replaces
UTxO-related closures and wraps the whole result in `tracedProvider`
again.

For fields that `indexerProvider` does not override, the call passes
through both wrappers and logs twice. For fields it does override, the
outer wrapper is the only trace coverage. Removing either wrapper
globally would regress one side of that split.

## Requirements

- FR-001: API `indexerProvider` must not wrap already-traced
  pass-through provider methods a second time.
- FR-002: API indexer-backed direct UTxO methods must remain traced.
- FR-003: API indexer-backed acquired-handle UTxO methods must remain
  traced.
- FR-004: CLI and devnet consumers that use `withLocalNodeBackend` or
  `withLocalNodeClient` directly must remain traced.
- FR-005: Regression coverage must document the construction shape so a
  future whole-provider outer wrap does not silently return.

## Success Criteria

- `Provider IO` pass-through calls such as `queryLedgerSnapshot` and
  `evaluateTx` have one trace layer in the API path.
- `queryUTxOs`, `queryUTxOByTxIn`, and acquired-handle UTxO queries
  have one trace layer in the API path.
- Direct N2C construction still uses `tracedProvider`.
- Full-tree `fourmolu -m check` and `hlint` are clean.
- Existing unit/golden/smoke/schema/release checks pass, excluding the
  known pre-existing `cabal build all` dependency-pin path from the
  local gate.
