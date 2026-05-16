# Data Model: DevNet Stake And Reward Setup

## StakeRewardInitRun

- `phase`: `stake-reward-init`.
- `network`: `devnet`.
- `networkMagic`: `42`.
- `registryPath`: path to the #147 registry artifact consumed by this
  run.
- `setupTxId`: transaction id for the submitted setup transaction.
- `accountsPath`: path to `stake-reward-init/accounts.json`.
- `provenancePath`: path to `stake-reward-init/provenance.json`.

Validation:

- `network` must be `devnet`.
- `setupTxId` is present only after submission succeeds.
- Success artifacts are removed or overwritten before a new run writes
  results.

## PreparedRewardAccount

- `role`: `treasury` or `permissions`.
- `scriptHash`: 28-byte script hash hex.
- `rewardAccount`: 28-byte reward-account credential hex used by
  intent JSON.
- `ledgerNetwork`: `Testnet`.
- `registered`: boolean indicating whether this setup transaction
  registered the credential on chain. For #148 this is `true` for
  `treasury` and `false` for `permissions`.
- `rewardsLovelace`: observed reward balance at verification time.

Validation:

- `treasury.rewardAccount` equals the treasury script hash from the
  registry projection.
- `permissions.rewardAccount` equals the permissions script hash from
  the registry projection.
- `ledgerNetwork` must be `Testnet` for DevNet.

## StakeRewardSetupTransaction

- `fundingAddress`: DevNet address that funds deposits, fees, and
  collateral.
- `submittedTxId`: setup transaction id.
- `registeredAccounts`: treasury account role only.
- `availableAccounts`: permissions account role, derived from the
  verified permissions reference script and emitted for later
  withdraw-zero transactions.
- `depositsLovelace`: total stake deposits consumed by setup.

Validation:

- The funding address must be a testnet address.
- The transaction must not include governance withdrawal proposal,
  treasury withdrawal materialization, disburse, swap, or external-role
  behavior.

## StakeRewardDiagnostic

- `phase`: `stake-reward-init`.
- `code`: stable diagnostic code such as `invalid-network`,
  `missing-registry`, `funding-shortfall`, `submit-rejected`, or
  `verification-timeout`.
- `message`: human-readable failure.
- `failedStep`: `validate-inputs`, `build`, `submit`, or `verify`.
- `observedTxIds`: optional setup tx id.
- `summaryPath`: path to failure artifact.

Validation:

- Failure artifacts must not be named as success summaries.
- Diagnostics must include enough context for the next run to identify
  the missing prerequisite.
