# Feature Specification: DevNet Swap Contract Readiness Slice

**Feature Branch**: `119-devnet-swap-readiness`
**Created**: 2026-05-15
**Status**: Draft
**GitHub Issue**: [#132](https://github.com/lambdasistemi/amaru-treasury-tx/issues/132)
**Input**: User description: "DevNet swap contract registration and order-build readiness."

## User Scenarios & Testing

### User Story 1 - Publish Real SundaeSwap Order References (Priority: P1)

As a release maintainer, I need the local DevNet to publish or verify
the real/public SundaeSwap V3 order-validator reference artifacts before
any Amaru swap order is built, so the later order-build proof cannot
silently depend on fake contract data.

**Why this priority**: A swap order-build smoke is only meaningful if
the order address, validator identity, and reference-script UTxO come
from the public SundaeSwap V3 interface, not from an Amaru-only toy
validator.

**Independent Test**: Run the planned `swap-ready` DevNet phase and
verify that the run directory contains a readiness summary naming the
order validator source, order address, script hash, and local
reference-script UTxO.

**Acceptance Scenarios**:

1. **Given** a fresh short-epoch local DevNet, **When** the readiness
   phase runs, **Then** it records the network magic, public
   SundaeSwap V3 order-validator source, order-validator script hash,
   DevNet order address, and reference-script UTxO.
2. **Given** the required public order-validator artifact is missing or
   cannot be verified against the expected hash, **When** the readiness
   phase runs, **Then** it fails with a typed diagnostic before writing
   any success summary.
3. **Given** a local fixture validator is used for developer
   experimentation, **When** readiness evidence is written, **Then** the
   evidence explicitly marks it as fixture-only and not accepted as
   SundaeSwap compatibility evidence.

---

### User Story 2 - Produce Order-Build Readiness Metadata (Priority: P1)

As the maintainer of the next order-build slice, I need machine-readable
readiness metadata that can be consumed by #84, so the later smoke can
resolve swap contract references from local DevNet artifacts instead of
hard-coded fake TxIns.

**Why this priority**: The next slice should focus on building and
funding a real order. It must not also guess how the contract reference
was registered or which local UTxO carries it.

**Independent Test**: Inspect the readiness registry artifact and prove
that it contains the fields needed by the later order-build smoke:
network identity, order address/hash, reference-script UTxO, source
provenance, and artifact paths.

**Acceptance Scenarios**:

1. **Given** the readiness phase succeeds, **When** the summary and
   registry files are read, **Then** #84 has enough information to
   resolve the order validator reference without a hand-wired fake.
2. **Given** the registry points at a stale, missing, or mismatched
   reference UTxO, **When** the readiness phase verifies its artifacts,
   **Then** it fails with a typed diagnostic that names the mismatch and
   preserves enough context to reproduce it.
3. **Given** mainnet constants already exist in the release CLI, **When**
   DevNet readiness metadata is written, **Then** it is explicitly local
   DevNet evidence and does not change public-network claims.

---

### User Story 3 - Preserve DevNet Slice Boundaries (Priority: P2)

As maintainers splitting the DevNet experiment, we need docs and issue
metadata to show that this slice proves readiness only, while #84 builds
and funds the order and #85 spends it.

**Why this priority**: Readiness evidence can easily be mistaken for a
successful swap. Release notes must avoid claiming order build,
submission, or spend before those slices land.

**Independent Test**: Review local DevNet docs, release notes, issue
metadata, and PR text after the slice; they must distinguish readiness
from order build/funding and order spend.

**Acceptance Scenarios**:

1. **Given** the readiness phase passes, **When** release docs are
   reviewed, **Then** they name the run directory and readiness
   artifacts without claiming a built, funded, submitted, or spent swap
   order.
2. **Given** #84, #85, #86, and #87 remain open, **When** the roadmap is
   reviewed, **Then** their boundaries remain explicit and this slice is
   listed as the prerequisite for #84.

### Edge Cases

- The public order-validator artifact is not present in the repository.
- The public artifact is present but hashes to a different script hash
  than the documented SundaeSwap V3 order validator.
- The local DevNet publishes a reference script, but the observed UTxO
  does not carry that script.
- The readiness phase is rerun into a non-empty run directory.
- The node is on the wrong network magic.
- The registry artifact references a UTxO from a previous run.
- A temporary local fixture is accidentally recorded as compatibility
  evidence.
- #84 is run without a readiness artifact from this slice.

## Requirements

### Functional Requirements

- **FR-001**: The system MUST add an opt-in local DevNet readiness phase
  for SundaeSwap V3 order-validator references.
- **FR-002**: The readiness phase MUST use the public SundaeSwap V3
  order-validator interface as its compatibility target and MUST NOT
  introduce an Amaru-only toy swap validator as accepted evidence.
- **FR-003**: The readiness phase MUST record the order-validator source
  provenance, order address, script hash, and local reference-script
  UTxO.
- **FR-004**: The readiness phase MUST write machine-readable readiness
  metadata that the #84 order-build/funding slice can consume without
  fake TxIns or private constants.
- **FR-005**: The readiness phase MUST verify that any recorded
  reference-script UTxO exists on the local DevNet and carries the
  expected order validator.
- **FR-006**: Missing artifact, hash mismatch, missing UTxO,
  reference-script mismatch, unsupported network identity, and stale run
  directory cases MUST fail with typed diagnostics and no misleading
  success artifact.
- **FR-007**: Documentation and issue/PR metadata MUST state that this
  slice proves readiness only and leaves order build/funding to #84,
  order spend to #85, disburse to #86, and reorganize to #87.
- **FR-008**: The RED/GREEN proof for the first implementation slice
  MUST be captured before production code changes.

### Key Entities

- **Swap Readiness Run**: One opt-in local DevNet execution with node
  context, order-validator publication or verification, registry
  metadata, diagnostics, and summary artifacts.
- **SundaeSwap V3 Order Validator Reference**: The public order
  validator identity and local DevNet UTxO carrying it as a reference
  script.
- **Swap Readiness Registry**: The machine-readable artifact consumed by
  #84, containing network identity, order address/hash, reference UTxO,
  source provenance, and artifact paths.
- **Readiness Diagnostic**: Typed failure evidence that names the failed
  phase, expected and observed contract identity, run directory, network
  identity, and relevant artifact paths.
- **Order-Build Prerequisite**: The minimal data #84 needs to build and
  fund a real order without hand-wired fake data.

## Success Criteria

### Measurable Outcomes

- **SC-001**: `just devnet-smoke swap-ready` either completes with
  readiness artifacts or exits with a typed diagnostic within the normal
  DevNet setup wait budget.
- **SC-002**: On success, the readiness registry includes a non-empty
  order-validator source, order address, script hash, reference-script
  UTxO, and network magic.
- **SC-003**: On success, the recorded reference-script UTxO is observed
  on the local DevNet and matches the recorded order-validator identity.
- **SC-004**: On missing or mismatched contract data, no success
  readiness summary is written.
- **SC-005**: Docs and issue metadata identify this as a prerequisite for
  #84 and do not claim order build/funding or order spend.

## Assumptions

- #83 is merged into `origin/main` and local withdrawal/materialized ADA
  evidence is available as the prior DevNet slice.
- #84 remains the follow-up slice that builds and funds a real
  SundaeSwap V3-compatible order using the readiness artifact produced
  here.
- The public SundaeSwap V3 order-validator artifact can be pinned from
  `SundaeSwap-finance/sundae-contracts` and verified locally before it
  is accepted as compatibility evidence.
- Publishing local DevNet setup/reference artifacts inside the opt-in
  smoke harness is acceptable; release-facing CLI commands remain
  build-only.
