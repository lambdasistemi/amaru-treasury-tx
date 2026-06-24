# Tasks: HTTP Swap Re-rate Build Endpoint

**Input**: Design documents from `/specs/401-http-rerate/`  
**Prerequisites**: `plan.md`, `spec.md`, `contracts/http-swap-rerate.md`

**Tests**: Required. This ticket is TDD; each implementation slice starts with a failing focused test.

## Phase 1: Setup

**Purpose**: Bootstrap is already complete.

- [X] T400 Add temporary PR `gate.sh` in repository root and open draft PR #414.

---

## Phase 2: User Story 1 - Route and Stubbed Request/Response (Priority: P1)

**Goal**: `POST /v1/build/swap-rerate` exists, decodes a request, calls the handler, and returns a typed response.

**Independent Test**: `nix develop --quiet -c just unit "Amaru.Treasury.Api.Server"` fails before the route exists and passes after the route/handler wiring is added.

### Tests

- [X] T401 [US1] Write failing WAI request/response test for `/v1/build/swap-rerate` in `test/unit/Amaru/Treasury/Api/ServerSpec.hs`.

### Implementation

- [X] T401 [US1] Add `Amaru.Treasury.Api.BuildSwapRerate` request/response types in `lib/Amaru/Treasury/Api/BuildSwapRerate.hs`.
- [X] T401 [US1] Wire `BuildSwapRerate` through `JsonAPI`, `Handlers`, `BuildHandlers`, `mkBuildHandlers`, and `mkServer` in `lib/Amaru/Treasury/Api/Server.hs`.
- [X] T401 [US1] Inject the runner in `app/amaru-treasury-tx-api/Main.hs`.
- [X] T401 [US1] Expose the new module in `amaru-treasury-tx.cabal`.
- [X] T401 [US1] Run focused test, run `./gate.sh`, and commit as `feat(api): route swap-rerate build endpoint` with `Tasks: T401`.

---

## Phase 3: User Story 2/3 - Runner, Decisions, Typed Failures (Priority: P1)

**Goal**: The endpoint reuses the merged re-rate planner/builder to return single/split decisions and typed failure tags.

**Independent Test**: Focused unit tests fail before `runBuildSwapRerate` is implemented and pass after it delegates to the re-rate core.

### Tests

- [ ] T402 [US2] Write failing tests for single-tx and split response decisions in `test/unit/Amaru/Treasury/Api/ServerSpec.hs` or `test/unit/Amaru/Treasury/Api/BuildSwapRerateSpec.hs`.
- [ ] T402 [US3] Write failing tests for off-scope, over-budget-with-no-valid-split, and value-conservation/build failure tags.

### Implementation

- [ ] T402 [US2] Implement `runBuildSwapRerate` in `lib/Amaru/Treasury/Api/BuildSwapRerate.hs` by calling the merged planner/builder modules.
- [ ] T402 [US2] Return machine-readable single/split decision, reason, estimate, and split groups.
- [ ] T402 [US3] Return stable typed failure tags for planner and builder failures.
- [ ] T402 [US2] Run focused test, run `./gate.sh`, and commit as `feat(api): build swap-rerate transactions` with `Tasks: T402`.

---

## Phase 4: Finalization

**Goal**: Contract artifacts and PR metadata match the delivered endpoint.

- [ ] T403 Resolve the `just update-swagger` acceptance item: regenerate `docs/assets/swagger.json` if the current repo provides that asset/generator, or write a Q-file if the generator is genuinely absent.
- [ ] T403 Run `./gate.sh`; if the known `arq`/Build Gate flake appears with zero test failures, rerun before escalating.
- [ ] T403 Update PR body with final behavior and evidence.
- [ ] T403 Drop `gate.sh` only when all tasks are checked and the final gate/audit passes; commit as `chore: finalize swap-rerate build endpoint` with `Tasks: T403` if behavior/artifact changes are included, otherwise use the normal `chore: drop gate.sh (ready for review)` sentinel.

## Dependencies & Execution Order

- Slice 1 (`T401`) must land before runner-specific tests because it creates the endpoint surface and response type.
- Slice 2 (`T402`) depends on Slice 1 and completes the behavior.
- Slice 3 (`T403`) depends on all implementation tasks.

## Parallel Opportunities

- None inside this ticket: route, runner, and finalization touch overlapping API files and should be serialized.

## Notes

- The driver/navigator pair owns all files outside `specs/401-http-rerate/`, `gate.sh`, and PR metadata.
- Do not edit CLI #400 logic or the pure #398/#399 modules except as read-only imports/users.
