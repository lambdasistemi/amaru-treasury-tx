# Tasks: `/operate` drafts book + auto-save + history

**Feature**: 288-operate-state-persistence
**Spec**: [`spec.md`](spec.md) — **Plan**: [`plan.md`](plan.md)

Three bisect-safe slices on PR [#290](https://github.com/lambdasistemi/amaru-treasury-tx/pull/290).  Each commit body trailer: `Tasks: T288-S<n>`.  Same persistent driver pane as #267 / #284.

## Slice A — `Shell.Book` foundation

- [X] T288-S1 [US1, US2, US5] Extend `frontend/src/Shell/Book.purs`: add `OperateDraftsBook` AND `OperateHistoryBook` to `NamedBookKey`.  Add `OperateSnapshotEntry :: { name :: String, snapshot :: Json }` record type used by BOTH books — `snapshot` stays as Argonaut `Json` (typed shape is `OperatePage`'s concern, not `Shell.Book`'s).  Wire encoders/decoders so the on-disk shape per book is `[{name, snapshot}, …]`.

- [X] T288-S1 Per-book cap: promote `maxEntries :: Int = 25` to `bookCap :: BookKey -> Int` returning `25` for `WalletsBook` / `ReferencesBook` / `OperateDraftsBook` and `100` for `OperateHistoryBook`.  Every `record*` / `addNamed` call uses `bookCap` instead of the constant.

- [X] T288-S1 [US4] Expose two query helpers:
  - `loadNamedVisible :: NamedBookKey -> Effect (Array NamedEntry)` — same as `loadNamed` but filters out entries whose `name` matches the reserved auto-save marker (`__autosave__`).  Used by `Drafts ▾` and the /books `Drafts` card.
  - `loadAutoSave :: NamedBookKey -> Effect (Maybe NamedEntry)` — returns the `__autosave__` entry if present.  Used by /operate Initialize.

- [X] T288-S1 Smoke proof in `WIP.md`: pre-plant `localStorage.book.operate_drafts` with one named entry + one `__autosave__` entry → reload → `loadNamedVisible OperateDraftsBook` returns the named entry only; `loadAutoSave OperateDraftsBook` returns the auto-save entry.  Plant 102 entries in `localStorage.book.operate_history` → reload → load returns exactly 100 (tail dropped).

- [X] T288-S1 Commit: `feat(288): Shell.Book — operate_drafts + operate_history + auto-save helpers + per-book cap` with `Tasks: T288-S1` trailer.

## Slice B — /operate integration

- [X] T288-S2 [US1] Extend `OperatePage.purs` State with `pickedDraftName :: Maybe String` and `saveDialog :: Maybe SaveDraftState`.

- [X] T288-S2 [US1] On every form-mutation action (every `SetWallet`, `SetDescription`, …), schedule a debounced (300 ms) auto-save: serialize the current form state into a `snapshot` Json blob and call `addNamed OperateDraftsBook { name: "__autosave__", snapshot }`.

- [X] T288-S2 [US1] On Initialize: call `loadAutoSave OperateDraftsBook`; if present, restore the snapshot into State.  No-op if absent.  This survives both route navigation (Halogen re-mounts /operate) and full reload.

- [X] T288-S2 [US2] Add the `Drafts ▾` picker (Halogen widget, same shape as the named-book widget on the wallet input) at the top of /operate, before the mode toggle.  Picking an entry calls `loadNamedVisible OperateDraftsBook`, finds the entry by name, restores its snapshot into State.

- [X] T288-S2 [US2] Add the `Save as draft…` button next to the picker.  Clicking opens an inline editor (one-input panel with name field + Save + Cancel).  Save validates non-empty, then calls `addNamed OperateDraftsBook { name, snapshot: <current state> }`.  If the name collides with an existing entry, the editor shows `Will overwrite existing draft '<name>'` BEFORE the operator confirms.

- [X] T288-S2 [US5] Add the `History ▾` picker next to `Drafts ▾`.  Lists every entry from `loadNamedVisible OperateHistoryBook` (auto-save filter is a no-op here, but reuses the same plumbing).  Newest-first order is enforced by `addNamed` (insert at head + dedup).  Picking an entry restores the snapshot identically to picking a draft — same `pickedDraftName` State plumbing.

- [X] T288-S2 [US1, US5] On successful Build response (where /operate shows the CBOR + Report tabs): (a) clear the auto-save slot via `removeNamed OperateDraftsBook "__autosave__"`; AND (b) append a fresh entry to `OperateHistoryBook` via `addNamed OperateHistoryBook { name: <UTC ISO timestamp Z>, snapshot: <current state> }`.  Use `Effect.Now` for the timestamp; format as `YYYY-MM-DD HH:MM:SS Z` (second precision).  Named drafts NOT cleared.

- [X] T288-S2 Smoke proof in `WIP.md`: deploy, plant some form values, navigate /operate → /books → /operate — fields restored.  Reload page — fields still restored.  Click `Save as draft…`, name `Test`, save — `localStorage.book.operate_drafts` has `[{name: "Test", snapshot: {…}}, {name: "__autosave__", snapshot: {…}}]`.  Refresh, `Drafts ▾` shows only `Test`.  Click Build (Reorganize mode for the dev path) → response lands → `localStorage.book.operate_history` has one entry whose `name` matches the regex `^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} Z$`; `__autosave__` is gone; `Test` is still present.  `History ▾` shows the timestamp.  Pick it → form repopulates from the historical snapshot.

- [X] T288-S2 Commit: `feat(288): /operate auto-save + Drafts picker + Save as draft + History picker + on-build history append` with `Tasks: T288-S2` trailer.

## Slice C — /books integration + bundle import/export

- [X] T288-S3 [US3] Add a `Drafts` group at the TOP of `/books`, above `Identities`.  The group contains TWO cards:
  - `Drafts` card — lists every entry from `loadNamedVisible OperateDraftsBook`.
  - `History` card — lists every entry from `loadNamedVisible OperateHistoryBook`.

- [X] T288-S3 [US3] Drafts card row: `[ name input (editable, commit on blur/Enter) | snapshot summary span | copy icon | guarded trash icon ]`.  Snapshot summary one-liner: `<mode> · <scope> · <beneficiary-truncated> · <amount> USDM` (handle missing fields with `—`).  Copy copies the snapshot Json string.

- [X] T288-S3 [US3, US5] History card row: `[ timestamp (readonly span — NOT editable) | snapshot summary span | copy icon | guarded trash icon ]`.  Same snapshot summary formatter as Drafts.  No name editing (timestamps are content-addressable).  No `Add new` button (history is auto-captured only).

- [X] T288-S3 [US3] Empty-state captions:
  - Drafts card: "No drafts yet.  Use 'Save as draft…' on `/operate` to capture the current form."
  - History card: "No history yet.  Every successful Build on `/operate` will appear here, indexed by date."

- [X] T288-S3 [US3] Extend `BooksPage/Import.purs`: bundle parse / merge / diff handles BOTH `operate_drafts` AND `operate_history`.  Dedup-on-name (not dedup-on-typed-value — neither book has a typed primitive).  Auto-save slot is filtered out of exports.  Imports of `__autosave__` entries are silently dropped (defensive — a bundle from another browser shouldn't overwrite the local auto-save).

- [X] T288-S3 Smoke proof in `WIP.md`: from /operate, save 3 drafts AND build twice.  Navigate /books → top of page shows `Drafts` group with TWO cards: Drafts (3 rows) and History (2 rows).  Rename one draft in place → next /operate visit shows the renamed entry in the `Drafts ▾` picker.  Click guarded trash on a History row → row turns red → confirm → entry gone.  Export all → JSON contains `books.operate_drafts: [3 entries]` AND `books.operate_history: [1 entry remaining]` (NOT including __autosave__).  Clear all books, import the JSON → both books restored.

- [X] T288-S3 Commit: `feat(288): /books Drafts group + History card + bundle import/export for operate_drafts and operate_history` with `Tasks: T288-S3` trailer.

## Dependencies

- Slice A blocks B + C.
- B and C are independent of each other once A is in.  Recommended order B → C so each slice ships a usable feature increment (B alone solves the route-loss bug AND delivers history-by-timestamp; C adds management).
