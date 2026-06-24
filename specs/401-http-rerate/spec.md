# Feature Specification: HTTP Swap Re-rate Build Endpoint

**Feature Branch**: `401-http-rerate`  
**Created**: 2026-06-24  
**Status**: Draft  
**Input**: GitHub issue #401, parent epic #395, and ticket brief in `/tmp/epic-395/tx-401/BRIEF.md`

## User Scenarios & Testing

### User Story 1 - Build a Re-rate Transaction (Priority: P1)

As the Operate UI or any API client, I submit one scope, selected pending order references, a new rate, and wallet fee/collateral inputs, then receive the unsigned re-rate transaction when the selection fits the current transaction budget.

**Why this priority**: This is the core endpoint value and unblocks the Operate UI child ticket.

**Independent Test**: A request/response test posts to `/v1/build/swap-rerate` through `mkApplication`, proves the handler is called with the decoded request, and receives a typed success body containing the unsigned CBOR/report fields and a single-transaction decision.

**Acceptance Scenarios**:

1. **Given** selected pending orders for one scope and a valid wallet UTxO, **When** the client posts a new rate, **Then** the response contains the unsigned transaction, report, and a `single_tx` decision with `RerateWithinBudget`.
2. **Given** the same request shape as the CLI re-rate flow, **When** the server builds the transaction, **Then** the handler uses the same pure planner and builder modules as the CLI path.

---

### User Story 2 - Report Split Fallback (Priority: P1)

As an API client, I need to know when the selected orders do not fit in one transaction so I can display the split plan rather than pretending a single unsigned transaction exists.

**Why this priority**: The parent epic requires single transaction where possible and explicit split fallback where required.

**Independent Test**: A request/response test or runner-level unit test posts a request whose planner result is split and asserts the response contains no single build CBOR for the overflowing selection, but does contain split groups, decision, and reason.

**Acceptance Scenarios**:

1. **Given** selected orders that exceed memory, steps, or size budget, **When** the client posts the re-rate request, **Then** the response identifies `split`, carries the `ReratePlanReason`, and lists split groups with the replacement-creating group marked.
2. **Given** no valid split can satisfy the budget, **When** the client posts the request, **Then** the response carries a typed over-budget failure instead of an unsigned transaction.

---

### User Story 3 - Typed Rejection (Priority: P1)

As an API client, I need off-scope selections, planner failures, and value-conservation failures to be machine-readable so the UI can show exact remediation.

**Why this priority**: The UI must distinguish operator selection errors from build failures without parsing prose.

**Independent Test**: Runner-level tests round-trip failure responses for off-scope order, over-budget-with-no-valid-split, and value-conservation/build failure tags.

**Acceptance Scenarios**:

1. **Given** a selected order attributed to another scope, **When** the client posts the request, **Then** the response contains a typed off-scope error that includes the selected order reference and expected/actual scopes.
2. **Given** the builder reports a value-conservation failure, **When** the client posts the request, **Then** the response contains a typed build failure tag and reason without signing or submitting anything.

### Edge Cases

- Empty selected-order list returns a typed no-orders failure, not a plain swap passthrough.
- Non-positive new rates are rejected before build.
- Unknown or malformed UTxO references are typed input failures.
- The endpoint is stateless: no signing, no submission, and no server-side persistence beyond normal logs.
- The current repo has `just update-schema` but no visible `just update-swagger` recipe or `docs/assets/swagger.json`; the implementation must either use the current swagger generator if present in the build environment or record the absence as a ticket-level blocker before claiming that acceptance item.

## Requirements

### Functional Requirements

- **FR-001**: The API MUST expose `POST /v1/build/swap-rerate`.
- **FR-002**: The request MUST include the target scope, selected pending order references, new rate, wallet fee UTxO, and optional collateral UTxO.
- **FR-003**: The handler MUST be stateless: it MUST NOT sign, submit, mutate server state, or persist build requests.
- **FR-004**: The handler MUST reuse the merged re-rate planner and builder modules rather than fork re-rate logic.
- **FR-005**: For within-budget selections, the response MUST include unsigned transaction bytes, text envelope, report JSON, and a machine-readable single/split decision with reason and estimate.
- **FR-006**: For split fallback, the response MUST include the split decision, reason, estimate, and group membership, including which group creates the replacement order.
- **FR-007**: The response MUST surface typed errors for off-scope orders, over-budget-with-no-valid-split, and value-conservation/build failures.
- **FR-008**: The endpoint MUST be wired through the existing build-handler rate limiter.
- **FR-009**: A request/response test MUST cover the new endpoint through the Servant application.
- **FR-010**: Swagger/OpenAPI assets MUST be regenerated if this repository has a current generator for them; otherwise the missing generator/asset must be recorded as a blocker before final acceptance.

### Key Entities

- **SwapRe-rate Build Request**: Scope, selected order references, new rate, wallet input, optional collateral input, and enough order/context data or server-resolved data to build with the pure re-rate core.
- **SwapRe-rate Build Response**: Success data, build artifacts, decision, split plan, and typed failure fields.
- **Re-rate Decision**: Single transaction or split fallback with `ReratePlanReason`, estimate, and selected order grouping.
- **Typed Failure**: Stable tag plus structured detail for planner and builder failures.

## Success Criteria

### Measurable Outcomes

- **SC-001**: A client can post one valid re-rate request and receive a JSON success body with an unsigned transaction and `single_tx` decision.
- **SC-002**: A client can post an over-budget selection and receive a JSON split body with at least one split group and a non-`RerateWithinBudget` reason.
- **SC-003**: Off-scope, over-budget-with-no-valid-split, and value-conservation failures are distinguishable by stable typed tags without parsing human-readable prose.
- **SC-004**: The new endpoint is covered by at least one WAI request/response test and the focused unit test command is green.
- **SC-005**: The final branch passes `./gate.sh`, or any repeated non-implementation gate flake is documented with retry evidence per the ticket brief.

## Assumptions

- The endpoint may mirror the existing `POST /v1/build/swap` response style: HTTP 200 with typed failure fields unless the existing server route rejects the request before the handler.
- The API binary continues to provide server-side metadata and an indexer-backed provider; clients do not send a metadata file path.
- #398, #399, and #400 are already merged on `origin/main` and are read-only dependencies for this ticket.
- UI-specific rendering and documentation are owned by #402 and #403 respectively.
