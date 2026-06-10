# 358 — Build card Analysis group: SPARQL proofs over the built-tx graph

## P1 user story

As a treasury operator, I open the **Analysis** group of the build card and see
proofs over the unsigned tx — the resolved spend→produce, value conservation,
recipient/scope resolution, and datum/redeemer projection — so I have evidence
the tx does what I intend before signing.

## Context

#357 landed the **How**/**What** groups, the unsigned-tx TTL lattice
(`Amaru.Treasury.Api.Ttl.buildTxLattice` = prefix block +
`metadataEntityTriples` overlay + `cq-rdf body` Turtle), and a provisional
**Analysis** tab holding the existing resolved spend→produce projection
(`GraphEffect`, "very good — keep it"). This child fills the Analysis group
out with the proof suite.

The existing history SPARQL queries already run over `cq-rdf body` output:
`lib/Amaru/Treasury/History/queries/{asset-flow,address-resolution,spend-edges}.rq`
document the `cardano:` vocab. Adapt them; reuse `runArq` + TSV parse.

## Functional requirements

- FR1 — Keep the resolved spend→produce projection as the first Analysis item
  (the existing `GraphEffect` render; do NOT re-derive it in SPARQL).
- FR2 — Three new named SPARQL queries over the built-tx lattice, each
  returning columns + rows:
  - **Value conservation** — inputs (resolved) = outputs + fee, per asset.
    Requires extending the lattice with resolved-input value triples (from
    `snapshotUtxosByTxIn`), emitted in the same `cardano:` value vocab the
    output triples use, so a single SPARQL sums both sides.
  - **Recipient / scope resolution** — every output address/credential
    resolved to its treasury `{scope, role}` (or `external`). Adapt
    `address-resolution.rq` + the `metadataEntityTriples` overlay.
  - **Datum / redeemer projection** — decoded datum/redeemer rows. Inspect
    what `cq-rdf body` emits for datums/redeemers (read the existing body
    Turtle / shapes) and query accordingly; if a field is not in the body
    graph, note the limitation rather than fabricate it.
- FR3 — Build responses carry the proof results (name + columns + rows per
  query), reusing the `HistoryQueryResult`-style {columns, rows} shape.
- FR4 — `/operate` Analysis group renders spend→produce + the three proof
  tables; the standalone provisional Analysis tab from #357 is replaced by
  this suite.

## Success criteria

- `nix build .#frontend .#amaru-treasury-tx-api` + golden/unit/smoke green.
- Dev smoke: build a tx; Analysis shows spend→produce + 3 proofs returning
  rows; value-conservation balances; recipients resolve to scope/role.

## Non-goals

- Operator-editable / free-form SPARQL (the queries are hardcoded).
- SHACL validation surface.
- Any tx-building / submission change. Build-only.
