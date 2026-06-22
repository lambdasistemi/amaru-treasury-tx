# Feature Specification: Pure Swap Re-Rate Body Builder

**Feature Branch**: `398-rerate-builder`
**Issue**: #398
**Parent Epic**: #395

## User Story

As a treasury operator, I can supply selected pending SundaeSwap order
UTxOs for one scope, the resolved scope context, a wallet fuel UTxO,
and a new ADA/USDM rate, and receive one unsigned transaction body that
cancels those orders and re-offers the conserved value at the new rate.

## Scope

This ticket owns only the pure builder foundation for re-rate. It does
not add CLI, HTTP, or UI wiring. The builder must be reusable by later
children without duplicating transaction logic.

## Functional Requirements

- FR-001: Provide a new pure module tree under
  `Amaru.Treasury.Swap.Rerate` with intent/input/error types and a
  pure `rerateProgram`.
- FR-002: Spend each selected SundaeSwap order UTxO with the existing
  `sundaeCancelRedeemer`.
- FR-003: Reference the existing SundaeSwap order script UTxO.
- FR-004: Validate every selected order datum with the existing
  `SwapCancel.Datum` safe parser before inclusion.
- FR-005: Reject any order whose cancel owner policy or destination
  does not match the selected scope's owners and treasury script hash.
- FR-006: Produce one new SundaeSwap order output per cancelled order,
  using the existing `swapOrderDatum` builder with the new rate.
- FR-007: Conserve each cancelled order's offered ADA into the new order
  output; any offered-amount delta must be typed and surfaced, not
  silently absorbed.
- FR-008: Ensure every new order output includes the configured
  min-UTxO plus Sundae protocol fee rider.
- FR-009: The wallet input is used for fee and collateral only; it must
  not fund the re-offered treasury value.
- FR-010: Reuse the scope ownership shape from current swap builders:
  scope reference inputs, withdraw-zero permissions reward account, and
  required scope-owner signer hashes.
- FR-011: Return typed errors for malformed order datums, off-scope
  orders, empty selections, non-positive rates, and value conservation
  failures.
- FR-012: The build runner must balance/evaluate against a supplied
  `ChainContext` and call `validateFinalPhase1`.

## Acceptance Criteria

- AC-001: A structural unit test proves a single-order re-rate spends
  wallet + order, uses wallet collateral, references the order script
  plus scope references, withdraws zero, requires the scope signers, and
  emits one inline-datum order output.
- AC-002: A structural unit test proves multi-order re-rate stays within
  one scope and emits one replacement order per cancelled order.
- AC-003: A unit test proves an off-scope order is rejected before the
  transaction program is built.
- AC-004: A unit test proves offered ADA is conserved per order and the
  output value includes min-UTxO plus the Sundae rider.
- AC-005: A unit test proves changing the new rate changes only the
  requested USDM amount in the replacement datum, while offered ADA
  remains conserved.
- AC-006: A build-level test proves the final body passes
  `validateFinalPhase1` against a frozen `ChainContext`.

## Non-Goals

- Budget estimation and split planning; owned by #399.
- CLI commands; owned by #400.
- HTTP endpoint; owned by #401.
- Operate UI affordance; owned by #402.
- Signing, witness collection, submission, or live-chain querying.
