# Data Model: DevNet Swap Contract Readiness Slice

## SwapReadinessRun

One local DevNet execution.

- `runDirectory`: root run path.
- `phase`: `swap-ready`.
- `status`: `passed` or `failed`.
- `network`: `devnet`.
- `networkMagic`: expected local magic.
- `socket`: local node socket path.
- `timing`: epoch/slot timing summary.
- `registryPath`: path to `swap-ready/registry.json`.
- `summaryPath`: path to `swap-ready/summary.json`.
- `failurePath`: optional path to `swap-ready/failure.json`.

## SundaeOrderValidatorArtifact

The public validator identity accepted as compatibility evidence.

- `sourceRepository`: upstream repository URL.
- `sourceCommit`: upstream commit used for the compiled artifact.
- `validatorTitle`: expected `order.spend`.
- `compiledCodeHash`: hash of the checked-in compiled artifact.
- `scriptHash`: order-validator payment script hash.
- `mainnetReference`: optional known mainnet reference UTxO for audit
  comparison only.
- `fixtureOnly`: boolean; must be false for successful compatibility
  evidence.

## SwapReferencePublication

The local DevNet reference-script UTxO.

- `referenceTxIn`: local `TxId#Ix`.
- `address`: DevNet order-validator script address or agreed reference
  holding address.
- `scriptHash`: observed reference script hash.
- `publishedAtSlot`: optional slot from the ledger snapshot after
  publication.
- `sourceArtifact`: link to the validator artifact record.

## SwapReadinessRegistry

Machine-readable handoff consumed by #84.

- `schemaVersion`: starts at `1`.
- `network`: `devnet`.
- `networkMagic`: local node magic.
- `orderValidator`: `SundaeOrderValidatorArtifact`.
- `orderReference`: `SwapReferencePublication`.
- `orderBuildInputs`: minimal data #84 needs to resolve the order
  validator without fake constants.
- `provenance`: upstream source and local run context.

## SwapReadinessDiagnostic

Typed failure artifact.

- `phase`: `swap-ready`.
- `status`: `failed`.
- `code`: stable diagnostic code.
- `message`: human-readable diagnostic.
- `runDirectory`: root run path.
- `networkMagic`: observed or expected magic.
- `expectedScriptHash`: optional expected hash.
- `observedScriptHash`: optional observed hash.
- `referenceTxIn`: optional local UTxO reference.
- `registryPath`: planned registry path.
- `summaryPath`: planned summary path.
- `sourceRepository`: optional upstream source.
- `sourceCommit`: optional upstream commit.

## State Transitions

```text
missing-artifact
  -> artifact-verified
  -> reference-published
  -> reference-verified
  -> registry-written
  -> ready-for-order-build
```

Any mismatch or unsupported fixture path transitions to `failed` and
writes `SwapReadinessDiagnostic` instead of success artifacts.
