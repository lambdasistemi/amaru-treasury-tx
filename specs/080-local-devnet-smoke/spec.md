# Feature Specification: Local Devnet Smoke

**Feature Branch**: `080-local-devnet-smoke`  
**Created**: 2026-05-11  
**Status**: Draft  
**Input**: User description: "Run a local network to actually test the operator steps. Use the cardano-node-clients devnet, and use a short epochLength for withdrawal rewards to operate."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Start a Short-Epoch Local Network (Priority: P1)

As a maintainer preparing an Amaru treasury release, I need a
repeatable local-network smoke environment so I can verify the tool
against a live Cardano node socket instead of relying only on frozen
fixtures.

**Why this priority**: Every later live smoke depends on a reachable
node, the expected test network identity, and fast epoch progression.

**Independent Test**: Start the local network smoke and verify that it
reports the node socket, accepted network magic, current tip, and
configured epoch duration before any treasury-specific action runs.

**Acceptance Scenarios**:

1. **Given** a clean checkout with the approved local devnet dependency, **When** the maintainer starts the local-network smoke, **Then** the smoke reports a reachable node socket and the expected local test-network identity.
2. **Given** the local network is running, **When** the smoke reads chain timing, **Then** it confirms epochs are short enough for a withdrawal reward scenario to complete during a manual verification session.
3. **Given** the local node is unavailable or on the wrong network, **When** the smoke runs, **Then** it fails before attempting any treasury action and prints the observed boundary failure.

---

### User Story 2 - Exercise Withdrawal With Accrued Rewards (Priority: P2)

As a maintainer validating the withdrawal workflow, I need the local
network to produce a positive reward balance quickly so the
withdrawal path can be tested against live chain state without waiting
for public-network epochs.

**Why this priority**: The current withdrawal golden is synthetic
because public-network treasury rewards were zero; this is the first
live proof that the withdrawal resolver can observe positive rewards.

**Independent Test**: Run only the withdrawal local-network smoke and
verify that it waits for a positive reward balance, emits a
positive-rewards intent, and records the reward account and reward
amount observed from the live chain.

**Acceptance Scenarios**:

1. **Given** the local network has short epochs and a prepared reward source, **When** enough epochs have elapsed, **Then** the smoke observes a reward account with rewards greater than zero.
2. **Given** the reward balance is positive, **When** the withdrawal resolver runs, **Then** it emits an intent with a positive `rewardsLovelace` value and does not take the zero-rewards no-op path.
3. **Given** rewards do not become positive within the configured wait budget, **When** the smoke exits, **Then** it reports the wait budget, last observed epoch/tip, and last observed reward value.

---

### User Story 3 - Exercise Disburse and Build Steps Against Live State (Priority: P3)

As a maintainer validating release-facing operator steps, I need a
local chain state that can drive a wizard-to-build flow for treasury
actions, so documentation and release claims are backed by live
socket verification.

**Why this priority**: Disburse and build already have strong fixture
coverage, but release confidence improves when the documented steps
also run against a live local chain.

**Independent Test**: Run the disburse/build local-network smoke and
verify that it produces reviewed artifacts from live chain queries:
intent JSON, build log, unsigned transaction CBOR, and report data.

**Acceptance Scenarios**:

1. **Given** the local network has prepared wallet and treasury state, **When** the disburse wizard runs, **Then** it resolves live UTxOs and emits an intent without relying on frozen fixture data.
2. **Given** a live-resolved disburse intent, **When** the build step runs, **Then** it emits unsigned transaction CBOR and a report showing successful validation.
3. **Given** required local treasury state is missing, **When** the smoke runs, **Then** it fails with a specific missing-state diagnostic rather than producing partial artifacts.

---

### Edge Cases

- The local devnet starts but never reaches a usable tip within the
  wait budget.
- The local devnet accepts a different network identity than the smoke
  expects.
- Short epochs are configured but rewards remain zero because the
  reward source is not delegated, not registered, or not active.
- Required treasury, registry, or wallet UTxOs are missing or already
  spent on the local chain.
- A previous smoke run left stale artifacts that could be mistaken for
  fresh results.
- The smoke is interrupted while the local network is running.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The system MUST provide a documented local-network smoke that starts from a clean run directory and records all generated artifacts in that directory.
- **FR-002**: The smoke MUST verify the local node socket and network identity before running any treasury wizard or build step.
- **FR-003**: The smoke MUST use a short-epoch local network suitable for observing withdrawal rewards during one manual verification session.
- **FR-004**: The smoke MUST report the effective epoch duration or equivalent timing evidence used to justify the withdrawal wait budget.
- **FR-005**: The smoke MUST prepare or require deterministic local chain state for wallet funds, treasury state, registry anchors, and reward observation before running release-facing treasury actions.
- **FR-006**: The withdrawal smoke MUST distinguish zero rewards from positive rewards and MUST only claim the positive path after observing rewards greater than zero from live chain state.
- **FR-007**: The withdrawal smoke MUST produce a withdrawal intent artifact when rewards are positive and MUST record the reward account and reward amount used.
- **FR-008**: The disburse/build smoke MUST produce intent, log, unsigned transaction, and report artifacts from live local chain queries.
- **FR-009**: The smoke MUST fail closed with actionable diagnostics when node readiness, network identity, rewards, or required treasury state are missing.
- **FR-010**: The smoke MUST keep signing and submission by the Amaru treasury CLI out of scope; any required chain preparation must not change the release-facing rule that this tool builds unsigned transactions.
- **FR-011**: The documentation MUST explain how to run the local-network smoke, how long it is expected to take, and how to inspect the generated artifacts.
- **FR-012**: The release checklist MUST reference this smoke as manual live evidence distinct from CI fixture evidence.

### Key Entities

- **Local Devnet Run**: One isolated smoke execution with a node
  socket, chain timing evidence, logs, and generated artifacts.
- **Epoch Timing Evidence**: The observed or configured values that
  prove withdrawal rewards can be tested without public-network epoch
  delays.
- **Prepared Treasury State**: Local wallet funds, treasury outputs,
  registry anchors, and reward source needed by the live smoke.
- **Withdrawal Observation**: The reward account, last observed reward
  value, and tip/epoch context captured before intent generation.
- **Smoke Artifact Set**: Intent JSON, command logs, unsigned CBOR,
  report output, and a summary transcript for review.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A maintainer can start the local-network smoke from a clean checkout and receive a node-ready or node-failed result within 2 minutes.
- **SC-002**: The withdrawal smoke can observe a positive reward balance within 10 minutes on the short-epoch local network, or fails with the last observed reward value and timing context.
- **SC-003**: Successful withdrawal smoke output includes a positive `rewardsLovelace` value, the reward account, and the intent artifact path.
- **SC-004**: Successful disburse/build smoke output includes paths to live-generated intent JSON, build log, unsigned CBOR, and report artifacts.
- **SC-005**: Re-running the smoke from a clean run directory produces fresh artifacts and does not reuse stale output from a prior run.
- **SC-006**: A maintainer following the documentation can identify whether a failure is due to node readiness, network mismatch, missing rewards, or missing treasury state.

## Assumptions

- The approved local network source is the existing
  `cardano-node-clients` devnet pinned by this repository.
- The live smoke is manual or opt-in because it starts a real local
  node and waits for chain progress; it is not part of default CI.
- A short epoch length is acceptable for the local smoke because it is
  a verification environment, not a public-network compatibility
  claim.
- The smoke validates build artifacts and resolver behavior; final
  multisig signing and submission remain outside `amaru-treasury-tx`.
