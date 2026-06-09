# Plan — #346 cardano-ledger-rdf vocab alignment

Backend (`lib/Amaru/Treasury/History/**`) + goldens. cq-rdf pinned
@27b68fc (the bumped lib). Apache Jena arq/shacl as today.

## Slice S1 — study + entity-triple migration
- Study the cardano-ledger-rdf `cardano:` vocab (the pinned 27b68fc source
  at /code/cardano-ledger-rdf) — the entity/label/identifier terms + how
  cq-rdf names address/credential/script nodes in `body` output. Record
  the term mapping in WIP.md.
- Rewrite `metadataEntityTriples`/`scopeEntities`/`entityTriples` to emit
  `cardano:`-vocab entity nodes keyed by the SAME identifier cq-rdf uses,
  carrying scope/role/label via cardano-ledger-rdf terms.
- Update `address-resolution.rq` (+ any affected query) to the new vocab.
- Golden/unit: the resolver returns the same logical rows over the unified
  graph (hermetic checks with real cq-rdf).

## Slice S2 — SHACL migration
- Rewrite `History/shapes/*.shacl.ttl` against the cardano-ledger-rdf
  vocab; validation runs over bodies + metadata entities.
- Update `runNamedHistoryShacl` wiring if shape names/targets change.
- Golden/unit for SHACL conformance.

## Proof
Per slice: `just unit` + `just golden` + hermetic
`nix build .#checks.x86_64-linux.{unit,golden}` + `nix build .#default` +
format + hlint. `just ci` before finalize.
