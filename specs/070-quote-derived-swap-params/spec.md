# Feature Specification: Quote-Derived Swap Parameters

**Feature Branch**: `070-quote-derived-swap-params`
**Created**: 2026-05-09
**Status**: Draft
**Input**: User description from issue [#70](https://github.com/lambdasistemi/amaru-treasury-tx/issues/70): make swap parameter filling quote-derived inside the CLI so operators do not hand-compute `--min-rate`.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Build swaps from an explicit fresh quote (Priority: P1)

A treasury operator wants to request a USDM swap without reusing a stale
example rate or manually calculating the Sundae limit price. The operator
provides, or asks the CLI to fetch, the current ADA/USD or ADA/USDM quote,
then supplies an explicit slippage policy. The CLI derives the minimum
acceptable rate, records the quote provenance, runs the existing swap intent
generation path, and continues into the existing unsigned-transaction build
path.

**Why this priority**: This removes the dangerous manual step that caused the
issue. Without it, the executable still allows an economically stale but
ledger-valid swap transaction.

**Independent Test**: Run the quote-derived swap command with a deterministic
quote override and explicit slippage. Verify that it derives the expected
minimum rate, passes that rate to swap intent generation, and produces the same
intent/build outputs that the existing manual `--min-rate` path would produce
for that derived value.

**Acceptance Scenarios**:

1. **Given** an operator provides an ADA/USD or ADA/USDM quote of `Q` and a
   slippage value of `S` basis points, **When** the quote-derived swap path
   runs, **Then** it computes `minRate = Q * (1 - S / 10000)` and uses that
   value as the minimum rate for the generated swap intent.
2. **Given** the operator does not provide an explicit slippage value, **When**
   the quote-derived path is invoked, **Then** the command exits before intent
   generation with a message requiring a slippage policy.
3. **Given** a quote source is used instead of a quote override, **When** the
   quote is fetched, **Then** the run records the source name and fetch time in
   the audit artifact.

---

### User Story 2 - Stop unaffordable swaps before CBOR output (Priority: P1)

A treasury operator requests a target USDM amount. The CLI derives the ADA
required at the observed quote and explicit slippage, generates the intent
values, and checks the selected treasury lovelace before building unsigned
CBOR. If the selected treasury cannot fund the swap amount plus per-chunk
overhead, the run stops with a clear economic shortfall report.

**Why this priority**: The executable must own the economic safety check before
the transaction body exists. A ledger-valid transaction is not enough if the
requested swap cannot be funded at the derived limit rate.

**Independent Test**: Use fixture quote and treasury values to exercise both an
affordable request and an unaffordable request. The affordable case reaches the
normal build outputs; the unaffordable case exits before unsigned CBOR is
written and reports the required ADA, available ADA, quote, slippage, and
shortfall.

**Acceptance Scenarios**:

1. **Given** generated swap intent values with `amountLovelace`,
   `chunk_count`, and `extraPerChunkLovelace`, **When** the selected treasury
   lovelace is at least `amountLovelace + chunk_count *
   extraPerChunkLovelace`, **Then** the quote-derived path may proceed to the
   existing transaction build path.
2. **Given** the selected treasury lovelace is below that same required total,
   **When** the quote-derived path runs, **Then** it exits before producing
   unsigned CBOR and reports required ADA, available ADA, quote, slippage, and
   shortfall.
3. **Given** chunking changes the number of generated swap orders, **When** the
   affordability check runs, **Then** the overhead term uses the generated
   chunk count rather than an operator-supplied estimate.

---

### User Story 3 - Preserve an auditable operator record (Priority: P2)

A reviewer or signer wants to understand how a swap limit price was chosen.
Successful quote-derived runs write an audit artifact that captures the quote,
where it came from, when it was observed, the explicit slippage policy, the
derived minimum rate, the request parameters, affordability inputs, selected
treasury total, and generated output paths.

**Why this priority**: The operator path must be replayable and reviewable.
Without a durable record, the new workflow would still depend on local shell
history or operator memory.

**Independent Test**: Run the command with a deterministic quote override and
fixture treasury data. Validate the audit artifact shape and values without
requiring live network access.

**Acceptance Scenarios**:

1. **Given** a successful quote-derived run, **When** the command finishes,
   **Then** it writes an audit JSON artifact containing quote, quote source or
   override provenance, fetch or observation time, slippage basis points,
   derived minimum rate, requested USDM amount, chunking, affordability totals,
   selected treasury total, and generated output paths.
2. **Given** a failed affordability check, **When** the command exits, **Then**
   it does not produce unsigned CBOR and still reports the calculation details
   needed to diagnose the shortfall.

---

### User Story 4 - Documentation makes the safe path primary (Priority: P3)

An operator reading the project documentation sees the quote-derived command as
the normal swap workflow. Direct `--min-rate` usage remains documented only as
an expert/manual override, so copy-pasted examples do not encourage stale rates.

**Why this priority**: Documentation caused part of the original process
mistake by presenting a hard-coded example rate. The safe CLI path should be
the first path operators copy.

**Independent Test**: Review the swap documentation and examples. The primary
flow must use the quote-derived command with explicit slippage, while direct
`--min-rate` examples are labelled as manual override material.

**Acceptance Scenarios**:

1. **Given** an operator follows the primary swap documentation, **When** they
   copy the example command, **Then** it requires a fresh quote source or quote
   override and explicit slippage rather than a hard-coded stale `--min-rate`.
2. **Given** an expert needs the old manual path, **When** they read the docs,
   **Then** direct `--min-rate` use is still described as an override with its
   audit responsibility made explicit.

### Edge Cases

- Missing slippage policy: the command must fail before quote fetching or
  intent generation; there is no hidden default.
- Invalid slippage value: negative values and values at or above 10000 basis
  points must be rejected before any build output is produced.
- Invalid or zero quote: the command must reject non-positive or unparsable
  quote values with a message naming the bad input.
- Quote source unavailable: the command must fail before producing intent JSON
  or unsigned CBOR and must identify the unavailable source.
- Quote provenance missing: a quote override must still record that it was an
  explicit operator override, including the observation time supplied or chosen
  for the run.
- Rounding at lovelace precision: rate and affordability calculations must be
  deterministic and conservative so the minimum rate is not rounded upward
  beyond the operator's explicit slippage policy.
- Affordability boundary: exact equality between required ADA and selected
  treasury lovelace is affordable; one lovelace short is not.
- Chunk count drift: affordability must use the chunk count generated by the
  swap intent, not a stale count from flags or documentation.
- Audit write failure: if the audit artifact cannot be written, the run must
  fail visibly rather than silently losing the calculation record.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST expose an operator-facing CLI path for quote-derived
  swap parameter filling that can run the existing `swap-wizard` plus
  `tx-build` flow without requiring the user to hand-compute `--min-rate`.
- **FR-002**: The quote-derived path MUST accept either an explicit quote
  override, such as ADA/USD or ADA/USDM, or a named quote source. Every run MUST
  record where the quote came from and when it was observed or fetched.
- **FR-003**: The quote-derived path MUST require an explicit slippage policy,
  such as slippage basis points. There MUST be no hidden default slippage.
- **FR-004**: The system MUST compute the generated minimum rate as
  `observed_quote * (1 - slippage)` using the explicit slippage policy, and
  MUST pass the derived value into the existing swap intent generation path.
- **FR-005**: The system MUST reject missing, invalid, zero, or negative quote
  values before intent generation or transaction building.
- **FR-006**: The system MUST reject missing or invalid slippage values before
  intent generation or transaction building.
- **FR-007**: Before building the transaction, the system MUST check treasury
  affordability from generated intent values using
  `amountLovelace + chunk_count * extraPerChunkLovelace <= selected treasury
  lovelace`.
- **FR-008**: If the requested USDM amount is not affordable at the derived
  rate, the system MUST exit before producing unsigned CBOR and report required
  ADA, available ADA, quote, slippage, and shortfall.
- **FR-009**: On successful runs, the system MUST write an audit JSON artifact,
  for example `params.json`, containing the quote, quote provenance, derived
  minimum rate, request parameters, estimated or live affordability inputs,
  selected treasury total, and generated output paths.
- **FR-010**: Tests MUST cover rate derivation, affordability pass and fail
  cases, and audit JSON shape without requiring live network access.
- **FR-011**: Documentation MUST make the quote-derived command the primary
  swap path and MUST move hard-coded `--min-rate` examples to expert/manual
  override documentation.
- **FR-012**: Direct manual `--min-rate` use MAY remain available as an expert
  override, but the quote-derived path MUST NOT rely on the user passing a
  precomputed `--min-rate`.
- **FR-013**: The audit artifact MUST be deterministic for deterministic
  inputs except for explicitly recorded observation/fetch timestamps and output
  paths.
- **FR-014**: The quote-derived path MUST preserve the existing unsigned-build
  trust boundary: it produces intent/build artifacts only and does not sign or
  submit transactions.

### Key Entities *(include if feature involves data)*

- **Quote Observation**: The ADA/USD or ADA/USDM value used for the run,
  including source or override provenance and observation/fetch time.
- **Slippage Policy**: The explicit operator-provided tolerance used to derive
  the minimum rate. It is part of the audited operator decision.
- **Derived Swap Parameters**: The calculated minimum rate and request values
  passed into the existing swap intent generation path.
- **Affordability Calculation**: The generated intent values, selected treasury
  lovelace, required lovelace, and shortfall or surplus used to decide whether
  unsigned CBOR may be produced.
- **Audit Artifact**: The JSON record that binds quote provenance, slippage,
  derived parameters, affordability, and generated output paths for signer and
  reviewer inspection.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: For deterministic quote and slippage inputs, 100% of rate
  derivation tests produce the mathematically expected minimum rate with
  conservative rounding documented by the test fixture.
- **SC-002**: For fixture treasury values, affordability tests cover both exact
  pass and one-lovelace-short fail cases, and the failing case produces no
  unsigned CBOR.
- **SC-003**: A successful fixture run writes an audit JSON artifact whose
  required fields validate against the checked test expectation.
- **SC-004**: The primary swap documentation contains no hard-coded
  `--min-rate 0.245` example as the recommended path; any direct `--min-rate`
  example is labelled as an expert/manual override.
- **SC-005**: An operator can complete the safe quote-derived swap preparation
  flow without doing any external arithmetic for `--min-rate`.

## Assumptions

- The feature extends the existing swap intent and build workflow rather than
  replacing `swap-wizard` or `tx-build`.
- Quote fetching may be implemented behind a selectable source, but the spec
  requires quote override support so tests and offline operation do not depend
  on a live network quote service.
- ADA/USD and ADA/USDM are treated as the accepted quote domains for this
  issue; adding other asset pairs is out of scope unless a later issue expands
  the operator workflow.
- The selected treasury lovelace and generated intent values are the
  authoritative inputs for affordability; documentation examples and operator
  estimates are not authoritative.
- Signing and submission remain out of scope, consistent with the project
  constitution.
