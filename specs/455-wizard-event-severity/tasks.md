# Tasks: Wizard Event Severity Filtering

## Slice 1 - Severity Mapping Foundation

- [X] T455-S1 Add pure severity classifier functions for all in-scope
  wizard/build event ADTs.
- [X] T455-S1 Add severity-aware tracer helpers while preserving existing
  render text.
- [X] T455-S1 Add unit coverage for representative routine and failure event
  severity mappings.
- [X] T455-S1 Run focused unit tests and `./gate.sh`.
- [X] T455-S1 Commit as `feat(trace): classify wizard events by severity`.

## Slice 2 - CLI Wiring

- [X] T455-S2 Route CLI wizard and tx-build event tracers through
  `filterSeverity` with the configured minimum severity.
- [X] T455-S2 Route auxiliary text-only wizard log lines through the same
  threshold at `Info` severity unless a stronger failure severity is already
  clear.
- [X] T455-S2 Add or update tests proving CLI call sites use the severity
  threshold.
- [X] T455-S2 Run focused unit tests and `./gate.sh`.
- [X] T455-S2 Commit as `feat(trace): filter cli wizard events by severity`.

## Slice 3 - API Build Wiring

- [X] T455-S3 Route API build endpoint wizard/build event traces through the
  resolved API minimum severity.
- [X] T455-S3 Add or update tests proving API build call sites use the
  severity threshold and do not touch provider tracing modules.
- [X] T455-S3 Run focused unit tests and `./gate.sh`.
- [X] T455-S3 Commit as `feat(trace): filter api wizard events by severity`.

## Slice 4 - Final Verification

- [ ] T455-S4 Run `./gate.sh` at the final implementation head.
- [ ] T455-S4 Update PR #462 body to match delivered behavior.
- [ ] T455-S4 Drop `gate.sh` in the ready-for-review commit.
- [ ] T455-S4 Mark PR #462 ready for review.
- [ ] T455-S4 Wait for GitHub Actions checks to pass at the final pushed head.
