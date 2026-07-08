# Spec: shared tracing severity vocabulary

## User Story

As a maintainer diagnosing provider and wizard execution, I need a shared
severity vocabulary and a generic `Tracer` combinator so future tracing can
be added consistently without repeating ad-hoc `stderr` helpers at each call
site.

## Scope

Issue #452 is the foundation child for epic #451. It defines reusable tracing
types and behavior only. It must not wire tracing into providers, registry
verification, `ChainContext`, wizard events, CLI flags, API environment
variables, or #450 stopgap cleanup.

## Functional Requirements

- FR-001: The library exposes a new small module, expected as
  `Amaru.Treasury.Trace`, importable by both CLI and API code.
- FR-002: The module defines `Severity` with exactly these constructors, in
  ascending order: `Debug`, `Info`, `Notice`, `Warning`, `Error`.
- FR-003: The module exposes a generic combinator shaped like
  `traced :: Tracer IO (Severity, Text) -> Severity -> Text -> IO a -> IO a`.
- FR-004: `traced` emits a start event before the action and a terminal event
  after the action completes.
- FR-005: The terminal event includes elapsed duration information.
- FR-006: When the wrapped action throws, `traced` emits a failure terminal
  event and rethrows the original exception.
- FR-007: The module provides a min-severity filtering surface so callers can
  suppress events below a threshold without adding CLI/API plumbing in this
  child.
- FR-008: Unit tests cover event ordering, exception logging plus propagation,
  and min-severity suppression.

## Non-Requirements

- No provider or backend wrapping.
- No changes to `lib/Amaru/Treasury/ChainContext.hs`.
- No changes to `lib/Amaru/Treasury/Registry/Verify.hs`.
- No changes to `lib/Amaru/Treasury/Api/RateLimit.hs`.
- No wizard `Event` migrations.
- No CLI `--verbose` or `--log-level` flags.
- No API environment variable parsing.

## Success Criteria

- `just unit "Trace"` passes.
- `./gate.sh` passes or any environmental dependency failure is recorded with
  the exact command and error.
- `fourmolu` and `hlint` are clean for the new module and test.
- The PR body clearly states that call-site wiring remains out of scope.
