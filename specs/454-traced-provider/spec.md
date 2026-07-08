# Feature Specification: Provider Boundary Tracing

## User Story

As an Amaru treasury operator, I need every live node provider
operation to emit start, finish, duration, and failure trace lines so
production hangs at the build/verify boundary can be diagnosed without
adding ad hoc debug wrappers at each call site.

## Scope

This feature instruments the Cardano node `Provider IO` and `Submitter
IO` record-of-functions once at construction time. It builds on
`Amaru.Treasury.Trace.traced` from #452 and applies to all current
provider methods, including acquired-handle methods reachable through
`withAcquired`.

#453 verbosity plumbing is still open on `main`, so this ticket emits
all events to stderr. Filtering will be consumed later when #453 lands.

## Functional Requirements

- FR-001: The library exposes wrappers for `Provider IO`,
  `QueryHandle IO`, and `Submitter IO` that preserve behavior while
  tracing each method before and after execution.
- FR-002: The provider wrapper covers every current provider method:
  `withAcquired`, `queryUTxOs`, `queryUTxOByTxIn`,
  `queryProtocolParams`, `queryLedgerSnapshot`,
  `queryStakeRewards`, `queryRewardAccounts`,
  `queryVoteDelegatees`, `queryTreasury`,
  `queryGovernanceState`, `evaluateTx`, `posixMsToSlot`,
  `posixMsCeilSlot`, and `queryUpperBoundSlot`.
- FR-003: The acquired-handle wrapper covers every current
  `QueryHandle` method: `queryUTxOsH`, `queryUTxOsAtH`,
  `queryUTxOByTxInH`, `queryProtocolParamsH`,
  `queryLedgerSnapshotH`, `queryStakeRewardsH`,
  `queryRewardAccountsH`, `queryVoteDelegateesH`,
  `queryTreasuryH`, `queryGovernanceStateH`, `evaluateTxH`,
  `posixMsToSlotH`, and `posixMsCeilSlotH`.
- FR-004: The submitter wrapper covers `submitTx`.
- FR-005: `withLocalNodeBackend` and `withLocalNodeClient` apply these
  wrappers before handing providers or submitters to callers, so CLI,
  API, devnet, and probe users get tracing without call-site changes.
- FR-006: API indexer adapter providers preserve tracing for their
  synthetic direct UTxO methods and acquired-handle adapter methods.
- FR-007: Stderr rendering formats `(Severity, Text)` into one log line
  per trace event.
- FR-008: Existing #450 stopgap debug helpers in `ChainContext.hs` and
  `Registry/Verify.hs` remain untouched.

## Success Criteria

- Unit tests prove each provider, query-handle, and submitter method
  emits start and terminal trace events when called through the wrapper.
- Grepping provider construction sites shows `withLocalNodeBackend`,
  `withLocalNodeClient`, and API indexer provider construction are
  wired through the tracing wrapper.
- `./gate.sh` passes.
- The PR body states that #453 filtering is separate and that live
  mainnet/preview verification is not performed in this worker.
