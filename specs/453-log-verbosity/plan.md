# Implementation Plan: #453 Log Verbosity Control

## Baseline

#452 introduced `Amaru.Treasury.Trace.Severity` plus
`filterSeverity`. #454 wired `stderrTracer` through provider wrappers
in:

- `lib/Amaru/Treasury/Backend/N2C.hs`
- `lib/Amaru/Treasury/Api/Server.hs`

This ticket only resolves thresholds and applies `filterSeverity` at
those existing call sites.

## Slice 1 - Shared parsing and CLI plumbing

Owned files:

- `lib/Amaru/Treasury/Trace.hs`
- `lib/Amaru/Treasury/Cli/Common.hs`
- `lib/Amaru/Treasury/Cli/Config.hs`
- `lib/Amaru/Treasury/Cli.hs`
- `app/amaru-treasury-tx/Main.hs`
- `lib/Amaru/Treasury/Backend/N2C.hs`
- `test/unit/Amaru/Treasury/TraceSpec.hs`
- `test/unit/Amaru/Treasury/Cli/ConfigSpec.hs`
- any directly affected unit tests that construct `GlobalOpts`

Work:

- Add a shared log-level parser/renderer near `Severity`.
- Extend `GlobalConfigOpts` and `GlobalOpts` with the minimum severity.
- Add top-level `--log-level LEVEL` and `--verbose` options. The default
  must be `Info`; `--verbose` resolves to `Debug`; an explicit
  `--log-level` takes precedence if both are present.
- Thread the threshold from `GlobalOpts` into `withLocalNodeBackend` and
  `withLocalNodeClient` without changing N2C behavior otherwise.
- Apply `filterSeverity` to the existing #454 provider/submitter tracer
  call sites in `N2C.hs`.
- Unit-test parsing/defaults and filtering behavior.

Proof:

- `nix develop --quiet -c just unit "Trace"`
- `nix develop --quiet -c just unit "Cli config"`
- `./gate.sh`

Commit:

- `feat: add CLI log verbosity control`
- `Tasks: T453-S1`

## Slice 2 - API environment and provider wiring

Owned files:

- `app/amaru-treasury-tx-api/Main.hs`
- `lib/Amaru/Treasury/Api/Config.hs`
- `lib/Amaru/Treasury/Api/Server.hs`
- `test/unit/Amaru/Treasury/Api/ConfigSpec.hs`
- any directly affected unit tests that construct `ApiRuntimeConfig`

Work:

- Read `AMARU_TREASURY_LOG_LEVEL` during API config resolution.
- Store the resolved `Severity` on `ApiRuntimeConfig`, defaulting to
  `Info`.
- Log the resolved level once during startup before opening node/indexer
  resources.
- Use `filterSeverity` for the tracer passed to `withApiIndexer` and the
  existing `indexerProvider`/`tracedProvider` call in `Api/Server.hs`.
- Keep the current double-wrap behavior intact; only filter on top.
- Unit-test default, env override, and invalid env value.

Proof:

- `nix develop --quiet -c just unit "Api config"`
- `./gate.sh`

Commit:

- `feat: add API log verbosity env control`
- `Tasks: T453-S2`

## Finalization

The orchestrator will review each slice commit, mark the matching tasks
complete in `tasks.md` by amending the slice commit, push the branch,
wait for GitHub Actions to finish, then drop `gate.sh` in the final
ready-for-review commit if all checks are green.
