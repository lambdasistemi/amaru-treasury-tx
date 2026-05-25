# Feature Specification: `/operate` drafts book + auto-save

**Feature Branch**: `288-operate-state-persistence`
**Issue**: [#288](https://github.com/lambdasistemi/amaru-treasury-tx/issues/288)
**Created**: 2026-05-25
**Status**: Draft

## Goal

Make /operate form work survive route navigation and page reload, and let the operator pull any past build from a chronological history to re-fire it.  Three persistence surfaces, all riding on the existing books infrastructure:

1. **Auto-save**: a hidden slot that overwrites on every form edit (debounced).  Recovers in-progress work across route swap + page reload.
2. **Drafts**: operator-named templates.  Curated, capped at 25.
3. **History**: auto-captured on every successful Build, named by timestamp, most-recent-first.  Capped at 100 entries (older drop off the tail).  Operator picks one by date → form repopulates exactly → tweak + Build a variant.

Drafts and History are two separate named books (`operate_drafts`, `operate_history`).  Both surface on /operate via dedicated `▾` pickers and on /books as cards under a top `Drafts` group.

## User Stories

### User Story 1 — Auto-save survives navigation and reload (P1)

The operator starts filling /operate (mode=Disburse, scope=network_compliance, beneficiary, amount, description, references…), clicks the `Books` topbar link to rename a wallet, clicks `Operate` to come back.  Every field is exactly as they left it.  Reloading the page (F5) does the same.

**Independent test**: open /operate, fill 5 fields, navigate to /books, come back — fields still populated.  Reload — fields still populated.  Click Build successfully — fields cleared.  Open /operate again — fresh form.

### User Story 2 — Save the current form as a named draft (P1)

The operator builds a recurring transaction (e.g. the monthly Cyber Castellum disburse).  After filling it out, they click `Save as draft…` and name it `Cyber Castellum monthly`.  Next month, they pick that name from the `Drafts ▾` picker at the top of /operate and every field fills at once.  They tweak the amount + invoice URI and click Build.

**Independent test**: with a fresh form, fill fields, click `Save as draft…`, name = `Test draft`.  Reload — pick `Test draft` from the picker — all fields restored.  Localstorage `amaru-treasury.book.operate_drafts` contains the named entry.

### User Story 3 — Manage drafts on `/books` (P1)

The operator visits `/books`, sees a new `Drafts` card (the named drafts they've created).  They rename one (operator drafts use the same `name` editing as wallets/references), delete obsolete ones with the guarded trash, export the lot to a JSON file to share with a teammate.

**Independent test**: from /books, the `Drafts` card lists every named draft.  Rename one, copy a draft's content to clipboard, delete one with guarded trash, export the bundle — verify the bundle JSON has `books.operate_drafts: [{name, snapshot}…]`.

### User Story 4 — Clean separation: auto-save slot stays out of the named-draft picker (P1)

The auto-save slot is a hidden entry — it does NOT appear in the `Drafts ▾` picker on /operate and does NOT appear as a row on /books' `Drafts` card.  Operators see only entries they've explicitly named.

**Independent test**: with a fresh form (no named drafts), type into a field, navigate to /books — `Drafts` card shows the empty-state caption.  The auto-save entry exists in localStorage (under a reserved name) but isn't surfaced anywhere.

### User Story 5 — Pull a past build from History to rebuild a variant (P1)

The operator remembers having built a similar transaction six weeks ago.  They open /operate, click the `History ▾` picker, scan the list of timestamps (most-recent-first), pick `2026-04-10 11:23:05 Z`.  Every form field repopulates from that past build.  They tweak the amount (e.g. from `400000` to `420000` USDM), update the invoice reference URI, click Build.  A fresh history entry is appended on the new successful Build.

**Independent test**: build two distinct transactions on /operate (different beneficiaries / amounts).  Each successful response appends an entry to `operate_history`.  Reload the page, click `History ▾` — the two entries are listed by timestamp, newest first.  Pick the older one — every field restores from the snapshot.  The current auto-save slot is overwritten by the restored values.

## Functional Requirements

- **FR-001**: New named book `operate_drafts` added to `Shell.Book`.  Storage key: `amaru-treasury.book.operate_drafts`.  Entry shape:

  ```json
  { "name": "Cyber Castellum monthly", "snapshot": {
      "mode": "disburse",
      "scope": "network_compliance",
      "wallet": "addr1q9...",
      "beneficiary": "addr1q8q...",
      "amountUsdm": "18750",
      "description": "Disburse 18750 USDM (CAG payee) for Cyber Castellum May 2026.",
      "justification": "Acceptance of the Cyber Castellum May 2026 cycle review.",
      "destinationLabel": "Crypto Accounting Group",
      "validityHours": "48",
      "slippageBps": "",
      "splitCount": "",
      "references": [
        { "uri": "ipfs://...", "type": "Other", "label": "..." }
      ],
      "signers": ["8bd03209..."]
  } }
  ```

  The `snapshot` field carries the entire /operate state as a nested JSON object.  Fields not relevant to the operator's current mode are still serialized (so a Disburse draft restored in Swap mode doesn't lose anything when the operator flips modes back).

- **FR-002**: A reserved `name` value `__autosave__` (double underscore prefix + suffix) identifies the auto-save slot.  The slot:
  - Is overwritten on every form field change (debounced 300 ms).
  - Is restored automatically on `Initialize` if present AND no named draft has been picked since.
  - Is NOT rendered in the `Drafts ▾` picker on /operate.
  - Is NOT rendered as a row on /books' `Drafts` card.
  - Is filtered out of `Export all` bundle exports (so the bundle JSON doesn't carry per-browser working state).
  - Is cleared (entry removed) when a successful Build response lands on /operate.

- **FR-003**: /operate gains two new top-bar affordances above the mode toggle:
  - `Drafts ▾` picker — same Halogen widget as the named-book widgets in slice B of #267, listing every entry in `operate_drafts` BY NAME (excluding `__autosave__`).  Picking a draft fills every form field from `snapshot`.
  - `Save as draft…` button — opens an inline editor (one text input + Save / Cancel) prompting for a name.  Save calls `addNamed OperateDraftsBook { name, snapshot }` with the current form's snapshot.

- **FR-004**: /books gains a new `Drafts` group at the TOP of the page (above `Identities`).  The group contains one card titled `Drafts` listing every named entry of `operate_drafts`.  Each row shows `[ name input | snapshot summary | copy | trash ]`.  The snapshot summary is a one-line preview: `mode · scope · beneficiary truncated · amount` (e.g. `disburse · network_compliance · addr1q8q…tyf4rl · 18750 USDM`).  The guarded-trash + copy + clickable-name affordances from slice E of #267 apply identically.  No `Add new` button — drafts are created via `/operate`'s `Save as draft…`.

- **FR-005**: Bundle import/export (`/books` top-of-page `Export all` / `Import…`) supports `operate_drafts` like every other book:
  - Export: `books.operate_drafts: [{ name, snapshot }, …]` (auto-save slot excluded).
  - Import: merges by `name` (dedup-on-name for drafts, NOT dedup-on-typed-value — drafts have no typed primitive).
  - The bundle's `kind` discriminator stays `amaru.book.bundle.v1`; missing key = empty list on the receiving end.

- **FR-006**: Atomic-reset (FR-011 of #267) applies: a malformed `operate_drafts` JSON in localStorage discards the whole book to empty on next load.  Snapshots whose individual fields don't match the expected primitive types are dropped from the entry's restored snapshot but the entry name survives (so an old-version snapshot can still be picked and seen as "I had something named X, please re-build it").  Actually: if any required field is missing, drop the whole entry.

- **FR-007**: On a successful Build response from the backend, /operate (a) clears the `__autosave__` slot in `operate_drafts`, AND (b) appends a fresh entry to `operate_history` named `<ISO timestamp Z>` (UTC, second-precision; e.g. `2026-05-25 14:32:08 Z`) carrying the current snapshot.  Named drafts are NOT cleared.

- **FR-008**: Saving a draft with a name that already exists overwrites the existing entry (the dedup-on-name rule for this book; consistent with `addNamed` in Shell.Book's existing semantics).  The /operate save dialog shows a one-line warning when the typed name collides: `Will overwrite existing draft '<name>'`.

- **FR-009**: New named book `operate_history` added to `Shell.Book`.  Storage key: `amaru-treasury.book.operate_history`.  Entry shape `{ name :: String, snapshot :: Json }` — same shape as `operate_drafts`; the `name` is a UTC timestamp (`YYYY-MM-DD HH:MM:SS Z`).  Cap = **100 entries** (vs drafts' 25).  Order: most-recent-first; oldest drops off the tail when the cap is exceeded.  Atomic-reset on malformed JSON (FR-006 generalises across both drafts and history).

- **FR-010**: /operate adds a `History ▾` picker next to the `Drafts ▾` picker (above the mode toggle).  Listing shows entries by `name` (timestamp).  Picking an entry restores the snapshot identically to picking a draft — same `pickedDraftName` State plumbing.  History entries are read-only from /operate's perspective; the operator never edits or saves into history directly.

- **FR-011**: /books gains an `History` card alongside the `Drafts` card under the top group.  Row shape `[ timestamp (readonly) | snapshot summary | copy | guarded trash ]` — no name editing (timestamps are content-addressable; renaming would be confusing).  Bundle import/export carries `operate_history` as a separate top-level key.  An imported `operate_history` merges by `name` (timestamp string) — duplicate timestamps from a re-imported bundle are skipped.

## Success Criteria

- **SC-001**: After filling 5+ fields on /operate, navigating to /books and back leaves every field populated.  Same after a hard reload (F5).
- **SC-002**: Saved drafts survive across browser sessions (close tab, reopen, drafts intact).
- **SC-003**: Successful Build clears the auto-save slot but NOT named drafts — operator can immediately pick a saved draft for the next build without seeing stale data from the previous one.
- **SC-004**: Every successful Build appears in `History ▾` within < 1 s of the response landing.  Operator can pick a timestamp from 6 months ago and the form repopulates with the historical snapshot in < 500 ms.
- **SC-005**: Build Gate green at HEAD.

## Out of scope

- Cross-device sync (use the bundle export/import flow).
- Per-mode-specific drafts (one drafts book, snapshot carries all fields including mode).
- Encryption at rest (no secrets in drafts; addresses + IPFS URIs are public).
- Auto-save granularity below 300 ms (faster ≈ more writes, no UX value).
- Migrating any pre-existing operator state (no operator state existed before this feature).
