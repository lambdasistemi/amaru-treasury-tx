# Implementation Plan: Constitution Principle IX

**Feature**: 284-purs-frontend-principle
**Spec**: [`spec.md`](spec.md)

## Tech stack

- Markdown (constitution).
- PureScript + Halogen (frontend `App.purs`) — current `main` already uses `Effect.Now` / `Instant` for the refresh status row.
- JavaScript FFI — remove the stale, now-unpaired `App.js` shim.

## Affected files

- `.specify/memory/constitution.md` — add Principle IX between VIII and Technology Constraints; bump version footer to `0.6.0`.
- `frontend/src/App.js` — delete the stale `nowIso` shim because `App.purs` no longer imports it on current `main`.
- `frontend/src/App.purs` — no code change after the rebase; preserve the current PureScript `Effect.Now` / `Instant` refresh status row.

## Slicing

**One slice.** The constitution amendment and the stale `App.js` deletion are mutually dependent (Principle IX requires the frontend JS surface to comply at the same SHA), and the surface is small.

## Out-of-scope (mirrors spec)

- Other `.js` files (already compliant per the issue's audit table).
- Lint enforcement of Principle IX.
- Any behavioural change visible to the operator.
