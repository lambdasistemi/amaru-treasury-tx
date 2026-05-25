# Implementation Plan: `/operate` form books + `/books` management route

**Feature**: 267-form-books
**Spec**: [`spec.md`](spec.md)

## Tech stack

- **Frontend only.** PureScript + Halogen + Argonaut, building under the existing `frontend/` flake target.
- **Persistence**: `window.localStorage` via a thin FFI module.  No backend or HTTP changes.
- **No new flake input.**  Argonaut + Halogen are already in `frontend/spago.yaml`.

## Module additions

- `frontend/src/Shell/Book.purs` — typed two-shape API (`loadNamed` / `loadFreeText` / `recordNamed` / `recordFreeText` / `renameNamed` / `addNamed` / `removeNamed` / `removeFreeText` / `clear`).  Per-book `BookKey` discriminates named (`wallets`, `reference_uris`) vs free-text (`descriptions`, …).
- `frontend/src/Shell/Book.js` — FFI for `localStorage.getItem/setItem/removeItem`.
- `frontend/src/BooksPage.purs` — new SPA route component.
- `frontend/src/BooksPage/Import.purs` — bundle/per-book parser + merge logic (kept separate from the page component for testability).

## Routing

The SPA already routes `view` / `operate` via `Main.purs` hash routing.  Add a `books` route, a topbar link, and the page component.

## Storage shape (per FR-002, FR-015)

Per-book localStorage values are **bare JSON arrays** matching the wire shape — no internal envelope, no version field per book:

- `amaru-treasury.book.wallets`        → `[ {"name":"…","address":"addr1q…"}, … ]`
- `amaru-treasury.book.reference_uris` → `[ {"name":"…","cid":"bafy…"}, … ]`
- `amaru-treasury.book.descriptions`   → `[ "…", … ]` (and same for every other free-text book key)

This matches the per-card export shape, so an operator-visible localStorage value IS a valid per-book export.  Lace contact-book imports drop in unchanged; IPFS Pinning Service `pins` arrays drop in unchanged.

## Bundle shape (per FR-015)

```json
{
  "kind": "amaru.book.bundle.v1",
  "books": {
    "wallets":          [ {"name":"…","address":"…"} ],
    "reference_uris":   [ {"name":"…","cid":"…"} ],
    "descriptions":     [ "…" ],
    "…":                [ … ]
  }
}
```

`kind` discriminator on the wrapper only; per-book wire shape IS its schema.

## Slicing

Four bisect-safe slices, each one usable on its own:

1. **Slice A — `Shell.Book` module (foundation)**: typed two-shape API + FFI; no UI consumer yet; proof = a minimal `Shell.BookSpec` round-trip property OR a documented manual-smoke recipe in `WIP.md` (frontend has no test harness).
2. **Slice B — `/operate` integration (US1 + US2)**: named-book widget (custom dropdown of `name` labels that substitutes the typed value into the input) for `wallets` / `reference_uris`; HTML5 `<datalist>` for every free-text field; record on `ClickBuild`.
3. **Slice C — `/books` route (US3)**: SPA router entry, topbar link, page component rendering one card per book; named cards with editable `name`, read-only typed value, `×`, `Add new`; free-text cards with `×` per row + `Clear all`.
4. **Slice D — Import / Export (US4)**: top-of-page `Export all` + `Copy all` + `Import…` + per-card `Export` + `Copy`.  Import dialog: file picker + paste textarea + dispatch (`kind`-tagged bundle vs bare array auto-detection) + before/after merge diff + confirm.

Each slice ends with a single commit carrying `Tasks: T267-S<n>` trailer.

## Out-of-scope (mirrors spec)

- Named bundles / recipe templates.
- Cross-device sync.
- Encryption at rest.
- Bisect of import for sub-book selection — whole-book granularity only.
