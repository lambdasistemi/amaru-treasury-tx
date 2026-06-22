# Implementation Plan: Pure Swap Re-Rate Body Builder

## Technical Approach

Add a new pure module tree under `lib/Amaru/Treasury/Swap/Rerate/`.
The module tree owns only re-rate-specific data shapes, validation,
value planning, and the pure `TxBuild` program. It reuses:

- `Amaru.Treasury.Tx.SwapCancel.Datum` for order owner/destination
  validation.
- `Amaru.Treasury.Redeemer.sundaeCancelRedeemer` for cancellation.
- `Amaru.Treasury.Tx.Swap.swapOrderDatum` for replacement order datums.
- `Cardano.Tx.Build` primitives matching `Swap` and `SwapCancel`.
- `Build.Common.validateFinalPhase1` in the build runner.

The first implementation slice establishes pure typed validation and
planning. The second slice wires the `TxBuild` program. The third slice
adds the `ChainContext` build runner and phase-1 proof. This keeps each
commit bisect-safe and keeps later #399/#400/#401 consumers from
depending on half-shaped builder APIs.

## Proposed Modules

- `Amaru.Treasury.Swap.Rerate.Types`
  - `RerateIntent`
  - `RerateOrder`
  - `RerateScopeContext`
  - `ResolvedRerateInputs`
  - `RerateError`
  - `PlannedRerateOrder`
- `Amaru.Treasury.Swap.Rerate.Plan`
  - validate non-empty orders and positive rate
  - validate datum owner/destination using `validateSwapOrderDatum`
  - calculate conserved offered lovelace and requested USDM
  - ensure replacement output value includes configured extra lovelace
- `Amaru.Treasury.Swap.Rerate`
  - `rerateProgram :: PlannedRerate -> TxBuild q e ()`
  - small wrapper from intent/input to plan + program if practical
- `Amaru.Treasury.Build.SwapRerate`
  - build/evaluate/serialize with `ChainContext`
  - missing-UTxO diagnostics
  - `validateFinalPhase1`

Exact names may be adjusted by the driver if the resulting API is
clearer, but the module tree must remain under
`Amaru.Treasury.Swap.Rerate`.

## Slice Boundaries

### Slice 1: Typed validation and value planning

Create the re-rate type and planning modules plus unit tests for:
single order plan, multi-order plan, off-scope rejection, empty order
rejection, non-positive rate rejection, and offered-value conservation.
No transaction body is built in this slice.

### Slice 2: Pure transaction program

Add `rerateProgram` and structural `draft` tests. The body must spend
wallet + every selected order, use wallet collateral, reference the
order script and scope refs, withdraw zero, emit replacement order
outputs before any change/leftover outputs, require scope signers, and
set the upper bound.

### Slice 3: ChainContext build runner and phase-1 proof

Add the build runner that mirrors `Build.SwapCancel` and existing
action runners: check required UTxOs, build, align fee if needed,
evaluate scripts, call `validateFinalPhase1`, and return `BuildResult`
with order outputs surfaced. Add frozen-context proof tests.

## Testing

Focused tests:

- `nix develop --quiet -c just unit "Amaru.Treasury.Swap.Rerate"`
- `nix develop --quiet -c just unit "Amaru.Treasury.Build.SwapRerate"`

Full gate:

- `./gate.sh`

The full gate remains required before each accepted slice and before
finalization. If GitHub CI hits the known flaky RDF/Jena hermetic-check
failure, rerun the failed job before investigating code.

## Constraints

- No CLI, HTTP, or UI files in this ticket.
- No live node dependency.
- No new low-level Sundae validator logic.
- No cross-scope batch.
- Do not change existing swap or swap-cancel semantics except where a
  shared helper is needed and covered by tests.
