# Implementation Plan: #299 — Playwright-driven UI review

**Feature**: 299-ui-review
**Spec**: [`spec.md`](spec.md)
**Parent**: #289

## Tech stack

- PureScript + Halogen (existing).
- CSS via `frontend/dist/styles.css` + `frontend/dist/style-build.css`
  (hand-rolled tokens layered on MWC defaults).
- Playwright via `frontend/test/playwright/` (existing harness from #289)
  + ad-hoc MCP captures into `frontend/test/ui-review/299/`.
- No backend / API changes.

## Affected modules

- `frontend/src/App.purs` — copy-button glyphs → `<md-icon>` (US-2, FR-1).
- `frontend/src/Shell.purs` — topbar theme toggle a11y (US-1, FR-2).
- `frontend/dist/styles.css` — `.visually-hidden`, `.topbar__theme-btn`,
  `.copy-row` grid (FR-3, FR-4, FR-5).
- `frontend/dist/style-build.css` — mobile topbar nav reorder, `md-icon`
  sizing inside `.v-copy--block` (FR-6).
- `frontend/test/ui-review/299/{before,after,findings}/` — review
  artifacts (US-5, FR-7).

## Slicing

Two bisect-safe vertical slices. Each is one commit with the
`Tasks: T299-S<n>` trailer. The seed-diff in the worktree at branch
creation (`stash@{0}: seed-diff for #299 UI review`) covers both, but
is split here so that bisection isolates "icon migration" from "layout
adjustment".

### Slice A — Material `<md-icon>` system + theme-toggle a11y

- `App.purs:389` — copy button label `⎘ Copy inspect JSON` → `<md-icon>content_copy</md-icon>` + `<span>Copy inspect JSON</span>`.
- `App.purs:735` (`copyRow`) — `if cfg.copied then "✓" else "⎘"` → `if cfg.copied then "check" else "content_copy"`, rendered inside `<md-icon>`.
- `Shell.purs:109-114` — topbar theme button: drop literal `themeLabel`
  text; add `<md-icon>` with `dark_mode` (light theme active) / `light_mode`
  (dark theme active); add `title="Switch to <opposite> theme"`; add
  `<span class="visually-hidden">{themeLabel}</span>` child.
- `frontend/dist/styles.css` — add `.visually-hidden` utility class,
  `.topbar__theme-btn` 44×44 grid styling + hover/outline tokens,
  `.v-copy--block md-icon { font-size: 18px; }`.

**Proof**: `nix build .#frontend` green; Playwright after-capture at
desktop / 390 / 320 of `/`, `/operate`, `/books` showing the icon
swaps. RED skipped — frontend has no test harness for atom-level
component shape; proof is the build + visual capture per `live-boundary-smoke`.

**Commit**: `feat(299): md-icon migration + a11y theme toggle` with
`Tasks: T299-S1` trailer.

### Slice B — Mobile topbar nav reorder + `.copy-row` grid

- `frontend/dist/styles.css` — `.copy-row` switches from
  `display: flex; flex-wrap: wrap` to
  `display: grid; grid-template-columns: minmax(8rem, auto) minmax(0, 1fr) auto`.
- `frontend/dist/style-build.css` — add `@media (max-width: 600px)`
  block: `.topbar__nav { margin-left: 0; order: 3; flex: 1 1 100%; }`
  and `.topbar__theme-btn { margin-left: auto; }`.
- Final Playwright after-capture committed under
  `frontend/test/ui-review/299/after/` + `findings/after.md` summarising
  before/after deltas.

**Proof**: `nix build .#frontend` green; Playwright responsive smoke
from #289 still passes; after-screenshots show no horizontal overflow
at 320 / 390 / 1280 on every page; `.copy-row` lays out as a grid.

**Commit**: `feat(299): mobile topbar reorder + copy-row grid + ui-review record`
with `Tasks: T299-S2` trailer.

## Constitution alignment

- Principle IX (PureScript-only frontend, JS as thin FFI shim): all logic
  stays in `.purs`. The `<md-icon>` element is a Material Web Component
  custom element already loaded by the page; no new JS shim required.
- Principle V (golden CBOR fixtures): unaffected (frontend-only).
- `#289`'s "responsive smoke" precedent: each slice extends — does not
  break — the 320/390/1024/1280 invariant.

## Slicing pragmatics

- Slice A is larger (touches three modules + CSS) but cohesive —
  everything Material icon migration.
- Slice B is small but its mobile-topbar change has the visible
  consequence that justifies the layout-only proof in its own commit
  (so a future bisect can pinpoint regressions there).
- Both slices preserve all existing Halogen state and event semantics
  — only render layer changes.

## Out-of-scope (mirrors spec)

- Backend / API / CLI / wizard / chain query semantics.
- BooksPage.purs (already on `md-icon-button`).
- Scope-card error rendering improvements (filed as follow-up).
- Books page disclosure-arrow chevron icon (filed as follow-up).
- `build identity loading…` footer spinner (filed as follow-up).

## Notes on Playwright captures

- Pre-review captures are already in `frontend/test/ui-review/299/before/`
  (committed in the orchestrator setup commit).
- Per-slice after-captures use the MCP `playwright__browser_*` tools
  during slice review (orchestrator runs them; not part of the driver
  brief).
- The Playwright responsive smoke harness
  (`frontend/test/playwright/responsive.spec.ts`) is the automated
  guardrail — it must keep passing.
