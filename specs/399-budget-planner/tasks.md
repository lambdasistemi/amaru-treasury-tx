# Tasks: Re-rate Budget Planner

## Slice 0 — Bootstrap

- [X] T399-S0 Create `/code/amaru-treasury-tx-issue-399` from
  `origin/main`.
- [X] T399-S0 Add PR-local `gate.sh`.
- [X] T399-S0 Push `399-budget-planner` and open draft PR #407.
- [X] T399-S0 Commit spec, plan, and tasks.

## Slice 1 — Pure Budget Planner

- [X] T399-S1 Add RED unit tests for within-budget, one-over-line,
  large-N multi-split, and exact-limit boundary cases.
- [X] T399-S1 Add additive plan/split/reason/estimate types.
- [X] T399-S1 Add
  `Amaru.Treasury.Swap.Rerate.Budget.planRerate`.
- [X] T399-S1 Ensure split groups are stable, atomic, individually
  within budget where possible, and create the replacement order once.
- [X] T399-S1 Register the module and unit spec in the Cabal file.
- [X] T399-S1 Run focused unit tests and `./gate.sh`.
- [X] T399-S1 Commit:
  `feat(rerate): add budget split planner`.
