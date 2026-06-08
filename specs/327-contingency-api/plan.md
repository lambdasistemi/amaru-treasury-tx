# Plan — /v1/build/contingency-disburse (API) (#327)

Stacked on `feat/326-multidest-contingency` (HEAD f689bae8). Reuses the
#326 multi-destination intent/tx model + the contingency address
resolution already in `Cli/DisburseWizard.hs`
(`destinationScopeAddress`).

## Slices

### Slice A — `buildContingencyDisburseIntent` (pure builder)
Add to `lib/Amaru/Treasury/Wizard/Disburse.hs`, mirroring
`buildDisburseIntent` but for the contingency path:
- verify registry for `Contingency ∪ {destinations}` (not just the
  source) so destination addresses resolve;
- resolve each destination scope's treasury address from the verified
  registry (reuse `Cli.DisburseWizard.destinationScopeAddress` — export
  it if needed; Wizard already imports Cli.DisburseWizard);
- build `DisburseAnswers` with scope = Contingency, ADA, the
  `NonEmpty DisburseDestination` (one per destination), fixed rationale
  (event "disburse", label "Contingency disburse");
- reuse `buildDisburseTx` unchanged.
- Files: `lib/Amaru/Treasury/Wizard/Disburse.hs`,
  `lib/Amaru/Treasury/Cli/DisburseWizard.hs` (export the resolver
  helper if needed), `test/unit/.../Wizard/` (type-witness + a
  translation test: N destinations → N-element payload).
- Proof: unit tests; `just ci`.

### Slice B — HTTP endpoint + wiring + tests
- New `lib/Amaru/Treasury/Api/BuildContingencyDisburse.hs`:
  `ContingencyDisburseBuildRequest`, mapper (reject Contingency dest +
  empty list; ADA amounts × 1e6), `runBuildContingencyDisburse` calling
  slice-A builder + `buildDisburseTx`; reuse `DisburseBuildResponse`.
- Wire into `Server.hs` (JsonAPI, Handlers, BuildHandlers,
  mkBuildHandlers, handler, `:<|>`) and
  `app/amaru-treasury-tx-api/Main.hs`; add module to cabal.
- `ServerSpec`: stub handler field + response round-trip + mapper
  rejection tests.
- Proof: `just ci`; live API smoke (boot the api binary against devnet
  or a stub, POST a 2-destination request, assert intent.json + CBOR +
  report present). Confirm fee comes from wallet fuel, not a scope
  output.

## Notes

- The endpoint is the contract #329's frontend will POST to:
  `{ walletAddr, metadataPath, destinations: [{scope, amountAda}],
  validityHours?, description, justification }` → `DisburseBuildResponse`.
- Single destination is the N=1 case (list of one).
