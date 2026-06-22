# Tasks: CLI Swap Re-Rate

**Input**: Design documents from `specs/400-cli-rerate/`  
**Prerequisites**: `plan.md`, `spec.md`  
**Tests**: Required by #400 and the ticket brief; every behavior slice
uses RED -> GREEN unless explicitly documented as a shell-smoke RED-skip.

## Phase 1: Setup

- [X] T400-S0 Create `/code/amaru-treasury-tx-issue-400` on branch `400-cli-rerate`
- [X] T400-S0 Add PR-local `gate.sh` in `/code/amaru-treasury-tx-issue-400/gate.sh`
- [X] T400-S0 Open draft PR #408 linked to #400

## Phase 2: Planning

- [X] T400-P1 Write feature spec in `specs/400-cli-rerate/spec.md`
- [X] T400-P2 Write implementation plan in `specs/400-cli-rerate/plan.md`
- [X] T400-P3 Write executable task breakdown in `specs/400-cli-rerate/tasks.md`
- [X] T400-P4 Run cross-artifact analysis for spec/plan/tasks consistency
- [X] T400-P5 Commit planning artifacts

## Slice 1: CLI Surface And Branch Logic

**Goal**: A visible `swap-rerate` command parses the operator contract
and exposes testable branch decisions without changing existing
swap-wizard/swap-cancel behavior.

**Independent Test**: `nix develop --quiet -c just unit "SwapRerate"`

- [X] T400-S1 Add RED parser/branch tests in `test/unit/Amaru/Treasury/Cli/SwapRerateSpec.hs`
- [X] T400-S1 Add `Amaru.Treasury.Cli.SwapRerate` to `amaru-treasury-tx.cabal`
- [X] T400-S1 Wire `CmdSwapRerate` in `lib/Amaru/Treasury/Cli.hs`
- [X] T400-S1 Dispatch `CmdSwapRerate` in `app/amaru-treasury-tx/Main.hs`
- [X] T400-S1 Implement parser, option record, selection mode, and report data in `lib/Amaru/Treasury/Cli/SwapRerate.hs`
- [X] T400-S1 Verify existing command help remains intact with `nix develop --quiet -c just smoke`
- [X] T400-S1 Commit as `feat(cli): add swap rerate command surface`

## Slice 2: Offline Re-Rate Build And Split Fallback

**Goal**: Fixture-backed offline inputs build a real unsigned re-rate
transaction when within budget and produce an explicit split fallback
when over budget.

**Independent Test**: `nix develop --quiet -c just unit "SwapRerate"`
and `nix develop --quiet -c just smoke`

- [X] T400-S2 Add RED unit tests for single-tx, over-budget split, wrong-scope rejection, decline-retract, and no-orders passthrough in `test/unit/Amaru/Treasury/Cli/SwapRerateSpec.hs`
- [X] T400-S2 Implement offline input resolution and `runSwapRerate` invocation in `lib/Amaru/Treasury/Cli/SwapRerate.hs`
- [X] T400-S2 Implement split report rendering with planner reason in `lib/Amaru/Treasury/Cli/SwapRerate.hs`
- [X] T400-S2 Add fixture-backed CLI smoke script `scripts/smoke/swap-rerate-offline`
- [X] T400-S2 Wire `scripts/smoke/swap-rerate-offline` into `justfile`
- [X] T400-S2 Add required smoke script path/module entries to `amaru-treasury-tx.cabal`
- [X] T400-S2 Verify CBOR/report artifact is non-empty and JSON schema-valid in the smoke
- [X] T400-S2 Commit as `feat(cli): build offline swap rerate transactions`

## Slice 3: Live Discovery And Devnet Boundary Smoke

**Goal**: The live N2C path discovers pending scope orders, gathers the
complete required UTxO set, and has conclusive phase-2 proof.

**Independent Test**: `nix develop --quiet -c just devnet-smoke node`
plus the new rerate devnet smoke command or named transcript.

- [ ] T400-S3 Add live pending-order discovery and operator selection in `lib/Amaru/Treasury/Cli/SwapRerate.hs`
- [ ] T400-S3 Ensure live gathering includes selected orders, wallet fuel/collateral, order script ref, scopes ref, permissions ref, treasury ref, and registry ref in `lib/Amaru/Treasury/Cli/SwapRerate.hs`
- [ ] T400-S3 Add `test/devnet/Amaru/Treasury/Devnet/RerateSmoke.hs`
- [ ] T400-S3 Wire `Amaru.Treasury.Devnet.RerateSmoke` into `test/devnet/Spec.hs` and `amaru-treasury-tx.cabal`
- [ ] T400-S3 Run the devnet smoke or create the named operator transcript artifact and link it in PR #408
- [ ] T400-S3 Commit as `test(devnet): prove swap rerate live boundary`

## Phase 4: Finalization

- [ ] T400-F1 Run `./gate.sh` at HEAD and record output
- [ ] T400-F2 Update PR #408 body with delivered behavior and devnet proof artifact
- [ ] T400-F3 Confirm every implementation task is checked in this file
- [ ] T400-F4 Drop `gate.sh` only after the devnet proof requirement is satisfied
- [ ] T400-F5 Mark PR #408 ready for review

## Dependencies & Execution Order

1. Planning artifacts must commit before implementation dispatch.
2. Slice 1 precedes Slice 2 because offline build depends on the command
   shape and tests.
3. Slice 2 precedes Slice 3 because the live path reuses the offline
   build/report machinery.
4. Finalization cannot start until either the devnet smoke is green or
   the named operator transcript exists and is linked in PR #408.

## Parallel Opportunities

Within a slice, driver and navigator execute the RED/GREEN review loop.
Across slices, work is serial because each later slice depends on the
previous command/report surface.

## Notes

- Do not edit HTTP endpoint or Operate UI files; those belong to #401
  and #402.
- Do not rewrite #398/#399 pure re-rate planner/builder logic unless a
  missing export blocks CLI integration and the ticket owner approves a
  scoped plan update.
- Product CLI emits unsigned bodies only. Devnet signing/submission is
  test-only proof.
