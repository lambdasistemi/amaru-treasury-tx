# Issue #456 Specification: Remove Stopgap Provider Tracing

## User Story

As an operator investigating production build/provider behavior, I want
all provider-bound observability to come from the generic
`Amaru.Treasury.Trace.Provider` instrumentation so that logs are
consistent, typed, and not duplicated by emergency `stderr` markers.

## Scope

Remove the emergency stopgap tracing introduced before epic #451's
generic provider instrumentation existed:

- `dbg` and `dbgEvaluateTx` in
  `lib/Amaru/Treasury/ChainContext.hs`
- `dbg` in `lib/Amaru/Treasury/Registry/Verify.hs`
- All call sites of those helpers in the same files

Do not change the #450 request timeout in
`lib/Amaru/Treasury/Api/RateLimit.hs`; it remains the safety net for
the unresolved #449 hang.

## Pre-Removal Live Evidence

Production host: `ssh production`, container `amaru-treasury`.

Command:

```bash
docker run --rm --network web \
  -v /tmp/disburse-repro.json:/repro.json:ro \
  curlimages/curl -sS -o /dev/null \
  -X POST http://amaru-treasury:8080/v1/build/disburse \
  -H "Content-Type: application/json" \
  --data @/repro.json \
  -w "HTTP_STATUS:%{http_code} TIME:%{time_total}s\n"
```

Result on 2026-07-08:

```text
HTTP_STATUS:200 TIME:0.249577s
```

Relevant log excerpt:

```text
2026-07-08T16:02:48.135501986Z amaru-treasury: registry-verify: fetchScopes: acquiring provider handle
2026-07-08T16:02:48.135515360Z [Info] provider.withAcquired start
2026-07-08T16:02:48.135785188Z amaru-treasury: registry-verify: fetchScopes: handle acquired; querying scope-owner utxos
2026-07-08T16:02:48.135792737Z [Info] provider.handle.queryUTxOByTxInH start
2026-07-08T16:02:48.136364997Z [Info] provider.handle.queryUTxOByTxInH ok after 1 ms
2026-07-08T16:02:48.136396973Z [Info] provider.withAcquired ok after 1 ms
2026-07-08T16:02:48.139900425Z amaru-treasury: chain-context: liveContext: querying protocol params
2026-07-08T16:02:48.139908649Z [Info] provider.queryProtocolParams start
2026-07-08T16:02:48.215652403Z [Info] provider.queryProtocolParams ok after 76 ms
2026-07-08T16:02:48.215682747Z amaru-treasury: chain-context: liveContext: querying utxos
2026-07-08T16:02:48.215686297Z [Info] provider.queryUTxOByTxIn start
2026-07-08T16:02:48.216127494Z [Info] provider.queryUTxOByTxIn ok after 0 ms
2026-07-08T16:02:48.216146393Z amaru-treasury: chain-context: liveContext: querying ledger snapshot
2026-07-08T16:02:48.216149832Z [Info] provider.queryLedgerSnapshot start
2026-07-08T16:02:48.216671805Z [Info] provider.queryLedgerSnapshot ok after 1 ms
2026-07-08T16:02:48.216864802Z amaru-treasury: chain-context: evaluateTx: calling provider
2026-07-08T16:02:48.216870681Z [Info] provider.evaluateTx start
2026-07-08T16:02:48.300236947Z [Info] provider.evaluateTx ok after 83 ms
```

This confirms the generic trace layer covers the same provider and
query-handle calls as the stopgap markers before removal.

## Functional Requirements

- FR-001: The stopgap `dbg` helpers and every call site are removed
  from the owned modules.
- FR-002: The production provider calls remain wrapped by generic
  `[Info] provider.* start/ok` traces.
- FR-003: The #450 timeout behavior is untouched.
- FR-004: The local gate runs a scoped compile plus the same full-tree
  `fourmolu -m check` and `hlint` surfaces used by CI.

## Success Criteria

- A post-removal build-only production request emits no
  `amaru-treasury: chain-context:` or
  `amaru-treasury: registry-verify:` stopgap lines.
- The same post-removal request still emits generic provider traces
  for registry acquisition/query, `liveContext` queries, and
  `evaluateTx`.
- `./gate.sh` passes locally.
- GitHub Actions for PR #464 are green before completion is reported.
