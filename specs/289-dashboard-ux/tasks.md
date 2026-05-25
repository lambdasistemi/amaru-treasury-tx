# Tasks: Treasury dashboard style + mobile UX overhaul

**Feature**: 289-dashboard-ux
**Spec**: [`spec.md`](spec.md) — **Plan**: [`plan.md`](plan.md)

Eight bisect-safe slices.  Each commit body trailer: `Tasks: T289-S<n>`.  Persistent driver pane re-pointed at `/code/amaru-treasury-tx-issue-289/`.

## Slice A — Mobile topbar + Playwright responsive smoke

- [X] T289-S1 [US1] Fix the topbar (in `frontend/src/Shell.purs`) so it doesn't overflow at 320 px / 390 px viewports.  Pattern: `flex-wrap` if the link set is short enough, OR collapse to a hamburger drawer below `600 px`.  Driver picks based on link count + theme-toggle width.
- [X] T289-S1 [US1] Add accessible names: every topbar link + the theme toggle carries `aria-label`.
- [X] T289-S1 [US9] Add `frontend/test/playwright/responsive.spec.ts` (or extend the existing Playwright harness) covering `/`, `/operate`, `/books` at 320 / 390 / 1024 / 1280 px.  Assert `document.documentElement.scrollWidth <= clientWidth` at every viewport on every page.  Capture screenshots into `frontend/test/playwright/screenshots/`.
- [X] T289-S1 [US9] Wire the responsive smoke into the dev-side smoke recipe (deploy + Playwright run).  Document the deploy ritual in `WIP.md`.
- [X] T289-S1 Smoke proof in `WIP.md`: scrollWidth ≤ clientWidth at every viewport.  Topbar links visible and keyboard-focusable.
- [X] T289-S1 Commit: `feat(289): mobile topbar + Playwright responsive smoke harness` with `Tasks: T289-S1` trailer.

## Slice B — `/operate` sticky action bar

- [X] T289-S2 [US2] Pick the FR-003 pattern: either drop sticky and place inline at flow end + add a "jump to Build" affordance from the progress indicator (slice D); OR keep sticky + add `padding-bottom` to the form area equal to the bar's height + a hide-on-scroll-up affordance.
- [X] T289-S2 [US2] Implement in `OperatePage.purs`.  Test at 390 px: after a synthesised validation error renders below the wallet field, both the field and the error are visible (not covered by the action bar).
- [X] T289-S2 Smoke proof in `WIP.md`: action bar non-occluding at 390 px; Build button reachable after validation error.
- [X] T289-S2 Commit: `feat(289): /operate action bar — non-occluding on mobile` with `Tasks: T289-S2` trailer.

## Slice C — `/operate` a11y

- [X] T289-S3 [US3] Every input/select/textarea on `/operate` gets `<label for="<id>">` OR `aria-label` (every input has a stable `id`).
- [X] T289-S3 [US3] Validation errors render `aria-invalid="true"` on the input + `aria-describedby="<error-id>"` linking to the error span (`id` on the span).
- [X] T289-S3 [US3] Touch-target sizes: every clickable / focusable element measures ≥ 44×44 px in the rendered DOM (or has equivalent padding/overlay covering ≥ 44×44 px hit-area).
- [X] T289-S3 Smoke proof in `WIP.md`: DOM checks pass.  Lighthouse accessibility on `/operate` reports ≥ 95 (run via Playwright's lighthouse plugin or a curl-based axe-core run; pick what's available in the existing harness).
- [X] T289-S3 Commit: `feat(289): /operate a11y — labels, aria-invalid, aria-describedby, touch targets` with `Tasks: T289-S3` trailer.

## Slice D — `/operate` progress + first-blocker navigation

- [X] T289-S4 [US4] Add a sectioned progress indicator at the top of `/operate`.  Sections: Identity (wallet + beneficiary), Amount, Rationale (description + justification + destination label), References, Signers.  Each section reports `complete` / `invalid` / `pending`.
- [X] T289-S4 [US4] Click a section → page scrolls to the section + focuses the first invalid input in it (or the first input if none invalid).
- [X] T289-S4 [US4] If slice B chose the "inline action bar" pattern: the progress indicator includes a "Jump to Build" affordance pinned to the right.
- [X] T289-S4 Smoke proof in `WIP.md`: with a wallet bech32 missing, the Identity section reports `invalid`; clicking it focuses the wallet input; the wallet input is in the viewport.
- [X] T289-S4 Commit: `feat(289): /operate sectioned progress + first-blocker navigation` with `Tasks: T289-S4` trailer.

## Slice E — Dashboard status indicators

- [X] T289-S5 [US5] Above the existing per-scope cards on `/`, render a status row: `chain tip: <slot>` + `refreshed: <relative-time>` + per-scope chips with `fresh` / `stale` / `partial` state.
- [X] T289-S5 [US5] Source: the existing `chainTip` query (App.purs has this via the periodic refresh helper added pre-#283).  Per-scope state derived from the existing per-scope load result (success / error / in-flight).
- [X] T289-S5 [US5] Visual: each state has a distinct colour token from the theme palette (subtle; fresh = neutral, stale = warning, partial = caution).
- [X] T289-S5 Smoke proof in `WIP.md`: `/` renders the status row; stale state computed correctly when a refresh fails (force via DevTools network throttle or by waiting past the staleness threshold).
- [X] T289-S5 Commit: `feat(289): / dashboard status row — chain tip + refresh time + per-scope state` with `Tasks: T289-S5` trailer.

## Slice F — Dashboard copy actions

- [X] T289-S6 [US6] Every long-string value (treasury addresses, txids, references) on `/` renders a copy icon-button DOM-adjacent to the value.  Reuse `Shell.Clipboard` from #267 (slice E).
- [X] T289-S6 [US6] Copy feedback: icon swaps to `check` for 1 s then reverts.  Clipboard failures render an inline `Copy failed` line directly below the button (the existing `_writeClipboard` swallows errors; this slice adds a status return to surface them).
- [X] T289-S6 Smoke proof in `WIP.md`: monkey-patch `navigator.clipboard.writeText` to capture the call; verify the value is exactly the displayed value (not truncated).  Visual check at 390 px: copy button + value fit on one row.
- [X] T289-S6 Commit: `feat(289): / dashboard copy actions colocated + immediate feedback` with `Tasks: T289-S6` trailer.

## Slice G — `/books` empty-state cleanup

- [X] T289-S7 [US7] When all cards in a group are empty, collapse the group under a single disclosure `N <group> books empty · expand`.  Clicking expands the group.  When ≥1 card in the group has entries, the group renders normally (no disclosure).
- [X] T289-S7 [US7] On empty cards (regardless of group collapse), the `Copy` and `Export` icon-buttons are `aria-disabled="true"` and visually de-emphasized (opacity 0.4, no hover).  Add new + Clear all stay active where applicable.
- [X] T289-S7 Smoke proof in `WIP.md`: from a freshly-cleared browser, `/books` no longer renders 10 identical full empty-card rows — the four groups all collapse under disclosures (since every card is empty).
- [X] T289-S7 Commit: `feat(289): /books empty-state — group collapse + disabled empty actions` with `Tasks: T289-S7` trailer.

## Slice H — Theme palette + hero scale

- [X] T289-S8 [US8] Refine `frontend/dist/styles.css` + `dist/style-build.css` theme tokens — narrower hue range, higher contrast on text/control pairs (target WCAG AA on body text; AAA on critical numeric values like balances).
- [X] T289-S8 [US8] Reduce hero spacing on `/` so the per-scope cards appear in the first fold on desktop (1280 px viewport) AND mobile (390 px viewport).  Set concrete `max-height` budgets in the smoke proof.
- [X] T289-S8 Smoke proof in `WIP.md`: contrast checks via Playwright + axe-core or a small JS check (every text/background pair ≥ 4.5:1).  Hero height ≤ specified budget at each viewport.
- [X] T289-S8 Commit: `feat(289): theme palette refinement + reduced hero scale` with `Tasks: T289-S8` trailer.

## Dependencies

- Slice A blocks all later slices (Playwright harness is shared).
- B blocks D if B picks the inline-bar pattern (D adds the "Jump to Build" affordance).
- C blocks D (a11y plumbing is the substrate for first-blocker focus management).
- E and F can land in either order.
- G and H are independent.

Recommended execution order: A → B → C → D → E → F → G → H.

## Gate

```bash
nix build --quiet .#frontend .#checks.x86_64-linux.unit .#checks.x86_64-linux.lint .#amaru-treasury-tx-api
```

Plus Playwright responsive smoke (from slice A onward) passes at HEAD.
