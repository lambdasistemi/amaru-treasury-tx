# Data Model: DevNet Governance And Withdrawal Setup

## GovernanceWithdrawalInitRun

- `phase`: fixed `governance-withdrawal-init`.
- `network`: fixed `devnet`.
- `networkMagic`: fixed `42`.
- `runDirectory`: command run directory.
- `registryPath`: #147 `registry-init/registry.json` input path.
- `stakeRewardPath`: #148 `stake-reward-init/accounts.json` input path.
- `fundingAddress`: DevNet funding address used for deposits, fees,
  vote output, and collateral.
- `amountLovelace`: requested treasury withdrawal amount.
- `status`: `passed`, `intent-ready`, `failed`, or a narrower stable
  command status if implementation needs intermediate summaries.
- `summaryPath`, `governancePath`, `withdrawalPath`,
  `materializationPath`, `provenancePath`: emitted artifact paths.

Validation:

- `network` must be `devnet` and `networkMagic` must be `42`.
- `registryPath` must decode as #147 DevNet registry artifacts.
- `stakeRewardPath` must decode as #148 DevNet stake/reward artifacts.
- The treasury script hash in both inputs must match.

## GovernanceProposal

- `proposalTxId`: submitted governance proposal tx id.
- `governanceActionId`: proposal tx id plus action index.
- `treasuryRewardAccount`: target reward account from #148.
- `treasuryScriptHash`: matching treasury script hash from #147/#148.
- `amountLovelace`: requested treasury withdrawal amount.
- `depositReturnAccount`: DevNet reward account receiving governance
  deposit return.
- `setupEpoch`: epoch after proposal submission.
- `voteEpoch`: epoch after vote submission.
- `finalEpoch`: epoch when reward increase was observed.

Validation:

- `treasuryRewardAccount` must match the #148 treasury account.
- `amountLovelace` must be positive.
- `finalEpoch` must be after the vote submission epoch before success.

## GovernanceVote

- `voteTxId`: submitted vote transaction id.
- `voterCredential`: DRep voting credential.
- `voterAddress`: DevNet base address that holds the vote UTxO.
- `vote`: fixed `VoteYes`.
- `governanceActionId`: action being voted on.

Validation:

- Vote must target the proposal emitted by the same run.
- Vote tx id must be observed through the provider before waiting for
  reward increase.

## RewardObservation

- `rewardAccount`: treasury reward account.
- `rewardBeforeLovelace`: balance before proposal submission.
- `rewardAfterGovernanceLovelace`: balance after vote enactment.
- `rewardBeforeSubmitLovelace`: balance before materialization submit.
- `rewardAfterSubmitLovelace`: balance after materialization submit.
- `epoch`, `tipSlot`: latest observed ledger position.

Validation:

- `rewardAfterGovernanceLovelace - rewardBeforeLovelace` must equal the
  configured withdrawal amount for success.
- `rewardAfterSubmitLovelace` must be `0` after successful
  materialization.

## WithdrawalMaterialization

- `intentPath`: schema-v1 withdrawal intent path.
- `txBodyPath`: unsigned transaction CBOR-hex path.
- `reportJsonPath`: tx-build JSON report path.
- `reportMarkdownPath`: tx-build Markdown report path.
- `signedTxPath`: signed transaction CBOR-hex path.
- `submitLogPath`: submission log path.
- `submittedTxId`: submitted tx id.
- `treasuryMaterializedTxIn`: resulting treasury UTxO ref.
- `treasuryAddress`: treasury spending validator address.
- `materializedAdaLovelace`: ADA locked by the treasury validator.
- `treasuryUtxoLovelaceBefore`: total ADA at treasury address before
  submit.
- `treasuryUtxoLovelaceAfter`: total ADA at treasury address after
  submit.

Validation:

- Built tx id, signed tx id, and submitted tx id must match.
- Materialized TxIn must exist on-chain.
- Materialized output address must be the treasury spending validator.
- Materialized output must contain exactly the withdrawn ADA and no
  native assets.

## GovernanceWithdrawalFailure

- `phase`: fixed `governance-withdrawal-init`.
- `status`: fixed `failed`.
- `code`: stable failure code.
- `message`: human-readable diagnostic.
- `failedStep`: `validate-inputs`, `governance-build`,
  `governance-submit`, `vote-submit`, `reward-wait`,
  `withdraw-intent`, `withdraw-build`, `withdraw-submit`, or
  `materialization-verify`.
- `observedTxIds`: object containing any proposal, vote, or withdrawal
  tx ids observed before failure.
- `lastObservedRewardLovelace`, `epoch`, `tipSlot`: latest known ledger
  state when relevant.
- `summaryPath`: failure artifact path.

Validation:

- Failure writes must remove stale success summaries for the same run.
- Partial submission details must be retained when available.
