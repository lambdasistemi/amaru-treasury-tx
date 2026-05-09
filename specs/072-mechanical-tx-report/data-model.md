# Data Model: Mechanical Transaction Report

**Plan**: [plan.md](./plan.md) | **Spec**: [spec.md](./spec.md)
**Date**: 2026-05-09

## TransactionReport

Top-level structured JSON artifact for one successful `tx-build`.

Fields:

- `schema`: report contract version. Initial value: `1`.
- `action`: intent action, for v1 at least `swap`, `disburse`, or
  `withdraw` when supported by the builder.
- `network`: intent network.
- `identity`: transaction identity and body facts.
- `walletAccounting`: success-path wallet view.
- `treasuryAccounting`: treasury view. Full accounting is required for
  swap; non-swap reports may carry common values and omit swap-only
  totals.
- `outputs`: every produced transaction output exactly once with a
  mechanical role.
- `signers`: every required signer key hash with source.
- `validation`: validation facts known when CBOR was emitted.
- `referenceInputs`: selected reference inputs used by the build.
- `metadata`: auxiliary-data summary, not full interpretive prose.

Validation:

- No wall-clock, random, host path, or machine-local fields.
- Stable object key order and stable array ordering.
- Report is written only for successful validation.

## TransactionIdentity

Fields:

- `txId`: transaction id when available from the final body.
- `bodySizeBytes`: CBOR byte length.
- `feeLovelace`: fee from the final balanced body.
- `totalCollateralLovelace`: total collateral from the final body.
- `validityInterval`: lower and upper slot data when present.

## WalletAccounting

Success-path wallet accounting required by FR-005 and FR-006.

Fields:

- `inputs`: wallet UTxOs used as fuel, including additional wallet fuel
  inputs.
- `collateralInput`: UTxO used as collateral.
- `changeOutput`: wallet change output if present.
- `collateralReturn`: collateral return output if present.
- `feeLovelace`: transaction fee paid by the wallet.
- `netSpendLovelace`: success-path wallet spend after subtracting wallet
  change and intact collateral return.

Validation:

- A UTxO that is both wallet fuel and collateral is counted once.
- Returned collateral is not counted as success-path spend.
- For the treasury-funded-overhead swap fixture,
  `netSpendLovelace == feeLovelace`.

## TreasuryAccounting

Treasury accounting required by FR-007.

Fields:

- `inputs`: treasury UTxOs spent by the transaction.
- `inputTotal`: lovelace and native-asset total from treasury inputs.
- `sundaeOrderTotal`: value sent into Sundae order outputs.
- `perChunkOverheadLovelace`: overhead funded by the treasury per chunk.
- `treasuryLeftover`: value returned to the treasury leftover output.
- `netDebit`: treasury input total minus treasury leftover.

Validation:

- Native assets are preserved in totals.
- Swap output totals include every order output.
- Non-swap actions still report common treasury input/leftover facts
  where roles are known.

## ProducedOutput

Mechanical classification for each transaction output.

Fields:

- `index`: transaction output index.
- `role`: `swapOrder`, `treasuryLeftover`, `walletChange`,
  `collateralReturn`, `metadata`, or `unknown`.
- `address`: bech32 or ledger-rendered address.
- `value`: lovelace plus native assets.
- `datum`: optional datum summary.

Validation:

- Every final body output appears exactly once.
- Unknown future roles are not omitted; they are reported as `unknown`
  with enough address/value data to audit.

## SignerRequirement

Required signer key hash plus the mechanical source that produced it.

Fields:

- `keyHash`: 28-byte hex key hash.
- `source`: `selectedScopeOwner`, `extraSigner`, `intentRequiredSigner`,
  or `txBodyRequiredSigner`.
- `scope`: scope id when the source is the selected scope owner.

Validation:

- Includes every key hash required by the final tx body.
- Includes every signer declared by the intent when applicable.
- Duplicates are removed only when the mechanical source can still be
  represented deterministically.

## ValidationFacts

Facts known by the builder when CBOR emission was allowed.

Fields:

- `intentNetwork`
- `socketNetworkMagic`
- `networkMatches`
- `feeLovelace`
- `bodySizeBytes`
- `redeemerCount`
- `redeemerFailures`
- `validationStatus`
- `validityInterval`

Validation:

- `validationStatus` is success for emitted reports.
- `redeemerFailures` is zero for emitted reports.
- Network facts match the handshake path used by `tx-build`.

