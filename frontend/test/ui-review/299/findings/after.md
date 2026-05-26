# #299 — Playwright after-review

After-state captured against a local serve of `nix build .#frontend`
output on 2026-05-26 (no API backend reachable from the local serve,
so scope cards still show fetch-error messages — outside this PR's
scope, see [pre-review out-of-scope findings](pre-review.md)). Screenshots
in `../after/`.

## Verified deltas (slice A + slice B applied)

### Theme toggle (dashboard / operate / books, all viewports)

- **Before**: bordered button containing the literal text `Dark` /
  `Light`. Tight rectangle, well below 44×44px hit target. No
  tooltip; no screen-reader label besides the visible text.
- **After**: 44×44 `inline-grid` button containing
  `<md-icon>dark_mode</md-icon>` (light theme active) or `light_mode`
  (dark theme active). `title="Switch to <opposite> theme"` tooltip.
  `<span class="visually-hidden">{themeLabel}</span>` child gives
  screen readers a real label.
- **Evidence**: `dashboard-desktop-1280` before/after — text `Dark`
  becomes a circle-moon icon top-right of the topbar. Same on
  `books-mobile-390` / `dashboard-mobile-390` — mobile shows the icon
  inside the 44×44 surface-container box.

### Copy buttons on /operate (inspect JSON + copy-row blocks)

- **Before**: bare unicode glyphs `⎘` (clipboard) and `✓` (check).
- **After**: `<md-icon>content_copy</md-icon>` in default state,
  `<md-icon>check</md-icon>` once copied. Visually consistent with
  `BooksPage.purs:1650` (`md-icon-button` pattern). The Material
  glyphs render at 18-20px inside their containing button.
- **Evidence**: `operate-desktop-1280` and `operate-mobile-390` —
  copy controls now render as outline icons (no unicode-character
  appearance).

### Mobile topbar nav reorder (≤600px, dashboard / operate / books)

- **Before**: at 390 / 320 the theme toggle wrapped to its own row
  left-aligned; nav links shared the row with the title.
- **After**: title + theme toggle stay on row 1 (title left,
  toggle right). Nav links wrap to row 2 (full-width, left-aligned).
  Both rows fit within `min-width: 320px` without horizontal page
  overflow.
- **Evidence**: `dashboard-mobile-390`, `books-mobile-390`,
  `operate-mobile-390` — every page shows the same two-row pattern.

### `.copy-row` grid layout (operate page copy-row blocks)

- **Before**: `display: flex; flex-wrap: wrap` — label, value, button
  stacked/wrapped inconsistently across viewports.
- **After**: `display: grid; grid-template-columns: minmax(8rem, auto)
  minmax(0, 1fr) auto` keeps label / value / button on one row;
  mobile breakpoint adapts to a single-column with the copy button on
  row 2 of its own.
- **Evidence**: the seed-diff edits in `frontend/dist/styles.css` for
  `.copy-row*` and the `@media (max-width: 600px) .copy-row*` block
  (still rendered without overflow at 320).

## Confirmed-unchanged surfaces

- Backend-driven content (scope card data, total ADA / USDM / UTXOs,
  intent JSON contents) — neither slice touched them. Pre-review
  errors persist on the local serve because there is no API; on the
  live dev deploy the same content renders normally.
- Halogen state and event semantics (theme switching still works on
  click; copy still copies; nav still routes).
- Desktop layout above 600px — the `@media` rule is mobile-only.

## Smoke

- `nix build --quiet --no-link .#frontend` — green at slice A HEAD
  and at slice B HEAD.
- Local serve of the built bundle (with an SPA-fallback Python
  server) used for the after-capture; no console errors beyond the
  expected fetch failures for `/v1/treasury-inspect`.
- The Playwright responsive smoke
  (`frontend/test/playwright/responsive.spec.ts`) is unchanged and
  expected to pass against the dev deploy once this PR merges.

## Out-of-scope follow-ups confirmed (not addressed)

Same as [`pre-review.md`](pre-review.md):

- Scope-card backend error rendering (raw `Unexpected token …` text).
- `build identity loading…` footer placeholder.
- Books-page disclosure `▸ … expand` chevron icon.
- Active-page chip differentiation in the topbar nav.

None blocked the icon/a11y/layout polish; they're filed only as
observations from this review pass.
