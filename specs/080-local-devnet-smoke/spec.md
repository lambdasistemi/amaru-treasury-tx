# Feature Specification: DevNet Governance Action Slice

**Feature Branch**: `080-local-devnet-smoke`  
**Created**: 2026-05-11  
**Status**: Draft  
**GitHub Issue**: [#82](https://github.com/lambdasistemi/amaru-treasury-tx/issues/82)
**Input**: User description: "Make the first DevNet experiment slice the governance action slice. Split withdrawal, disburse, swap/order, and reorganize into their own DevNet tickets."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Prove the Local DevNet Boundary (Priority: P1)

As a maintainer preparing the release, I need a repeatable local
DevNet that starts quickly, exposes a node socket, and uses short
epochs so later governance and reward experiments can complete during
one manual verification session.

**Why this priority**: The governance action cannot be trusted until
the local network identity and timing are proven.

**Independent Test**: Run the node phase and verify that it reports a
fresh run directory, node socket, network magic, tip, and short epoch
timing before any governance setup runs.

**Acceptance Scenarios**:

1. **Given** a clean checkout with the approved local DevNet dependency, **When** the maintainer starts the node smoke, **Then** it reports a reachable node socket and the expected local network identity.
2. **Given** the local node is running, **When** the smoke reads chain timing, **Then** it records the effective epoch duration used by later governance and reward checks.
3. **Given** the node is unavailable or on the wrong network, **When** the smoke runs, **Then** it fails before attempting any governance action and records the observed boundary failure.

---

### User Story 2 - Submit the Treasury-Withdrawal Governance Action (Priority: P1)

As a maintainer validating the Amaru treasury setup path, I need the
local DevNet to create and submit the Conway treasury-withdrawal
governance action that funds the Amaru treasury script reward account.

**Why this priority**: Withdrawal testing requires treasury reward
state. A delegated key reward account is not enough; the funded account
must be the Amaru script stake credential used by the withdrawal
transaction.

**Independent Test**: Run the governance phase and verify that it
prepares the script stake credential, submits the governance action,
and records the resulting action id, tx id, reward account, amount,
and chain context.

**Acceptance Scenarios**:

1. **Given** a running short-epoch DevNet with deterministic setup funds, **When** the governance phase starts, **Then** it prepares the Amaru treasury script stake credential and vote-delegation state.
2. **Given** the script stake credential is prepared, **When** the governance action is built and submitted, **Then** the smoke records the treasury-withdrawal action id, transaction id, reward account, and amount.
3. **Given** required upstream support is missing, **When** the governance phase reaches that boundary, **Then** it fails with a typed missing-upstream diagnostic instead of replacing the library path with permanent shell code.

---

### User Story 3 - Leave a Clean Handoff for Later DevNet Slices (Priority: P2)

As a maintainer continuing the DevNet experiment, I need the governance
slice to produce artifacts that the withdrawal, disburse, SundaeSwap
V3 order build/funding, SundaeSwap V3 order-spend, and reorganize
slices can consume without rediscovering setup assumptions.

**Why this priority**: Tomorrow's work should start from explicit
state: governance action first, withdrawal second, disburse third,
SundaeSwap V3 order build/funding fourth, SundaeSwap V3 order spend
fifth, and reorganize sixth.

**Independent Test**: Inspect the governance run directory and issue
links; the next slice can identify the funded reward account and the
exact upstream capabilities still required.

**Acceptance Scenarios**:

1. **Given** the governance phase succeeds, **When** the withdrawal slice starts, **Then** it can locate the funded reward account and chain context from the governance summary.
2. **Given** the governance phase is blocked by upstream library support, **When** the issue is reviewed, **Then** the blocking upstream issue or PR is linked from the summary.
3. **Given** the DevNet experiment backlog is reviewed, **When** maintainers inspect the tickets, **Then** governance, withdrawal, disburse, SundaeSwap V3 order build/funding, SundaeSwap V3 order spend, and reorganize are separate issues with explicit dependencies.

### Edge Cases

- The DevNet starts but never reaches a usable tip within the wait budget.
- The DevNet accepts a network identity other than magic `42`.
- The copied or patched genesis leaves no protocol treasury/reserve funds for a treasury-withdrawal action.
- The treasury script stake credential is registered with the wrong certificate shape.
- Governance action submission succeeds, but the action cannot be observed before the wait budget expires.
- Required support in `cardano-node-clients` is missing for certificates, proposal procedures, or node queries.
- A previous run directory contains stale governance artifacts.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The system MUST provide an opt-in local DevNet smoke that records all artifacts in a fresh run directory.
- **FR-002**: The smoke MUST verify the local node socket, network magic `42`, and short epoch timing before running governance setup.
- **FR-003**: The governance phase MUST prepare the treasury script stake credential using the original Amaru certificate intent: registration plus always-abstain vote delegation.
- **FR-004**: The governance phase MUST create and submit a Conway treasury-withdrawal governance action that targets the Amaru script reward account.
- **FR-005**: The governance summary MUST record tx id, governance action id, reward account, amount, epoch/tip context, and run directory.
- **FR-006**: Missing upstream library capabilities MUST be reported as typed blockers with links to the upstream issue or PR.
- **FR-007**: Any signing/submission required for DevNet setup MUST remain inside the smoke harness and MUST NOT become release-facing `amaru-treasury-tx` CLI behavior.
- **FR-008**: The documentation MUST present governance action as slice 1, withdrawal as slice 2, disburse as slice 3, SundaeSwap V3 order build/funding as slice 4, SundaeSwap V3 order spend as slice 5, and reorganize as slice 6.
- **FR-009**: Withdrawal transaction building MUST remain out of scope for this slice and tracked by #83.
- **FR-010**: Disburse evidence MUST remain out of scope for this slice and tracked by #86.
- **FR-011**: SundaeSwap V3 order build/funding evidence MUST remain out of scope for this slice and tracked by #84.
- **FR-012**: SundaeSwap V3 order spend evidence MUST remain out of scope for this slice and tracked by #85.
- **FR-013**: Reorganize evidence MUST remain out of scope for this slice and tracked by #87.

### Key Entities

- **Local DevNet Run**: One isolated smoke execution with node socket, timing evidence, logs, and generated artifacts.
- **Governance Setup State**: Local funds, stake credential state, certificate artifacts, and proposal/action inputs needed to submit the treasury-withdrawal action.
- **Treasury Withdrawal Governance Action**: The submitted Conway governance action that moves protocol treasury funds to an Amaru script reward account.
- **Governance Evidence Set**: Summary JSON/log data containing tx id, action id, reward account, amount, epoch/tip context, and upstream blockers.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A maintainer can run the node phase from a clean checkout and receive a node-ready or node-failed result within 2 minutes.
- **SC-002**: The governance phase either submits the treasury-withdrawal governance action or fails with a typed upstream/local-state blocker.
- **SC-003**: Successful governance output includes tx id, governance action id, reward account, amount, epoch/tip context, and run directory.
- **SC-004**: The governance run directory contains enough evidence for #83 to start withdrawal testing without rediscovering governance setup.
- **SC-005**: README and release docs identify the implemented DevNet evidence and do not claim withdrawal, disburse, SundaeSwap order-build, order-spend, or reorganize proof before #83/#86/#84/#85/#87 land.

## Assumptions

- The approved local network source remains the pinned
  `cardano-node-clients` DevNet.
- The first DevNet implementation slice may require upstream
  `cardano-node-clients` changes, especially issues #130 and #131.
- Temporary `cardano-cli` calls may appear only as explicit blockers or
  migration aids inside the DevNet harness; the desired state is
  library support.
- The local DevNet governance action is release evidence for setup
  mechanics, not a public-network governance claim.
