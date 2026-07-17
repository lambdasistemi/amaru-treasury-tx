# Spec — book-export verb (issue #472)

## P1 user story

As an operator, I run

```
amaru-treasury-tx book-export --metadata journal/2026/metadata.json --out amaru-book.ttl
```

and observe a Turtle overlay book naming the scope owners, treasury
addresses, and scripts, which the cardano-swiss-knife Library imports as a
resolution book.

## Contract (agreement surface)

`docs/book-interchange.md` in cardano-swiss-knife, pinned at
`5ca7dd9f60c8bd1609e5548574b18fffb1bf09cc` (branch
`feat/40-book-import-bundle`). Output is **form (1)**: Turtle overlay text
with the canonical prefixes and the existing overlay classes.

Canonical prefixes (verbatim from the contract):

```turtle
@prefix cardano: <https://lambdasistemi.github.io/cardano-ledger-rdf/vocab/cardano#> .
@prefix rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#> .
@prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#> .
@prefix overlay: <https://lambdasistemi.github.io/cardano-ledger-inspector/overlay/amaru-treasury#> .
```

Entity block shapes:

| Entity | Subject IRI | Class | Predicates |
| --- | --- | --- | --- |
| Scope owner key hash | `urn:cardano:id:key:<hash>` | `overlay:Owner` | `rdfs:label` |
| Treasury address | `urn:cardano:id:address:<bech32>` | `overlay:Address` | `rdfs:label`, `cardano:bech32` |
| Script hash | `urn:cardano:id:script:<hash>` | `overlay:CardanoScript` | `rdfs:label` |

The `key`/`address` subject IRIs and the `Owner`/`Address` blocks are taken
verbatim from the contract. Scripts have no block documented in the contract
text, so they use the **existing** overlay vocabulary the Library itself
emits for the Amaru journal (`docs/inspector/src/FFI/OverlayBook.js`:
`<urn:cardano:id:script:<hash>> a overlay:CardanoScript`). No overlay
vocabulary is added or redesigned. Labels mirror the repo's own identity
convention (`Amaru.Treasury.Report.Identity` /
`Amaru.Treasury.History.Sparql` — `"<scope> scope owner"`, `"<scope>
treasury"`), which already matches the contract's example label style.

## Functional requirements

- **FR-001** `book-export` subcommand: `--metadata PATH` (required), `--out
  PATH` (optional, stdout default, `-` = stdout), `--scope NAME` (optional).
- **FR-002** Emits, for every scope in the metadata (declaration order):
  the scope-owner key hash (when present — Contingency has none), the
  treasury address, and the treasury / permissions / registry script hashes.
- **FR-003** `--scope NAME` restricts the book to that one scope; an unknown
  name is rejected at parse time by the existing `scopeFromText`.
- **FR-004** Output is deterministic Turtle: canonical prefix block, then one
  block per entity separated by a blank line, terminating with a newline.

## Success criteria

- Golden test pins the exported Turtle for the checked-in metadata fixture
  (`test/fixtures/metadata.json`), both full-book and `--scope` variants.
- The built verb produces the golden byte-for-byte against the fixture.
- Repo gate green (`./gate.sh`).

## Non-goals

No indexer/history export; no book import into amaru-treasury-tx; no changes
to existing verbs or wire formats; no overlay vocabulary changes.
