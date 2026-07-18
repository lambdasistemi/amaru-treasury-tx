# spec — #475 Link the books and advertise the inspector in CLI and web UI

Issue: https://github.com/lambdasistemi/amaru-treasury-tx/issues/475
Epic: https://github.com/lambdasistemi/cardano-swiss-knife/issues/45
Depends on (merged): #474 — published book at
https://lambdasistemi.github.io/amaru-treasury-tx/assets/amaru-treasury-book.ttl

## P1 user story

As a co-signer asked to witness a treasury tx, I read the CLI output (or the
web UI page) for that tx and observe a pointer to the Cardano Swiss Knife
inspector and to the published treasury book, so I can independently inspect
what I am signing with names resolved.

## Canonical URLs (single-sourced)

- Inspector: `https://lambdasistemi.github.io/cardano-swiss-knife/`
- Published book: `https://lambdasistemi.github.io/amaru-treasury-tx/assets/amaru-treasury-book.ttl`
- CSK Library (where the book is imported): `https://lambdasistemi.github.io/cardano-swiss-knife/library/`

## Functional requirements

- FR-1 One CLI module holds the URLs + the co-signer pointer text. No URL
  string scatter across CLI call sites.
- FR-2 The rendered tx-build report (`report-render` Markdown) carries an
  "Independent inspection" section: inspect independently + import the book
  for named identities, with both URLs.
- FR-3 The `witness` command prints the co-signer pointer block to stderr
  (stdout stays the witness hex — pipeline-safe).
- FR-4 The `coordinate` command prints the co-signer pointer block to stderr
  (stdout stays the JSON receipt — pipeline-safe).
- FR-5 `book-export --help` mentions the published book asset URL.
- FR-6 One frontend module holds the URLs + reusable inspect/book snippets.
- FR-7 The Books page shows the canonical published book: a clearly visible
  URL with a one-click Copy and a link to the CSK Library to import it.
- FR-8 The signing-facing pages (operate + pending) carry a visible
  "Inspect with Cardano Swiss Knife" link.
- FR-9 Tests cover both surfaces per repo convention; full repo gate green.

## Non-goals

- No deep-link / auto-import protocol in csk.
- No book-generation changes.
- No redesign of the pages touched (additive only).

## Success criteria

- `report-render` on each golden envelope renders the pointer section
  (goldens regenerated, `just golden` + smoke green).
- `book-export --help` output contains the published book URL (smoke).
- `witness` stderr shows the pointer block (vault-witness smoke).
- Frontend bundle builds and `spago test` passes with the new URL asserts.
