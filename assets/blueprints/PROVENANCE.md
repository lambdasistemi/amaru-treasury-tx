# Vendored CIP-57 blueprints — provenance

These blueprints are compiled-into-the-backend (`embedFile`) and decoded
via `Cardano.Tx.Blueprint.decodeBlueprintDataWith` (cardano-tx-tools).
They are never accepted at request time. Refresh by re-copying from the
recorded source at the recorded commit.

## treasury-spend.cip57.json
- Source: <https://github.com/pragma-org/amaru-treasury>
  `treasury-contracts/plutus.json`
- Commit: `15817e6bcd6da7121f93022508572784af94a270`
- Aiken project: `sundae/treasury-funds`. Validator
  `treasury.treasury.spend` (datum `Data`; redeemer
  `TreasurySpendRedeemer` = Reorganize | SweepTreasury | Fund | Disburse).
- This is the donor repo's committed compiled artifact (`aiken build`
  output). `aiken` is not available in this build environment, so the
  committed compiled blueprint at the pinned commit is vendored verbatim;
  it is the canonical compiled output for the deployed contracts.

## sundae-order.cip57.json
- Source: `cardano-rdf` case study at
  `docs/case-studies/2026-05-amaru-treasury/blueprints/sundae-order-typed.cip57.json`
  (the only typed SundaeSwap order blueprint on disk; the donor
  amaru-treasury repo vendors the SundaeSwap contracts as Aiken source
  only, with no compiled order blueprint checked in).
- Aiken project `sundae/contracts` ("Experimental port of SundaeSwap to
  Aiken"), compiler Aiken `v1.0.26-alpha+075668b`, plutusVersion v2.
- Typed datum `types/order/OrderDatum`
  (@pool_ident, owner, max_protocol_fee, destination, details,
  extension@) is carried by the `documentation.spend` validator. The
  sibling `order.spend` validator declares an untyped `Data` datum, so
  the typed projection selects `documentation.spend`; the `OrderDatum`
  schema matches the real on-chain SundaeSwap order datum produced by
  'Amaru.Treasury.Tx.Swap.swapOrderDatum' (verified by the projection
  golden).
