# Tasks: Constitution Principle IX

**Feature**: 284-purs-frontend-principle
**Spec**: [`spec.md`](spec.md) — **Plan**: [`plan.md`](plan.md)

One bisect-safe slice.  Commit body trailer: `Tasks: T284-S1`.

## Slice A — Principle IX + App formatting move

- [ ] T284-S1 Append the Principle IX block from issue #284 to `.specify/memory/constitution.md`, placed between Principle VIII and the "## Technology Constraints" section.  Include the **atomic browser idiom** clause verbatim from the issue body (multi-step `Blob` + `URL.createObjectURL` + `<a>` + `click()` sequences ARE allowed inside a single shim function).

- [ ] T284-S1 Bump the constitution version footer from `0.5.1 | Last Amended 2026-05-22` to `0.6.0 | Last Amended 2026-05-25`.

- [ ] T284-S1 Reduce `frontend/src/App.js`'s `nowIso` body to `new Date().toISOString()`.  Keep the existing top-of-file FFI comment but trim it to reflect the new (smaller) responsibility.

- [ ] T284-S1 Move the chip-display formatting (`replace /\.\d+Z$/ "Z"` then `replace "T" " "`) into `frontend/src/App.purs` as a small pure helper.  The render site at line ~411 consumes the FFI's raw string + applies the helper — or pipes them via `<$>` — either composition is acceptable.

- [ ] T284-S1 Smoke proof in `WIP.md`: deploy the bundle, open `https://amaru-treasury.dev.plutimus.com/view`, inspect the status chip text — must match the pre-change format exactly (e.g. `2026-05-25 07:39:12 Z` without milliseconds and without a literal `T`).

- [ ] T284-S1 Commit: `feat(284): constitution Principle IX + App.js nowIso shrinks to one expression` with `Tasks: T284-S1` trailer.

## Dependencies

- None — this is a single slice that bundles spec + plan + tasks + the constitution amendment + the code shuffle into one PR.
