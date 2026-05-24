# Implementation Plan: typed `buildSwapTx` + HTTP + `/operate` CBOR & Report

**Branch**: `270-build-swap-typed` | **Date**: 2026-05-24 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `specs/270-build-swap-typed/spec.md` (#269 follow-up of #259)

## Summary

Land the missing half of #259. Extract a pure-ish `buildSwapTx :: GlobalOpts -> Backend -> SwapIntent -> Tracer IO BuildEvent -> ExceptT BuildFailure IO (CborHex, Report)` from the existing `Build.Swap.runSwap` / `runSwapAction` pipeline; replace every exit-on-error site with a typed `BuildFailure` variant; rewire the CLI through it (byte-identical CBOR + report.json); extend `SwapBuildResponse` with `cborHex` + `report` fields so one `POST /v1/build/swap` returns both; wire `/operate` so the CBOR + Report tabs render real data.

## Technical Context

**Language/Version**: Haskell, GHC 9.6+ (matches `cardano-node-clients`); PureScript / Halogen for the frontend tabs.
**Primary Dependencies**: `cardano-node-clients` (`TxBuild` DSL, `Backend`/`Provider IO`), `cardano-ledger-conway` (Conway tx body, balancing), `cardano-tx-tools` (`Cardano.Tx.Build`, `setMetadata`), `servant-server` (HTTP endpoint), `aeson` (response shape), `browser-json-tree` flake input (frontend rendering of the Report tab).
**Storage**: Filesystem only — `intent.json`, `tx.cbor`, `report.json` (CLI output); HTTP response carries the same payloads in-band. No database, no on-disk state for the API.
**Testing**: Hspec + golden CBOR / JSON fixtures (existing swap corpus extended), QuickCheck properties for the `BuildFailure` constructor coverage harness. The CLI golden corpus is the regression net; the HTTP-shaped harness is the per-variant coverage net.
**Target Platform**: Linux server (Docker container, mainnet-pinned dev deploy), aarch64-darwin for local dev.
**Project Type**: Library + CLI + HTTP API + Halogen frontend (existing project layout, no new top-level dirs).
**Performance Goals**: `POST /v1/build/swap` end-to-end under 5 s against the mainnet-pinned dev container (SC-005); web operator's "fill → click → see" under 10 s (SC-004). These are the existing CLI numbers; no regression.
**Constraints**: Zero byte-diff on every CLI golden fixture (SC-001); zero `exitWith` / `abortTr` / `die` / unchecked `error` reachable from `buildSwapTx` or `buildSwapIntent` (SC-003); bisect-safe — every commit individually passes the Build Gate (SC-006).
**Scale/Scope**: Single tenant; one operator at a time on `/operate`; the existing swap fixture corpus (~handful of golden scenarios) is the test budget.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle                                                       | Pass | Notes                                                                                                                                                                                                                                                                                                                                                                  |
|-----------------------------------------------------------------|------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| I.  Faithful port of the bash recipes                           | ✅   | Refactor preserves byte-identical CLI output (FR-005, FR-006, SC-001). The bash recipes' behaviour, encoded as the v0.2.15.0 golden corpus, is the load-bearing reference; this PR cannot drift from it.                                                                                                                                                               |
| II. Pure builders, impure shell                                 | ✅   | `buildSwapTx` is shape-aligned with the principle: `Backend` is injected, the tx assembly is pure (lives in `cardano-tx-tools` `TxBuild`), only the resolver steps reach the network via `Backend`. The refactor STRENGTHENS this principle by removing the legacy `IORef`-driven exit paths from the build core.                                                       |
| III. Pluggable data source, local-node default                  | ✅   | No backend change. The same pre-opened `Backend IO` flows from CLI / API host through `buildSwapTx`. Local-N2C remains default.                                                                                                                                                                                                                                        |
| IV. Build, never sign or submit                                 | ✅   | `buildSwapTx` returns `CborHex` of an unsigned Conway tx body; signing and submission stay out of tree (offline `attach-witness` + `envelope-*` CLI tools). The HTTP endpoint surfaces the same unsigned bytes.                                                                                                                                                       |
| V.  Test-first with golden CBOR fixtures (NON-NEGOTIABLE)       | ✅   | The plan is TDD: every refactor commit lands AFTER the golden / harness test that pins its target behaviour. The existing swap golden corpus is reused as the regression spine; the new HTTP-shaped harness pins per-`BuildFailure`-variant coverage.                                                                                                                  |
| (#259 echo) Typed failures, no host termination from the core   | ✅   | FR-002 + FR-003 + SC-003 enforce this. Mirrors the #259 contract for `buildSwapIntent`.                                                                                                                                                                                                                                                                                |
| (#259 echo) Tracer informational only                            | ✅   | FR-004. `BuildEvent` mirrors `WizardEvent`; control flow never branches on tracer presence.                                                                                                                                                                                                                                                                            |
| (#259 echo) Pre-opened `Backend` parameter                       | ✅   | `buildSwapTx :: GlobalOpts -> Backend -> SwapIntent -> ...` — no per-call backend lifecycle inside the builder. CLI + API both pass their long-lived `Backend`.                                                                                                                                                                                                       |
| (#259 echo) Sysexits 64 / 69 / 70                                | ✅   | FR-005 keeps the CLI exit taxonomy. The mapping `BuildFailure -> ExitCode` is added next to `sysexitsFor` in `Wizard.Swap`.                                                                                                                                                                                                                                            |

No violations. No `Complexity Tracking` entries required.

## Project Structure

### Documentation (this feature)

```text
specs/270-build-swap-typed/
├── plan.md                  # This file (/speckit.plan output)
├── research.md              # Phase 0 — every NEEDS CLARIFICATION resolved
├── data-model.md            # Phase 1 — BuildFailure / BuildEvent / SwapBuildResponse shapes
├── quickstart.md            # Phase 1 — REPL / curl / browser smoke recipes
├── contracts/
│   ├── http-build-swap.json     # extended SwapBuildResponse JSON schema
│   ├── build-swap-tx.hs.md      # Haskell signature + variant list
│   └── operate-tabs.purs.md     # Halogen tab population contract
├── checklists/
│   └── requirements.md      # (already written) spec-quality checklist
└── tasks.md                 # Phase 2 — /speckit.tasks output
```

### Source Code (repository root, existing layout)

```text
amaru-treasury-tx/
├── lib/Amaru/Treasury/
│   ├── Build/
│   │   └── Swap.hs                  # extract pure-ish core; keep runSwap as thin CLI shim
│   ├── Wizard/
│   │   ├── Failure.hs               # add BuildFailure constructors
│   │   ├── Event.hs                 # add BuildEvent constructors
│   │   └── Swap.hs                  # export buildSwapTx; map BuildFailure -> sysexits
│   ├── Api/
│   │   ├── BuildSwap.hs             # extend SwapBuildResponse, runBuildSwap runs both stages
│   │   └── Server.hs                # already exposes /v1/build/swap; no route change
│   └── Cli/
│       └── SwapWizard.hs            # rewire through buildSwapTx, keep sysexits 64/69/70
├── frontend/
│   └── src/OperatePage.purs         # populate TabCbor + TabReport from response
├── test/
│   ├── unit/Amaru/Treasury/Wizard/
│   │   ├── BuildSwapSpec.hs         # HTTP-shaped per-variant harness (new)
│   │   └── BuildSwapGoldenSpec.hs   # extend existing golden coverage (CBOR + report.json)
│   └── unit/Amaru/Treasury/Api/
│       └── ServerSpec.hs            # extend SwapBuildResponse round-trip
└── specs/270-build-swap-typed/      # this feature
```

**Structure Decision**: Single repository, existing project layout. No new top-level directories. Three Haskell modules grow (`Build.Swap`, `Wizard.Failure`, `Wizard.Event`); two grow + expose new symbols (`Wizard.Swap`, `Api.BuildSwap`); one PureScript module gains real tab-population (`OperatePage.purs`); two test specs grow (one new, two extended). The frontend continues to consume `browser-json-tree` from the flake input for the Report tab.

## Complexity Tracking

> No constitution violations. No entries.

