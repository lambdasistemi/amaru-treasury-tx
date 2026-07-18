# Spec — publish canonical treasury books as repo assets (issue #474)

## P1 user story

As a treasury actor, I copy the published book URL from this repo and
import it in the Cardano Swiss Knife Library via "Book URL", and observe
the Amaru treasury book load with its parts counted, live from the
published location.

## Canonical source (provenance)

The book is generated from a **vendored copy of the upstream journal
metadata**, not the repo test fixture:

- Upstream: `pragma-org/amaru-treasury`, path `journal/2026/metadata.json`.
- Pinned commit `15817e6bcd6da7121f93022508572784af94a270` (on `main`);
  last upstream change to the file at
  `99600d8cedf0e3c4894fe7f45d5e8abad2289d76` (2026-05-01).
- Vendored verbatim at `journal/2026/metadata.json`
  (sha256 `921f0f8dc2c219826ffb02eea2ec37d1fda70623dab35e9f30537b2ada919145`).

The repo's `test/fixtures/metadata.json` is a **different, corrected**
copy used only for golden tests — it is NOT the real journal. The known
upstream `registry_script.hash` typo (contingency scope,
`...992f988`, one nibble short of the on-chain `...992f9888`) is
**preserved faithfully** in the vendored copy and the generated book: the
resolution book mirrors the canonical journal and does not silently
correct source data.

## Functional requirements

- **FR-001** Vendor the canonical journal metadata with written provenance
  and the typo preserved.
- **FR-002** Generate `docs/assets/amaru-treasury-book.ttl` deterministically
  from the vendored metadata via the shipped `book-export` verb.
- **FR-003** CI drift check regenerates the book from the vendored metadata
  and fails closed if the committed asset diverges from regeneration.
- **FR-004** The book is published at a stable HTTPS URL a browser can fetch
  cross-origin: GitHub Pages of this repo,
  `https://lambdasistemi.github.io/amaru-treasury-tx/assets/amaru-treasury-book.ttl`
  (served by the existing "Build and deploy documentation" workflow with
  `access-control-allow-origin: *`; same-origin with the csk Library at
  `https://lambdasistemi.github.io/cardano-swiss-knife/`).
- **FR-005** README documents the book URL and its purpose.

## Success criteria

- `nix build .#checks.x86_64-linux.book` (drift check) is green and fails
  closed on a mutated asset.
- Importing the published (or PR-preview) URL in the csk Library "Book URL"
  input loads the Amaru treasury book with its parts counted — live proof
  in the PR body.

## Non-goals

No CLI/webUI link surfaces (sibling ticket); no csk changes; no indexer
data in the book; no overlay-vocabulary changes.
