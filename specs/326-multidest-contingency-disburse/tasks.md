# Tasks — Multi-destination contingency disburse (#326)

## Slice A — Typed ADA intent + tx-build carry a destination list

- [X] T326-SA1 RED: golden CBOR fixture for a 2-destination ADA disburse
      (3 outputs: leftover + 2 beneficiaries) and a unit test asserting
      redeemer `amount` = Σ and leftover = input − Σ; assert existing
      single-destination golden is unchanged.
- [X] T326-SA2 GREEN: lift `DisburseAdaPayload` + the ADA arm of
      `disburseToTreasuryIntent` / `resolveDisburseEnvIC` to a non-empty
      beneficiary list; loop `payTo` in `disburseAdaProgram`; redeemer
      `amount` = Σ; leftover = input − Σ; intent JSON schema carries the
      list. Single-destination callers pass singletons.
- [X] T326-SA3 Regenerate goldens; confirm N=1 byte-identical; `just ci`
      green.

## Slice B — contingency-disburse-wizard repeatable destinations

- [X] T326-SB1 RED: parser unit tests — repeatable `--to <scope>:<ada>`
      accumulates; rejects `Contingency`; rejects empty set; malformed
      `scope:ada` errors.
- [X] T326-SB2 GREEN: `ContingencyDisburseOpts` + parser gain repeatable
      `--to`; `runContingencyDisburse` resolves each destination address
      from verified metadata, builds the beneficiary list, verifies
      Contingency ∪ destinations.
- [X] T326-SB3 `just ci` green; manual: wizard writes a 3-output
      unsigned intent for `--to a:100 --to b:50`.

## Slice C — Devnet 2-destination proof

- [X] T326-SC1 RED: devnet spec that builds + submits a 2-destination
      contingency disburse (mirrors `DisburseSubmitSpec`), expected to
      fail until wired.
- [X] T326-SC2 GREEN: spec passes — tx accepted on the local devnet
      node; cabal `other-modules` updated.
- [X] T326-SC3 Devnet test target green; record the submitted txid in
      `WIP.md`.
