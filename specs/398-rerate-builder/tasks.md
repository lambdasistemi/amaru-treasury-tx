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

- [X] T006 Add `Amaru.Treasury.Swap.Rerate.rerateProgram` using the
  planned re-rate shape.
- [X] T007 Spend each selected order with `sundaeCancelRedeemer`, use the
  wallet as collateral, reference the order script and scope refs,
  withdraw zero, emit replacement order outputs, require scope signers,
  and set validity.
- [X] T008 Add structural `draft` tests for single-order and multi-order
  transaction bodies.
- [X] T009 Add tests proving replacement outputs include inline datums
  built with the new rate and preserve offered ADA plus order extra
  lovelace.
- [X] T010 Run focused unit tests and `./gate.sh`, then commit as:
  `feat(rerate): build pure cancel-and-reoffer body`.

## Slice 3 — ChainContext Runner And Phase-1 Proof

- [X] T011 Add `Amaru.Treasury.Build.SwapRerate` with a
  `ChainContext`-backed runner that checks required UTxOs, builds,
  evaluates, and serializes the unsigned body.
- [X] T012 Call `validateFinalPhase1` and surface typed
  `BuildResult`/diagnostics consistent with existing build runners.
- [X] T013 Add frozen-context unit/golden coverage proving the final
  body passes phase-1 validation.
- [X] T014 Add cabal entries for the build runner and tests.
- [X] T015 Run focused unit tests and `./gate.sh`, then commit as:
  `feat(rerate): validate re-rate bodies against chain context`.

## Finalization

- [X] T016 Run `./gate.sh` at HEAD.
- [X] T017 Update PR body with delivered behavior and verification.
- [X] T018 Drop `gate.sh` in the final ready-for-review commit.
