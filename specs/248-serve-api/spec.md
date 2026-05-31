# Feature Specification: Indexer-Backed Serve API

## User Story

As an untrusted HTTP client of the containerized treasury service, I
can read treasury state, transaction details, registry/script metadata,
health, tip/params, and submit signed transactions through stable JSON
endpoints without requiring the service to sign anything.

## Functional Requirements

- `GET /v1/tx/{txid}` MUST read the tx-history indexer by transaction id
  and return the same decoded facts exposed by the `tx-detail` CLI path.
- `GET /v1/scope/{id}/state`, `GET /v1/scope/{id}/utxos`, and
  `GET /v1/pending` MUST read from the embedded indexer, not from node
  UTxO queries.
- `GET /v1/registry` and `GET /v1/scripts` MUST expose deployment
  metadata needed by web clients to interpret treasury state.
- `GET /v1/tip`, `GET /v1/params`, and `POST /v1/submit` MAY touch the
  local node; other read endpoints must not.
- `GET /v1/health` MUST expose readiness/lag information consistent
  with the existing readiness bridge and lag guard.
- Existing shipped endpoints MUST keep their current `/v1` paths and
  JSON shapes.

## Success Criteria

- Unit tests cover route wiring and tx-detail JSON encoding.
- New indexer-backed read handlers can be exercised without a live node.
- The existing lag guard still wraps the full WAI application.
- Devnet smoke wiring documents the full build/sign/submit/detail path;
  live execution may be operator-gated.
