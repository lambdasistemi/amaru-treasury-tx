# Feature Specification: DevNet Withdrawal Slice

**Feature Branch**: `083-devnet-withdrawal`  
**Created**: 2026-05-13  
**Status**: Draft  
**GitHub Issue**: [#83](https://github.com/lambdasistemi/amaru-treasury-tx/issues/83)
**Input**: User description: "Back to the Amaru withdrawal plan after the upstream governance/query support was merged."

## User Scenarios & Testing

### User Story 1 - Consume Funded Reward State (Priority: P1)

As a release maintainer, I need the withdrawal DevNet slice to start
only from reward state that was funded by the governance slice, so that
withdrawal evidence proves the real treasury reward path and not a
synthetic or delegated-key shortcut.

**Why this priority**: The withdrawal transaction is only meaningful
after the Amaru treasury script reward account has a positive balance.
The governance slice is the source of that state.

**Independent Test**: Run `just devnet-smoke withdraw` and verify that
it records governance prerequisite evidence before it attempts any
withdraw wizard or builder step.

**Acceptance Scenarios**:

1. **Given** a short-epoch local DevNet, **When** the withdrawal phase
   starts, **Then** it records the funded Amaru treasury script reward
   account, reward amount, epoch/tip context, and source governance
   evidence in the withdrawal run directory.
2. **Given** no positive reward state can be observed before the wait
   budget, **When** the withdrawal phase runs, **Then** it fails with a
   typed diagnostic that includes the last observed reward value and
   epoch/tip context.

---

### User Story 2 - Produce A Live Withdraw Intent (Priority: P1)

As an operator validating the release flow, I need
`withdraw-wizard --network devnet` to query the live node, observe the
positive reward balance, and emit a unified `withdraw` intent that can
be archived as DevNet evidence.

**Why this priority**: The offline withdraw fixture already proves the
pure JSON and builder contract. The release risk is the live resolver
boundary: registry state, wallet UTxO selection, reward query, and
validity horizon.

**Independent Test**: Run the withdrawal phase and inspect
`withdraw/intent.json`; it must decode as `TreasuryIntent 'Withdraw`,
carry the funded treasury reward account, and contain a positive
`rewardsLovelace` equal to the observed node reward.

**Acceptance Scenarios**:

1. **Given** the governance prerequisite funded the Amaru treasury
   script reward account, **When** `withdraw-wizard` runs against the
   same live DevNet, **Then** it writes a unified withdraw intent with
   positive rewards and no log text mixed into JSON.
2. **Given** the selected scope or network does not match the live
   DevNet registry context, **When** the wizard resolves state, **Then**
   it aborts before writing `intent.json`.

---

### User Story 3 - Build Unsigned Withdrawal CBOR (Priority: P1)

As a release maintainer, I need `tx-build` to consume the live DevNet
withdraw intent and produce unsigned Conway CBOR plus reports, without
signing or submitting the final withdrawal transaction.

**Why this priority**: The release-facing Amaru CLI builds unsigned
transactions. DevNet evidence for #83 must stop at that same boundary.

**Independent Test**: Run `just devnet-smoke withdraw` and verify that
the run directory contains unsigned CBOR, machine-readable report JSON,
human report markdown, tx body hash, and the source intent.

**Acceptance Scenarios**:

1. **Given** a valid live withdraw intent, **When** `tx-build` runs,
   **Then** it produces unsigned withdrawal CBOR and report artifacts.
2. **Given** `tx-build` fails, **When** the smoke records the failure,
   **Then** the diagnostic identifies the build phase and preserves the
   intent plus live chain context used for reproduction.

---

### User Story 4 - Preserve Slice Boundaries (Priority: P2)

As maintainers splitting the release experiment, we need the withdrawal
slice to document exactly what it proves and what it leaves for
disburse, swap, and reorganize.

**Why this priority**: The governance proof must not be confused with
withdrawal proof, and withdrawal proof must not claim disburse or swap
execution.

**Independent Test**: Read README, release notes, and #83 metadata
after the smoke passes; they must identify this as withdrawal evidence
only.

**Acceptance Scenarios**:

1. **Given** the withdrawal smoke passes, **When** release docs are
   reviewed, **Then** they include the withdrawal run directory, reward
   account, reward amount, tx body hash, and report paths.
2. **Given** follow-up slices remain open, **When** the roadmap is
   reviewed, **Then** disburse (#86), SundaeSwap order build/funding
   (#84), SundaeSwap order spend (#85), and reorganize (#87) remain
   separate evidence claims.

### Edge Cases

- Governance setup succeeds but the target reward account stays zero.
- The reward account is funded after the timeout budget expires.
- A stale governance summary points to a run whose node is no longer
  live.
- `withdraw-wizard` observes zero rewards and correctly writes no
  intent.
- Registry metadata or reference UTxOs do not match the local DevNet
  fixture state.
- Wallet selection finds no usable pure ADA fuel/collateral UTxO.
- The intent network and node magic disagree.
- `tx-build` fails during context query, script evaluation, balancing,
  report rendering, or CBOR writing.
- The withdrawal smoke is rerun into a directory containing stale
  artifacts.

## Requirements

### Functional Requirements

- **FR-001**: The system MUST add an opt-in local DevNet `withdraw`
  phase under `just devnet-smoke`.
- **FR-002**: The withdrawal phase MUST start from governance-slice
  funded reward evidence for the Amaru treasury script reward account.
- **FR-003**: The withdrawal phase MUST observe a positive reward
  balance through supported library APIs before writing a withdraw
  intent.
- **FR-004**: The generated intent MUST be a schema-v1
  `action = "withdraw"` document and MUST include the observed positive
  `rewardsLovelace`.
- **FR-005**: The generated intent MUST identify the same treasury
  reward account that the governance prerequisite funded.
- **FR-006**: The withdrawal phase MUST run `tx-build` against the live
  DevNet intent and write unsigned CBOR plus mechanical report
  artifacts.
- **FR-007**: The withdrawal phase MUST NOT sign or submit the final
  withdrawal transaction.
- **FR-008**: Zero reward, timeout, stale evidence, network mismatch,
  and build failure cases MUST fail with typed diagnostics and no
  misleading success artifacts.
- **FR-009**: The run directory MUST include enough reproduction
  artifacts to rerun the wizard/build path without rediscovering state:
  summary JSON/logs, intent JSON, tx body path, report paths, reward
  evidence, epoch/tip context, and upstream dependency SHA.
- **FR-010**: README, release docs, and #83 metadata MUST document this
  as withdrawal evidence only.

### Key Entities

- **Withdrawal DevNet Run**: One smoke execution with node socket,
  governance prerequisite evidence, wizard output, builder output, and
  summary logs.
- **Governance Prerequisite Evidence**: The reward account, amount,
  governance tx/action id, epoch/tip context, and run directory from
  the #82 setup path.
- **Live Withdraw Intent**: The schema-v1 `withdraw` intent emitted by
  `withdraw-wizard` from live local-node state.
- **Withdrawal Build Evidence**: Unsigned CBOR, tx body hash/report,
  mechanical JSON report, human markdown report, and build diagnostics.
- **Withdrawal Diagnostic**: Typed failure record with phase, last
  observed reward, epoch/tip context, and artifact paths.

## Success Criteria

### Measurable Outcomes

- **SC-001**: `just devnet-smoke withdraw` either completes with
  withdrawal artifacts or fails with a typed diagnostic within the
  configured wait budget.
- **SC-002**: On success, `withdraw/intent.json` contains
  `action = "withdraw"` and `rewardsLovelace > 0`.
- **SC-003**: On success, `tx-build` produces unsigned CBOR and report
  artifacts from the live DevNet intent.
- **SC-004**: On zero reward or timeout, no `intent.json` or success
  CBOR is written.
- **SC-005**: Release docs distinguish governance funding evidence
  from withdrawal build evidence and leave later slices unclaimed.

## Assumptions

- #82 remains the source of the DevNet governance setup and reward
  funding mechanics.
- The withdrawal smoke may call #82 helper code as fixture setup, but
  the withdrawal evidence boundary starts after funded reward state is
  observed.
- `cardano-node-clients` #132 is merged into upstream `main`; Amaru
  should refresh its pin from the temporary stack SHA to the merged
  upstream `main` commit before implementation.
- The release-facing CLI remains build-only: no signing or final
  withdrawal submission.
