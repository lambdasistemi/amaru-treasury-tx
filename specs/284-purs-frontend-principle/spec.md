# Feature Specification: Constitution Principle IX (PureScript frontend, JS as thin FFI shim)

**Feature Branch**: `284-purs-frontend-principle`
**Issue**: [#284](https://github.com/lambdasistemi/amaru-treasury-tx/issues/284)
**Created**: 2026-05-25
**Status**: Draft

## Goal

Add Principle IX to `.specify/memory/constitution.md` so future contributions can't grow a JavaScript escape hatch in `frontend/`, and remove the existing drift from `frontend/src/App.js`.  After rebasing onto current `main`, the `/view` status row already uses PureScript `Effect.Now` / `Instant` logic, so the old `nowIso` shim has no remaining PureScript consumer and should be deleted rather than kept as an unpaired `.js` file.

## User scenarios

### User Story 1 — Operator reviewing a future frontend PR (P1)

When a future PR adds a `.js` file in `frontend/src/`, the reviewer can point at Principle IX and the rule is in the project constitution rather than informal convention — the rule survives turnover and applies uniformly to every contributor.

**Independent test**: `cat .specify/memory/constitution.md | grep -A5 "IX. PureScript frontend"` returns the principle text; the version footer reports `0.6.0`.

### User Story 2 — Future contributor running `/speckit.plan` (P1)

`/speckit.plan` gates every implementation against the constitution.  A plan that adds a multi-line `.js` helper with branching / formatting / parsing trips Principle IX and the plan loops back through `speckit-plan`.

**Independent test**: not directly verifiable here; this is the long-term value the principle delivers.  The constitution amendment alone makes it possible.

### User Story 3 — no stale `App.js` escape hatch remains (P1)

The stale `frontend/src/App.js` FFI is removed.  The current `App.purs` refresh status is already pure PureScript (`Effect.Now`, `Instant`, and `relativeTime`), so no JavaScript formatting shim remains and there is no operator-facing change to the status row.

**Independent test**: hit the deployed dashboard and confirm the status row still renders; inspect `frontend/src/` and confirm there is no `App.js`; inspect `App.purs` and confirm there is no `nowIso` or `formatNowIso` path.

## Functional Requirements

- **FR-001**: `.specify/memory/constitution.md` contains a new section "### IX. PureScript frontend, JavaScript only as a thin FFI shim (NON-NEGOTIABLE)" placed between Principle VIII and the "## Technology Constraints" section.
- **FR-002**: The principle's prose carries the wording from issue [#284](https://github.com/lambdasistemi/amaru-treasury-tx/issues/284), including the **atomic browser idiom** clause (a multi-step sequence like `Blob` + `URL.createObjectURL` + `<a>` + `click()` is the irreducible idiom for a download and IS allowed inside a single shim function).
- **FR-003**: The constitution version footer is bumped from `0.5.1 | Last Amended 2026-05-22` to `0.6.0 | Last Amended 2026-05-25`.
- **FR-004**: `frontend/src/App.js` is removed because `App.purs` no longer has a matching `foreign import` consumer for `nowIso` on current `main`.
- **FR-005**: `frontend/src/App.purs` keeps the current PureScript refresh-time implementation (`Effect.Now`, `Instant`, and `relativeTime`) and does not introduce `nowIso`, `formatNowIso`, or any JavaScript-backed display formatting path.
- **FR-006**: The dev-deployed `/view` page's status row still renders after the deletion.  Verified by browser smoke when the dev service is available.

## Success Criteria

- **SC-001**: Constitution version footer reads `0.6.0` at HEAD.
- **SC-002**: `frontend/src/App.js` is absent at HEAD.
- **SC-003**: `/view` status row on the deployed dashboard renders without an operator-visible regression from current `main`.
- **SC-004**: Build Gate green at HEAD.

## Out of scope

- Auditing other `.js` files in `frontend/src/` — the audit on the issue body shows they all comply.
- Adding a grep-based lint to enforce Principle IX automatically — left as a possible future ticket.
- Migrating any other PureScript code (current `main` already moved the refresh status row to PureScript `Effect.Now` / `Instant`).
