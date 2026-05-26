# #299 — Playwright pre-review findings

Captured against `https://amaru-treasury.dev.plutimus.com/` at desktop
(1280×800), mobile-390 (390×844), and mobile-320 (320×568) on
2026-05-26. Before screenshots in `../before/`.

## Topbar theme toggle (all pages, all viewports)

- Renders the literal text `Dark` / `Light` in a bordered button — no
  Material icon, no `title` tooltip, no screen-reader label besides the
  visible text.
- Hit target is a tight text-sized rectangle, well below the 44×44 mobile
  affordance ([#289 AC mobile touch sizes]).
- Inconsistent with `BooksPage.purs:1650-1655`, which already uses
  `<md-icon-button>` + `<md-icon>` pairs.

**Action — Slice A:** swap to `<md-icon>dark_mode|light_mode</md-icon>` +
`.visually-hidden` text label + `title` tooltip; style `.topbar__theme-btn`
to 44×44 with the same Material-style border/hover the rest of the icon
buttons use.

## Dashboard copy buttons (Operate page; covered by seed diff)

- `App.purs:389` and `:735` use literal unicode glyphs `⎘` (clipboard) and
  `✓` (check) inside `<button>` elements.
- Sits next to `BooksPage.purs` `md-icon-button` pattern — visually
  inconsistent (one is a Material outline icon, the other is a flat
  unicode glyph).

**Action — Slice A:** swap to `<md-icon>content_copy</md-icon>` (and
`check` on the copied state). Add a `.v-copy--block md-icon` font-size
rule so the icon doesn't dwarf the button label.

## Mobile topbar nav reorder (≤600px)

- At 390px and 320px the topbar already wraps gracefully thanks to #289,
  but the theme toggle drops to a new row aligned left.
- Per the seed diff, on mobile the nav should wrap to its own row (full
  width) and the theme toggle should stay top-right, matching the
  desktop position.

**Action — Slice B:** `@media (max-width: 600px)` rule in
`frontend/dist/style-build.css` reordering `.topbar__nav` to `order: 3;
flex: 1 1 100%` and right-aligning `.topbar__theme-btn`.

## `.copy-row` layout

- Current `display: flex; flex-wrap: wrap` makes the label / value / copy
  button stack inconsistently across viewports.

**Action — Slice B:** switch to `display: grid; grid-template-columns:
minmax(8rem, auto) minmax(0, 1fr) auto` per seed diff.

## Out-of-scope findings (filed as follow-ups, not addressed here)

- **Scope cards show backend errors verbatim** ("Unexpected token 'B',
  'Bad Gateway' is not valid JSON"). The dev API was returning 502 at
  capture time; the dashboard renders the raw fetch error string. The
  display layer could wrap with a friendlier "Service unavailable —
  retrying…" but this is a separate concern; the ticket scope is icon /
  layout / a11y, not error rendering.
- **"build identity loading…" footer placeholder.** No spinner, no
  timeout. Separate ticket.
- **Books page disclosure affordance (▸ + "expand" text).** Could swap
  for a Material chevron icon, but the format was set in #289 and the
  expand text doubles as an affordance — out of scope.

## What the after-pass must capture

- Theme toggle on `/` desktop and 390px: visible icon, hover state, focus
  ring, screen-reader label inspected via `browser_snapshot`.
- Copy buttons on `/operate`: clicked once, captured in default + copied
  state.
- `.copy-row` on `/operate` and on the inspect JSON section: label /
  value / button on one line.
- Mobile topbar nav reorder at 320 and 390: nav row + theme toggle row
  layout matches the seed-diff intent.
