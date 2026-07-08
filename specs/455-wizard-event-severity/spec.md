# Feature Specification: Wizard Event Severity Filtering

**Issue**: #455
**Epic**: #451
**Branch**: `feat/455-wizard-event-severity`
**Status**: Draft PR implementation

## User Story

As an Amaru treasury operator, I want wizard and tx-build trace output to
respect the same log-level threshold as provider tracing, so `--log-level`
and `AMARU_TREASURY_LOG_LEVEL` consistently control operational verbosity.

## Background

Issue #452 added the shared `Severity` vocabulary and `filterSeverity`.
Issue #453 threads the configured minimum severity through CLI/API runtime
options and provider construction sites. Wizard and build events still render
through `Event -> Text` tracers backed by unconditional `hPutStrLn`, so they
are visible even when the caller asks for `warning` or `error`.

## Functional Requirements

- FR-001: Every existing wizard/build event ADT in scope maps each
  constructor to a shared `Severity`.
- FR-002: Existing rendered event text remains unchanged.
- FR-003: Default verbosity (`Info`) preserves currently visible wizard and
  tx-build log lines.
- FR-004: CLI wizard and tx-build call sites route severity-tagged events
  through `filterSeverity (goMinimumSeverity ...)` or an equivalent minimum
  severity value already in scope.
- FR-005: API build endpoint wizard/build traces route through the API
  request/runtime `goMinimumSeverity` threshold without touching provider
  tracing modules.
- FR-006: Error/failure/abort-like events remain visible at warning/error
  thresholds according to their assigned severity.

## Out Of Scope

- Rewriting log message text.
- Changing when events are emitted.
- Provider-boundary tracing (`ChainContext.hs`, `Registry/Verify.hs`,
  `Trace/Provider.hs`, `Backend/N2C.hs`, provider construction).
- Removing debug stopgaps tracked by #456.

## Success Criteria

- Unit coverage proves routine events are `Info` and failure events are
  `Warning`/`Error` as appropriate.
- Source or behavior coverage proves call sites no longer construct raw
  unfiltered `Text` sinks for wizard/build event tracers.
- `./gate.sh` passes locally.
- GitHub Actions for PR #462 pass at the final pushed head before completion
  is reported.
