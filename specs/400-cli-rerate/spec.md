# Feature Specification: CLI Swap Re-Rate

**Feature Branch**: `400-cli-rerate`  
**Created**: 2026-06-22  
**Status**: Draft  
**Input**: GitHub issue #400, parent epic #395, and worker brief

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Build A Re-Rate Transaction (Priority: P1)

As a treasury operator, I can run a scope-specific CLI command, see the
pending SundaeSwap orders that belong to that scope, select the orders
to retract, provide the new ADA/USDM rate, and receive an unsigned
transaction body plus report for the re-rate.

**Why this priority**: This is the command-recovery deliverable. The
ticket is not complete unless the shipped command works end-to-end.

**Independent Test**: Run the command against frozen fixtures in offline
mode and assert it writes non-empty CBOR/TextEnvelope plus a report that
names the selected order, the new rate, the returned value, and signing
steps.

**Acceptance Scenarios**:

1. **Given** a scope with one pending order within protocol budget,
   **When** the operator selects that order and supplies a new rate,
   **Then** the CLI emits one unsigned re-rate transaction that cancels
   the old order and creates the replacement order.
2. **Given** a selection whose budget estimate exceeds one transaction,
   **When** the operator builds the re-rate,
   **Then** the CLI emits the split fallback plan with cancel groups and
   the final replacement step, and states the planner reason.
3. **Given** a selected pending order from a different scope, **When**
   the operator builds the re-rate, **Then** the command rejects it
   before writing a transaction artifact.

---

### User Story 2 - Preserve Plain Swap Behavior (Priority: P1)

As a treasury operator, I can decline retraction or run with no pending
orders and still produce the normal swap build without new surprises.

**Why this priority**: The re-rate affordance must not make the existing
scope-swap workflow worse.

**Independent Test**: Run parser/unit tests for decline-retract and
no-orders paths and verify they dispatch to the existing swap wizard or
plain swap build behavior without selecting re-rate orders.

**Acceptance Scenarios**:

1. **Given** pending orders are listed, **When** the operator declines
   retraction, **Then** the command continues with the plain swap path.
2. **Given** no pending order belongs to the selected scope, **When** the
   operator runs the command, **Then** the plain swap path is unchanged.

---

### User Story 3 - Prove The Live Boundary (Priority: P1)

As a maintainer, I can see a conclusive smoke proving that the live N2C
path gathers every required UTxO and that the validators accept the
cancel-and-reoffer transaction on a devnet.

**Why this priority**: Unit and golden tests use complete frozen
contexts and cannot prove that the CLI asks the node for the full live
UTxO set.

**Independent Test**: Run the devnet re-rate smoke. It creates a pending
order, runs the re-rate, submits the signed test transaction, and
asserts phase-2 acceptance plus the old/new order UTxO transition.

**Acceptance Scenarios**:

1. **Given** a live devnet with a pending order, **When** the smoke runs
   the CLI N2C path, **Then** the submitted transaction is phase-2
   accepted.
2. **Given** that accepted transaction, **When** the smoke queries the
   order address, **Then** the original order UTxO is gone and a new
   order at the supplied rate is present.

### Edge Cases

- No pending order for the selected scope falls back to the normal swap
  path.
- Operator declines retraction despite pending orders.
- Selected order datum is malformed or owned by another scope.
- The selected order carries native assets instead of ADA-only offered
  value.
- The order-script reference is omitted outside mainnet.
- Offline inputs omit one of wallet, selected order, order script ref,
  or registry/scope reference UTxOs; the command fails before writing a
  success artifact.
- The split planner exceeds memory, steps, or size budget.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The CLI MUST expose a shipped swap re-rate command or flow
  that accepts scope, wallet fuel/collateral, new rate, metadata,
  selected pending order(s), outputs, and report/log paths.
- **FR-002**: The command MUST discover pending orders for the selected
  scope when using the live N2C path and MUST allow explicit offline
  order inputs for CI fixtures.
- **FR-003**: The command MUST let the operator select one, some, all,
  or none of the discovered pending orders.
- **FR-004**: If the operator selects no orders or declines retraction,
  the command MUST continue through the plain swap build path without
  changing existing swap behavior.
- **FR-005**: For selected orders within budget, the command MUST call
  the existing `runSwapRerate` path and write exactly one unsigned
  re-rate transaction body.
- **FR-006**: For selected orders over budget, the command MUST call the
  existing #399 planner and surface the split fallback groups plus the
  reason instead of attempting an overflowing transaction.
- **FR-007**: The command MUST identify every retracted order as
  `TXHASH#IX`, the new rate, returned/re-offered value, fee/collateral
  facts when available, and next signing steps.
- **FR-008**: The live N2C build path MUST gather the full required set:
  selected order UTxOs, wallet fuel/collateral, order script reference,
  scopes reference, permissions reference, treasury reference, and
  registry reference.
- **FR-009**: Parser and wizard tests MUST cover orders-present
  single-transaction, over-budget split, decline-retract, no-orders
  passthrough, and wrong-scope rejection.
- **FR-010**: `just smoke` and `nix run .#smoke` MUST run an offline
  `scripts/smoke/swap-rerate-*` check that fails loudly if no
  non-empty transaction artifact is produced.
- **FR-011**: A devnet phase-2 smoke MUST exist and either be green in
  gate or have a named operator transcript linked in the draft PR before
  readiness.
- **FR-012**: The product CLI MUST emit unsigned bodies only; signing and
  submission are allowed only inside the devnet test smoke.

### Key Entities

- **Pending Order**: A SundaeSwap order UTxO, identified by `TxIn`, full
  value, inline datum, and attributed treasury scope.
- **Re-Rate Selection**: The operator's chosen subset of pending orders
  for one scope plus the new ADA/USDM rate.
- **Re-Rate Plan**: The budget planner's single-transaction or split
  decision, including reason and estimates.
- **Re-Rate Artifact**: Unsigned CBOR/TextEnvelope and JSON report
  emitted by the CLI.
- **Boundary Transcript**: Devnet smoke output proving live UTxO
  gathering, phase-2 acceptance, and old/new order transition.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A one-order fixture re-rate command writes a non-empty
  unsigned transaction artifact and schema-valid JSON report in CI.
- **SC-002**: Unit tests exercise all five CLI behavior branches named
  in FR-009.
- **SC-003**: The live N2C path is proven by a devnet smoke or linked
  transcript before the PR leaves draft.
- **SC-004**: Existing `swap-wizard`, `swap-cancel`, and `tx-build`
  smoke checks remain green.

## Assumptions

- A dedicated `swap-rerate` subcommand is the least surprising CLI
  shape because it mirrors `swap-cancel` and emits unsigned CBOR/report
  directly.
- Offline CI uses explicit selected order fixtures; live discovery is
  guarded by the devnet smoke because it requires a node.
- HTTP endpoint and Operate UI work belongs to #401/#402 and is out of
  scope for this ticket.
