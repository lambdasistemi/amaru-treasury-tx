# Feature Specification: webUI tx audit history

**Feature Branch**: `feat/310-webui-tx-audit`
**Created**: 2026-05-31
**Issue**: lambdasistemi/amaru-treasury-tx#310

## P1 User Story

As a treasury auditor, I open the web UI, pick a scope, and see the
scope's transaction history with slot, txid, role, and direction. I can
apply the filters supported by the indexer API so audit work does not
require the CLI.

## Acceptance Criteria

- The web UI has a tx-audit view that calls
  `GET /v1/scope/{scope}/txs`.
- The view maps scope, role, asset, direction, since, until, and limit
  controls to the API query parameters.
- Results show slot, txid, role, and direction.
- Empty, error, and lagging/indexer-503 states have distinct, readable
  UI states.
- Per-tx drill-down is represented as a stub until #248 releases
  `GET /tx/{txid}`.
- `nix build .#checks.x86_64-linux.frontend-bundle` stays green.

## Non-Goals

- No backend endpoint changes.
- No write actions.
- No final tx-detail rendering until the #248 endpoint shape is
  released.

## Scope

Owned files are limited to frontend PureScript/Halogen sources, the
frontend stylesheet, frontend smoke tests, and this ticket's planning
artifacts.
