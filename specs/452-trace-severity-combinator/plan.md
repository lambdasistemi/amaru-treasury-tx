# Plan: shared tracing severity vocabulary

## Technical Shape

Add `lib/Amaru/Treasury/Trace.hs` as a small library module. It should depend
only on existing lightweight dependencies already present in the library,
notably `base`, `text`, `time`, and `contra-tracer`.

The primary surface is:

```haskell
data Severity = Debug | Info | Notice | Warning | Error

traced
    :: Tracer IO (Severity, Text)
    -> Severity
    -> Text
    -> IO a
    -> IO a
```

The implementation should use the existing `Control.Tracer` idiom
(`Tracer`, `traceWith`, and `contramap` where useful). The message text may be
simple and human-readable, but tests should assert stable semantic substrings
rather than brittle exact duration values.

Filtering should be explicit and local to this module, for example:

```haskell
severityAtLeast :: Severity -> Severity -> Bool
filterSeverity
    :: Severity
    -> Tracer IO (Severity, Text)
    -> Tracer IO (Severity, Text)
```

Names may vary if the implementation is clearer, but the module must expose a
plain min-severity filter that child #453 can later wire to CLI/API config.

## Cabal Changes

- Add `Amaru.Treasury.Trace` to the library exposed modules.
- Add `Amaru.Treasury.TraceSpec` to the unit-test suite `other-modules`.
- No new dependencies should be necessary.

## Test Shape

Add `test/unit/Amaru/Treasury/TraceSpec.hs`.

The test should build an in-memory tracer, likely with `IORef [(Severity,
Text)]`, and cover:

- successful action logs start before terminal success;
- terminal success includes duration information;
- throwing action logs start and failure terminal event, then rethrows;
- min-severity filtering suppresses lower severity events while preserving
  events at or above the threshold.

## Slice Breakdown

This ticket is intentionally one implementation slice because the behavior is
small and the tests define the public surface.

Slice 1:

- Add the trace module.
- Add focused tests.
- Register the module and spec in the cabal file.
- Run `just unit "Trace"` and `./gate.sh`.

## Risks

- Duration assertions can become flaky if tests assert exact values. Assert
  only that duration text is present.
- Exception tests must prove the original exception propagates, not merely
  that a failure line was logged.
- The module must stay free of CLI/API concerns so sibling children can own
  verbosity plumbing and call-site wiring independently.
