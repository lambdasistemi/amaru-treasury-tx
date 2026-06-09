# Spec — Align metadata triples + SHACL to cardano-ledger-rdf vocab (#346)

## P1 user story
As an operator/auditor querying the lattice, the metadata-derived entities
(treasury addresses, owner keys, permissions reward accounts,
registry/scopes/treasury-script refs) are first-class nodes in the SAME
cardano-ledger-rdf (`cardano:`) vocabulary as the cq-rdf ledger-body
triples — so an output's address/credential node joins directly to its
metadata entity + {scope, role}, and one SHACL pass validates the unified
graph.

## Context
- Today `History/Sparql.hs` emits metadata entities as a bespoke `atx:`
  island (`atx:TreasuryEntity` with `atx:address/scope/role/label`) and
  the SHACL shapes (`History/shapes/*.shacl.ttl`) are `atx:`-namespaced.
- cq-rdf emits ledger bodies in `cardano:`
  (`https://lambdasistemi.github.io/cardano-ledger-rdf/vocab/cardano#`).
  The bumped cq-rdf (27b68fc) now also emits generic transaction-metadata
  RDF + traces vocab against the owned ontology.
- The `address-resolution` named query + others read these triples.

## Functional requirements
- FR1: Metadata entity triples emitted using cardano-ledger-rdf vocabulary
  terms (reuse the `cardano:` entity/label/identifier pattern cq-rdf +
  graph-emit already use), not bespoke `atx:TreasuryEntity`.
- FR2: Metadata entities reference the SAME node identifiers cq-rdf uses
  for the corresponding address/credential/script in the body graph, so
  resolution joins against the body graph rather than a parallel island.
- FR3: The named queries (`address-resolution.rq` + any others touching
  the migrated terms) updated to the cardano-ledger-rdf vocab; results
  unchanged in shape ({address|id, scope, role, label}).
- FR4: SHACL shapes expressed against the cardano-ledger-rdf vocabulary;
  validation runs over the unified graph (bodies + metadata entities).
- FR5: Pin/record the cardano-ledger-rdf vocab terms used (auditable;
  the lib is pinned @27b68fc).

## Decision point (driver: assess + log, Q-file if unsure)
The per-tx **history-entry** triples (`atx:HistoryEntry` — slot/scope/role
/direction) are amaru-app history metadata, not ledger facts. Decide
whether they ALSO move to a cardano-ledger-rdf-aligned term or legitimately
stay `atx:` (an amaru vocabulary extension). Default: migrate the
**entity/identity** triples + SHACL to `cardano:`; keep history-entry
triples as an amaru extension IF the cardano vocab has no faithful term —
but ensure they still join the unified graph. Record the call.

## Success criteria
- Metadata entities + SHACL in cardano-ledger-rdf vocab; resolution joins
  the body graph; queries return the same logical rows.
- Goldens refreshed (verified correct); `just ci` + hermetic checks green.

## Non-goals
- No on-chain/wizard/validator change. No new endpoints. UI unchanged
  (it renders whatever the resolver returns).
