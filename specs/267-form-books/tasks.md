# Tasks: `/operate` form books + `/books` management route

**Feature**: 267-form-books
**Spec**: [`spec.md`](spec.md) — **Plan**: [`plan.md`](plan.md)

Four bisect-safe slices.  Each lands as ONE commit with body trailer `Tasks: T267-S<n>`.  Worker pair: persistent driver + navigator at `%150` / `%151`.

## Slice A — `Shell.Book` foundation

- [X] T267-S1 [US1, US2] Implement `frontend/src/Shell/Book.purs` (typed two-shape API: `BookKey` GADT-style sum discriminating named-wallets / named-reference_uris / free-text; `loadNamed` / `loadFreeText` / `recordNamed` / `recordFreeText` / `renameNamed` / `addNamed` / `removeNamed` / `removeFreeText` / `clear`).  Per-book wire shape IS storage shape (no inner envelope).  Cap=25, dedup-on-typed-value (named) / dedup-on-string (free-text), move-to-front, empty-trim silent-skip per FR-004 / FR-011 / FR-016.

- [X] T267-S1 [US1, US2] Implement `frontend/src/Shell/Book.js` FFI for `localStorage.getItem` / `setItem` / `removeItem`.

- [X] T267-S1 Proof: smoke recipe in `WIP.md` covering the round-trip for one named book + one free-text book + an invalid-shape on-disk value (must reset to empty).  Frontend has no test harness — documented exception per resolve-ticket protocol.

- [X] T267-S1 Commit: `feat(267): Shell.Book — typed named/free-text per-field history persisted in localStorage` with `Tasks: T267-S1` trailer.

## Slice B — `/operate` integration

- [X] T267-S2 [US1, US2] Extend `OperatePage.purs` State with `books :: Books`; Action with `BooksLoaded Books`; Initialize handler loads all books at mount; `ClickBuild` handler records non-empty supplied values to their books.

- [X] T267-S2 [US1] Named-book widget for `wallets` (Wallet + Beneficiary inputs) and `reference_uris`: custom dropdown rendering each entry's `name` label, picking substitutes the typed value (`address` / `cid`) into the input.  HTML5 `<datalist>` cannot map name→value; this is a small Halogen component that renders an `<input>` paired with a click-to-open list of `<button name>` rows.

- [X] T267-S2 [US2] Free-text fields (`descriptions`, `justifications`, `destination_labels`, `validity_hours`, `slippage_bps`, `split_counts`, `reference_types`, `reference_labels`) get an HTML5 `<datalist>` of the history strings.

- [X] T267-S2 Smoke proof in `WIP.md`: deploy to dev host, submit a build with a wallet bech32 + a description + a reference URI; refresh; named-dropdown shows the bech32's auto-name; datalist shows the description; localStorage values match the bare-array wire shape per FR-015.

- [X] T267-S2 Commit: `feat(267): /operate wires Shell.Book — named-book widget + free-text datalist + record on ClickBuild` with `Tasks: T267-S2` trailer.

## Slice C — `/books` route

- [X] T267-S3 [US3] Add `books` SPA route to `Main.purs` (hash router) and a `Books` topbar link with `aria-current="page"` matching the existing View / Operate pattern.

- [X] T267-S3 [US3] Implement `frontend/src/BooksPage.purs`: one card per book defined in the Field → book mapping table.
  - Named cards: `name | typed-value` row per entry; name editable (commit on blur / Enter); typed value read-only with `title=full-value` hover; `×` per row (no confirm); `Add new` opens inline editor with two fields.
  - Free-text cards: plain text row per entry; `×` per row; `Clear all` button at bottom with confirm prompt.
  - Empty-state card placeholder for books with zero entries.

- [X] T267-S3 Smoke proof in `WIP.md`: deploy, populate via `/operate`, navigate `/books`, rename an auto-named wallet, refresh `/operate` — dropdown shows the new name; click `×` on a free-text entry — datalist no longer contains it.

- [X] T267-S3 Commit: `feat(267): /books route + named & free-text card UIs (rename, add, remove, clear)` with `Tasks: T267-S3` trailer.

## Slice D — Import / Export

- [X] T267-S4 [US4] Implement `frontend/src/BooksPage/Import.purs`:
  - `parseBundle :: Json -> Either ImportError BundlePayload` (accepts `{kind:"amaru.book.bundle.v1", books:…}`).
  - `parseBareBook :: BookKey -> Json -> Either ImportError BookPayload` (per-book wire shape).
  - `merge :: BookKey -> Books -> BookPayload -> Books` enforcing dedup + 25-cap per FR-016.
  - `diff :: Books -> Books -> Array BookDiff` for the before/after summary.

- [X] T267-S4 [US4] Extend `BooksPage.purs` with top-of-page `Export all` + `Copy all` + `Import…`.  `Import…` opens a Halogen dialog with file picker + paste textarea + a destination-book dropdown (active only when a bare-array is detected).  Confirm step shows the per-book before/after summary; Cancel leaves state untouched.

- [X] T267-S4 [US4] Add per-card `Export` (download `<book-key>-<UTC>.json`) + `Copy` (clipboard) buttons.  UTC-timestamped filenames per FR-018.

- [X] T267-S4 Smoke proof in `WIP.md`: round-trip — export all, clear all books, import the file, verify content matches; export `wallets` per-card, rename the file `lace-contacts.json`, verify shape is bare `[{name, address}]` (drop-in for a Lace import attempt — actual Lace import out-of-scope to verify here, but the shape is documented).  Clipboard transport: copy all, paste into Import dialog textarea, confirm — verify merge.

- [X] T267-S4 Commit: `feat(267): /books import/export — bundle + per-book, file + clipboard transports` with `Tasks: T267-S4` trailer.

## Slice E — `/books` row polish

Operator-side feedback after the four shipping slices merged: the per-row `×` is unclear, addresses should link out, every value should be one-tap copyable, and accidental clicks on the trash should be impossible.

- [X] T267-S5 [US3] Replace the `×` text glyph on every entry row (named + free-text) with a Material trash icon-button (`<md-icon-button><md-icon>delete</md-icon></md-icon-button>`) carrying `aria-label="Remove …"` for screen readers.

- [X] T267-S5 [US3] Guard the per-row delete — clicking the trash icon flips the row into an inline confirm state (red-tinted background, `check` + `close` icon-buttons in place of the trash).  `check` actually removes; `close` reverts.  No modal; the operator stays on the same scroll position.  State extension: `confirmingRemove :: Maybe RemoveTarget` plus `RequestRemove` / `ConfirmRemove` / `CancelRemove` actions.

- [X] T267-S5 [US3] Add a copy icon-button (`content_copy`) between the value cell and the trash on every row.  Named rows copy the typed value (`address` / `cid`); free-text rows copy the string.  After a successful copy the icon flips to `check` for ~1 s then reverts — a snackbar-free "copied!" affordance.

- [X] T267-S5 [US3] Linkify the typed-value cell on named rows: `wallets` → `https://cardanoscan.io/address/<bech32>`; `reference_uris` → `https://ipfs.io/ipfs/<cid>` when the value is a bare CID, or the value's own URL when it already carries an `ipfs://` / `http(s)://` scheme.  `<a target="_blank" rel="noopener noreferrer">`.  Truncated display + `title=full` stay.  Free-text rows are NOT linkified.

- [X] T267-S5 [US3] Promote `_writeClipboard` out of `BooksPage.js` into `Shell/Clipboard.purs` + `Shell/Clipboard.js` so the copy button can reuse the FFI without re-declaring the foreign import.

- [X] T267-S5 Amend `spec.md` in the SAME commit: FR-007 (icon-button + copy + clickable typed values), FR-008 (read-only typed-value link — change typed value via delete + re-add), FR-010 (per-entry trash is guarded; `Clear all` keeps its existing confirm).

- [X] T267-S5 Smoke proof in `WIP.md`: deploy, plant a wallet + a description, navigate `/books`; confirm icon trash visible (not `×`), guarded delete (cancel keeps entry, confirm removes), copy button copies the typed value + flashes `check`, wallet `<a>` carries Cardanoscan href + `target="_blank"`, reference URI `<a>` carries the IPFS gateway href.

- [X] T267-S5 Commit: `feat(267): /books row polish — icon trash (guarded), copy, clickable typed values` with `Tasks: T267-S5` trailer.

## Slice F — `/books` semantic grouping

Operator-side feedback after slice E: the flat list of ten cards reads as a "mess".  Group cards by how operators actually cluster the fields when authoring a build.

- [X] T267-S6 [US3] Introduce a `BooksGroup` enum (`Identities` / `References` / `RationaleText` / `BuildParameters`) plus a `groupContents :: BooksGroup -> Array BookKey` taxonomy in `frontend/src/BooksPage.purs`.  Iterate `allGroups` in render order, emit one `<h2 class="md-typescale-title-large books-group">` per group, then dispatch each card via the existing per-card render path (`namedCard` / `freeTextCard`).

- [X] T267-S6 [US3] Card order under each group: **Identities** → `wallets`; **References** → `reference_uris`, `reference_types`, `reference_labels`; **Rationale text** → `descriptions`, `justifications`, `destination_labels`; **Build parameters** → `validity_hours`, `slippage_bps`, `split_counts`.  Per-card render path (rows, copy / guarded trash, link wraps, Add new, Clear all, per-card export/copy) stays byte-identical to slice E.

- [X] T267-S6 [US3] Empty-state top-of-page notice (FR-013) stays at the TOP, above the first group header.

- [X] T267-S6 Amend `spec.md` FR-007 in the SAME commit to mention the grouping and the fixed order.

- [X] T267-S6 Smoke proof in `WIP.md`: deploy, navigate `/books`; verify four `h2.books-group` headers in DOM order (`Identities`, `References`, `Rationale text`, `Build parameters`); verify each group's cards are in the spec order; verify the empty-state caption precedes the first group header; verify one row's slice-E affordances (copy, link href, guarded trash) still work in the grouped layout.

- [X] T267-S6 Commit: `feat(267): /books — group cards by semantics (Identities, References, Rationale, Build parameters)` with `Tasks: T267-S6` trailer.

## Dependencies

- Slice A blocks B, C, D.
- B / C / D are independent of each other once A is in.  Default execution order B → C → D for the obvious smoke flow (data needs to exist before the /books UI is meaningful, and /books needs to exist before import/export has a host).
- Slice E lands after the original four are merged, on a re-opened draft of the same PR (polish).
