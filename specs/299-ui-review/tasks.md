# Tasks: #299 — Playwright-driven UI review

**Spec**: [`spec.md`](spec.md) — **Plan**: [`plan.md`](plan.md)

Each slice = one bisect-safe commit. Driver appends each milestone to
`WIP.md` in the worktree root.

## Slice A — Material `<md-icon>` system + theme-toggle a11y

- [ ] T299-S1 — `frontend/src/App.purs:389` — replace the `⎘ Copy inspect JSON` text node with `<md-icon>content_copy</md-icon>` + `<span>Copy inspect JSON</span>`.
- [ ] T299-S1 — `frontend/src/App.purs:735` (`copyRow`) — render the `icon` value inside an `<md-icon>` element; flip the label vocabulary to `"content_copy"` / `"check"` instead of `"⎘"` / `"✓"`.
- [ ] T299-S1 — `frontend/src/Shell.purs:109-114` — topbar theme button: drop the literal text label; add `<md-icon>` (`dark_mode` when `themeLabel == "Dark"`, else `light_mode`); add `title="Switch to <themeLabel> theme"`; add `<span class="visually-hidden">{themeLabel}</span>` child.
- [ ] T299-S1 — `frontend/dist/styles.css` — add `.visually-hidden` utility class (position: absolute; 1×1px; clip).
- [ ] T299-S1 — `frontend/dist/styles.css` — add `.topbar__theme-btn` styling (44×44, `inline-grid`, hover / outline tokens).
- [ ] T299-S1 — `frontend/dist/styles.css` — add `.v-copy--block md-icon { font-size: 18px; }` rule.
- [ ] T299-S1 — `nix build --quiet .#frontend` green at HEAD.
- [ ] T299-S1 — Playwright after-capture (orchestrator-run) at `/`, `/operate`, `/books` × {1280, 390, 320} dropped under `frontend/test/ui-review/299/after/` (slice A subset).
- [ ] T299-S1 — Commit `feat(299): md-icon migration + a11y theme toggle` with `Tasks: T299-S1` trailer.

## Slice B — Mobile topbar nav reorder + `.copy-row` grid + after-review record

- [ ] T299-S2 — `frontend/dist/styles.css` — `.copy-row` switches from `display: flex; flex-wrap: wrap` to `display: grid; grid-template-columns: minmax(8rem, auto) minmax(0, 1fr) auto`.
- [ ] T299-S2 — `frontend/dist/style-build.css` — add `@media (max-width: 600px)` block reordering `.topbar__nav` to `order: 3; flex: 1 1 100%; margin-left: 0` and `.topbar__theme-btn { margin-left: auto; }`.
- [ ] T299-S2 — `nix build --quiet .#frontend` green at HEAD.
- [ ] T299-S2 — Playwright after-capture (orchestrator-run): re-take `/`, `/operate`, `/books` × {1280, 390, 320} and overwrite the slice-A subset with the final state.
- [ ] T299-S2 — `frontend/test/ui-review/299/findings/after.md` summarising before/after deltas + any new follow-up issues filed.
- [ ] T299-S2 — Playwright responsive smoke from #289 (`frontend/test/playwright/responsive.spec.ts`) still passes against a local serve (orchestrator-run).
- [ ] T299-S2 — Commit `feat(299): mobile topbar reorder + copy-row grid + ui-review record` with `Tasks: T299-S2` trailer.

## Finalize (orchestrator)

- [ ] Drop `gate.sh` in `chore: drop gate.sh (ready for review)` commit.
- [ ] PR body audit + update.
- [ ] `gh pr ready 299`.
- [ ] Wait for CI green.
- [ ] Merge via `mcp__merge-guard__guard-merge`.
- [ ] Post-merge cleanup: `git worktree remove`, delete local + remote branch, `git worktree prune`.
