# Implementation Plan: Treasury dashboard style + mobile UX overhaul

**Feature**: 289-dashboard-ux
**Spec**: [`spec.md`](spec.md)

## Tech stack

- PureScript + Halogen (existing frontend stack).
- CSS via `frontend/dist/styles.css` + `frontend/dist/style-build.css` (the project's hand-rolled tokens, layered on top of MWC defaults).
- Playwright for responsive verification (existing harness on the dev deploy).
- No backend changes.

## Affected modules

- `frontend/src/Shell.purs` — topbar layout (US-1, US-9).
- `frontend/src/OperatePage.purs` — sticky bar, a11y, progress (US-2, US-3, US-4).
- `frontend/src/App.purs` — dashboard status row + copy actions (US-5, US-6).
- `frontend/src/BooksPage.purs` — empty-state collapse (US-7).
- `frontend/dist/styles.css` + `frontend/dist/style-build.css` — palette + hero scale + responsive breakpoints (US-1, US-8).
- `frontend/test/playwright/responsive.spec.ts` — NEW responsive smoke harness (US-9).  If the project already has a Playwright harness, extend it; else introduce one.

## Slicing

Eight bisect-safe slices, each one operator-meaningful on its own:

1. **Slice A — Mobile topbar + Playwright responsive smoke**: fix overflow at 320 / 390 / 1024 / 1280 px on every page; arm the responsive smoke harness.  Lands the test scaffolding the rest of the slices reuse.  US-1, US-9.

2. **Slice B — `/operate` sticky action bar**: pick the FR-003 pattern; ensure form fields + errors visible at 390 px viewport.  US-2.

3. **Slice C — `/operate` a11y**: labels, ids, aria-invalid, aria-describedby, touch-target sizes.  US-3.

4. **Slice D — `/operate` progress + first-blocker navigation**: top-of-page sectioned progress indicator; click jumps to first invalid input.  US-4.

5. **Slice E — Dashboard status indicators**: chain tip + last-refresh + per-scope load status with fresh/stale/partial visuals.  US-5.

6. **Slice F — Dashboard copy actions**: colocated copy buttons + immediate feedback.  US-6.

7. **Slice G — `/books` empty-state cleanup**: collapse empty categories or hide actions until populated.  US-7.

8. **Slice H — Theme palette + hero scale**: restrained palette, smaller hero, contrast on text/control pairs.  US-8.

Each slice = one commit with `Tasks: T289-S<n>` trailer.  All slices preserve byte-for-byte behaviour on the data layer (Shell.Book, intent.json shape, backend) — only render layer changes.

## Constitution alignment

- Principle IX (PureScript-only frontend, JS as thin FFI shim, NON-NEGOTIABLE per #284 once that lands): all logic in `.purs`; no new `.js` shims unless an atomic browser idiom requires (e.g. ResizeObserver for the responsive progress indicator might warrant a shim).
- Principle V (golden CBOR fixtures): unaffected — frontend-only feature.
- Constitution doesn't yet have a "golden screenshot regression" principle.  Slice A's Playwright harness establishes the precedent; future tickets can codify it.

## Slicing pragmatics

- Slice A is the largest (responsive harness scaffolding).  Subsequent slices reuse it for verification.
- Slices B-D all touch `OperatePage.purs` — implementation order must thread carefully to avoid step-on conflicts (slice C should land before D so the a11y plumbing is the substrate for D's first-blocker navigation).
- Slices E-F touch `App.purs` (dashboard).
- Slice G touches `BooksPage.purs`.
- Slice H touches CSS tokens + per-page hero spacing.  Best last so the visual palette is set against the FINAL layout.

## Out-of-scope (mirrors spec)

- Backend / API / CLI work.
- Cross-device sync.
- Marketing landing page.
