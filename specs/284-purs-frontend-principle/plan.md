# Implementation Plan: Constitution Principle IX

**Feature**: 284-purs-frontend-principle
**Spec**: [`spec.md`](spec.md)

## Tech stack

- Markdown (constitution).
- PureScript + Halogen (frontend `App.purs`) — `Data.String` for the format helper.
- JavaScript FFI (`App.js`) — strictly reduced.

## Affected files

- `.specify/memory/constitution.md` — add Principle IX between VIII and Technology Constraints; bump version footer to `0.6.0`.
- `frontend/src/App.js` — replace the `.replace`-chain `nowIso` body with `new Date().toISOString()`.
- `frontend/src/App.purs` — add a small `formatNowIso :: String -> String` helper (or inline at the call site if cleaner) that drops the millisecond suffix and replaces `T` with a space.  The render at line 411 produces the same display string as before.

## Slicing

**One slice.** The constitution amendment and the App.js / App.purs shuffle are mutually dependent (Principle IX requires App.js to comply at the same SHA), and the surface is ~15 lines total.

## Out-of-scope (mirrors spec)

- Other `.js` files (already compliant per the issue's audit table).
- Lint enforcement of Principle IX.
- Any behavioural change visible to the operator.
