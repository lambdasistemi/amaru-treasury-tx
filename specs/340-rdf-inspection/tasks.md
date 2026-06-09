# Tasks — #340

## Slice S1 — address→entity triples + resolver query (backend)
- [X] T340-S1a Thread `Maybe TreasuryMetadata` into `buildHistoryLattice` + `runNamedHistoryQuery` + `Api/History.hs` query path.
- [X] T340-S1b `metadataEntityTriples`: emit address→entity triples (treasury addr, owner key, permissions reward account, registry/scopes/treasury-script refs) using `Report.Identity` label vocab.
- [X] T340-S1c `AddressResolutionQuery` constructor + `History/queries/address-resolution.rq` (embedFile) + parse/render names + `queryNeedsBodies=False`.
- [X] T340-S1d Golden: emitted-triples snapshot + resolver rows for pinned metadata. `just unit golden` + `nix build .#default`.

## Slice S2 — tx-detail per-output {scope,role} + values (backend)
- [X] T340-S2a Add `tdoScope`/`tdoRole` to `TxDetailOutput` (+ ToJSON + schema asset regen).
- [X] T340-S2b Resolve each output address → {scope, role} via metadata map (reuse `Report.Identity`).
- [ ] T340-S2c Resolve input source addresses + values via the UTxO indexer (`apiIdx`) where available; label known addresses even when value absent. — DEFERRED: inputs are txin refs; labelling needs a UTxO-by-txin lookup (follow-up).
- [X] T340-S2d Tests for resolution mapping + enriched `/v1/tx/{txid}` shape. `just unit golden` + `nix build .#default`.

## Slice S3 — SundaeSwap order datum projection via CIP-57 blueprint (backend)
Decision A-S3-001: use the REAL typed `sundae/contracts` blueprint (order.spend datum), not the toy fixture.
- [X] T340-S3a Vendor + embed the real `sundae-order-typed.cip57.json` (order.spend) into `assets/blueprints/` with provenance recorded; add `cardano-tx-tools` lib dep; new `Inspect.SwapOrderProjection` over `Cardano.Tx.Blueprint`.
- [X] T340-S3b Project recipient/destination/min-receive/scooper-fee into the swap-order tx-detail output (structured `projectedDatum`).
- [X] T340-S3c Golden anchored on a real amaru swap order datum → expected projected fields. `just unit golden` + `nix build .#default`.

## Slice S3b — amaru treasury datum/redeemer projection via CIP-57 blueprint (backend)
Decision A-S3-001: also embed amaru's own treasury validator blueprint.
- [X] T340-S3b-a Vendor + embed the donor `treasury.treasury.spend` blueprint (from `/code/amaru-treasury/treasury-contracts/plutus.json` @15817e6) into `assets/blueprints/` with provenance recorded.
- [X] T340-S3b-b Project the treasury datum + redeemer (Reorganize/SweepTreasury/Fund/Disburse) onto the tx-detail treasury fields via the same `Cardano.Tx.Blueprint` engine.
- [X] T340-S3b-c Golden anchored on a real treasury tx (e.g. a Disburse) → expected decoded redeemer/datum. `just unit golden` + `nix build .#default`.

## Slice S4 — frontend lenses + tx-detail rendering (after destcard PR merges)
- [ ] T340-S4a `Api.purs`: `fetchScopeHistoryQuery`/`fetchScopeHistoryShacl` + response record types.
- [ ] T340-S4b `AuditPage.purs`: lens selector (known queries/shapes) + results table.
- [ ] T340-S4c tx-detail panel: resolved labels + `showAda` amounts + projected swap fields (reuse `Format`).
- [ ] T340-S4d `nix build .#frontend` + browser smoke on /audit.
