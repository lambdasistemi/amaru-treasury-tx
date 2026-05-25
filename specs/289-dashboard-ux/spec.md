# Feature Specification: Treasury dashboard style + mobile UX overhaul

**Feature Branch**: `289-dashboard-ux`
**Issue**: [#289](https://github.com/lambdasistemi/amaru-treasury-tx/issues/289)
**Created**: 2026-05-25
**Status**: Draft

## Goal

Make the live Amaru Treasury web UI feel like a dense operator tool: responsive at every viewport, accessible, clear about live chain status, and safe on mobile.  No backend changes — frontend-only refresh of layout, semantics, palette, and Playwright responsive coverage.

## P1 user story

As a treasury operator, I inspect balances, prepare a transaction, and manage saved form values in the web UI and observe a compact, responsive, accessible interface whose controls do not overlap, overflow, or obscure transaction-critical information.

## User Stories (operator-facing scenarios)

### US-1 — Mobile topbar fits and stays usable (P1)

Operator opens the dashboard on a 320 px-wide phone.  The topbar (View / Operate / Books links + theme toggle) fits without horizontal page overflow.  At 390 px the same.  At tablet + desktop everything stays where it is.

**Independent test**: Playwright sweeps `/`, `/operate`, `/books` at 320 px, 390 px, 1024 px, and 1280 px.  `document.documentElement.scrollWidth ≤ clientWidth` at every viewport, every page.  Topbar links + theme toggle remain in the viewport and carry `aria-label` / accessible names.

### US-2 — /operate's action bar never obscures form fields on mobile (P1)

Operator scrolls through /operate on a phone, fills inputs, scrolls down to read a validation error.  The Reset / Build action bar (currently sticky to the viewport bottom) no longer covers form fields or error text.  The Build action remains discoverable after validation errors and near the end of the flow.

**Independent test**: at 390 px viewport, after a validation error renders below the wallet field, the field + the error are visible (not covered by the action bar).  The Build button is reachable by scrolling or by the position of the action bar (e.g. inline at flow end, or with a hide-on-scroll-up affordance).

### US-3 — /operate inputs carry proper accessibility semantics (P1)

A screen reader announces every input's purpose; invalid inputs are marked with `aria-invalid`; error text is linked via `aria-describedby`; touch targets meet the 44×44 px minimum (WCAG 2.5.5).

**Independent test**: DOM check on `/operate`: every `<input>` has either `<label for="…">` or `aria-label`; invalid inputs (under a synthesised invalid state) carry `aria-invalid="true"`; the error span's `id` matches the input's `aria-describedby`; computed `width × height` on each interactive element is ≥ 44×44 px.

### US-4 — /operate communicates wizard progress (P1)

Operator scrolls a long /operate form and can see at a glance which sections are complete and which still block a build.  A click on a section indicator jumps to the first blocking input.

**Independent test**: a progress indicator at the top of /operate shows N sections with completed/invalid/pending state.  Clicking an invalid section scrolls the page to (and focuses) the first invalid input in that section.

### US-5 — Dashboard surfaces live chain status (P1)

Operator opens `/` and immediately sees: chain tip slot, when the data last refreshed, and per-scope load status (fresh / stale / partial-load).  Stale / partial states are visually distinct from fresh.

**Independent test**: `/` renders a status row with `chain tip: <slot>`, `refreshed: <relative time>`, and per-scope chips with computed colour classes that map cleanly to `fresh` / `stale` / `partial`.

### US-6 — Dashboard copy actions are colocated and snappy (P1)

Operator clicks Copy next to an address.  The button is right next to the address (not in a separate panel).  Visual feedback (check icon ~1 s) confirms the copy.  Errors (clipboard denied) surface inline.

**Independent test**: every long-string value on `/` has an adjacent copy button; clicking it triggers `navigator.clipboard.writeText` with the value; the icon swaps to `check` for 1 s then reverts.

### US-7 — /books reduces empty-state noise (P1)

Operator visits `/books` on a fresh browser.  Empty categories (no entries yet) group or collapse rather than blasting a full card with disabled actions.  Copy / Export buttons on empty cards are disabled or de-emphasized.

**Independent test**: from a freshly-cleared browser, `/books` does NOT render 10 identical empty-card-with-action-buttons rows.  Empty cards either: (a) collapse under a "X books empty" disclosure, or (b) hide actions until ≥1 entry exists.  At least one of these patterns applies.

### US-8 — Theme palette + hierarchy refinement (P1)

Light and dark themes adopt a restrained operational palette (less hue variance, more contrast in critical text/control pairs).  Hero spacing on landing reduces so balances + operate controls appear earlier on every viewport.

**Independent test**: visual review (no programmatic check beyond screenshot regression).  Hero height ≤ N px on desktop and ≤ M px on mobile (figures TBD in slice H — set based on what fits in one fold).

### US-9 — Playwright responsive coverage in CI / the gate (P1)

`./gate.sh` (or the equivalent dev-side smoke harness) runs Playwright sweeps for `/`, `/operate`, `/books` at desktop, 390 px, and 320 px widths.  Snapshots are captured.  No horizontal overflow at any viewport on any page.

**Independent test**: gate green; snapshot artefacts produced per page × viewport.

## Functional Requirements

- **FR-001**: Topbar uses a CSS pattern (flex with `flex-wrap`, or `<nav>` collapsing to icon + drawer below `~600 px`) that prevents horizontal overflow at every viewport from 320 px up.
- **FR-002**: Topbar links carry explicit `aria-label` (e.g. `aria-label="View transactions"`); theme toggle carries `aria-label="Toggle theme"` and the dropdown widget on `/operate` keeps its existing `aria-current="page"` semantics.
- **FR-003**: `/operate` sticky action bar uses a pattern that doesn't cover form content — either:
  - non-sticky, inline at the end of the flow + a "jump to Build" affordance from the progress indicator; OR
  - sticky with `padding-bottom` on the form area equal to the bar's height + a hide-on-scroll-up affordance.
  Decision in slice B; either pattern satisfies US-2.
- **FR-004**: Every `<input>` / `<select>` / `<textarea>` on `/operate` carries either `<label for="<id>">` or `aria-label`.  Invalid state sets `aria-invalid="true"` and adds `aria-describedby="<error-id>"` pointing at the error span.
- **FR-005**: Touch targets — every clickable element on `/operate` measures ≥ 44×44 px in the DOM.  Inline icon-buttons may be smaller VISUALLY if their accessible hit-area is padded to ≥ 44×44 (e.g. via padding or an absolute overlay).
- **FR-006**: `/operate` renders a sectioned progress indicator at the top of the page.  Sections derived from the existing form structure (e.g. Identity, Amount, Rationale, References, Signers).  Each section reports state `complete` / `invalid` / `pending`.  Clicking an invalid section scrolls to + focuses the first invalid input.
- **FR-007**: `/` renders a status row above the per-scope cards:
  - `chain tip: <slot>` (link to a cardanoscan slot if practical, else plain text).
  - `refreshed: <relative time>` (e.g. `12 s ago`, `5 min ago`).
  - per-scope load status chips with `fresh` / `stale` / `partial` visual states.
- **FR-008**: Copy buttons on `/` use the existing `Shell.Clipboard` FFI (added in #267).  Each copy button is immediately adjacent (DOM-sibling) to the value it copies.  Success feedback: icon swap to `check` for 1 s.  Failure feedback: inline error text below the button.
- **FR-009**: `/books` empty-state pattern: by default, an empty card collapses under a top-of-group disclosure "N books empty · expand"; clicking expands.  Alternatively (driver's call in slice G) hide the Copy / Export buttons until ≥1 entry exists.
- **FR-010**: Theme tokens (`--md-sys-color-*` and the project's CSS custom properties in `dist/styles.css` / `dist/style-build.css`) are tightened — narrower hue range, higher contrast on text/control pairs.  Hero spacing on `/` reduces (figure set in slice H).
- **FR-011**: A new `frontend/test/playwright/responsive.spec.ts` (or analogous) sweeps `/`, `/operate`, `/books` at 320 / 390 / 1024 / 1280 px.  Asserts no horizontal overflow; captures screenshots.  Integrated into the dev-side smoke loop (live deploy + Playwright run).

## Success Criteria

- **SC-001**: At every viewport (320 / 390 / 1024 / 1280) on every page (`/`, `/operate`, `/books`), `scrollWidth ≤ clientWidth`.  Playwright proves it.
- **SC-002**: Lighthouse accessibility score on `/operate` ≥ 95 (was lower; target validated by Lighthouse run).
- **SC-003**: Every interactive element's accessible hit-area is ≥ 44×44 px.
- **SC-004**: `/` displays chain-tip + last-refresh + per-scope status within 100 ms of first render.
- **SC-005**: Build Gate green at HEAD.

## Out of scope

- Backend / API / CLI changes.
- Cross-device sync of any kind.
- Treasury math / metadata / scope definitions.
- A marketing landing page.
- Lighthouse accessibility on other pages (only `/operate` is targeted by SC-002 — the form is the dense one).
