# Feature Specification: Constitution Principle IX (PureScript frontend, JS as thin FFI shim)

**Feature Branch**: `284-purs-frontend-principle`
**Issue**: [#284](https://github.com/lambdasistemi/amaru-treasury-tx/issues/284)
**Created**: 2026-05-25
**Status**: Draft

## Goal

Add Principle IX to `.specify/memory/constitution.md` so future contributions can't grow a JavaScript escape hatch in `frontend/`, and fix the one existing drift in `frontend/src/App.js` (a cosmetic `.replace` chain that belongs in PureScript).

## User scenarios

### User Story 1 — Operator reviewing a future frontend PR (P1)

When a future PR adds a `.js` file in `frontend/src/`, the reviewer can point at Principle IX and the rule is in the project constitution rather than informal convention — the rule survives turnover and applies uniformly to every contributor.

**Independent test**: `cat .specify/memory/constitution.md | grep -A5 "IX. PureScript frontend"` returns the principle text; the version footer reports `0.6.0`.

### User Story 2 — Future contributor running `/speckit.plan` (P1)

`/speckit.plan` gates every implementation against the constitution.  A plan that adds a multi-line `.js` helper with branching / formatting / parsing trips Principle IX and the plan loops back through `speckit-plan`.

**Independent test**: not directly verifiable here; this is the long-term value the principle delivers.  The constitution amendment alone makes it possible.

### User Story 3 — `nowIso` returns a raw ISO string, PureScript formats it (P1)

The `.replace`-chain ISO formatting in `frontend/src/App.js` is moved to `frontend/src/App.purs`.  The FFI returns the unmodified `Date.toISOString()` output; PureScript drops the milliseconds suffix and replaces `T` with a space.  No visible operator-facing change — the status chip still reads e.g. `2026-05-25 07:39:12 Z`.

**Independent test**: hit the deployed dashboard and confirm the status chip looks identical to before; inspect `App.js` and confirm the function body is one expression (`new Date().toISOString()`); inspect `App.purs` and confirm the formatting code lives in a PureScript helper.

## Functional Requirements

- **FR-001**: `.specify/memory/constitution.md` contains a new section "### IX. PureScript frontend, JavaScript only as a thin FFI shim (NON-NEGOTIABLE)" placed between Principle VIII and the "## Technology Constraints" section.
- **FR-002**: The principle's prose carries the wording from issue [#284](https://github.com/lambdasistemi/amaru-treasury-tx/issues/284), including the **atomic browser idiom** clause (a multi-step sequence like `Blob` + `URL.createObjectURL` + `<a>` + `click()` is the irreducible idiom for a download and IS allowed inside a single shim function).
- **FR-003**: The constitution version footer is bumped from `0.5.1 | Last Amended 2026-05-22` to `0.6.0 | Last Amended 2026-05-25`.
- **FR-004**: `frontend/src/App.js`'s `nowIso` function body is `new Date().toISOString()` (no `.replace`, no other formatting).
- **FR-005**: `frontend/src/App.purs` has a new helper that takes the raw ISO string and produces the chip's display format (`HH:MM:SS Z` with the `T` replaced by a space and milliseconds dropped).  The render site (`App.purs:411`) calls the new helper, not the FFI directly — OR the FFI's `nowIso :: Effect String` returns the raw value and a `formatNowIso :: String -> String` pure helper post-processes it.  Either composition is fine.
- **FR-006**: The dev-deployed `/view` page's status chip still displays the same text format as before (`YYYY-MM-DD HH:MM:SS Z`, no millis, no `T`).  Verified by playwright smoke.

## Success Criteria

- **SC-001**: Constitution version footer reads `0.6.0` at HEAD.
- **SC-002**: `App.js` is ≤ 6 lines after the change (was 10; the body shrinks from 1 expression with two `.replace` calls to 1 plain expression).
- **SC-003**: `/view` status chip on the deployed dashboard shows identical text to the pre-change deploy (no operator-visible regression).
- **SC-004**: Build Gate green at HEAD.

## Out of scope

- Auditing other `.js` files in `frontend/src/` — the audit on the issue body shows they all comply.
- Adding a grep-based lint to enforce Principle IX automatically — left as a possible future ticket.
- Migrating any other PureScript code (no behavior change beyond the `App.js` / `App.purs` shuffle).
