# Data Model: Cancel Pending SundaeSwap Orders

## SwapCancelIntent

Represents one explicit cancellation build.

- `walletTxIn`: wallet fuel input used for fees and collateral.
- `orderTxIn`: pending SundaeSwap order UTxO to cancel.
- `orderValue`: full value locked at the order UTxO.
- `orderDatum`: inline order datum used for validation and signer
  derivation.
- `orderScriptRef`: reference input carrying the SundaeSwap order
  spending script.
- `treasuryAddress`: destination receiving the cancelled value.
- `requiredSigners`: signer hashes derived from the order owner policy.
- `upperBound`: invalid-hereafter slot.

## SundaeOrderDatum

Subset of SundaeSwap V3 order datum needed by this command.

- `poolIdent`: optional pool identifier.
- `owner`: cancellation authority.
- `maxProtocolFee`: protocol fee bound.
- `destination`: execution/cancel destination information.
- `details`: order details; swap/deposit/withdrawal/etc.
- `extension`: protocol extension data.

## CancelAuthority

Supported owner policy for the initial Amaru implementation.

- `AllOfSignatures`: legacy all-owner list, all required.
- `AtLeastSignatures`: current all-owner list with threshold 2.

Unsupported forms are rejected until explicitly modeled:

- `AnyOf`
- `AtLeast` with any threshold other than 2, or any owner set other
  than the four verified treasury owners
- `Before`
- `After`
- `Script`
- nested combinations that cannot be flattened to an all-signatures
  policy.

## TreasuryDestination

The destination encoded in the order datum.

- `paymentScriptHash`: expected treasury script hash.
- `stakeScriptHash`: expected treasury script hash for the current
  Amaru-generated base address shape.
- `datum`: expected no-datum for current swap orders.

## CancelBuildReport

Operator report for review before signing.

- `orderTxIn`
- `treasuryDestination`
- `returnedValue`
- `requiredSigners`
- `txFee`
- `collateralInput`
- `referenceInputs`
- `nextSteps`
