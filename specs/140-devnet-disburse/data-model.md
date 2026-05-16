# Data Model: DevNet Disburse Slice

## DisburseDevnetRun

One local DevNet execution.

- `runDirectory`: root artifact directory.
- `phase`: `disburse`.
- `network`: expected `devnet`.
- `networkMagic`: expected local magic.
- `socket`: local node socket path.
- `status`: `passed` or typed failure.
- `timing`: epoch/slot timing summary.
- `summaryPath`: path to `disburse/summary.json`.
- `failurePath`: optional path to `disburse/failure.json`.

## DisbursePrerequisiteEvidence

Live state used before disburse artifacts are written.

- `governanceSummaryPath`: optional path to governance setup evidence.
- `withdrawSummaryPath`: optional path to withdrawal materialization
  evidence.
- `treasuryAddress`: local treasury script address.
- `treasuryUtxoBefore`: selected live treasury input reference.
- `treasuryAdaBeforeLovelace`: observed ADA at the treasury address.
- `rewardAccount`: reward account used to fund the treasury.
- `materializedWithdrawalTxIn`: withdrawal output consumed or observed
  as treasury state.

## LiveDisburseIntent

The schema-v1 disburse intent emitted from live state.

- `intentPath`: path to `disburse/intent.json`.
- `action`: `disburse`.
- `scope`: selected treasury scope.
- `unit`: `ADA` or USDM policy/token identity.
- `amount`: positive quantity in the selected unit.
- `beneficiaryAddress`: local DevNet beneficiary.
- `walletTxIn`: selected wallet fuel input.
- `treasuryTxIns`: selected treasury script inputs.
- `registryReferences`: scopes, permissions, treasury, and registry
  reference UTxOs.
- `signers`: signer names or key hashes required by the intent.
- `validityUpperBoundSlot`: live horizon-derived upper bound.

## DisburseBuildEvidence

Unsigned builder output from the live intent.

- `txBodyPath`: path to `disburse/tx-body.cbor.hex`.
- `txId`: tx body hash reported by `tx-build`.
- `reportJsonPath`: path to `disburse/report.json`.
- `reportMarkdownPath`: path to `disburse/report.md`.
- `txBuildLogPath`: path to `disburse/tx-build.log`.
- `feeLovelace`: builder fee.
- `beneficiaryOutput`: output address, unit, and amount.
- `treasuryChange`: leftover treasury value and address.
- `validityUpperBoundSlot`: copied from intent/report evidence.

## UsdmBoundaryEvidence

Explicit USDM subcase result.

- `status`: `passed`, `skipped`, or `failed`.
- `policyId`: USDM policy id when available.
- `assetName`: USDM asset name when available.
- `requestedQuantity`: requested USDM quantity.
- `observedTreasuryQuantity`: observed USDM quantity in selected
  treasury state.
- `diagnosticCode`: stable missing-token/setup code when not successful.

## DisburseDiagnostic

Typed failure artifact.

- `phase`: prerequisite, wizard, build, usdm-boundary, or docs.
- `status`: `failed`.
- `code`: stable diagnostic code.
- `message`: single-line human-readable message.
- `runDirectory`: root run path.
- `networkMagic`: expected or observed magic.
- `intentPath`: optional preserved intent path.
- `txBuildLogPath`: optional preserved build log path.
- `selectedTreasuryTxIns`: selected inputs when available.
- `selectedWalletTxIn`: selected wallet input when available.
- `artifactPaths`: paths preserved for reproduction.

## State Transitions

```text
missing-phase
  -> prerequisites-ready
  -> live-intent-written
  -> unsigned-build-written
  -> usdm-boundary-recorded
  -> evidence-ready
```

Any missing live state, stale artifact, network mismatch, token
mismatch, or build failure transitions to `failed` and writes a
`DisburseDiagnostic` instead of success evidence.
