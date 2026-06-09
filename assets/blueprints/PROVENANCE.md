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
