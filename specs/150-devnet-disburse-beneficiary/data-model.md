# Data Model: DevNet Disburse Submit

## DevnetDisburseSubmitConfig

- `networkMagic`: fixed DevNet magic `42`.
- `registryPath`: #147 `registry-init/registry.json`.
- `materializedPath`: #149
  `governance-withdrawal-init/materialized.json`.
- `fundingAddress`: DevNet wallet address used for fees/collateral.
- `signingKeyFile`: cardano-cli payment signing-key JSON.
- `beneficiaryAddress`: DevNet beneficiary address.
- `amountLovelace`: ADA sent to beneficiary.
- `runDir`: command output directory.

## DisburseSubmitResult

- `registryPath`: input registry artifact.
- `materializedPath`: input #149 materialized artifact.
- `intentPath`: generated disburse intent JSON.
- `txBodyPath`: unsigned CBOR hex.
- `reportJsonPath`: tx-build report JSON.
- `reportMarkdownPath`: tx-build report Markdown.
- `signedTxPath`: signed transaction CBOR hex.
- `submitLogPath`: submission evidence.
- `submittedTxId`: submitted disburse transaction id.
- `treasuryBefore`: treasury UTxO(s)/lovelace before submission.
- `treasuryAfter`: treasury UTxO(s)/lovelace after submission.
- `beneficiaryOutput`: observed beneficiary TxIn and lovelace.

## BeneficiaryReceipt

- `address`: beneficiary bech32 address.
- `txIn`: submitted output reference.
- `lovelace`: observed beneficiary lovelace.
- `submittedTxId`: submitted disburse tx id.

## Failure

- `code`: stable failure code.
- `message`: human-readable diagnostic.
- `failedStep`: `validate-inputs`, `build-intent`, `tx-build`,
  `sign-submit`, `treasury-verify`, or `beneficiary-verify`.
- `observedTxIds`: submitted tx id if known.
- `summaryPath`: failure artifact path.
