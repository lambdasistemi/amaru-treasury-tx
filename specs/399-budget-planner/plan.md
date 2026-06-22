# Implementation Plan: Re-rate Budget Planner

## Status

- Completed: branch, gate, draft PR, and planning artifacts.
- Current: dispatch the single implementation slice to the
  driver+navigator pair.
- Blockers: none.

## Scope

Add a pure budget planner under
`Amaru.Treasury.Swap.Rerate.Budget`, with additive types exported from
`Amaru.Treasury.Swap.Rerate.Types`. Leave the existing
`Amaru.Treasury.Swap.Rerate.Plan.planRerate` and
`Amaru.Treasury.Swap.Rerate.rerateProgram` behavior unchanged.

## Data Shape

The worker may refine names, but the public shape must express:

- `ReratePlan`
  - `SingleTx ReratePlanReason RerateBudgetEstimate [order]`
  - `Split ReratePlanReason RerateBudgetEstimate [RerateSplit]`
- `RerateSplit`
  - one or more cancelled orders in the atomic subset;
  - whether this subset creates the replacement order.
- `ReratePlanReason`
  - within budget;
  - over execution memory;
  - over execution steps;
  - over transaction size.
- `RerateBudgetEstimate`
  - memory, steps, and size estimates.

The exact order element type should follow the existing rerate domain:
use `PlannedRerateOrder` unless the worker finds a stronger reason to
plan over `RerateOrder`.

## Estimator Rules

- Estimate = fixed base + per-order cost * selected order count.
- Compare memory and steps independently against
  `maxTxExecutionUnits`.
- Compare size against `maxTxSize`.
- Boundary is inclusive: equal to the limit is within budget.
- Split grouping is greedy and stable in caller order.
- The replacement order is created exactly once across all split groups,
  preferably in the final group so earlier groups can be understood as
  cancel-only groups.
- If a single order cannot fit within protocol budget, return a split
  with that order isolated and an over-budget reason rather than dropping
  it. The later build guard can surface the impossible subset.

## Owned Files

- `lib/Amaru/Treasury/Swap/Rerate/Budget.hs`
- `lib/Amaru/Treasury/Swap/Rerate/Types.hs` additive exports/types only
- `test/unit/Amaru/Treasury/Swap/Rerate/BudgetSpec.hs`
- `amaru-treasury-tx.cabal` only for exposing the new module and adding
  the new unit spec

Forbidden: CLI, HTTP, UI, sibling worktrees, #398 logic changes, and
other tickets' specs.

## Slice

One bisect-safe implementation slice:

1. RED: add focused unit tests for the four acceptance cases.
2. GREEN: add the planner module/types and Cabal wiring.
3. Run focused unit test, then `./gate.sh`.
4. Commit with:
   `feat(rerate): add budget split planner`

## Gates

Focused:

```bash
nix develop --quiet -c just unit "Rerate.Budget"
```

Full:

```bash
./gate.sh
```

If the known intermittent RDF/Jena shellout flake occurs after tests
show zero failures, retry once before escalating.
