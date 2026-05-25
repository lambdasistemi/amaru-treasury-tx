# Tasks: `/operate` form books + `/books` management route

**Feature**: 267-form-books
**Spec**: [`spec.md`](spec.md) — **Plan**: [`plan.md`](plan.md)

Four bisect-safe slices.  Each lands as ONE commit with body trailer `Tasks: T267-S<n>`.  Worker pair: persistent driver + navigator at `%150` / `%151`.

## Slice A — `Shell.Book` foundation

- [ ] T267-S1 [US1, US2] Implement `frontend/src/Shell/Book.purs` (typed two-shape API: `BookKey` GADT-style sum discriminating named-wallets / named-reference_uris / free-text; `loadNamed` / `loadFreeText` / `recordNamed` / `recordFreeText` / `renameNamed` / `addNamed` / `removeNamed` / `removeFreeText` / `clear`).  Per-book wire shape IS storage shape (no inner envelope).  Cap=25, dedup-on-typed-value (named) / dedup-on-string (free-text), move-to-front, empty-trim silent-skip per FR-004 / FR-011 / FR-016.

- [ ] T267-S1 [US1, US2] Implement `frontend/src/Shell/Book.js` FFI for `localStorage.getItem` / `setItem` / `removeItem`.

- [ ] T267-S1 Proof: smoke recipe in `WIP.md` covering the round-trip for one named book + one free-text book + an invalid-shape on-disk value (must reset to empty).  Frontend has no test harness — documented exception per resolve-ticket protocol.

- [ ] T267-S1 Commit: `feat(267): Shell.Book — typed named/free-text per-field history persisted in localStorage` with `Tasks: T267-S1` trailer.

## Slice B — `/operate` integration

- [ ] T267-S2 [US1, US2] Extend `OperatePage.purs` State with `books :: Books`; Action with `BooksLoaded Books`; Initialize handler loads all books at mount; `ClickBuild` handler records non-empty supplied values to their books.

- [ ] T267-S2 [US1] Named-book widget for `wallets` (Wallet + Beneficiary inputs) and `reference_uris`: custom dropdown rendering each entry's `name` label, picking substitutes the typed value (`address` / `cid`) into the input.  HTML5 `<datalist>` cannot map name→value; this is a small Halogen component that renders an `<input>` paired with a click-to-open list of `<button name>` rows.

- [ ] T267-S2 [US2] Free-text fields (`descriptions`, `justifications`, `destination_labels`, `validity_hours`, `slippage_bps`, `split_counts`, `reference_types`, `reference_labels`) get an HTML5 `<datalist>` of the history strings.

- [ ] T267-S2 Smoke proof in `WIP.md`: deploy to dev host, submit a build with a wallet bech32 + a description + a reference URI; refresh; named-dropdown shows the bech32's auto-name; datalist shows the description; localStorage values match the bare-array wire shape per FR-015.

- [ ] T267-S2 Commit: `feat(267): /operate wires Shell.Book — named-book widget + free-text datalist + record on ClickBuild` with `Tasks: T267-S2` trailer.

## Slice C — `/books` route

- [ ] T267-S3 [US3] Add `books` SPA route to `Main.purs` (hash router) and a `Books` topbar link with `aria-current="page"` matching the existing View / Operate pattern.

- [ ] T267-S3 [US3] Implement `frontend/src/BooksPage.purs`: one card per book defined in the Field → book mapping table.
  - Named cards: `name | typed-value` row per entry; name editable (commit on blur / Enter); typed value read-only with `title=full-value` hover; `×` per row (no confirm); `Add new` opens inline editor with two fields.
  - Free-text cards: plain text row per entry; `×` per row; `Clear all` button at bottom with confirm prompt.
  - Empty-state card placeholder for books with zero entries.

- [ ] T267-S3 Smoke proof in `WIP.md`: deploy, populate via `/operate`, navigate `/books`, rename an auto-named wallet, refresh `/operate` — dropdown shows the new name; click `×` on a free-text entry — datalist no longer contains it.

- [ ] T267-S3 Commit: `feat(267): /books route + named & free-text card UIs (rename, add, remove, clear)` with `Tasks: T267-S3` trailer.

## Slice D — Import / Export

- [ ] T267-S4 [US4] Implement `frontend/src/BooksPage/Import.purs`:
  - `parseBundle :: Json -> Either ImportError BundlePayload` (accepts `{kind:"amaru.book.bundle.v1", books:…}`).
  - `parseBareBook :: BookKey -> Json -> Either ImportError BookPayload` (per-book wire shape).
  - `merge :: BookKey -> Books -> BookPayload -> Books` enforcing dedup + 25-cap per FR-016.
  - `diff :: Books -> Books -> Array BookDiff` for the before/after summary.

- [ ] T267-S4 [US4] Extend `BooksPage.purs` with top-of-page `Export all` + `Copy all` + `Import…`.  `Import…` opens a Halogen dialog with file picker + paste textarea + a destination-book dropdown (active only when a bare-array is detected).  Confirm step shows the per-book before/after summary; Cancel leaves state untouched.

- [ ] T267-S4 [US4] Add per-card `Export` (download `<book-key>-<UTC>.json`) + `Copy` (clipboard) buttons.  UTC-timestamped filenames per FR-018.

- [ ] T267-S4 Smoke proof in `WIP.md`: round-trip — export all, clear all books, import the file, verify content matches; export `wallets` per-card, rename the file `lace-contacts.json`, verify shape is bare `[{name, address}]` (drop-in for a Lace import attempt — actual Lace import out-of-scope to verify here, but the shape is documented).  Clipboard transport: copy all, paste into Import dialog textarea, confirm — verify merge.

- [ ] T267-S4 Commit: `feat(267): /books import/export — bundle + per-book, file + clipboard transports` with `Tasks: T267-S4` trailer.

## Dependencies

- Slice A blocks B, C, D.
- B / C / D are independent of each other once A is in.  Default execution order B → C → D for the obvious smoke flow (data needs to exist before the /books UI is meaningful, and /books needs to exist before import/export has a host).
