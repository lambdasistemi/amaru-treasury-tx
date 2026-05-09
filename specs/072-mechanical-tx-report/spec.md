# Feature Specification: Mechanical Transaction Report for Built Treasury Transactions

**Feature Branch**: `072-mechanical-tx-report`
**Created**: 2026-05-09
**Status**: Draft
**Input**: User description from issue [#72](https://github.com/lambdasistemi/amaru-treasury-tx/issues/72): after a successful `tx-build`, emit a deterministic, mechanically generated report that explains the built transaction's wallet accounting, treasury accounting, signer requirements, output roles, and validation facts before an operator signs the unsigned CBOR.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Save a deterministic build report (Priority: P1)

A treasury operator builds an unsigned transaction with `tx-build`. The current trace confirms that CBOR was produced and prints facts such as fee, total collateral, and validation status, but it does not leave a structured artifact that downstream tools or reviewers can inspect. The operator wants an explicit report file written by the executable during the successful build, using the same transaction, intent, resolved inputs, outputs, fee/collateral, redeemer, and validation data that produced the unsigned CBOR.

**Why this priority**: This is the base deliverable for issue #72. Without a deterministic report artifact, every later accounting and signer explanation still depends on logs or manual transaction decoding.

**Independent Test**: Run `tx-build` against a checked-in successful fixture with a report destination. Verify that the command emits the normal unsigned CBOR and writes a JSON report whose bytes are stable across repeated runs with the same inputs.

**Acceptance Scenarios**:

1. **Given** a valid swap intent and frozen chain context fixture, **When** `tx-build` runs with a report destination, **Then** it writes unsigned CBOR as before and also writes a JSON report generated from the build data for that exact transaction.
2. **Given** the same intent, chain context, and report destination content path on two runs, **When** both builds succeed, **Then** the report JSON is byte-identical except for no fields that depend on wall-clock time, randomness, or local machine state.
3. **Given** `tx-build` runs without a report destination, **When** the build succeeds, **Then** the existing CBOR and trace behavior remains unchanged.

---

### User Story 2 - Understand swap wallet and treasury accounting before signing (Priority: P1)

An operator prepares a swap transaction and needs to answer concrete signing questions before sending CBOR to a signer: how much did the wallet actually pay, what came back as wallet change, how much collateral was required and returned, how much treasury value went into Sundae order outputs, how much overhead the treasury funded per chunk, and what value remains in the treasury. The report must state those facts mechanically so the operator does not have to infer them from logs or decode the transaction by hand.

**Why this priority**: This is the exact operator pain described in issue #72. The triggering example already printed `fee=1058169`, `total_collateral=1587254`, and `VALIDATION OK`, but those lines did not answer the wallet-net-spend and treasury-leftover questions.

**Independent Test**: Build the existing swap fixture that uses treasury-funded swap-order overhead. Verify the report states wallet inputs, wallet change, wallet net spend, fee, collateral input/return/total, treasury inputs, Sundae order totals, per-chunk overhead, treasury leftover, and treasury net debit; assert that wallet net spend on the success path equals the transaction fee.

**Acceptance Scenarios**:

1. **Given** a successful swap build where the treasury funds the per-chunk overhead, **When** the operator reads the report, **Then** wallet net spend on the success path equals the transaction fee and excludes collateral that returns intact.
2. **Given** a successful multi-chunk swap build, **When** the operator reads the treasury accounting section, **Then** it shows treasury input totals, lovelace/assets sent into Sundae order outputs, per-chunk overhead funded by the treasury, treasury leftover lovelace/assets, and treasury net debit.
3. **Given** the transaction body contains wallet change, collateral return, Sundae order outputs, and a treasury leftover output, **When** the report lists outputs by role, **Then** each produced output is represented exactly once under its mechanical role.

---

### User Story 3 - Review signers and validation facts from the same artifact (Priority: P2)

Before signing, an operator or reviewer needs to confirm which key hashes are required, why they are required, and whether the builder validated the transaction against the intended network and scripts. They want those facts in the report rather than scattered across trace lines, intent JSON, and CBOR decoding output.

**Why this priority**: Signer requirements and validation facts are signing safety data. They are less specific to the swap accounting pain than Story 2, but they determine whether the generated CBOR should be handed to the expected signers.

**Independent Test**: Run a successful swap build with a selected scope owner and at least one extra signer. Verify the report lists every required signer key hash with its source, then lists network, socket/network magic match, fee, body size, redeemer count, redeemer failures, validity interval, and selected reference inputs.

**Acceptance Scenarios**:

1. **Given** an intent that names required signers, **When** the report is generated, **Then** every required signer key hash appears with a mechanical source such as selected scope owner or extra signer.
2. **Given** the build re-evaluates redeemers successfully, **When** the operator reads the validation facts, **Then** the report states the redeemer count, zero redeemer failures, and the validation status that allowed CBOR emission.
3. **Given** a network handshake was performed, **When** the report is generated, **Then** it records the intent network and the matching socket/network magic observed during the build.

---

### User Story 4 - Document the report as the pre-signing review artifact (Priority: P3)

An operator following the public docs wants the supported review flow to say what they should inspect before signing. The docs should name the mechanically generated report, explain that it is produced by the executable from build data, and position it before any external signing or submission step.

**Why this priority**: Documentation does not create the safety property by itself, but it makes the report the default operational review surface rather than a hidden developer feature.

**Independent Test**: Read the operator documentation for swap building and quickstart flows. Verify it tells operators to generate and inspect the report before signing, and does not describe the report as an LLM-written interpretation.

**Acceptance Scenarios**:

1. **Given** an operator follows the swap quickstart, **When** they reach the signing step, **Then** the docs direct them to inspect the generated report before handing CBOR to a signer.
2. **Given** the docs describe the report, **When** they explain its provenance, **Then** they state that it is generated mechanically from the transaction build.

### Edge Cases

- **No report destination supplied**: existing `tx-build` output and logging behavior remains unchanged.
- **Requested report path cannot be written**: the command must fail rather than claim a complete successful build without the requested report artifact.
- **Build or validation failure**: no success report is produced; existing failure traces remain the diagnostic surface for failed builds.
- **Multiple wallet inputs**: wallet accounting must include the primary wallet input and any additional wallet fuel inputs, while still identifying which input was used as collateral.
- **Collateral input also appears as wallet fuel**: the report must avoid double-counting collateral in success-path wallet net spend when collateral returns intact.
- **Native assets in treasury inputs or leftover**: treasury accounting must preserve asset totals, not only lovelace.
- **Unexpected or future output role**: the report must not omit an output; if it cannot be classified as a known role, it must appear under a generic role with enough data to audit it.
- **Optional human-readable rendering**: if added, it must be generated from the same structured report data and must not replace the JSON artifact.

## Requirements *(mandatory)*

### Scope

- This feature covers successful `tx-build` runs for built treasury transactions.
- The required v1 artifact is structured JSON suitable for downstream tooling.
- Swap transactions require the full wallet and treasury accounting described in issue #72.
- Non-swap successful builds must at least report common transaction facts, signer requirements, validation facts, reference inputs, and produced outputs by role where the role is known.
- Documentation updates must teach operators to review the report before signing.

### Explicit Exclusions

- This feature does not sign or submit transactions.
- This feature does not implement the quote-derived SWOP parameter-filling workflow from issue [#70](https://github.com/lambdasistemi/amaru-treasury-tx/issues/70), though #70 may later consume the same report data.
- This feature does not require a human-readable Markdown or text report in v1.
- This feature does not use an LLM or hand-authored interpretive prose to explain transaction contents.
- This feature does not change on-chain validators, redeemer formats, or the transaction semantics required for existing golden CBOR fixtures except where report artifacts are added.
- This feature does not attempt to reconstruct reports from arbitrary historical CBOR without the builder's resolved input/output context.

### Functional Requirements

- **FR-001**: `tx-build` MUST provide a way for the operator to request a transaction report destination for a successful build, while preserving existing behavior when no report is requested.
- **FR-002**: The report MUST be a deterministic JSON artifact generated by Haskell code from the built transaction, intent, resolved inputs, outputs, fee/collateral data, builder accounting, signer data, and validation result.
- **FR-003**: The report MUST NOT contain LLM-written analysis or unverifiable prose interpretations; any explanatory labels must be derived from structured build facts.
- **FR-004**: The report MUST identify the built transaction with action, transaction id when available, CBOR/body size, fee, validity interval, and the report schema/version.
- **FR-005**: For swap transactions, the report MUST list wallet input UTxOs and lovelace, wallet change output and lovelace, wallet net spend on the success path, transaction fee paid by the wallet, collateral input, collateral return, and total collateral.
- **FR-006**: For swap transactions, wallet net spend on the success path MUST be computed as non-collateral wallet input lovelace plus any collateral input lovelace that is also spent as fuel, minus wallet change lovelace and minus collateral returned intact, with no double-counting of the same UTxO.
- **FR-007**: For swap transactions, the report MUST list treasury input UTxOs and total lovelace/assets, amount sent into Sundae order outputs, per-chunk overhead funded by the treasury, treasury leftover lovelace/assets, and treasury net debit.
- **FR-008**: The report MUST list produced outputs by role, including swap-order outputs, treasury leftover output, wallet change output, collateral return, and a metadata/auxiliary-data summary.
- **FR-009**: The report MUST list required signer key hashes and the mechanical source that produced each signer requirement, including selected scope owner and extra-signer inputs when applicable.
- **FR-010**: The report MUST include validation facts already known to the builder: intent network, socket/network magic match, fee, body size, redeemer count, redeemer failures, validation status, validity interval, and selected reference inputs.
- **FR-011**: The JSON report contract MUST be documented and covered by executable validation so downstream tooling can rely on its shape.
- **FR-012**: Regression tests MUST include a golden report for at least the existing swap fixture and MUST assert that wallet net spend equals the transaction fee for the treasury-funded-overhead success path.
- **FR-013**: Documentation MUST explain that operators should review the report before signing and that the report is mechanically generated from transaction-build data.
- **FR-014**: If a human-readable report rendering is added, it MUST be generated from the same structured data as the JSON report and tests MUST verify that it does not diverge from the JSON facts.
- **FR-015**: If report writing was requested and fails, the command MUST exit non-zero and report the write failure clearly.

### Key Entities

- **Transaction Report**: The structured artifact for one successful build. It contains identity, accounting, outputs, signers, validation facts, and schema/version fields.
- **Wallet Accounting**: The success-path wallet view: wallet inputs, change, fee, collateral, collateral return, and net spend without double-counting returned collateral.
- **Treasury Accounting**: The treasury view: treasury inputs, order-output funding, per-chunk overhead funded by the treasury, leftover value, and net debit.
- **Produced Output Role**: A mechanical classification for each output in the built transaction, such as swap order, treasury leftover, wallet change, collateral return, or unknown/other.
- **Signer Requirement**: A required signer key hash plus the source that caused it to be required.
- **Validation Facts**: Network, magic, fee, body size, redeemer, validity, reference-input, and validation status facts known during the build.
- **Report Contract**: The documented JSON shape that downstream tools and golden tests validate.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Rebuilding the checked-in swap fixture twice with report output produces byte-identical JSON reports.
- **SC-002**: The swap golden report shows wallet net spend equal to the tx fee for the treasury-funded-overhead success path.
- **SC-003**: A reviewer can answer, from the report alone, the wallet amount paid, wallet change returned, collateral required/returned, treasury leftover, and treasury net debit for the swap fixture without decoding CBOR manually.
- **SC-004**: The report JSON validates against the checked-in report contract in automated tests.
- **SC-005**: Operator documentation names the report as the pre-signing review artifact and states that it is mechanically generated by the executable.

## Assumptions

- The default operator workflow remains `swap-wizard` or another intent producer feeding `tx-build`; this issue adds a build report, not a new economic-parameter workflow.
- Issue #70 may later wrap `swap-wizard` and `tx-build` in a higher-level SWOP path. That later command should be able to reuse or forward this report, but issue #72 does not depend on #70 being complete.
- The checked-in swap fixture represents the treasury-funded-overhead success path after issue #68's behavior, so it is the right minimum golden-report fixture for wallet-net-spend proof.
- Existing build traces remain useful diagnostics, but the report is the durable audit artifact for successful builds.
- A future text or Markdown rendering is useful for operators, but JSON is the required v1 contract because downstream tooling needs structured fields.
