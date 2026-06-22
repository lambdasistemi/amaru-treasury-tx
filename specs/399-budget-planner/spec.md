# Feature Spec: Re-rate Budget Planner

## User Story

As a treasury operator selecting pending SundaeSwap orders for re-rate,
I receive either a single atomic re-rate transaction plan when the
selection fits protocol budget, or a typed split plan with the reason it
must split, so the builder never attempts a transaction that exceeds
execution-unit or body-size limits.

## Acceptance

- The budget planner is pure and lives beside the existing re-rate
  value planner. It does not query the node, build a body, or perform
  CLI/API/UI work.
- `Amaru.Treasury.Swap.Rerate.Budget.planRerate` decides `SingleTx`
  when estimated execution units are at or below
  `maxTxExecutionUnits` and estimated size is at or below `maxTxSize`.
- The same function returns `Split [...]` when the full selection is
  over either budget.
- The estimate grows linearly with the number of cancelled orders, with
  per-order execution units and body bytes added to a fixed base.
- The memory budget is respected independently from the step budget, and
  is expected to be the tighter execution-unit limit for normal
  parameters.
- A split plan groups cancelled orders into atomic subsets where every
  subset is individually within budget.
- The replacement order is represented exactly once across a split plan.
- Every decision carries the chosen shape and a reason suitable for
  later operator-facing surfacing.
- Unit coverage proves:
  - within-budget selection produces `SingleTx`;
  - one-over-the-line selection produces `Split`;
  - large selections produce multiple split groups;
  - exact-limit selections remain `SingleTx`.

## Non-Goals

- Changing the #398 validation planner or pure body builder logic.
- CLI, HTTP, or UI surfacing of the planner decision.
- Live chain reads, fee balancing, signing, witness collection, or
  submission.

## Constraints

- The planner takes protocol parameters as data and returns typed data.
- The build-side budget guard invariant from #395 must hold: over-budget
  work falls back to a split plan instead of overflowing protocol
  limits.
- Split plans are about budget shape only. Later tickets decide how to
  render, build, and submit the split flow.
