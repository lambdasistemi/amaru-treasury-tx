# Data Model: DevNet Withdrawal Slice

## WithdrawalDevnetRun

- `runDirectory`: root artifact directory.
- `phase`: always `withdraw` for this slice.
- `network`: expected `devnet`.
- `networkMagic`: expected `42`.
- `socket`: local node socket path.
- `epochDurationSeconds`: short-epoch timing.
- `status`: `passed` or typed failure.

## GovernancePrerequisite

- `governanceRunDirectory`: directory containing setup evidence.
- `governanceTxId`: transaction id for the treasury-withdrawal
  governance action.
- `governanceActionId`: action id and index.
- `rewardAccount`: Amaru treasury script reward account.
- `amountLovelace`: requested treasury withdrawal amount.
- `rewardBeforeLovelace`: observed balance before governance.
- `rewardAfterLovelace`: observed balance after governance.
- `setupEpoch`, `voteEpoch`, `finalEpoch`: epoch evidence.

## LiveWithdrawIntent

- `intentPath`: path to `withdraw/intent.json`.
- `rewardAccount`: same account as `GovernancePrerequisite`.
- `rewardsLovelace`: positive live reward balance.
- `walletTxIn`: selected fuel input.
- `validityUpperBoundSlot`: live horizon-derived upper bound.
- `network`: `devnet`.

## WithdrawalBuildEvidence

- `txBodyPath`: unsigned CBOR hex output path.
- `txId`: tx body hash reported by `tx-build`.
- `reportJsonPath`: mechanical report path.
- `reportMarkdownPath`: human report path.
- `feeLovelace`: builder fee.
- `validityUpperBoundSlot`: copied from the intent/report.

## WithdrawalDiagnostic

- `phase`: setup, reward-observation, wizard, build, or docs.
- `message`: single-line human-readable diagnostic.
- `lastObservedRewardLovelace`: nullable integer.
- `epoch`: nullable epoch number.
- `tipSlot`: nullable slot number.
- `artifactsPreserved`: paths useful for reproduction.
