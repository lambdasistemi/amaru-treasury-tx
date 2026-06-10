# 357 — Build card phases (How / What) + unsigned-tx TTL emit

## P1 user story

As a treasury operator building a tx in `/operate`, I see the build result
organised as **How** (intent.json, CLI, report) and **What** (CBOR + TTL),
and I can inspect the unsigned tx as RDF Turtle.

## Context

Today the build-result card is five flat tabs:
`intent.json | CLI | CBOR | Report | Graph`. The "Graph" tab is mislabelled —
it is a resolved spend→produce projection, not a graph. The honest
"what we built" view is the **CBOR** (wire bytes) + the **TTL** (the same tx
as RDF). This child re-groups the card into **How** and **What** and adds
the TTL. The **Analysis** group (SPARQL proofs) is child #358; the existing
spend→produce projection survives as a provisional Analysis tab here.

## Functional requirements

- FR1 — Build responses (disburse, swap, contingency-disburse, reorganize)
  carry a new `ttl` field: the unsigned tx serialised to RDF Turtle.
- FR2 — TTL is produced by shelling out to `cq-rdf body <cbor-file>` on the
  built tx CBOR, NOT by importing `Cardano.Tx.Graph.Emit` (module clash with
  `Cardano.Tx.*`, see cabal.project). Mirror `History.Sparql.entryBodyTurtle`.
- FR3 — A `buildTxLattice` helper assembles: prefix block (reuse the
  `historyMetadataTurtle` prefix lines) + `metadataEntityTriples md` +
  the `cq-rdf body` Turtle. This function + prefix vocab is the agreement
  surface #358 extends.
- FR4 — `/operate` card renders two labelled groups:
  **How** = {intent.json, CLI, report}; **What** = {CBOR, TTL}.
- FR5 — The spend→produce projection remains reachable as a provisional
  **Analysis** tab (re-homed in #358).

## Success criteria

- `nix build .#frontend .#amaru-treasury-tx-api` green; golden/unit/smoke green.
- Dev smoke: build a tx in `/operate`; How/What groups render; TTL tab shows
  non-empty Turtle for the built tx.

## Non-goals

- The four SPARQL proofs + Analysis group (#358).
- Any tx-building / balancing / submission change. Build-only.
- Bespoke CSS beyond existing card markup + Material tokens.
