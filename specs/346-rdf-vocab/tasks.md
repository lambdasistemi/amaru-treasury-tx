# Tasks — #346

## Slice S1 — entity-triple migration to cardano-ledger-rdf vocab
- [X] T346-S1a Study cardano-ledger-rdf `cardano:` vocab (@27b68fc) + cq-rdf body node identifiers; record term mapping + the history-entry decision in WIP.md.
- [X] T346-S1b Rewrite metadataEntityTriples/scopeEntities to `cardano:` entity nodes keyed by cq-rdf's identifiers (join the body graph), carrying scope/role/label.
- [X] T346-S1c Update `address-resolution.rq` (+ affected queries) to the new vocab; resolver returns same logical rows.
- [X] T346-S1d Goldens/unit (hermetic checks, real cq-rdf) + nix build .#default green.

## Slice S2 — SHACL migration
- [X] T346-S2a Rewrite History/shapes/*.shacl.ttl against cardano-ledger-rdf vocab; validate the unified graph.
- [X] T346-S2b Update runNamedHistoryShacl wiring if shape targets/names change.
- [X] T346-S2c Goldens/unit for SHACL conformance; just ci + hermetic checks green.
