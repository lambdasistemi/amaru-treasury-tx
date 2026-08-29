# Modules model — #494 indexer-backed API tip

Artifact ceiling: 3,000 bytes / 70 lines.

## Changed responsibilities

### M-494-001 — `Amaru.Treasury.Api.Readiness`

- Owns the API's non-blocking projection of the latest upstream tip slot
  from the readiness snapshot.
- Continues to own readiness classification and lag information.
- Does not acquire live ledger state or define HTTP responses.
- Data: D-494-001. Functions: F-494-001.

### M-494-002 — `Amaru.Treasury.Cli.TreasuryInspect`

- Reusable report construction consumes an explicit current tip slot.
- The CLI entry point remains the owner of live-provider `nowTip`
  acquisition for CLI operation.
- Does not depend on API readiness types.
- Data: D-494-002. Functions: F-494-002.

### M-494-003 — `Amaru.Treasury.Api.Server`

- Passes the explicit readiness-derived tip into indexed inspection.
- Maps the existing typed tip timeout to the established structured HTTP
  503 response at both API tip boundaries.
- Keeps indexed UTxO reads and unrelated live-provider queries in their
  current dependency direction.
- Data: D-494-002 and D-494-003. Functions: F-494-003 and F-494-004.

### M-494-004 — `app/amaru-treasury-tx-api/Main`

- Wires the shared `ReadinessHandle` into `/v1/tip` and inspector report
  production.
- No longer treats the live provider as the API current-tip authority.
- Retains live-provider ownership for protocol parameters, submit, and
  other unrelated ledger queries.
- Functions: F-494-005.

### M-494-005 — API documentation and regression specifications

- Explain the readiness-backed API boundary and permanently prove that
  provider tip conversion is unreachable from successful API tip paths.
- No new runtime dependency.

## Dependency direction

`Main` consumes `Api.Readiness` and injects a slot into `Api.Server`;
`Api.Server` injects that slot into reusable inspection; reusable CLI
inspection remains independent of API readiness. The CLI command alone
continues to depend on live-provider `nowTip`.

No abstraction is promoted beyond the existing readiness and inspection
owners.
