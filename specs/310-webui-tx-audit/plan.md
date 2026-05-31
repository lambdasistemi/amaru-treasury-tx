# Implementation Plan: webUI tx audit history

## Technical Context

- PureScript + Halogen frontend under `frontend/`.
- Existing API wrapper style is `Api.getJson` with `Affjax.Web` and
  Argonaut decoders.
- History response shape is read from
  `lib/Amaru/Treasury/Api/Types.hs`:
  `{ scope :: String, entries :: Array { slot, txid, role, direction } }`.
- Backend-owned files are read-only for this ticket.

## Slices

### Slice 1: Ticket artifacts

Create the small spec/plan/tasks contract for #310.

### Slice 2: Audit view

Add an `/audit` route and topbar link. Implement a Halogen audit page
with scope picker, query-param controls, request lifecycle states,
history table, and tx detail stub. Extend the frontend API wrapper with
the typed history fetcher.

### Slice 3: Smoke coverage

Extend the Playwright route matrix to include `/audit` and assert that
the audit shell renders without horizontal overflow. The existing Nix
frontend-bundle check remains the required gate.

## Verification

- `nix build .#checks.x86_64-linux.frontend-bundle`
- Playwright smoke if the local/test environment has the Node tooling
  available; otherwise the route matrix update is still covered by the
  built bundle.

## Coordination Notes

The tx detail drill-down remains stubbed. If worker t248 publishes a
`NOTE RELEASE: /tx/{txid}` line before completion, integrate the released
shape; otherwise log a protocol NOTE and ship the stub.
