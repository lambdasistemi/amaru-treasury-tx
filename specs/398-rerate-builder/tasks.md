# Tasks: Pure Swap Re-Rate Body Builder

## Slice 1 — Typed Validation And Value Planning

- [X] T001 Add `Amaru.Treasury.Swap.Rerate.Types` with exported intent,
  order, scope context, planned order, and typed error shapes.
- [X] T002 Add pure planning that rejects empty selections,
  non-positive rates, malformed/off-scope order datums, and
  value-conservation failures.
- [X] T003 Add unit tests covering single-order planning,
  multi-order planning, off-scope rejection, value conservation, and
  rate-derived requested USDM.
- [X] T004 Add the new modules/tests to `amaru-treasury-tx.cabal`.
- [X] T005 Run focused unit tests and `./gate.sh`, then commit as:
  `feat(rerate): add typed re-rate planning`.

## Slice 2 — Pure TxBuild Program

- [ ] T006 Add `Amaru.Treasury.Swap.Rerate.rerateProgram` using the
  planned re-rate shape.
- [ ] T007 Spend each selected order with `sundaeCancelRedeemer`, use the
  wallet as collateral, reference the order script and scope refs,
  withdraw zero, emit replacement order outputs, require scope signers,
  and set validity.
- [ ] T008 Add structural `draft` tests for single-order and multi-order
  transaction bodies.
- [ ] T009 Add tests proving replacement outputs include inline datums
  built with the new rate and preserve offered ADA plus order extra
  lovelace.
- [ ] T010 Run focused unit tests and `./gate.sh`, then commit as:
  `feat(rerate): build pure cancel-and-reoffer body`.

## Slice 3 — ChainContext Runner And Phase-1 Proof

- [ ] T011 Add `Amaru.Treasury.Build.SwapRerate` with a
  `ChainContext`-backed runner that checks required UTxOs, builds,
  evaluates, and serializes the unsigned body.
- [ ] T012 Call `validateFinalPhase1` and surface typed
  `BuildResult`/diagnostics consistent with existing build runners.
- [ ] T013 Add frozen-context unit/golden coverage proving the final
  body passes phase-1 validation.
- [ ] T014 Add cabal entries for the build runner and tests.
- [ ] T015 Run focused unit tests and `./gate.sh`, then commit as:
  `feat(rerate): validate re-rate bodies against chain context`.

## Finalization

- [ ] T016 Run `./gate.sh` at HEAD.
- [ ] T017 Update PR body with delivered behavior and verification.
- [ ] T018 Drop `gate.sh` in the final ready-for-review commit.
