# Implementation Plan: Swap Wizard All ADA Mode

**Branch**: `009-swap-wizard-all-ada` | **Date**: 2026-05-15 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/009-swap-wizard-all-ada/spec.md`
**Tracking issue**: [#127](https://github.com/lambdasistemi/amaru-treasury-tx/issues/127)

## Status

**Completed**: clean worktree created; baseline `nix develop --quiet -c just unit` passed.
**Current**: authoring Spec Kit artifacts and RED tests.
**Blockers**: none.

## Summary

Add an explicit `swap-wizard --all-ada` target mode. The CLI target parser chooses either fixed `--usdm` or `--all-ada`. Fixed `--usdm` keeps the current path. All-ADA mode verifies metadata, queries live treasury UTxOs for the selected scope, filters to pure ADA UTxOs, reserves `split * extraPerChunkLovelace` and the minimum treasury leftover, derives the maximum swap ADA amount, computes chunk size from `--split`, and emits the same unified swap intent accepted by `tx-build`.

## Technical Context

**Language/Version**: Haskell, GHC 9.12.3 in the current Nix dev shell
**Primary Dependencies**: existing `Amaru.Treasury.Cli.SwapWizard`, `Amaru.Treasury.Tx.SwapWizard`, `Amaru.Treasury.Tx.SwapQuote`, `optparse-applicative`, Hspec/QuickCheck
**Storage**: filesystem only for optional intent output and logs
**Testing**: `just unit`, targeted Hspec matches, golden/schema tests already in the unit suite
**Target Platform**: Linux and macOS CLI
**Project Type**: Haskell CLI tool
**Performance Goals**: no additional network query beyond the existing resolver queries
**Constraints**: preserve JSON-only wizard output; no transaction build inside the wizard; keep pure calculation helpers unit-testable
**Scale/Scope**: one new target mode for `swap-wizard`; no change to `swap-quote`

## Constitution Check

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Faithful port of bash recipes | Pass | This adds a reproducible wizard calculation for an operator workflow, but emits the same swap intent and build semantics. |
| II. Pure builders, impure shell | Pass | Max-spend arithmetic lands in pure helpers; resolver only supplies live UTxO data. |
| III. Pluggable data source | Pass | Resolver continues to use `ResolverEnv`, not direct N2C calls in pure code. |
| IV. Build, never sign or submit | Pass | Wizard still emits JSON only. |
| V. Test-first with golden fixtures | Pass | RED tests cover calculation, parser conflicts, trace, and intent translation before implementation. |
| VI. Hackage-ready Haskell | Pass | Existing style, explicit exports, fourmolu, and `just unit` gate apply. |

## Project Structure

### Documentation (this feature)

```text
specs/009-swap-wizard-all-ada/
├── spec.md
├── plan.md
├── research.md
├── data-model.md
├── quickstart.md
├── contracts/
│   └── swap-wizard-all-ada-cli.md
├── checklists/
│   └── requirements.md
└── tasks.md
```

### Source Code (repository root)

```text
lib/Amaru/Treasury/Cli/SwapWizard.hs
lib/Amaru/Treasury/Tx/SwapWizard.hs
lib/Amaru/Treasury/Tx/SwapWizard/Trace.hs
test/unit/Amaru/Treasury/Tx/SwapWizardSpec.hs
docs/swap.md
docs/quickstart.md
```

**Structure Decision**: Reuse the existing swap wizard modules. No new package, executable, schema version, or build path is needed.

## Complexity Tracking

No constitution violations.
