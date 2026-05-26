# Tasks: Constitution Principle IX

**Feature**: 284-purs-frontend-principle
**Spec**: [`spec.md`](spec.md) — **Plan**: [`plan.md`](plan.md)

One bisect-safe slice.  Commit body trailer: `Tasks: T284-S1`.

## Slice A — Principle IX + App.js cleanup

- [X] T284-S1 Append the Principle IX block from issue #284 to `.specify/memory/constitution.md`, placed between Principle VIII and the "## Technology Constraints" section.  Include the **atomic browser idiom** clause verbatim from the issue body (multi-step `Blob` + `URL.createObjectURL` + `<a>` + `click()` sequences ARE allowed inside a single shim function).

- [X] T284-S1 Bump the constitution version footer from `0.5.1 | Last Amended 2026-05-22` to `0.6.0 | Last Amended 2026-05-25`.

- [X] T284-S1 Delete the stale `frontend/src/App.js` `nowIso` shim.  On current `main`, `App.purs` no longer has a matching `foreign import`, so keeping a reduced-but-unpaired shim would still violate Principle IX.

- [X] T284-S1 Preserve the current `frontend/src/App.purs` refresh status row (`Effect.Now`, `Instant`, `relativeTime`); do not reintroduce `nowIso`, `formatNowIso`, or any JavaScript-backed display formatting.

- [ ] T284-S1 Smoke proof in `WIP.md`: deploy the bundle, open `https://amaru-treasury.dev.plutimus.com/view`, and inspect that the `/view` status row still renders without a JavaScript-backed `nowIso` path.

- [X] T284-S1 Commit: `feat(284): constitution Principle IX + App.js cleanup` with `Tasks: T284-S1` trailer.

## Dependencies

- None — this is a single slice that bundles spec + plan + tasks + the constitution amendment + the code shuffle into one PR.
