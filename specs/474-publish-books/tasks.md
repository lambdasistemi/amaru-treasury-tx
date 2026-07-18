# Tasks — publish canonical treasury books (issue #474)

## Slice 1 — vendor canonical journal + generated book

- [X] T001-S1 Vendor `journal/2026/metadata.json` (upstream verbatim,
      typo preserved) + `journal/README.md` provenance; generate
      `docs/assets/amaru-treasury-book.ttl` via `book-export`; verify the
      book carries the `...992f988` typo and is byte-deterministic.

## Slice 2 — book drift check in CI

- [ ] T002-S2 Add a `book` check to `nix/checks.nix` (regenerate from the
      vendored metadata, `diff -u` against the committed asset, fail
      closed); wire `.#checks.x86_64-linux.book` into `ci.yml`; extend
      `gate.sh`. Prove it fails closed on a mutated asset.

## Slice 3 — document the book URL

- [ ] T003-S3 README section + `docs/book.md` (MkDocs nav) naming the
      published book URL and its purpose.
