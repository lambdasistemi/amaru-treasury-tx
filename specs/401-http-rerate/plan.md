# Implementation Plan: HTTP Swap Re-rate Build Endpoint

**Branch**: `401-http-rerate` | **Date**: 2026-06-24 | **Spec**: [spec.md](spec.md)
**Input**: Feature specification from `/specs/401-http-rerate/spec.md`

## Summary

Add a stateless `POST /v1/build/swap-rerate` endpoint beside the existing `POST /v1/build/swap` route. The endpoint should preserve the current API build-handler shape, rate limiting, and runtime provider wiring while delegating all re-rate planning/building to the merged `Amaru.Treasury.Swap.Rerate.*` and `Amaru.Treasury.Build.SwapRerate` modules.

## Technical Context

**Language/Version**: Haskell, GHC 9.12.3 via Nix/haskell.nix  
**Primary Dependencies**: Servant, Aeson, Hspec/WAI Test, cardano-node-clients provider, cardano-ledger Conway types  
**Storage**: None for this endpoint; uses the server's existing indexer-backed provider and metadata at request time  
**Testing**: Hspec unit tests through `just unit`, with RED/GREEN focused tests first  
**Target Platform**: Linux API server executable `amaru-treasury-tx-api`  
**Project Type**: Haskell CLI plus HTTP service  
**Performance Goals**: Same build latency profile as the existing `/v1/build/swap` endpoint; no new long-lived state  
**Constraints**: Pure core reuse; no signing/submission; #400 CLI and #398/#399 core are read-only; fourmolu 70-column formatting; `./gate.sh` before completion  
**Scale/Scope**: One scope per request; multiple selected orders within that scope; no UI or docs work

## Constitution Check

- **Faithful port / pure builders**: Pass. The endpoint wraps existing pure re-rate planner/builder logic instead of creating a second transaction algorithm.
- **Build, never sign or submit**: Pass. The response contains unsigned build artifacts only.
- **Test-first**: Pass condition for implementation slices. The driver must write the endpoint request/response test first and observe it fail before handler code.
- **Hackage-ready Haskell**: Pass condition for implementation slices. New exports need Haddock, explicit export lists, fourmolu formatting, and warning-clean build.

## Project Structure

### Documentation (this feature)

```text
specs/401-http-rerate/
+-- spec.md
+-- plan.md
+-- tasks.md
+-- checklists/
|   +-- requirements.md
+-- contracts/
    +-- http-swap-rerate.md
```

### Source Code

```text
lib/Amaru/Treasury/Api/
+-- BuildSwap.hs                  # existing mirror point; read-only except shared imports if required
+-- BuildSwapRerate.hs            # new endpoint request/response/runner module
+-- Server.hs                     # route, handlers, build-handler wiring

app/amaru-treasury-tx-api/Main.hs # inject runner into BuildHandlers

test/unit/Amaru/Treasury/Api/
+-- ServerSpec.hs                 # WAI request/response and JSON round-trip tests

amaru-treasury-tx.cabal           # expose new module if required by the library stanza

docs/assets/swagger.json          # regenerate only if a current generator exists
```

**Structure Decision**: Mirror the existing `BuildSwap`/`Server` pattern. Keep transaction and planner logic in the existing re-rate modules.

## Design Notes

- Request data should be sufficient to construct or resolve `RerateIntent` plus `RerateProgramInputs` without accepting client-controlled metadata paths.
- Response data should be machine-readable for the UI: decision, reason, estimate, split groups, success artifacts, and stable failure tags.
- Existing build endpoints attach graph-effect/TTL/proofs after a CBOR success. Re-rate should either receive equivalent additive attachments or explicitly document why the response shape does not support them.
- The current codebase has no visible swagger recipe or swagger asset. The implementation slice must search again after code lands and either regenerate the correct artifact or write a Q-file if the ticket acceptance item cannot be executed in this repo state.

## Slice Plan

### Slice 1 - Route, Types, and Request Test

Add the new API module, route, handler field, build-handler field, API binary injection, and a WAI request/response test. RED must prove `/v1/build/swap-rerate` is not currently routed. GREEN can use a stubbed handler response while the runner details are completed in Slice 2.

Owned files:

- `lib/Amaru/Treasury/Api/BuildSwapRerate.hs`
- `lib/Amaru/Treasury/Api/Server.hs`
- `app/amaru-treasury-tx-api/Main.hs`
- `test/unit/Amaru/Treasury/Api/ServerSpec.hs`
- `amaru-treasury-tx.cabal`

Focused test: `nix develop --quiet -c just unit "Amaru.Treasury.Api.Server"`

Commit subject: `feat(api): route swap-rerate build endpoint`

Tasks: `T401`

### Slice 2 - Pure-core Runner, Decisions, and Typed Failures

Implement `runBuildSwapRerate` so the HTTP runner uses the merged planner and builder. Add runner-level tests for single-tx, split, off-scope, over-budget-with-no-valid-split, and value-conservation/build failure response tagging. Do not fork #398/#399/#400 logic.

Owned files:

- `lib/Amaru/Treasury/Api/BuildSwapRerate.hs`
- `test/unit/Amaru/Treasury/Api/ServerSpec.hs` or a new `test/unit/Amaru/Treasury/Api/BuildSwapRerateSpec.hs`
- `amaru-treasury-tx.cabal` only if a new test module needs exposure

Focused test: `nix develop --quiet -c just unit "swap-rerate"`

Commit subject: `feat(api): build swap-rerate transactions`

Tasks: `T402`

### Slice 3 - Swagger/Schema, Final Gate, PR Metadata

Resolve the `just update-swagger` acceptance item against current repo tooling, regenerate any committed API contract artifact if present, run the full gate, update PR body, and drop `gate.sh` only after all implementation tasks are checked.

Owned files:

- `docs/assets/swagger.json` if the repository has/gains that asset
- `specs/401-http-rerate/tasks.md`
- `gate.sh`
- PR body

Focused test: `./gate.sh`

Commit subject: `chore: finalize swap-rerate build endpoint`

Tasks: `T403`

## Complexity Tracking

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|-------------------------------------|
| None | N/A | N/A |
