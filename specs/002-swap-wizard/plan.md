# Implementation Plan: Swap Wizard

**Branch**: `002-swap-wizard` | **Date**: 2026-05-05 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/002-swap-wizard/spec.md`
**Tracking issue**: [#27](https://github.com/lambdasistemi/amaru-treasury-tx/issues/27)

> **Superseded (intent shape) by feature 005** ([PR #52](https://github.com/lambdasistemi/amaru-treasury-tx/pull/52)).
> The wizard architecture in this plan ships unchanged;
> feature 005 unifies the produced JSON across all four
> actions and folds the per-action build modules into a
> single `tx-build` subcommand. See
> [`specs/005-unified-tx-build/`](../005-unified-tx-build/)
> for the unified shape.

## Summary

Add a `swap-wizard` subcommand to `amaru-treasury-tx` that produces a
valid `intent.json` for the existing `swap` subcommand from a small
typed questionnaire. The human answers the ~7 fields they actually
decide; the wizard resolves the remaining ~28 derivable fields via the
existing `Provider IO` (registry NFT walk, treasury UTxO selection,
wallet UTxO discovery, current chain tip) and a curated
`NetworkConstants` table (SundaeSwap V3 order address, USDM
policy/token, sundae fee, default pool, extra-per-chunk lovelace).

The translation from `(WizardEnv, SwapWizardQ)` to `SwapIntentJSON` is
a pure function. The IO layer is the resolver that builds `WizardEnv`
plus the prompt loop that builds `SwapWizardQ`. The wizard never
calls `runSwapBuild` — its only output is the JSON file, preserving
the existing audit artifact and rationale-metadata flow.

## Technical Context

**Language/Version**: Haskell, GHC 9.6+ (matches `cardano-node-clients`)
**Primary Dependencies**:
- existing `lib/Amaru/Treasury/**` (`SwapIntentJSON`, `SwapBuild`,
  `Backend`, `Scope`, `Constants`)
- `cardano-node-clients` `Provider IO` for queries (UTxOs at address,
  registry NFT walk, current tip, slot conversion)
- `optparse-applicative` for CLI parsing (already used)
- `aeson` for JSON output (already used)

**Storage**: filesystem only — single `intent.json` written at
`--out` path; no other persistence.
**Testing**: Hspec unit tests + golden test on the pure
`wizardToIntentJSON`. No new integration tests beyond the existing
swap golden harness, which the wizard's output is required to
satisfy.
**Target Platform**: Linux (CI) and macOS (dev), x86_64 + aarch64.
**Project Type**: CLI tool (extension of existing executable).
**Performance Goals**: Wizard must complete answer collection +
resolution + JSON write in under ~5 s on a warm `Provider IO`. Not a
hot path; correctness >> speed.
**Constraints**:
- Pure builder principle (Constitution II): the translation
  `WizardEnv -> SwapWizardQ -> SwapIntentJSON` MUST be pure; only the
  resolver and prompt loop sit in IO.
- JSON-only build path (FR-009): the wizard MUST NOT invoke
  `runSwapBuild`.
- Hackage-ready (Constitution VI): every new export gets a Haddock
  header; fourmolu 70-col; explicit export lists; `-Werror`.
**Scale/Scope**: Adds one new Haskell module
(`Amaru.Treasury.Tx.SwapWizard`), one new app entry under
`app/amaru-treasury-tx/`, one CLI flag group, one golden fixture, and
the network-constants table extension if not already present.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Faithful port of bash recipes | ✅ | The wizard does not change `swap` semantics; it only writes the same `intent.json` `swap.sh` would imply. |
| II. Pure builders, impure shell | ✅ | `wizardToIntentJSON` is pure; the `Provider IO` resolver and the prompt loop are the only IO. |
| III. Pluggable data source | ✅ | Resolver reuses the existing `Backend` typeclass — no new direct N2C dependency. |
| IV. Build, never sign or submit | ✅ | The wizard does not even build; it only writes JSON. |
| V. Test-first with golden fixtures | ✅ | A golden test on `wizardToIntentJSON` lands before the resolver/IO is wired. |
| VI. Hackage-ready Haskell | ✅ | New module follows the `/haskell` skill rules; `cabal check` will be re-run. |

No violations. The Complexity Tracking table is empty and intentionally omitted.

## Project Structure

### Documentation (this feature)

```text
specs/002-swap-wizard/
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
├── contracts/
│   ├── swap-wizard-cli.md            # CLI argument + prompt schema
│   └── network-constants.md          # NetworkConstants table shape
├── checklists/
│   └── requirements.md  # Already created by /speckit.specify
└── tasks.md             # Phase 2 output (/speckit.tasks)
```

### Source Code (repository root)

```text
lib/Amaru/Treasury/Tx/
├── Swap.hs                    # unchanged
├── SwapBuild.hs               # unchanged
├── SwapIntentJSON.hs          # add: ToJSON instances if missing,
│                              # plus a stable encoder for golden tests
└── SwapWizard.hs              # NEW: SwapWizardQ ADT, WizardEnv,
                               # NetworkConstants table, pure
                               # wizardToIntentJSON, plus the
                               # IO-bearing resolver + prompt loop

app/amaru-treasury-tx/
└── Main.hs                    # add: `swap-wizard` subcommand wiring

test/unit/
└── SwapWizardSpec.hs          # NEW: golden + roundtrip tests

test/fixtures/swap-wizard/
├── env.json                   # fixture WizardEnv inputs
├── answers.json               # fixture SwapWizardQ
└── expected.intent.json       # golden produced JSON
```

**Structure Decision**: Stay inside the existing layout. One new
library module under `lib/Amaru/Treasury/Tx/` and one new app
subcommand under `app/amaru-treasury-tx/Main.hs`. No new package, no
new sublibrary, no new flake output.

## Complexity Tracking

> Constitution Check passed without violations; this section is omitted.
