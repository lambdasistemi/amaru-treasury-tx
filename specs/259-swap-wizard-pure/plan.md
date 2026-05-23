# Implementation Plan: Swap wizard pure intent producer

**Branch**: `259-swap-wizard-pure` | **Date**: 2026-05-23 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/259-swap-wizard-pure/spec.md`

## Summary

Lift the swap-wizard runtime out of "CLI-only, exit-on-error" shape into a typed, reusable surface. Two new callable entry points — `buildSwapIntent` (chain → intent) and `buildSwapTx` (intent → CBOR + report) — return `Either WizardFailure SwapIntent` / `Either BuildFailure (CborHex, Report)` instead of calling `abortTr`. Existing CLI commands `swap-wizard` and `tx-build` rewire through the new functions and remain byte-identical against the existing golden corpus. This unblocks the swap build page (#256) and the `POST /build/{kind}` slice of #248 by giving them a function they can invoke from a servant handler without crashing the host on validation errors.

## Technical Context

**Language/Version**: Haskell, GHC 9.6+ (matches `cardano-node-clients`)
**Primary Dependencies**: `cardano-node-clients` (Provider IO + N2C), `cardano-tx-tools` (`TxBuild` DSL), `cardano-ledger-conway` (Conway tx body), `plutus-tx` (`ToData`/`FromData`), `aeson` (intent.json), `contra-tracer` (informational logging)
**Storage**: filesystem only — `intent.json` (CLI output, builder input), `report.json` (builder output). No DB.
**Testing**: Hspec + golden fixtures + QuickCheck for failure-variant coverage
**Target Platform**: Linux x86_64 (musl) + macOS aarch64; library is portable
**Project Type**: single Haskell project — `amaru-treasury-tx` library + `amaru-treasury-tx` (CLI) + `amaru-treasury-tx-api` (HTTP) executables. No frontend or backend split in this slice.
**Performance Goals**: P50 wall-clock for `buildSwapIntent` ≤ existing CLI wizard latency (typically 1–3 s against mainnet N2C). No new chain queries.
**Constraints**: Zero `abortTr` / `die` / `exitWith` reachable from `buildSwapIntent` or `buildSwapTx`. CLI byte-identity preserved (intent.json, CBOR, report.json) across the full golden corpus.
**Scale/Scope**: ~280 lines of `runWizard` redistributed across one new failure-types module and one new builders module. Tx-build side is comparable scope.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | Note |
|---|---|---|
| I. Faithful port of bash recipes | PASS | The refactor is internal — bash entrypoint behaviour is unchanged. Golden CBOR + intent.json + report.json fixtures pin the CLI surface. |
| II. Pure builders, impure shell | PASS, REINFORCED | This refactor strengthens the principle: `buildSwapIntent` / `buildSwapTx` get teased OUT of the "impure shell" and become callable values that the CLI shell happens to wrap. The `Tracer IO Text` injection becomes a parameter rather than a process-global. |
| III. Pluggable data source, local-node default | PASS | No backend change. The wizard continues to call the existing `Provider IO` via N2C. The new functions accept the same `GlobalOpts` and resolve the backend the same way. |
| IV. Build, never sign or submit | PASS | This slice only touches building. No new submission paths. |
| V. Test-first with golden CBOR fixtures (NON-NEGOTIABLE) | PASS | The whole refactor is gated by golden tests on intent.json + CBOR + report.json. A failed golden = a failed refactor. |
| VI. Hackage-ready Haskell | PASS | New modules ship with module Haddock, explicit export lists, `-Werror`, fourmolu, hlint. The `WizardFailure`/`BuildFailure` sum types get full Haddock per variant. |
| VII. Label-1694 metadata: bash parity over spec body-shape | PASS | Out of scope — this refactor does not touch metadata construction. |
| VIII. IPFS-anchored disbursement evidence (NON-NEGOTIABLE) | PASS | Out of scope — swap, not disburse. |

No violations. No Complexity Tracking entries required.

## Project Structure

### Documentation (this feature)

```text
specs/259-swap-wizard-pure/
├── plan.md              # This file
├── research.md          # Phase 0 — design decisions resolved
├── data-model.md        # Phase 1 — WizardFailure / BuildFailure sum types + SwapIntent recap
├── quickstart.md        # Phase 1 — how a caller (CLI or HTTP) invokes the new functions
├── contracts/
│   ├── failures.md      # The two failure sum-types' constructor list + payload schema
│   └── builders.md      # buildSwapIntent / buildSwapTx call signatures + invariants
└── tasks.md             # Phase 2 — created by /speckit.tasks
```

### Source Code (repository root)

```text
amaru-treasury-tx/
├── lib/Amaru/Treasury/
│   ├── Cli/
│   │   └── SwapWizard.hs            # runWizard (refactored — thin CLI wrapper)
│   ├── Build/
│   │   └── Swap.hs                  # tx-build pipeline (refactored — pure-ish entry)
│   ├── Tx/
│   │   └── Swap.hs                  # SwapPayload + intent shape (unchanged)
│   └── Wizard/                      # NEW directory
│       ├── Failure.hs               # WizardFailure + BuildFailure + FieldId sum types
│       ├── Event.hs                 # WizardEvent + BuildEvent + renderWizardEvent / renderBuildEvent
│       └── Swap.hs                  # buildSwapIntent + buildSwapTx pure-ish entry points + ChainEnv
├── test/
│   ├── unit/Amaru/Treasury/Wizard/
│   │   ├── FailureSpec.hs           # Per-variant constructor coverage
│   │   └── SwapSpec.hs              # buildSwapIntent / buildSwapTx unit-style
│   └── golden/swap/                 # Existing golden fixtures (untouched)
└── app/amaru-treasury-tx/Main.hs    # Unchanged — dispatches CmdSwapWizard through runWizard
```

**Structure Decision**: Single Haskell project. New `lib/Amaru/Treasury/Wizard/` directory hosts the failure types and pure-ish builders. The CLI module (`Cli/SwapWizard.hs`) stays as a thin wrapper. The `Build/Swap.hs` module receives a similar split — its pure-ish core moves into the same `Wizard/` directory as `buildSwapTx`.

## Complexity Tracking

No violations. Section intentionally empty.
