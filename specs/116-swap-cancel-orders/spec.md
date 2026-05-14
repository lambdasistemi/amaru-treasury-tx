# Feature Specification: Cancel Pending SundaeSwap Orders

**Feature Branch**: `116-swap-cancel-orders`  
**Created**: 2026-05-14  
**Status**: Draft  
**Input**: Issue #116 — add a command to cancel pending SundaeSwap
orders discovered by `treasury-inspect` (#109).

## Background

Treasury swaps place one or more pending SundaeSwap order outputs on
chain. If an order is stuck, stale, or no longer desired, operators need
a first-class treasury command to retract it and return the locked value
under treasury control. Today that requires manual transaction assembly
and detailed knowledge of SundaeSwap order datums.

This feature depends on #109 for discovery of pending swap orders. Until
that discovery command lands, this work can still define the cancel
surface, validate order ownership, parse the order authority, and build
the pure cancellation transaction from an explicitly supplied order UTxO.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Build A Cancel Transaction (Priority: P1)

A treasury operator has identified a pending swap order and wants an
unsigned cancellation transaction body that can be reviewed, signed, and
submitted through the existing treasury workflow.

**Why this priority**: this is the core operational need. The command is
useful even before #109 is complete if the operator already knows the
order UTxO.

**Independent Test**: provide a frozen order UTxO, metadata, scope, and
wallet fuel input. The command emits unsigned CBOR plus a report naming
the cancelled order, returned assets, and required signers.

**Acceptance Scenarios**:

1. **Given** a pending SundaeSwap order that belongs to the selected
   treasury scope, **When** the operator runs the cancel command with
   that order reference, **Then** the command builds an unsigned
   cancellation transaction body.
2. **Given** the cancellation transaction is built, **When** the report
   is inspected, **Then** it names the order reference, returned value,
   treasury destination, and required signers.
3. **Given** the order value includes native assets, **When** the
   transaction is built, **Then** the returned value preserves those
   assets and transaction fees are paid from wallet fuel.

---

### User Story 2 - Prevent Cancelling The Wrong Order (Priority: P1)

An operator or automation may accidentally point at an unrelated
SundaeSwap order. The command must reject orders that are not owned by
the Amaru treasury authority or do not return to the selected treasury.

**Why this priority**: a cancel command is high-risk. It must fail closed
when the order datum does not match the selected treasury.

**Independent Test**: provide an order datum with an owner or destination
that does not match metadata for the selected scope. The command fails
before producing CBOR.

**Acceptance Scenarios**:

1. **Given** an order whose owner policy does not match the treasury
   owners, **When** the cancel command runs, **Then** it fails before
   transaction construction and explains the mismatch.
2. **Given** an order whose destination is not the selected treasury,
   **When** the cancel command runs, **Then** it fails before
   transaction construction and explains the mismatch.
3. **Given** an order datum shape the tool cannot safely interpret,
   **When** the cancel command runs, **Then** it fails closed and does
   not guess required signers.

---

### User Story 3 - Use Inspect Output As Input (Priority: P2)

After #109 lands, an operator should be able to copy or pipe a pending
order reported by `treasury-inspect` into the cancel command without
manually re-entering protocol details.

**Why this priority**: this ties the follow-on command into the operator
workflow, but it is blocked by #109's final report shape.

**Independent Test**: using a recorded `treasury-inspect` pending-order
entry, run the cancel command and verify it selects the same order and
returns the same assets reported by inspect.

**Acceptance Scenarios**:

1. **Given** `treasury-inspect` reports a pending order, **When** the
   operator supplies that order to the cancel command, **Then** the
   command builds the cancellation without requiring datum re-entry.
2. **Given** the inspect report is stale and the order is no longer
   present, **When** the cancel command runs, **Then** it fails with a
   spent-or-missing-order diagnostic.

### Edge Cases

- The order has already been scooped or cancelled before the command
  runs.
- The order datum is missing, malformed, or not a SundaeSwap V3 order.
- The order owner uses an authority form outside the initial supported
  treasury policy.
- Wallet fuel cannot cover normal transaction fees or collateral.
- The order reference belongs to another treasury scope.
- Multiple pending orders from the same swap must be cancelled one at a
  time unless batch cancellation is explicitly added later.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The system MUST provide a `swap-cancel` or equivalent
  command that builds an unsigned transaction body to cancel exactly one
  pending SundaeSwap order.
- **FR-002**: The command MUST accept network, node socket, metadata,
  scope, wallet fuel, order reference, and output/report options
  consistent with existing treasury commands.
- **FR-003**: The command MUST validate that the order datum owner
  matches the Amaru treasury cancellation authority before building.
- **FR-004**: The command MUST validate that the order destination
  returns funds under the selected treasury scope before building.
- **FR-005**: The command MUST derive required cancellation signers from
  the order datum; operators must not provide them manually as an
  unchecked override.
- **FR-006**: The command MUST fail closed when the order datum cannot be
  safely interpreted.
- **FR-007**: The cancellation transaction MUST preserve the cancelled
  order value in the treasury return output, with wallet fuel paying
  normal fees.
- **FR-008**: The command MUST produce human-readable and JSON output
  that identifies the order reference, treasury destination, returned
  assets, required signers, and next signing/submission steps.
- **FR-009**: The command MUST be compatible with the pending-order
  discovery output from #109 once that output is available.
- **FR-010**: The command MUST NOT sign or submit transactions.

### Key Entities

- **Pending Swap Order**: an open SundaeSwap order UTxO with value and
  inline datum.
- **Cancel Authority**: the signer policy encoded in the order datum.
- **Treasury Destination**: the selected Amaru treasury script
  destination that should receive the cancelled funds.
- **Cancel Build Report**: operator-facing summary of the unsigned
  cancellation transaction.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A frozen pending order fixture can be cancelled into a
  deterministic unsigned transaction body and report.
- **SC-002**: Tests prove mismatched owner and mismatched destination
  orders are rejected before CBOR output.
- **SC-003**: Tests prove all signer hashes required by the Amaru
  treasury order owner policy are present in the transaction body.
- **SC-004**: Tests prove the returned output preserves ADA and native
  assets from the cancelled order while fees are paid from wallet fuel.
- **SC-005**: The command documentation lets an operator go from a
  pending order reference to an unsigned cancellation body without
  needing SundaeSwap protocol internals.

## Assumptions

- #109 will provide the canonical discovery and reporting shape for
  pending orders.
- The first supported order shape is the current Amaru-generated
  SundaeSwap V3 order: treasury owner policy and treasury script
  destination.
- Batch cancellation is out of scope for this issue.
- Signing and submission remain handled by existing external steps.

