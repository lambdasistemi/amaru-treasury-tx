# Feature Specification: `/operate` form books + `/books` management route

**Feature Branch**: `267-form-books`
**Created**: 2026-05-25
**Status**: Draft (Specs review — second iteration after operator feedback on book shapes)
**Input**: Per-field history "books" on `/operate` with dedicated `/books` management route.  Two distinct book shapes: **named** (for cryptographic / identity material — operator picks a name, the value fills the field) and **free-text** (for prose — operator picks the text itself, which fills the field verbatim).

## Two book shapes

### Named books (identity / cryptographic material)

An entry is a `{ name :: String, <typed-value> :: String }` pair, where the value field name is **typed per book** to match the ecosystem convention for that material — `address` for bech32 (Lace / Eternl contact-book convention), `cid` for IPFS CIDs (IPFS Pinning Service API convention).

- The **typed value** is the load-bearing cryptographic data (a bech32 address, an IPFS CID, a key hash) — long, opaque, error-prone to type.
- The **name** is a human-readable label the operator assigns (e.g. *"Ledger wallet"*, *"CAG payee"*, *"Antithesis INV-635"*).
- The `/operate` dropdown shows **names**; picking a name substitutes the underlying typed value into the form input.
- **Standards alignment**: see FR-015 — wallet exports drop cleanly into a Lace contact-book import; IPFS exports drop cleanly into an IPFS Pinning Service `pins` array.  This is deliberate, so operators can move their booked material between tools without writing `jq`.

### Free-text books (prose)

An entry is a plain `String`.

- The text IS the thing the operator picks.  No name — the entry's own contents are the label.
- The `/operate` dropdown shows the **text**; picking substitutes the text verbatim.
- **Standards alignment**: exported as a bare JSON `Array String` — the most universal shape for "a list of strings".  No envelope, no version field per book on this side.

## Field → book mapping

| Field | Book key | Shape |
|---|---|---|
| Wallet bech32 | `wallets` | **Named** |
| Beneficiary bech32 | `wallets` | **Named** (shared book with Wallet — same address shape) |
| Reference URI (IPFS CID) | `reference_uris` | **Named** |
| Description | `descriptions` | Free-text |
| Justification | `justifications` | Free-text |
| Destination label | `destination_labels` | Free-text |
| Validity hours | `validity_hours` | Free-text |
| Slippage bps | `slippage_bps` | Free-text |
| Split count | `split_counts` | Free-text |
| Reference @type | `reference_types` | Free-text |
| Reference label | `reference_labels` | Free-text |

## User Scenarios & Testing *(mandatory)*

### User Story 1 — Operator picks a wallet by NAME from the dropdown (Priority: P1)

A treasury operator opens `/operate`, focuses the Wallet field, and sees a dropdown of friendly names — *"Ledger wallet"*, *"Mainnet hot wallet"*, *"Antithesis cold wallet"*.  They pick *"Ledger wallet"*; the Wallet input populates with the corresponding `addr1q…` bech32.  Same affordance for Beneficiary (shares the `wallets` book) and for Reference URI (`reference_uris` book — picking *"Antithesis INV-635"* fills `ipfs://bafy…`).

**Why this priority**: This is THE central UX win.  Bech32 addresses are 100+ chars; IPFS CIDs are 50+ chars; both are opaque hex / base58.  Operators today copy-paste from a separate notes app, which is the typo-and-mismatch surface.  Name → value indirection lets the operator think in domain terms ("the Antithesis invoice") and stops them ever looking at the raw value during the build.

**Independent Test**: Open `/operate`, name a wallet via `/books` (Story 3 covers the creation flow), refresh `/operate`, focus Wallet — pick the name; verify the input contains the full bech32 value.

**Acceptance Scenarios**:

1. **Given** the `wallets` book has one named entry `{ name = "Ledger", value = "addr1qABC…" }`, **When** the operator focuses the Wallet input and picks "Ledger", **Then** the input's value becomes `"addr1qABC…"`.
2. **Given** the `wallets` book is empty, **When** the operator types a fresh bech32 directly into the Wallet input and clicks Build, **Then** the input accepts the typed value (no dropdown coercion) and the value is auto-recorded as a named entry with a derived default name (truncation: `"addr1qABC…znjcrz"`).
3. **Given** the operator has previously submitted a wallet that was auto-named, **When** they later open `/books` and rename it to a friendlier label, **Then** the next visit to `/operate` shows the new name in the dropdown.
4. **Given** the operator types a value that already exists in the book (by VALUE match, not by name) and clicks Build, **Then** the entry is moved to the top of the book without being duplicated (dedup-on-value).

---

### User Story 2 — Operator picks a free-text rationale from the dropdown (Priority: P1)

The operator focuses the **Description** field (or Justification, or any free-text-booked field) and sees a dropdown of previously-submitted prose: *"Weekly USDM build"*, *"Monthly buffer top-up"*, *"Quarterly rebalance"*.  Picking one substitutes the prose verbatim.

**Why this priority**: Operators often reuse the same rationale templates verbatim across many builds (especially for routine ops).  Booking eliminates the retype.

**Independent Test**: Open `/operate`, type a description, Build (success or failure — the operator's intent still recorded the value), refresh, focus Description — the dropdown shows the typed text; picking substitutes it.

**Acceptance Scenarios**:

1. **Given** the `descriptions` book contains `["Weekly USDM build", "Monthly buffer"]`, **When** the operator focuses Description, **Then** both strings appear in the dropdown.
2. **Given** the operator types `"Weekly USDM build"` (matching an existing entry), **When** they click Build, **Then** the entry moves to the top of the book — no duplicate.
3. **Given** the operator submits an empty / whitespace-only Description, **When** the build returns, **Then** the empty value is NOT recorded.
4. **Given** the operator's build fails server-side, **When** they refresh, **Then** the submitted Description still appears in the dropdown — the value was intentionally typed; the server's rejection of the tx isn't the operator's fault.

---

### User Story 3 — Operator manages books on `/books` (Priority: P2)

Operator navigates to `/books` (topbar link alongside View / Operate).  They see one card per book, each card matching the book's shape:

- **Named books** (`wallets`, `reference_uris`): each entry shows `name | value`, with an editable name field, the **read-only** value displayed truncated (full value on hover via `title`), an `×` to delete the entry, and an `Add new` button at the bottom of the card.  To change a value, delete + re-add.
- **Free-text books** (`descriptions`, `justifications`, …): each entry shows just the text, with `×` to delete and `Clear all` at the bottom.  No `Add new` here — free-text entries arrive via build submission only.

**Why this priority**: Without a UI, the only ways to curate are (1) browser devtools editing localStorage by hand, (2) clear all site data which clobbers everything.  Operators absolutely need to rename auto-recorded wallets to meaningful names; that's the whole point of the named-book shape.

**Independent Test**: After Stories 1-2 populate books, navigate to `/books`, rename an auto-named wallet, refresh `/operate` — the dropdown shows the new name.  Click `×` on a free-text entry — refresh, dropdown no longer contains it.

**Acceptance Scenarios**:

1. **Given** the operator visits `/books`, **When** they look at the wallet card, **Then** each entry shows `name` editable + `value` displayed truncated with the full bech32 in the `title` attribute.
2. **Given** a wallet entry's name is editable, **When** the operator changes it and tabs out / clicks elsewhere, **Then** the new name is persisted (no Save button required; blur commits).
3. **Given** the operator clicks `Add new` on the wallets card, **When** the inline editor opens, **Then** they can paste a value, give it a name, and Save; the entry appears in the list and in `/operate`'s dropdown.
4. **Given** the operator clicks `×` on a single entry, **Then** that entry only is removed (no confirmation needed for single-entry removal).
5. **Given** the operator clicks `Clear all` on a free-text card, **Then** a confirmation prompt asks them to confirm; on confirm the book is emptied.
6. **Given** no books have any entries, **When** the operator visits `/books`, **Then** an empty-state caption explains that values appear after the operator submits a build, that named books can also be manually populated via `Add new`, and that books are per-browser (no cross-device sync).
7. **Given** the operator visits `/books` from `/operate`, **When** they look at the topbar, **Then** the `Books` link is marked active (`aria-current="page"`) using the same affordance as View / Operate.

---

### User Story 4 — Operator moves books between browsers via import/export (Priority: P2)

Operator wants to seed a fresh browser (or backup before clearing site data) with their existing book contents.  They visit `/books`, click `Export all` — a JSON file downloads.  On the destination browser they visit `/books`, click `Import…`, drop the JSON file (or paste its contents in the textarea), confirm the diff summary, and the books appear in the destination browser merged with whatever was already there.

**Why this priority**: Cross-device sync is out-of-scope (per the original ticket).  Export + import via JSON file (or clipboard copy/paste) is the operator-driven equivalent — they choose when to ship the books across, and the wire stays under their control (no central server, no cloud).

**Independent Test**: Populate books in browser A; export; verify the JSON file matches the on-disk shape.  In browser B (or a private window), import the file; verify `/operate`'s dropdowns now contain browser A's entries.

**Acceptance Scenarios**:

1. **Given** browser A has populated books, **When** the operator clicks `Export all`, **Then** a JSON file downloads with all books bundled (`{"version":1,"books":{…}}`).
2. **Given** a per-card export, **When** the operator clicks the card's `Export` button, **Then** a single-book JSON file downloads with that book's shape + entries.
3. **Given** an import file with conflicting entries (same value, different name in a named book), **When** the operator confirms the import, **Then** the imported entry wins (imported name overrides the local name; the underlying value is preserved).
4. **Given** an import bundle's per-book shape doesn't match (e.g. import says `wallets` is free-text but local is named), **When** the import runs, **Then** that single book is rejected with a one-line error in the dialog; other books in the bundle still merge.
5. **Given** the operator opens the `Import…` dialog, **When** they paste JSON into the textarea AND select a file, **Then** the file picker wins (textarea ignored on dual input); the dialog explains this.
6. **Given** the import would push a book over the 25-entry cap, **When** the merge runs, **Then** the oldest entries drop from the tail; the operator sees the cap behaviour reflected in the before/after diff.

---

### Edge Cases

- Operator submits a build with an empty (whitespace-only) field — no record happens (named OR free-text).
- Operator submits the 26th distinct value for a book — the oldest entry drops (FIFO at the tail, cap = 25).
- Operator types a wallet value that VALUE-matches an existing named entry but doesn't pick it from the dropdown — the entry moves to the top of the book (dedup-on-value), the entry's existing **name** is preserved.
- Operator renames a named entry to a name that already exists — same-name collision: the spec accepts duplicate names (the value is the unique key, the name is a label).  The operator can clean up via `/books` if they want.
- Operator pastes a value that doesn't pass the field's client-side validation (e.g. wallet doesn't start with `addr1`) — the field still records the (invalid) value on Build click; the typed-failure surface from #269/#277/#280 reports the validation error.  Books don't pre-validate.
- Operator opens `/operate` or `/books` in a private-browsing window — books are empty for that session; no error toast.
- localStorage quota exceeded — `record` / `clear` / `remove` no-op silently; the operator can still build.
- On-disk schema version differs from the code's current version — the on-disk value is discarded; the book starts empty.  No migration logic.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Every operator-supplied text/number input in the Field → book mapping table renders a dropdown of historical values.

- **FR-002**: Named books store entries with **per-book typed field names**:
  - `wallets`: `{ name :: String, address :: String }` (Lace / Eternl contact-book convention).
  - `reference_uris`: `{ name :: String, cid :: String }` (IPFS Pinning Service API convention).

  Free-text books store entries as plain `String`.  The dropdown always shows the human-facing field (`name` on named books, the string itself on free-text); picking substitutes the typed cryptographic field (`address` / `cid`) for named, or the string itself for free-text.

- **FR-003**: Wallet and Beneficiary inputs share the `wallets` (named) book.

- **FR-004**: On `ClickBuild` (regardless of backend response), every supplied non-empty field value is recorded to its book.  Named books record `{ name = deriveDefaultName submittedValue, <addr|cid> = submittedValue }` where `deriveDefaultName` produces a truncated `…`-marked stand-in (e.g. `"addr1qABC…znjcrz"`).  Dedup-on-typed-value: if a named entry with the same `address` (resp. `cid`) already exists, move-to-front and preserve its existing **name** rather than overwriting with the derived default.

- **FR-005**: A new `Shell.Book` module exposes:
  - `loadNamed   :: NamedBookKey   -> Effect (Array NamedEntry)`  -- `NamedEntry` is a per-book record with `name` plus the book-typed value field
  - `loadFreeText :: FreeTextBookKey -> Effect (Array String)`
  - `recordNamed   :: NamedBookKey   -> String -> Effect Unit`  -- typed-value only; auto-name on insert
  - `recordFreeText :: FreeTextBookKey -> String -> Effect Unit`
  - `renameNamed :: NamedBookKey -> String -> String -> Effect Unit` -- typed-value → new-name
  - `addNamed   :: NamedBookKey -> NamedEntry -> Effect Unit` -- manual create
  - `removeNamed   :: NamedBookKey   -> String -> Effect Unit` -- by typed value
  - `removeFreeText :: FreeTextBookKey -> String -> Effect Unit` -- by string
  - `clear         :: BookKey         -> Effect Unit` -- works on either shape

  All operations are total — they degrade to no-ops on localStorage failure.

- **FR-006**: A new `/books` route is added to the SPA router.  The topbar nav gains a third link `Books` between Operate and the theme toggle, with the same `aria-current="page"` affordance as the other links.

- **FR-007**: The `/books` page renders one card per book defined in the Field → book mapping table.  Named cards show entries as editable `name | value` rows with `×` per row and `Add new` button.  Free-text cards show entries as plain text rows with `×` per row and `Clear all` button at the bottom.

- **FR-008**: Renaming a named entry commits on blur or Enter — no Save button.  The renamed entry is reflected in `/operate`'s dropdown on the next render.  The **value** is read-only on `/books` — operators change a value by deleting the entry (`×`) and adding a fresh one via `Add new`.  Why: the value represents a real on-chain entity (a wallet, an IPFS document); silently editing it under an existing friendly name (e.g. "CAG payee" suddenly pointing at a different address) is exactly the kind of stale-state-with-trusted-label footgun named books are supposed to prevent.

- **FR-009**: `Add new` on a named card opens an inline editor with two text fields (name + value) and a Save / Cancel pair.  Save calls `addNamed`; the entry appears in the card and in `/operate`'s dropdown.

- **FR-010**: `Clear all` shows a confirmation prompt before wiping the book.  `×` on a single entry does NOT prompt.

- **FR-011**: Each book caps at 25 entries (named: 25 named-entry records; free-text: 25 strings).  Cap enforced on `record*` and `addNamed`.  The on-disk shape per book is the **wire shape** (no internal envelope) — `[ { name, address }, … ]` for `wallets`, `[ { name, cid }, … ]` for `reference_uris`, `[ "…", … ]` for free-text.  An unrecognised entry shape (missing required field, wrong primitive type) for a given book discards the entire on-disk value and resets the book to empty — no per-entry partial recovery, no migration logic.

- **FR-012**: Books that have zero entries on the `/books` page render as a placeholder card (so all booked fields are visible to the operator) rather than being hidden.

- **FR-013**: When no books have any entries, the empty-state caption on `/books` explicitly says that named books can be manually populated via `Add new` even before the operator submits a build.

- **FR-014**: `/books` exposes **import** + **export** for every book, across two transports (download/upload AND clipboard copy/paste).  Surfaces:

  - **Top-of-page actions**: `Export all` (downloads a single `amaru-treasury-books.json` containing every book) + `Copy all` (puts the same JSON on the clipboard) + `Import…` (opens a dialog with a file picker AND a textarea for paste).
  - **Per-card actions**: each card gets `Export` (downloads `<book-key>.json`) + `Copy` (clipboard).  Per-card import is not exposed — `Import…` at the top-of-page handles per-book or all-books JSON shapes.

- **FR-015**: Export JSON shapes are **standards-aligned** so per-book exports drop directly into ecosystem tools.

  **Per-book exports (bare JSON, no envelope)** — `Export` / `Copy` on a card produces:

  ```json
  // wallets (per-card export — drops into a Lace contact-book import as-is)
  [ { "name": "Ledger wallet", "address": "addr1qABC…" }, … ]

  // reference_uris (per-card export — matches the IPFS Pinning Service API `pins` array shape)
  [ { "name": "Antithesis INV-635", "cid": "bafy…" }, … ]

  // any free-text book (descriptions, justifications, …) — bare Array String
  [ "Weekly USDM build", "Monthly buffer top-up", … ]
  ```

  **All-books bundle** — `Export all` / `Copy all` produces an envelope keyed by book name, with each book's value following the per-book wire shape above:

  ```json
  {
    "kind": "amaru.book.bundle.v1",
    "books": {
      "wallets":          [ { "name": "Ledger wallet", "address": "addr1qABC…" } ],
      "reference_uris":   [ { "name": "Antithesis INV-635", "cid": "bafy…" } ],
      "descriptions":     [ "Weekly USDM build" ],
      "…":                [ … ]
    }
  }
  ```

  The `kind` discriminator (`amaru.book.bundle.v1`) lets a future v2 bundle co-exist; absent or unrecognised `kind` rejects the whole import with a one-line error.  No per-book version field — the per-book wire shape IS its schema; an entry that doesn't match (missing required field, wrong primitive type) rejects that book with a one-line error and leaves the rest of the bundle to merge.

  **Standards reference**:
  - Lace / Eternl Cardano wallet contact books use `{ name, address }` per entry.  Operators can rename `wallets.json` → `lace-contacts.json` and import it into Lace without translation.
  - IPFS Pinning Service API (https://ipfs.github.io/pinning-services-api-spec/) defines `Pin` as `{ cid, name?, origins?, meta? }`.  Our `reference_uris` shape is a subset (`{ name, cid }`) — additional unknown fields on import are silently ignored (forward-compatible).

- **FR-016**: **Import semantics**: merge (NOT replace).
  - Entries from the imported file are appended to existing books.
  - Named books dedup on the typed-value field (`address` for `wallets`, `cid` for `reference_uris`) — if an imported entry shares the typed value with an existing entry, the imported entry wins (the imported **name** replaces the local name; the typed value is unchanged).
  - Free-text books dedup on the string — duplicates from the import are skipped.
  - The 25-entry cap is enforced after merge — newest survive at the head, oldest drop at the tail.
  - **Import dispatch**: a top-level JSON object with `"kind": "amaru.book.bundle.v1"` is treated as the all-books bundle; a top-level JSON array is treated as a per-book import — the operator picks the destination book from a dropdown in the dialog (the wire shape disambiguates: array of `{name, address}` → wallets, array of `{name, cid}` → reference_uris, array of strings → any free-text book the operator selects).
  - Per-book shape mismatch (e.g. operator picks `wallets` as destination but the imported array is strings) aborts that import with a one-line error in the dialog; in a bundle import, other books in the same bundle still merge.

- **FR-017**: Import dialog surfaces a per-book before/after summary (`wallets: 3 → 5 entries`) before the operator confirms.  Cancelling at the confirm step leaves all books untouched.

- **FR-018**: Export filenames carry a UTC timestamp (`amaru-treasury-books-2026-05-25T05-30-00Z.json` and `wallets-2026-05-25T05-30-00Z.json`) so multiple exports from the same browser don't collide in the operator's downloads folder.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: An operator with 3 named wallets can pick the right one from the dropdown in < 2 seconds on a fresh page load, by name (zero exposure to the raw bech32).
- **SC-002**: Zero successful builds get blocked by a wallet typo for values that exist in the book.
- **SC-003**: The `/books` route loads in < 200 ms on the dev container against an empty network cache.
- **SC-004**: An operator can rename an auto-named wallet in < 3 clicks (focus name field → type → blur).
- **SC-005**: Build Gate green on every commit in the PR (bisect-safe).

## Assumptions

- localStorage is available; private-browsing degradation is acceptable.
- 25 entries per book is enough for ~6 months of typical operator use.
- No cross-device / cross-browser sync.
- The operator can live with the auto-name format (`addr1qABC…znjcrz`) as a default that they rename later.

## Out of Scope

- Named bundles ("recipe" templates — save 8 fields as a single named build).
- Cross-device sync (use the operator-driven import/export instead).
- Indexer-derived presets.
- Search / filter / fuzzy match on the dropdown — native HTML behaviour is enough for 25 entries.
- Encryption at rest (no secrets are booked; addresses are public).
- Selective per-book import — import is at the granularity of a whole book bundle.  The dialog can disable individual books from a multi-book import via per-book checkboxes if operators ask for it later.
