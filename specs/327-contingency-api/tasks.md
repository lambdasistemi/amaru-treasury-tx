# Tasks — /v1/build/contingency-disburse (API) (#327)

## Slice A — buildContingencyDisburseIntent (pure builder)

- [X] T327-SA1 RED: unit test asserting `buildContingencyDisburseIntent`
      exists with the documented signature (type-witness) + a
      translation test that N destinations produce an N-element
      `dapBeneficiaries` / `diDestinations`.
- [X] T327-SA2 GREEN: implement `buildContingencyDisburseIntent` in
      `Wizard/Disburse.hs` (verify Contingency ∪ destinations, resolve
      each destination treasury address, build the contingency
      DisburseAnswers list, reuse buildDisburseTx). Export the resolver
      helper from `Cli/DisburseWizard.hs` if needed.
- [X] T327-SA3 `just ci` green.

## Slice B — HTTP endpoint + wiring + tests

- [X] T327-SB1 RED: `ServerSpec` response round-trip + mapper rejection
      tests (Contingency destination rejected; empty list rejected).
- [X] T327-SB2 GREEN: `BuildContingencyDisburse.hs` (request/mapper/
      runner, reuse `DisburseBuildResponse`); wire endpoint into
      `Server.hs` + api `Main.hs`; add module to cabal.
- [X] T327-SB3 `just ci` green + live API smoke: POST a 2-destination
      contingency disburse, assert intent.json + CBOR + report present,
      fee from wallet fuel not a scope output. Record evidence in WIP.md.
