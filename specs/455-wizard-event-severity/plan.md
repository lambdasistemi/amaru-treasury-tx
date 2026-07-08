# Implementation Plan: Wizard Event Severity Filtering

## Technical Shape

Keep every existing event constructor and `render*Event` function text stable.
Each trace module will add a pure severity classifier and a severity-aware
tracer helper:

- `BuildEvent -> Severity`
- `WizardEvent -> Severity`
- `DisburseWizardEvent -> Severity`
- `WithdrawWizardEvent -> Severity`
- `ReorganizeWizardEvent -> Severity`
- `DisburseEvent -> Severity` if the existing disburse trace surface is still
  compiled into the event facade

Routine narration should classify as `Info` so the default threshold preserves
today's output. Abort, mismatch, validation failure, script failure, and report
write failure events should classify as `Error` unless surrounding semantics
make `Warning` more appropriate. Events that are currently routine but noisy
can be considered `Debug` only if default visibility is not required; avoid
that unless tests document the choice.

The existing `render*` functions remain available for APIs/tests that need
plain text. Severity-aware tracer helpers should emit `(Severity, Text)` into
the shared filter path.

## Slice Strategy

### Slice 1: Severity Mapping Foundation

Add severity classifier functions and severity-aware tracer helpers in the
event trace modules. Add unit coverage that fails while no classifier exists
and proves representative routine/failure severities. Preserve existing text
tracer helpers until call sites are migrated.

### Slice 2: CLI Wiring

Migrate CLI wizard and tx-build emitters from raw `Tracer IO Text` sinks to
severity-aware sinks filtered with `goMinimumSeverity` or the explicit
`minimumSeverity` argument. Text-only auxiliary wizard log lines, such as
operator exclusion lines, should be routed through an `Info` severity path so
the same threshold suppresses them when configured above `Info`.

### Slice 3: API Build Wiring

Migrate API build endpoint traces that currently use `render*Event` manually to
the same severity-aware path, using the already-resolved API `GlobalOpts`
minimum severity. Do not touch API provider-level tracing modules.

### Slice 4: Final Verification

Run the full temporary gate, update PR body if needed, drop `gate.sh`, mark the
draft PR ready only after local gate is green, then wait for GitHub Actions to
pass at the final pushed head.

## Files By Slice

Slice 1 owned files:

- `lib/Amaru/Treasury/Build/Trace.hs`
- `lib/Amaru/Treasury/Tx/Disburse/Trace.hs`
- `lib/Amaru/Treasury/Tx/DisburseWizard/Trace.hs`
- `lib/Amaru/Treasury/Tx/ReorganizeWizard/Trace.hs`
- `lib/Amaru/Treasury/Tx/SwapWizard/Trace.hs`
- `lib/Amaru/Treasury/Tx/WithdrawWizard/Trace.hs`
- `lib/Amaru/Treasury/Wizard/Event.hs`
- focused unit specs under `test/unit/Amaru/Treasury/**`

Slice 2 owned files:

- `lib/Amaru/Treasury/Cli/DisburseWizard.hs`
- `lib/Amaru/Treasury/Cli/SwapQuote.hs`
- `lib/Amaru/Treasury/Cli/SwapWizard.hs`
- `lib/Amaru/Treasury/Cli/TxBuild.hs`
- `lib/Amaru/Treasury/Cli/WithdrawWizard.hs`
- `lib/Amaru/Treasury/Wizard/Disburse.hs`
- `lib/Amaru/Treasury/Wizard/Reorganize.hs`
- `lib/Amaru/Treasury/Wizard/Swap.hs`
- focused unit/source specs under `test/unit/Amaru/Treasury/**`

Slice 3 owned files:

- `lib/Amaru/Treasury/Api/BuildContingencyDisburse.hs`
- `lib/Amaru/Treasury/Api/BuildDisburse.hs`
- `lib/Amaru/Treasury/Api/BuildReorganize.hs`
- `lib/Amaru/Treasury/Api/BuildSwap.hs`
- focused unit/source specs under `test/unit/Amaru/Treasury/Api/**`

Forbidden throughout:

- `lib/Amaru/Treasury/Backend/N2C.hs`
- `lib/Amaru/Treasury/ChainContext.hs`
- `lib/Amaru/Treasury/Registry/Verify.hs`
- `lib/Amaru/Treasury/Trace/Provider.hs`
- epic or sibling issue metadata

## Verification

Focused slice commands should use `nix develop --quiet -c just unit <match>`
where possible. Every accepted slice must pass `./gate.sh` before the
orchestrator pushes. Final completion additionally requires GitHub Actions
checks to pass on PR #462.
