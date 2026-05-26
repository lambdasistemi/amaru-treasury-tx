# Feature Specification: Playwright-driven UI review — md-icon + theme-toggle a11y + mobile topbar polish

**Feature Branch**: `feat/playwright-driven-ui-review-ship-queued-md-icon-th`
**Issue**: [#299](https://github.com/lambdasistemi/amaru-treasury-tx/issues/299)
**Parent**: [#289](https://github.com/lambdasistemi/amaru-treasury-tx/issues/289) (closed)
**Created**: 2026-05-26
**Status**: Draft

## Goal

Replace remaining unicode-glyph iconography (`⎘`, `✓`, `Dark`/`Light`) in
the treasury web UI with Material `<md-icon>` elements consistent with
`BooksPage.purs:1650`, make the theme toggle keyboard- and
screen-reader-accessible with a visible icon plus a hidden text label,
and tidy `.copy-row` and the mobile topbar nav layout. Backed by a
Playwright-driven before/after capture across `/`, `/operate`, `/books` at
desktop / 390px / 320px so the polish has visible proof.

## P1 user story

As a `treasury operator`, I `interact with /, /operate, and /books on
desktop, 390px, and 320px after a Playwright review pass` and observe `a
consistently iconified UI, an accessible theme toggle, no a11y or layout
regressions versus #289 acceptance, and a recorded review document
showing the screenshots that drove each fix`.

## User Stories (operator-facing scenarios)

### US-1 — Theme toggle is iconified and accessible (P1)

Operator opens any page and sees the theme toggle as a Material icon
(`dark_mode` in light theme, `light_mode` in dark theme) inside a
44×44px button with a `title` tooltip ("Switch to Dark theme" /
"Switch to Light theme") and a `.visually-hidden` text label readable by
screen readers.

**Independent test**: DOM check on `/`, `/operate`, `/books` —
`.topbar__theme-btn` contains exactly one `<md-icon>` element with text
matching the current theme; the button has a non-empty `title`
attribute; a `<span class="visually-hidden">` child holds the
theme label; computed `width × height ≥ 44 × 44`. Playwright captures
before/after at the three viewports.

### US-2 — Copy buttons use Material icons (P1)

Operator clicks a copy button on `/operate` (inspect JSON, intent JSON,
copy-row blocks). The button renders `<md-icon>content_copy</md-icon>`
in the default state and `<md-icon>check</md-icon>` once copied,
replacing the unicode `⎘` / `✓` glyphs in `App.purs:389` and `:735`.

**Independent test**: DOM check on `/operate` — every `.v-copy--block`
button contains an `<md-icon>` (not a bare text node). After a click
the icon's text content transitions from `content_copy` to `check`.

### US-3 — `.copy-row` lays out as a grid on every viewport (P1)

Operator looks at any `copy-row` (label + value + copy button). At 320,
390, and 1280px the row stays on a single line: the label keeps a
minimum width, the value truncates with ellipsis, and the copy button
hugs the right edge.

**Independent test**: `.copy-row` computed style is
`display: grid; grid-template-columns: minmax(8rem, auto) minmax(0, 1fr) auto`;
no `flex-wrap: wrap`; no horizontal page overflow at any viewport.

### US-4 — Mobile topbar nav wraps on its own row (≤600px) (P2)

At viewports ≤600px the topbar nav links wrap to a row of their own,
full-width, while the theme toggle stays right-aligned and the title
stays left-aligned. No horizontal page overflow.

**Independent test**: at 390px and 320px the computed flex order /
basis on `.topbar__nav` places it as a full-width row below the title
and the theme toggle stays in the original row right-aligned.

### US-5 — Playwright review record exists and is captured (P1)

A reviewer reading the PR can see the before/after side-by-side for
each page × viewport and read a findings note explaining what changed
and why.

**Independent test**: `frontend/test/ui-review/299/` contains:
`before/` (9 PNGs covering / + /operate + /books × 3 viewports), `after/`
(9 PNGs same matrix), and `findings/pre-review.md` + `findings/after.md`.

## Functional Requirements

- **FR-1** — `frontend/src/App.purs` MUST replace the two `⎘`/`✓` text
  nodes (lines 389 and 735) with `<md-icon>` elements carrying
  `content_copy` / `check`.
- **FR-2** — `frontend/src/Shell.purs` MUST replace the topbar theme
  toggle text label with `<md-icon>` (`dark_mode` / `light_mode`), add
  a `title` attribute ("Switch to <opposite> theme"), and add a
  `<span class="visually-hidden">` child holding the theme label.
- **FR-3** — `frontend/dist/styles.css` MUST define a
  `.visually-hidden` utility class (position: absolute; 1×1px; clip).
- **FR-4** — `frontend/dist/styles.css` MUST style `.topbar__theme-btn`
  with `width: 44px; height: 44px; display: inline-grid; place-items:
  center;` plus hover / outline tokens consistent with the rest of the
  topbar.
- **FR-5** — `frontend/dist/styles.css` MUST switch `.copy-row` to a
  3-column grid layout `minmax(8rem, auto) minmax(0, 1fr) auto`.
- **FR-6** — `frontend/dist/style-build.css` MUST add a `@media
  (max-width: 600px)` block reordering `.topbar__nav` to a full-width
  row 3 and keeping `.topbar__theme-btn` right-aligned.
- **FR-7** — A Playwright before/after capture artifact MUST land
  under `frontend/test/ui-review/299/`.

## Success criteria

- All Functional Requirements satisfied.
- `nix build .#frontend` green at HEAD.
- The Playwright responsive smoke from #289
  (`frontend/test/playwright/responsive.spec.ts`) passes against a
  locally built bundle.
- Before/after PNGs at desktop / 390 / 320 demonstrate the changes for
  the theme toggle, the copy buttons, and the mobile topbar nav.

## Non-goals

- Backend / API / CLI / wizard behavior changes.
- Restyling `BooksPage.purs`'s existing `md-icon-button` usage.
- Wrapping the dashboard scope-card "Bad Gateway" error text in a
  friendlier surface (separate ticket).
- Replacing the Books page disclosure `▸ … expand` affordance with a
  chevron icon (separate ticket).
- Spinner / timeout for the `build identity loading…` footer (separate
  ticket).
- Cross-device sync, server-side persistence, additional pages.

## Out-of-scope findings filed as follow-ups (not addressed in this PR)

See `frontend/test/ui-review/299/findings/pre-review.md` for the full
list. The PR body lists any new GH issues filed for these.
