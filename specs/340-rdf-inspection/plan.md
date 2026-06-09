# Plan — #340 RDF-backed inspection

Tech: Haskell (backend lib + servant API), PureScript/Halogen (frontend).
RDF via the existing `Amaru.Treasury.History.Sparql` (Apache Jena `arq` /
`shacl`, `cq-rdf` for ledger-body triples). Datum projection via the
`cardano-tx-tools` libraries (pinned @587076b): `Cardano.Tx.Blueprint`,
`Cardano.Tx.Graph.Emit`, `Cardano.Tx.Graph.Rules.Load`, `Cardano.Tx.Rewrite`.

One PR, four bisect-safe slices. Backend slices S1–S3 touch only `lib/`,
`app/`, `test/` (disjoint from the in-flight frontend destination-card
work). S4 touches `frontend/` and is dispatched **after** the
destination-card PR merges (shared `AuditPage.purs`).

## Slice S1 — address→entity triples + resolver query (backend)
- Thread `Maybe TreasuryMetadata` into `buildHistoryLattice` (and
  `runNamedHistoryQuery` / the query handler in `Api/History.hs`).
- New `metadataEntityTriples`: emit `atx:` triples for each metadata
  entity (treasury address, owner key, permissions reward account,
  registry/scopes/treasury-script refs), reusing the `Report.Identity`
  label vocabulary.
- New `AddressResolutionQuery` constructor + `History/queries/address-
  resolution.rq` (embedded via `embedFile`); `queryNeedsBodies = False`.
- Golden: emitted-triples snapshot + resolver query rows for the pinned
  metadata.

## Slice S2 — tx-detail per-output {scope,role} + values (backend)
- Add `tdoScope`/`tdoRole` to `TxDetailOutput` (+ ToJSON + report schema
  enum if shared). Resolve each output address via the metadata address
  map (reuse `Report.Identity.resolveAddress`).
- Resolve input source addresses + values via the UTxO indexer (`apiIdx`)
  where available; keep `unknown` only when genuinely absent, but still
  carry a label when the address is known.
- Structured ADA value already present (`ValueSummary`); ensure it is
  surfaced, not stringified.
- Tests for the resolution mapping + the enriched response shape.

## Slice S3 — swap-datum projection via CIP-57 blueprint (backend)
- Embed `assets/blueprints/swap-v2-datum.cip57.json` (file-embed) + a baked
  rules file; new `Amaru.Treasury.Inspect.SwapOrderProjection` calling
  `Cardano.Tx.Blueprint.blueprintDataDecoder` (replacing / backing the
  hard-coded `SwapOrderDatum.parseSwapOrderDatum`).
- Project recipient credential, destination, min-receive/limit, scooper
  fee into the tx-detail output (structured `projectedDatum`) and through
  the graph emit, so the SPARQL view sees the decoded fields.
- Golden anchored on the `01-amaru-treasury-swap` projected shape.

## Slice S4 — frontend lenses + tx-detail rendering (frontend; after destcard PR)
- `Api.purs`: `fetchScopeHistoryQuery`/`fetchScopeHistoryShacl` +
  `ScopeHistoryQueryResponse`/`ScopeHistoryShaclResponse` record types.
- `AuditPage.purs`: lens selector (hardcoded `knownHistoryQueryNames` /
  `knownHistoryShapeNames` mirror, or a tiny `/v1/known-queries` endpoint),
  a results table, and tx-detail rows showing resolved labels + `showAda`
  amounts + projected swap fields. Reuse `Format`.
- Proof: `nix build .#frontend` + browser smoke on /audit.

## Proof per slice
Backend: `just unit` + `just golden` (new goldens) + `nix build .#default`.
Frontend: `nix build .#frontend` + browser smoke. `just ci` before finalize.
