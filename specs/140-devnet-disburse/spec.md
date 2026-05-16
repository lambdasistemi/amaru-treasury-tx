# Feature Specification: DevNet Disburse Slice

**Feature Branch**: `140-devnet-disburse`
**Created**: 2026-05-16
**Status**: Draft
**GitHub Issue**: [#86](https://github.com/lambdasistemi/amaru-treasury-tx/issues/86)
**Input**: User description: "Proceed with the DevNet roadmap after closing #83; implement the #86 disburse evidence prerequisite before swap order build/funding and execution."

## User Scenarios & Testing

### User Story 1 - Start From Live Treasury State (Priority: P1)

As a release maintainer, I need the disburse DevNet slice to start
from treasury UTxO state produced by the governance and withdrawal
slices, so that disburse evidence proves the live treasury spend path
and not a frozen fixture.

**Why this priority**: A disbursement is only meaningful after the
treasury script address holds spendable ADA or token value. #83 proved
withdrawal materialization; this slice must consume that kind of live
state before it can validate the release-facing disburse workflow.

**Independent Test**: Run `just devnet-smoke disburse` and verify that
the run records governance/withdrawal prerequisite evidence and selected
live treasury and wallet UTxOs before any success artifacts are written.

**Acceptance Scenarios**:

1. **Given** a fresh short-epoch local DevNet, **When** the disburse
   phase runs, **Then** it creates or consumes governance and withdrawal
   prerequisite evidence and observes a treasury UTxO at the target
   treasury script address.
2. **Given** no suitable treasury UTxO or wallet fuel UTxO exists,
   **When** the disburse phase runs, **Then** it fails with a typed
   diagnostic before writing a success summary.
3. **Given** a stale run directory contains old disburse artifacts,
   **When** the disburse phase starts, **Then** stale success artifacts
   are removed or the phase refuses to run in a way that cannot be
   mistaken for fresh evidence.

---

### User Story 2 - Produce And Build A Live Disburse Intent (Priority: P1)

As an operator validating the release flow, I need
`disburse-wizard --network devnet` to resolve live node state and
`tx-build` to produce unsigned Conway CBOR plus reports from that
intent.

**Why this priority**: The offline disburse fixtures already cover the
pure builder surface. The release risk is the live resolver boundary:
registry references, treasury UTxO selection, wallet fuel/collateral,
beneficiary address, unit selection, and validity horizon.

**Independent Test**: Run the disburse phase and inspect
`disburse/intent.json`, `disburse/tx-body.cbor.hex`,
`disburse/report.json`, `disburse/report.md`, and
`disburse/tx-build.log`; all must be produced from the same live DevNet
session.

**Acceptance Scenarios**:

1. **Given** live treasury state and wallet fuel are available, **When**
   the disburse wizard resolves state, **Then** it writes a schema-v1
   `action = "disburse"` intent with selected treasury inputs,
   selected wallet input, beneficiary, unit, amount, scope, signers,
   and validity upper bound.
2. **Given** the live disburse intent is written, **When** `tx-build`
   runs, **Then** it writes unsigned CBOR, a JSON report, a Markdown
   report, a build log, and a summary that names the same selected
   inputs and beneficiary.
3. **Given** `tx-build` fails, **When** the smoke records the failure,
   **Then** the diagnostic preserves the intent and build log where
   useful, removes stale success artifacts, and identifies the build
   failure code.

---

### User Story 3 - Cover ADA And USDM Boundaries (Priority: P2)

As a maintainer, I need the disburse phase to make the USDM boundary
explicit while still covering ADA behavior, because USDM is the usual
operator path but local DevNet may need synthetic token setup before a
USDM happy path can succeed.

**Why this priority**: Issue #86 names USDM as the common operator
path. The DevNet harness must not silently downgrade to ADA and claim
USDM proof, but it may use ADA as the first successful live spend when
synthetic USDM setup is absent.

**Independent Test**: Run `just devnet-smoke disburse` and verify that
the evidence either proves a USDM disburse or records a typed
missing-USDM/setup diagnostic while separately documenting the ADA
subcase.

**Acceptance Scenarios**:

1. **Given** synthetic local USDM exists in the selected treasury UTxO,
   **When** the USDM disburse path runs, **Then** the success evidence
   records the USDM policy, token, quantity, beneficiary output, and
   leftover treasury value.
2. **Given** no local USDM setup exists, **When** the USDM path is
   requested, **Then** the phase fails or records a subcase diagnostic
   with a stable missing-token/setup code instead of reporting USDM
   success.
3. **Given** ADA treasury value exists, **When** the ADA subcase runs,
   **Then** the evidence clearly labels the unit as ADA and does not
   satisfy USDM acceptance by implication.

---

### User Story 4 - Preserve Roadmap Boundaries (Priority: P2)

As maintainers splitting the DevNet experiment, we need docs and issue
metadata to show that #86 proves disburse evidence only, while #84
builds/funds SundaeSwap orders, #85/#136 spend or execute them, and #87
reorganizes treasury UTxOs.

**Why this priority**: DevNet evidence is used for release claims. A
successful disburse run must not be confused with swap order creation
or execution.

**Independent Test**: Read README, release notes, local DevNet docs,
and #86 metadata after the smoke passes; they must identify this as
disburse evidence only.

**Acceptance Scenarios**:

1. **Given** the disburse smoke passes, **When** release docs are
   reviewed, **Then** they include the disburse run directory, selected
   inputs, unit/amount, beneficiary, tx id or unsigned body identity,
   and report paths.
2. **Given** swap and reorganize follow-up slices remain open, **When**
   the roadmap is reviewed, **Then** #84, #85, #136, and #87 remain
   separate evidence claims.

### Edge Cases

- Governance or withdrawal prerequisite setup fails before treasury
  value materializes.
- Treasury UTxOs exist but do not belong to the selected scope.
- The selected treasury UTxO has insufficient ADA for the requested ADA
  disbursement plus required leftover minimum ADA.
- The selected treasury UTxO has insufficient USDM for the requested
  USDM disbursement.
- Wallet fuel/collateral UTxOs are missing or carry native assets that
  make them unsuitable for the current selection rule.
- The beneficiary address is malformed or belongs to the wrong network.
- The intent network and live node magic disagree.
- Registry, permissions, treasury, or scopes reference UTxOs are
  missing or mismatched.
- `tx-build` fails during context query, script evaluation, balancing,
  report rendering, final transaction validation, or CBOR writing.
- The phase is rerun into a directory containing stale success or
  failure artifacts.
- The USDM path is requested before local synthetic USDM setup exists.

## Requirements

### Functional Requirements

- **FR-001**: The system MUST add an opt-in local DevNet `disburse`
  phase under `just devnet-smoke`.
- **FR-002**: The disburse phase MUST start from live local DevNet
  treasury state produced by the governance/withdrawal setup path or
  fail with a typed missing-state diagnostic.
- **FR-003**: The disburse phase MUST resolve wallet fuel/collateral,
  treasury inputs, registry references, permissions references,
  beneficiary, unit, amount, signers, and validity from live DevNet
  state before writing a success summary.
- **FR-004**: The generated intent MUST be a schema-v1
  `action = "disburse"` document and MUST decode through the normal
  unified intent path.
- **FR-005**: The disburse phase MUST run `tx-build` against the live
  DevNet intent and write unsigned CBOR, JSON report, Markdown report,
  build log, and summary artifacts.
- **FR-006**: Successful evidence MUST record run directory, network
  magic, socket, selected wallet inputs, selected treasury inputs,
  selected scope, beneficiary address, unit, amount, validity context,
  artifact paths, and relevant asset quantities.
- **FR-007**: USDM evidence MUST either prove a successful USDM
  disbursement with policy/token/quantity details or fail with a typed
  missing-token/setup diagnostic; ADA evidence MUST be labelled as ADA.
- **FR-008**: Missing treasury, registry, permissions, wallet,
  beneficiary, token, network, or build state MUST fail with typed
  diagnostics before stale or partial success artifacts can be reported.
- **FR-009**: README, release docs, local DevNet docs, Spec Kit tasks,
  and #86 metadata MUST document this as disburse evidence only.
- **FR-010**: The normal release-facing CLI MUST remain build-only;
  any automatic signing or submission, if added for DevNet evidence,
  MUST stay inside the opt-in DevNet harness.

### Key Entities

- **Disburse DevNet Run**: One smoke execution with node socket,
  prerequisite treasury state, wizard output, builder output,
  diagnostics, and summary logs.
- **Disburse Prerequisite Evidence**: Governance and withdrawal evidence
  used to establish a spendable treasury UTxO for the selected scope.
- **Live Disburse Intent**: The schema-v1 `disburse` intent emitted by
  `disburse-wizard` from live local-node state.
- **Disburse Build Evidence**: Unsigned CBOR, tx identity, mechanical
  JSON report, human Markdown report, build log, selected inputs,
  beneficiary, unit, amount, and validity context.
- **Disburse Diagnostic**: Typed failure artifact with phase, code,
  message, artifact paths, and enough live context to reproduce the
  failure.

## Success Criteria

### Measurable Outcomes

- **SC-001**: `just devnet-smoke disburse` either completes with
  disburse artifacts or fails with a typed diagnostic within the
  configured wait budget.
- **SC-002**: On success, `disburse/intent.json` contains
  `action = "disburse"` and the selected beneficiary, unit, amount, and
  treasury input references.
- **SC-003**: On success, `tx-build` produces unsigned CBOR and report
  artifacts from the live DevNet intent.
- **SC-004**: Missing live treasury state, missing wallet state, invalid
  beneficiary, missing token state, or build failure never leaves stale
  success artifacts in the run directory.
- **SC-005**: Release documentation distinguishes #86 disburse evidence
  from governance, withdrawal, SundaeSwap order build/funding,
  SundaeSwap order execution, and reorganize evidence.

## Assumptions

- #82 governance and #83 withdrawal evidence are already merged into
  `main`; #83 is closed manually because PR #100 used `Refs #83`
  instead of a closing keyword.
- The first successful live disburse proof may use ADA if synthetic
  local USDM setup is not yet available; USDM must still be represented
  by either a successful subcase or a typed missing-token/setup
  diagnostic.
- The opt-in DevNet harness may prepare local fixture state needed to
  exercise live node boundaries, but success evidence must clearly
  distinguish fixture setup from public-network claims.
- `just ci` remains free of DevNet startup; the live node proof stays
  behind `just devnet-smoke disburse`.
