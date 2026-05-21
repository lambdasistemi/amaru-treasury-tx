# Data Model: bump cardano-tx-tools reward-state validation

## Dependency Pin

Represents the reproducible upstream source selected for
`cardano-tx-tools`.

**Fields**:

- `location`: `https://github.com/lambdasistemi/cardano-tx-tools`
- `oldCommit`: `25d7ce349f826e9888fb8565eeb816babb06d922`
- `targetRelease`: `v0.2.0.0`
- `annotatedTagObject`: `d53943d842b740b313b6b67c7784f4308e5847f0`
- `targetCommit`: `9e77e90728729bdd22e3bfbe0cf7515b33d5ea13`
- `minimumFixCommit`: `6a7a7d424594e8d891dd2b7df5c4e9a7884e6779`
- `sha256`: nix32 fixed-output hash for `targetCommit`, regenerated
  during implementation

**Validation rules**:

- `targetCommit` must be equal to or a descendant of
  `minimumFixCommit`.
- `cabal.project` `tag:` must use `targetCommit`, not
  `annotatedTagObject`.
- `sha256` must be regenerated for `targetCommit` and verified by Nix.

**State transitions**:

1. `Current`: `tag = oldCommit`, `sha256 = old hash`.
2. `Pinned`: `tag = targetCommit`, `sha256` not yet accepted.
3. `Verified`: `tag = targetCommit`, `sha256` matches Nix fetch.

## Final Phase-1 Validation

Represents the shared pre-flight applied to final built transactions
before the build runner returns CBOR/report material.

**Fields**:

- `chainContext`: network, protocol parameters, UTxO map, sampled tip
  slot, and script evaluator from `ChainContext`
- `finalTx`: built `ConwayTx`
- `ledgerResult`: result of `Cardano.Tx.Validate.validatePhase1`
- `acceptedNoise`: witness-completeness failures for unsigned
  transaction build output
- `structuralFailures`: all non-witness ledger failures

**Validation rules**:

- `validatePhase1` runs for every transaction, including transactions
  whose body has withdrawals.
- Missing vkey witness failures are accepted as signing-step noise.
- Any non-witness structural ledger failure rejects the build with a
  diagnostic that includes the sampled slot.

**State transitions**:

1. `SkippedWithdrawal` (pre-#191 only): withdrawal-bearing tx returned
   success without validation.
2. `Validated`: tx ran through `validatePhase1`.
3. `Accepted`: no structural failures remain after filtering witness
   noise.
4. `Rejected`: one or more structural failures remain.

## Governance Withdrawal Init Disposition

Represents the post-bump decision for the governance-withdrawal-init
validation workaround.

**Fields**:

- `proposalFixtureResult`: result of running the proposal fixture through
  the active validation path
- `materializationFixtureResult`: result of running the materialization
  fixture through the active validation path
- `skipDisposition`: `removed` or `retained`
- `residualLedgerRule`: optional concrete ledger failure when retained
- `upstreamIssue`: optional upstream tracking issue when retained

**Validation rules**:

- If proposal and materialization fixtures pass, the skip helper and
  stale comments are removed.
- If either fixture fails for a residual rule outside #191's owned
  scope, implementation stops through a Q-file before editing beyond the
  ticket boundary.
- A retained skip must name `residualLedgerRule` and link
  `upstreamIssue`.

**State transitions**:

1. `Unassessed`: dependency not yet bumped or fixtures not yet rerun.
2. `PassesNormalPath`: fixtures pass with active final Phase-1
   validation.
3. `SkipRemoved`: code uses `materializeResult`.
4. `ResidualRuleFound`: fixtures expose a specific non-reward-state
   ledger rule.
5. `SkipRetainedWithRule`: skip remains with refreshed comment and
   upstream tracking link.
