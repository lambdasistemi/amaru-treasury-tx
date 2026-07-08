# Feature Spec: #453 Log Verbosity Control

## User Story

Operators need one runtime knob for the provider-boundary tracing added
under epic #451: CLI invocations should accept a visible global flag,
and the containerized API should read an environment variable at
startup, so production deployments can raise or lower trace volume
without recompilation.

## Acceptance

- `amaru-treasury-tx --help` advertises `--verbose` and
  `--log-level LEVEL`, including the default threshold.
- CLI parsing resolves a minimum `Severity` into `GlobalOpts` and uses
  `Amaru.Treasury.Trace.filterSeverity` before passing provider traces
  to `stderrTracer`.
- The default threshold keeps #454's `[Info] provider.X ...` events
  visible. `Debug` is opt-in.
- `amaru-treasury-tx-api` resolves `AMARU_TREASURY_LOG_LEVEL` at
  startup, stores the threshold in `ApiRuntimeConfig`, logs the resolved
  level once, and uses the filtered tracer for provider/indexer tracing.
- Invalid log levels fail during parser/config resolution with a clear
  message.
- Unit coverage proves `Warning` suppresses `Debug`, `Info`, and
  `Notice` through the existing filter, and proves CLI/API config
  resolution of defaults, explicit levels, and invalid levels.
- `./gate.sh` passes locally, including full-tree `hlint` and
  `fourmolu -m check`.

## Non-Goals

- Do not migrate wizard-specific event ADTs.
- Do not remove the #450 debug helper stopgap.
- Do not change provider instrumentation shape except to wrap existing
  `stderrTracer` call sites with a resolved threshold.
- Do not fix the separately tracked double-wrapped tracing issue.

## Notes

Use the `Severity` and `filterSeverity` definitions from
`Amaru.Treasury.Trace`; do not duplicate filtering semantics. The
operator-facing syntax should be lowercase strings:
`debug|info|notice|warning|error`.
