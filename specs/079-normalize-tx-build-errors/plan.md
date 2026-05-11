# Implementation Plan: Normalize tx-build Builder Errors

**Branch**: `079-normalize-tx-build-errors` | **Date**: 2026-05-11 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/079-normalize-tx-build-errors/spec.md`

## Summary

Introduce a project-owned typed build diagnostic layer for expected `tx-build` failures. Convert upstream `BuildError` and local runner failures into structured diagnostics before CLI/report output. Use action-local `ExceptT ActionBuildError IO` inside the runners and lift it to the public `BuildError` with `withExceptT` at dispatcher boundaries. Use the `mapException` pattern at compatibility boundaries to add structured context without flattening to strings: base `mapException` where pure exception mapping applies, and a typed `try`/`catch` helper for `IO` exceptions. Pure transaction builders stay unchanged.

## Status

**Completed**: typed diagnostic model, `withExceptT` runner lifting, compatibility exception rendering, `runFromIntentEither`, CLI/report wiring, docs updates, focused RED/GREEN tests, formatting, `just build`, and full `just ci`.
**Current**: ready for review.
**Blockers**: none.

## Technical Context

**Language/Version**: Haskell, GHC 9.12.3 in current Nix dev shell.
**Primary Dependencies**: `cardano-node-clients` (`BuildError`, `BalanceError`), base `Control.Exception.mapException`, `transformers` for `ExceptT` and `withExceptT`.
**Storage**: N/A.
**Testing**: Hspec unit tests, golden/report tests where failure envelope bytes are deterministic.
**Target Platform**: CLI on Linux and macOS.
**Project Type**: Single Haskell library plus CLI executable.
**Performance Goals**: N/A; error rendering is not performance-sensitive.
**Constraints**: Do not change transaction balancing semantics. Do not change pure `TxBuild q e a` programs. Preserve success report schema.
**Scale/Scope**: `lib/Amaru/Treasury/Build.hs`, `app/amaru-treasury-tx/Main.hs`, report failure envelopes, and focused tests.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

- **I. Faithful port of the bash recipes.** Pass. This changes error reporting after build failure, not transaction semantics or bash-compatible payloads.
- **II. Pure builders, impure shell.** Pass. The pure `TxBuild` programs stay pure; `ExceptT`, `withExceptT`, and `mapException` are confined to the IO runner and compatibility exception layers.
- **III. Pluggable data source, local-node default.** Pass. No backend contract change.
- **IV. Build, never sign or submit.** Pass. No signing/submission scope.
- **V. Test-first with golden CBOR fixtures.** Pass with TDD requirement: add failing normalization tests before changing runner code. Existing golden success CBOR must remain unchanged.
- **VI. Hackage-ready Haskell.** Pass. New exports need Haddock; formatting/lint/cabal checks remain gate.

## Project Structure

### Documentation (this feature)

```text
specs/079-normalize-tx-build-errors/
+-- spec.md
+-- plan.md
+-- research.md
+-- data-model.md
+-- quickstart.md
+-- contracts/
|   +-- tx-build-failure-contract.md
+-- checklists/
|   +-- requirements.md
+-- tasks.md
```

### Source Code (repository root)

```text
lib/Amaru/Treasury/
+-- Build.hs                 # typed build errors, withExceptT runner flow, mapException context wrapping
+-- Report.hs                        # failure envelope keeps normalized code/message
+-- Build/Trace.hs           # only if trace wording needs a new event

app/amaru-treasury-tx/
+-- Main.hs                          # consume typed build failures for report/non-report CLI

test/unit/Amaru/Treasury/
+-- BuildSpec.hs             # normalizer and runner failure tests
+-- ReportSpec.hs                    # failure envelope code/message tests if needed
```

**Structure Decision**: keep changes in the existing single package. Add a small error model near `Build` unless implementation shows a separate `Build.Error` module makes the export list clearer.

## Phase 0: Research Output

See [research.md](./research.md). Main decisions:

- project-owned diagnostic type;
- nested `ExceptT ActionBuildError IO` inside IO runners, lifted with `withExceptT`;
- structured exception context composed with `mapException` at exception boundaries;
- typed `runFromIntentEither` entry point with compatibility wrapper;
- conservative `InsufficientFee` wording;
- stable lowercase hyphenated failure codes.

## Phase 1: Design Output

See:

- [data-model.md](./data-model.md)
- [contracts/tx-build-failure-contract.md](./contracts/tx-build-failure-contract.md)
- [quickstart.md](./quickstart.md)

## Complexity Tracking

No constitution violations. `ExceptT`, `withExceptT`, and `mapException` are not added architectural layers in the pure builders; they are local IO error-flow and compatibility-exception plumbing at boundaries that already perform effects and can fail.
