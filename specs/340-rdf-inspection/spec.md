# Spec — RDF-backed inspection: address resolution + swap-datum projection (#340)

## P1 user story

As a treasury operator inspecting a transaction, I see each input and
output labelled by what it IS — "contingency treasury (leftover)",
"network_compliance treasury", "operator wallet (change)" — derived from
the knowledge graph, instead of raw 56-char hashes; swap order outputs
show the decoded `SwapOrder` (recipient, min-receive, scooper fee) instead
of a raw datum blob; and I can run the backend's named SPARQL queries /
SHACL shapes as analysis lenses from the Audit page.

## Architecture invariant (per operator, non-negotiable)

Address resolution + swap-datum projection are **hardcoded SPARQL/rules
over the RDF graph, compiled into the backend**. The CIP-57 blueprints +
collapse/rewrite rules are **file-embedded** (Template Haskell /
`file-embed`), never passed at request time. The inspection endpoints
return already-projected, resolved JSON. The **frontend runs no SPARQL,
carries no rules** — it is a thin renderer that may pick among the
backend's known named queries/shapes by name.

## Functional requirements

### Backend — graph + resolution
- FR1: `buildHistoryLattice` emits metadata-derived `address → entity`
  triples for every known address: per-scope treasury address, scope
  owner key, permissions reward account, registry/scopes/treasury script
  refs. Source = verified `TreasuryMetadata`.
- FR2: A baked named query (`AddressResolutionQuery` in `HistoryQueryName`,
  text under `History/queries`, embedded) resolves an address →
  `{scope, role}` over the graph. `role ∈ {treasury, owner,
  permissions.reward_account, registry, scopes, treasury-script,
  external, operator-wallet}`.
- FR3: `/v1/tx/{txid}` carries a resolved `{scope, role}` label per output
  (no `scope: null`), and per input where the UTxO indexer has the source
  address; output `value` is structured + ADA-denominated (already
  `ValueSummary`); input `value` resolved where available, labelled
  `unknown` only when genuinely absent.

### Backend — swap-datum projection
- FR4: Swap order outputs/inputs are **datum-projected**, not raw: the
  decoded `SwapOrder` fields (recipient credential, destination,
  min-receive/limit, scooper fee) appear as named, labelled values —
  decoded against the embedded `swap-v2-datum.cip57.json` CIP-57 blueprint
  using the cardano-tx-tools `Cardano.Tx.Blueprint` / graph-emit engine.
- FR5: Projection runs through the RDF/graph layer (the `045` graph emit +
  SPARQL view) so address resolution AND datum projection share one
  engine; the same blueprint/rules drive both `/v1/tx/{txid}` and
  `/v1/scope/{scope}/txs/query`.

### Frontend — Audit / inspection (thin renderer)
- FR6: `Api.purs` gains `fetchScopeHistoryQuery` (named SPARQL) +
  `fetchScopeHistoryShacl` clients.
- FR7: The Audit page offers `knownHistoryQueryNames` as selectable lenses
  and runs `knownHistoryShapeNames` as integrity checks, rendering results
  with resolved labels (reusing the #338 `Format` helpers).
- FR8: The tx-detail panel shows resolved input/output labels + ADA
  amounts + projected swap-order fields (no raw `scope: null` /
  `value: unknown` / raw datum hash).

## Success criteria
- A real treasury tx inspected via `/v1/tx/{txid}` shows scope/role labels
  on outputs and a decoded SwapOrder on swap outputs.
- The Audit page lens selector runs each named query/shape and renders the
  labelled result.
- Golden tests cover the resolver query output and the swap-datum
  projection (anchored on the `01-amaru-treasury-swap` shape).
- `just ci` green; CI green.

## Non-goals
- No change to on-chain tx building / the wizard / the validator.
- No new indexer interest-set scope (reuse the existing per-scope graph).
- No client-side SPARQL or runtime-passed rules/blueprints.
