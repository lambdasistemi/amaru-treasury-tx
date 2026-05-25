# Implementation Plan: `/operate` drafts book + auto-save + history

**Feature**: 288-operate-state-persistence
**Spec**: [`spec.md`](spec.md)

## Tech stack

- PureScript + Halogen (frontend only).
- Existing `Shell.Book` API extended with TWO new named book keys (`OperateDraftsBook`, `OperateHistoryBook`).  Storage uses the same localStorage / Argonaut infrastructure.
- No backend changes.

## Affected modules

- `frontend/src/Shell/Book.purs` — add `OperateDraftsBook` + `OperateHistoryBook` to `NamedBookKey`, `OperateDraftEntry` record type with `snapshot` nested JSON, new `NamedEntry` constructor used by both books.  Per-book cap (drafts=25, history=100) — promote `maxEntries` from a constant to a `bookCap :: BookKey -> Int` function.  Auto-save reserved-name filtering helper.
- `frontend/src/OperatePage.purs` — TWO pickers (`Drafts ▾` + `History ▾`) at the top; `Save as draft…` button; on every form-field action, debounced auto-save; on Initialize, restore from `__autosave__`; on successful Build, clear the auto-save slot AND append a timestamped entry to `operate_history`.
- `frontend/src/BooksPage.purs` — new top `Drafts` group with TWO cards (`Drafts` and `History`).  History card is read-only-name (rows render `[ timestamp | summary | copy | trash ]`, no name editing).  Snapshot one-line summary helper shared by both cards.
- `frontend/src/BooksPage/Import.purs` — bundle parse/merge/diff handles BOTH new books with dedup-on-name semantics.  History dedup uses the timestamp string verbatim.

## Slicing

Three bisect-safe slices:

1. **Slice A — `Shell.Book` foundation**: add both new books + their per-book caps + auto-save filtering helper (`loadNamedVisible` / `loadAutoSave`).  No UI consumers yet; smoke plants entries in both books and verifies round-trip + cap enforcement.

2. **Slice B — /operate integration**: auto-save on form-field change (debounced); restore on Initialize; clear `__autosave__` + append `operate_history` entry on Build success; `Drafts ▾` picker + `Save as draft…` editor + `History ▾` picker.  Smoke covers US-1 + US-2 + US-5.

3. **Slice C — /books integration + bundle import/export**: top `Drafts` group + Drafts card + History card; bundle key handling for both books.  Smoke covers US-3 + US-4 + bundle round-trip.

Each slice = one commit with `Tasks: T288-S<n>` trailer.

## Out-of-scope (mirrors spec)

- /view state preservation.
- Cross-device sync.
- Per-mode-specific drafts (one shape per book; mode is one snapshot field).
- Encryption.
- Auto-save granularity < 300 ms (no UX value).
- Pre-existing operator state migration (the feature is net-new).
