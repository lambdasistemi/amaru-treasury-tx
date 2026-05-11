# Feature Specification: Normalize tx-build Builder Errors

**Feature Branch**: `079-normalize-tx-build-errors`
**Created**: 2026-05-11
**Status**: Draft
**Input**: User description: "Normalize lower-level tx-build builder failures opened as issue #79. Consider ExceptT to clean up the syntax. Exceptions can be structured like tracer events and composed with context; see mapException."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Operator Gets a Stable Build Failure (Priority: P1)

A treasury operator runs `tx-build` on an intent whose selected inputs cannot produce a valid transaction. Instead of seeing an internal-looking Haskell exception such as `runSwap: build failed: BalanceFailed ...`, the operator sees a stable `tx-build` diagnostic that names the failure class and the relevant lovelace figures.

**Why this priority**: this is the direct follow-up to #64/#77. Wizard preflight now catches the known affordability bug, but a stale intent, manually edited intent, or later protocol-parameter change can still fail inside the builder.

**Independent Test**: force a `BuildError` in the swap build path and verify the CLI/report output contains a normalized message and never contains `runSwap: build failed` or raw `user error`.

**Acceptance Scenarios**:

1. **Given** a swap intent that reaches `tx-build` and the balancer reports an insufficient-fee balance failure, **When** the command exits, **Then** stderr and any failure report use a stable `tx-build` message with labeled lovelace fields.
2. **Given** the same failure with `--report -`, **When** the command exits, **Then** stdout is a `{ intent, result: { failure } }` envelope whose failure message is the normalized diagnostic.

---

### User Story 2 - Reports Preserve Structured Failure Semantics (Priority: P2)

A downstream renderer or automation receives a tx-build failure envelope. It should be able to distinguish failure categories by a stable code rather than scraping Haskell constructor text.

**Why this priority**: the report pipeline is now the review surface. Failure envelopes should be as usable as success envelopes.

**Independent Test**: construct representative failure envelopes for balance, fee convergence, collateral, script evaluation, and final validation failures; decode them and assert stable `code` values plus human-readable messages.

**Acceptance Scenarios**:

1. **Given** `tx-build --report failure.json` hits `FeeNotConverged`, **When** the report is read, **Then** `result.failure.code` is stable and the message tells the operator to retry with fresh chain state or report protocol-parameter drift.
2. **Given** collateral is insufficient, **When** the report is read, **Then** required and available collateral lovelace are both labeled.

---

### User Story 3 - Shared Normalization Across Actions (Priority: P3)

A maintainer adds or fixes builder failure handling for one action. The behavior should apply to swap, disburse, and withdraw without copy-pasting separate renderers.

**Why this priority**: the current problem exists three times: `runSwap`, `runDisburse`, and `runWithdraw` each throw raw `BuildError` text.

**Independent Test**: unit tests exercise the shared normalizer directly and at least one action-specific runner path; compile-time structure makes disburse/withdraw call the same normalizer.

**Acceptance Scenarios**:

1. **Given** any action runner receives `BalanceFailed`, **When** it converts the error, **Then** the same code/message policy is used.
2. **Given** an action has a non-balancer failure such as missing UTxOs or fee alignment failure, **When** it exits, **Then** the diagnostic still uses the shared build-failure type and stable wording.

### Edge Cases

- `InsufficientFee` currently carries values that can be misread as "shortfall"; messages must label upstream fields and only compute a shortfall when the semantics are known.
- `ChecksFailed` may contain multiple validation failures; the renderer must preserve all failure details in a bounded single diagnostic.
- `EvalFailure` includes a Plutus purpose and evaluator text; the normalized message must keep both.
- `tx-build` without `--report` must not rely on JSON output to be understandable.
- Report write failure is a separate existing failure path and is not part of this builder-error normalization.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The system MUST convert known `BuildError` cases into a project-owned build failure type before they reach CLI/report output.
- **FR-002**: `BalanceFailed (InsufficientFee ...)` MUST render labeled lovelace fields and MUST NOT present the raw input coin as the shortfall.
- **FR-003**: `FeeNotConverged` MUST render a stable actionable diagnostic.
- **FR-004**: collateral shortfall MUST render required and available collateral lovelace.
- **FR-005**: script evaluation failures MUST preserve the script purpose and evaluator message.
- **FR-006**: final validation failures MUST preserve every validation failure message in a deterministic order.
- **FR-007**: `tx-build --report` failure envelopes MUST contain the normalized code and message.
- **FR-008**: non-report CLI failures MUST print the normalized message and MUST NOT print an uncaught/internal-looking Haskell exception.
- **FR-009**: swap, disburse, and withdraw MUST share the same normalization path.
- **FR-010**: The implementation SHOULD use `ExceptT` or an equivalent local error-flow abstraction inside the IO build runners when it makes the code simpler without changing the pure builders.
- **FR-011**: Expected build exceptions MUST remain structured until the CLI/report boundary, with context composed as data rather than concatenated into strings.
- **FR-012**: When an exception crosses a context boundary, the implementation SHOULD use `mapException` or an equivalent typed wrapper to enrich the exception with additional structured context.

### Key Entities

- **Build Diagnostic**: project-owned classification of a builder failure, including code, action, phase, composable context, and optional numeric fields.
- **Failure Envelope**: existing tx-build output shape `{ intent, result: { failure } }`, populated with normalized diagnostic data.
- **Action Runner**: `runSwap`, `runDisburse`, and `runWithdraw`, which currently convert lower-level errors to exceptions.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: No tested builder failure path emits `runSwap: build failed`, `runDisburse: build failed`, `runWithdraw: build failed`, or `user error` in the user-facing message.
- **SC-002**: Failure envelope `code` values are stable across swap, disburse, and withdraw for the same failure class.
- **SC-003**: Unit tests cover all normalized upstream `BuildError` constructors used by the current dependency version.
- **SC-004**: At least one CLI-level or runner-level test proves `--report` failure output uses the normalized message.

## Assumptions

- The existing success report schema remains unchanged.
- This feature does not change transaction balancing behavior; it only changes error transport and rendering.
- Reorganize remains unshipped and can keep its existing unsupported-action behavior unless it enters the unified builder during this issue.
- `ExceptT` means `Control.Monad.Trans.Except.ExceptT`, not an exception-throwing transformer.
- Structured exceptions should behave like trace events: producers attach typed context, context boundaries may map/enrich the value, and only the outer renderer turns the final value into operator-facing text.
