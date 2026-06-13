# Issue 381 UI polish plan

## Scope

Polish the visual layout of the `/operate` build page controls and the
populated `/pending` page without changing store, routing, endpoint, or
handler behavior.

## Owned files

- `frontend/dist/styles.css`
- `frontend/dist/style-build.css`
- `frontend/src/OperatePage.purs`
- `frontend/src/PendingPage.purs`
- `frontend/test/playwright/ui-polish-381.spec.ts`
- `frontend/test/ui-review/381/`

## Verification

- Build the frontend bundle with `nix build .#frontend`.
- Run the Playwright guard at 1280px and 390px on `/operate` and
  `/pending` with seeded IndexedDB entries.
- Run `./gate.sh` before finalization.
