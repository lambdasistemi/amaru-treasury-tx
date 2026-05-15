# Feature Specification: Swap Wizard All ADA Mode

**Feature Branch**: `009-swap-wizard-all-ada`
**Created**: 2026-05-15
**Status**: Draft
**Input**: User description: "GitHub issue #127: Add a first-class `swap-wizard` mode that swaps all available ADA for USDM for a selected treasury scope, instead of requiring the operator to pre-compute and pass a target `--usdm` amount."

Tracking issue: [#127](https://github.com/lambdasistemi/amaru-treasury-tx/issues/127)

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Swap Remaining Spendable ADA (Priority: P1)

A treasury operator has selected a scope and wants to convert that scope's remaining spendable ADA to USDM. Instead of calculating the target USDM amount in a spreadsheet or shell script, the operator requests an explicit "all ADA" mode and supplies the normal scope, metadata, rate, slippage, split count, and rationale fields. The wizard resolves the live treasury UTxOs, computes the maximum ledger-valid ADA amount, and emits the same swap intent shape accepted by `tx-build`.

**Why this priority**: This removes the manual arithmetic that motivated the issue and makes the live treasury remainder workflow reproducible.

**Independent Test**: Run the swap wizard over a fixture resolver containing pure ADA treasury UTxOs, a known rate, a split count, and known network constants. The produced intent must carry the computed maximum ADA amount, expected chunk count, selected treasury UTxOs, and leftover lovelace.

**Acceptance Scenarios**:

1. **Given** a selected scope with pure ADA treasury UTxOs, verified metadata, and a valid rate, **When** the operator passes `--all-ada --split N`, **Then** the wizard emits an intent whose ADA amount equals available pure ADA minus per-chunk overhead minus the required treasury leftover.
2. **Given** the emitted intent, **When** the operator pipes it through `tx-build`, **Then** the normal swap build path can translate the intent without using a separate all-ADA transaction path.

---

### User Story 2 - Prevent Ambiguous Swap Targets (Priority: P1)

An operator needs clear failures when the requested target mode is ambiguous or unsafe. `--all-ada` must be mutually exclusive with `--usdm`, and chunk sizing must not require a pre-known USDM amount.

**Why this priority**: This mode touches live treasury balances; unclear flag combinations can produce a wrong swap target.

**Independent Test**: Parse the CLI with conflicting or incomplete target flags and assert it fails before any resolver or chain query is run.

**Acceptance Scenarios**:

1. **Given** a command containing both `--all-ada` and `--usdm`, **When** the CLI parses it, **Then** parsing fails with a diagnostic that names the mutually exclusive target modes.
2. **Given** a command containing `--all-ada --chunk-usdm`, **When** the CLI parses it, **Then** parsing fails with a diagnostic explaining that all-ADA mode requires `--split`.

---

### User Story 3 - Explain the Derived Amount (Priority: P2)

A reviewer wants to understand the arithmetic before signing. The wizard trace records the selected UTxOs, available pure ADA, computed ADA spend, implied USDM target, retained leftover, split count, per-chunk overhead, and effective rate.

**Why this priority**: The feature moves arithmetic from an external script into the tool; the audit trail must expose the calculation.

**Independent Test**: Render a `WizardEvent` for an all-ADA calculation and assert the line includes the computed ADA amount, implied USDM, leftover, chunk count, overhead, and rate.

**Acceptance Scenarios**:

1. **Given** a successful all-ADA run, **When** the trace log is inspected, **Then** the log contains the derived amount facts needed to reproduce the intent arithmetic.
2. **Given** a rejected all-ADA run, **When** the diagnostic is inspected, **Then** it names the available ADA, required overhead or leftover, and shortfall reason.

---

### Edge Cases

- The selected scope has no pure ADA treasury UTxO. The wizard aborts with a clear all-ADA diagnostic.
- Available pure ADA cannot cover `split * extraPerChunkLovelace + minimum treasury leftover + at least one lovelace of swap amount`. The wizard aborts with the available and required lovelace.
- `--split` is zero or larger than the derived lovelace amount. The wizard rejects the command or resolver result with a typed error.
- `--chunk-usdm` is supplied with `--all-ada`. The wizard rejects it because the target USDM amount is derived after the ADA amount is known.
- Token-bearing treasury UTxOs exist at the selected scope. All-ADA mode ignores them by default and logs that it used pure ADA only; preserving token-bearing deposits remains outside this feature.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST expose an explicit `swap-wizard --all-ada` target mode.
- **FR-002**: System MUST reject commands that provide both `--all-ada` and `--usdm`, or neither target mode.
- **FR-003**: System MUST define all-ADA mode as "spend the maximum ADA from pure ADA treasury UTxOs for the selected scope"; token-bearing UTxOs MUST NOT be selected by this mode.
- **FR-004**: System MUST compute the all-ADA amount after metadata verification and live treasury UTxO query, inside the wizard resolver path.
- **FR-005**: System MUST reserve the existing minimum treasury leftover lovelace and `split * extraPerChunkLovelace` before deriving the swap ADA amount.
- **FR-006**: System MUST compute chunk size from the derived ADA amount and `--split`, using the existing chunking semantics.
- **FR-007**: System MUST reject `--all-ada --chunk-usdm` with a clear diagnostic.
- **FR-008**: System MUST support both existing rate inputs: `--min-rate` and `--ada-usdm` plus `--slippage-bps`.
- **FR-009**: System MUST derive and log the implied USDM target from the chunk amounts and effective minimum rate.
- **FR-010**: System MUST emit the existing unified swap intent schema and route through the normal `tx-build` path.
- **FR-011**: Unit tests MUST cover max-spend calculation, per-chunk overhead, minimum leftover constraints, pure-ADA filtering, and ambiguous CLI combinations.
- **FR-012**: A smoke or golden test MUST cover a produced all-ADA intent being accepted by intent decoding and translation.
- **FR-013**: Documentation MUST show the operator workflow for swapping remaining ADA.

### Key Entities

- **SwapTarget**: The operator's target mode, either fixed USDM or all-ADA.
- **AllAdaPlan**: The resolved calculation result: selected pure ADA UTxOs, available lovelace, overhead, leftover, amount to swap, chunk size, chunk count, implied USDM, and effective rate.
- **TreasurySelection**: Existing selected treasury inputs and leftover lovelace used by the emitted intent.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Operators can produce a remaining-ADA swap intent without external arithmetic or scripts.
- **SC-002**: Unit tests cover at least one successful all-ADA calculation and at least three failure paths: insufficient ADA, `--all-ada` plus `--usdm`, and `--all-ada` plus `--chunk-usdm`.
- **SC-003**: The derived intent decodes and translates through the existing unified intent path in the test suite.
- **SC-004**: The documentation includes one copy-pasteable `swap-wizard --all-ada` command.

## Assumptions

- All-ADA mode uses pure ADA treasury UTxOs only; token-bearing UTxO deposit handling can be added later with explicit native-asset preservation.
- The minimum ledger-valid leftover is the project's existing `minUtxoDepositLovelace` constant.
- `--split` is the only supported chunking control for all-ADA mode.
