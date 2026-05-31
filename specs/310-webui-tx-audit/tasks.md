# Tasks: webUI tx audit history

## Slice 1 — Ticket artifacts

- [X] T310-S1 Write spec, plan, and task artifacts for the frontend-only
  audit view.
- [X] T310-S1 Commit the artifacts.

## Slice 2 — Audit view

- [ ] T310-S2 Add typed API client support for
  `GET /v1/scope/{scope}/txs` with optional query parameters.
- [ ] T310-S2 Add an `/audit` route and topbar navigation entry.
- [ ] T310-S2 Implement the Halogen audit view with scope, role, asset,
  direction, since, until, and limit controls.
- [ ] T310-S2 Render loading, empty, error, and 503 lagging states.
- [ ] T310-S2 Render slot, txid, role, and direction rows plus a
  per-transaction detail stub.
- [ ] T310-S2 Run the frontend bundle gate and commit the slice.

## Slice 3 — Smoke coverage

- [ ] T310-S3 Include `/audit` in the Playwright responsive route matrix.
- [ ] T310-S3 Run available frontend verification and commit the slice.
