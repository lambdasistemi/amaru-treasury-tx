# Feature Specification: DevNet Stake And Reward Setup

**Feature Branch**: `148-devnet-stake-reward`  
**Created**: 2026-05-16  
**Status**: Draft  
**GitHub Issue**: [#148](https://github.com/lambdasistemi/amaru-treasury-tx/issues/148)  
**Parent Issue**: [#151](https://github.com/lambdasistemi/amaru-treasury-tx/issues/151)  
**Input**: User description: "Move the DevNet stake/reward-account prerequisites out of specs and into production-backed setup code." Parent issue #151 requires every operator-created bootstrap transaction to be recovered as a production command, so the shipped DevNet setup command is required for #148.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Prepare Reward Accounts With A Shipped Command (Priority: P1)

As a release maintainer recovering the DevNet bootstrap path, I need a
shipped `amaru-treasury-tx` DevNet command that prepares the treasury
and permissions script reward accounts required by later treasury
actions, so disburse and withdrawal proofs do not rely on setup
transactions hidden inside `SmokeSpec.hs`.

**Why this priority**: Parent issue #151 is command recovery. #148
blocks submitted disburse proof because permissions zero-withdrawal and
treasury reward-account setup must exist on the live DevNet before the
later treasury actions can be submitted.

**Independent Test**: Run the shipped `amaru-treasury-tx` DevNet
stake/reward setup command against a local DevNet after registry-init
has produced registry artifacts. Verify that it rejects non-DevNet
networks before effects, submits the setup transaction through
production-backed code, writes structured artifacts, and reports the
prepared reward accounts.

**Acceptance Scenarios**:

1. **Given** a local DevNet with registry/reference-script artifacts
   from #147, **When** an operator runs the shipped DevNet
   stake/reward setup command with an explicit socket, registry file,
   funding address, signing source, and run directory, **Then** it
   submits the setup transaction through production-backed code.
2. **Given** setup submission succeeds, **When** the command verifies
   the local ledger, **Then** it reports the treasury script reward
   account and permissions script reward account as prepared for later
   treasury actions.
3. **Given** the command is invoked for a non-DevNet network or without
   required inputs, **When** argument validation runs, **Then** it fails
   before reading signing-key material, opening the node socket, or
   writing success artifacts.

---

### User Story 2 - Make Permissions Reward Parsing Testnet-Aware (Priority: P1)

As a maintainer building DevNet treasury actions, I need permissions
reward-account parsing to use the transaction network, so DevNet and
other testnet-family intents create `Testnet` reward accounts instead
of silently constructing Mainnet accounts.

**Why this priority**: #32 is the known root of this class of bug, and
PR #145 observed that submitted disburse failed at the permissions
zero-withdrawal boundary. A prepared DevNet reward account is useless if
the intent translator points the transaction at a Mainnet reward
account.

**Independent Test**: Translate a DevNet disburse intent and verify that
the permissions reward account is a ledger `Testnet` account. Existing
mainnet behavior remains unchanged.

**Acceptance Scenarios**:

1. **Given** a DevNet disburse intent with a permissions script hash,
   **When** translation builds the permissions reward account, **Then**
   the account uses the ledger `Testnet` network.
2. **Given** a mainnet disburse intent, **When** translation builds the
   permissions reward account, **Then** the account remains Mainnet.
3. **Given** an unknown network name, **When** reward-account parsing
   runs, **Then** it fails with a typed parser error instead of choosing
   a default network.

---

### User Story 3 - Prove Setup Through Thin DevNet Smoke (Priority: P2)

As a reviewer of the recovery work, I need the smoke layer to invoke the
production command runner and verify ledger effects only, so setup
transaction construction remains reusable and operator-facing.

**Why this priority**: PR #145 showed that adding more bootstrap logic
inside `SmokeSpec.hs` makes the proof unusable as an operator path.

**Independent Test**: Run `just devnet-smoke stake-reward-init` and
verify that it runs the same command runner path, records setup
artifacts, and leaves the chain ready for later governance/withdrawal
and disburse child tickets.

**Acceptance Scenarios**:

1. **Given** the smoke starts from a fresh local DevNet, **When** the
   stake/reward setup phase runs, **Then** it invokes the production
   command runner and writes the same artifact contract as the shipped
   command.
2. **Given** setup succeeds, **When** later #149 and #150 slices start,
   **Then** they can consume the emitted artifacts instead of
   rediscovering reward-account hashes and setup tx ids from logs.
3. **Given** setup fails, **When** the smoke records diagnostics,
   **Then** stale success artifacts are not left behind.

### Edge Cases

- Registry-init artifacts are missing, stale, malformed, or for a
  network other than DevNet.
- The funding address has no pure ADA UTxO large enough for deposits,
  fees, collateral, and change.
- The submitted setup transaction is accepted but the expected reward
  account state cannot be observed within the wait budget.
- The permissions zero-withdrawal validation still targets a Mainnet
  account on a DevNet transaction.
- The run directory contains stale success artifacts from a previous
  run.
- Required cardano-node-clients certificate support changes shape or is
  unavailable in the pinned dependency.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The system MUST provide a shipped `amaru-treasury-tx`
  DevNet stake/reward setup command. A smoke-only command is not
  sufficient for #148 under parent #151.
- **FR-002**: The command MUST consume registry/reference-script
  artifacts from #147 or an equivalent production projection and MUST
  verify that they describe DevNet registry state.
- **FR-003**: The command MUST prepare the treasury script reward
  account used by later treasury withdrawal materialization.
- **FR-004**: The command MUST prepare the permissions script reward
  account used by disburse and other permissions zero-withdrawal paths.
- **FR-005**: The command and smoke layer MUST invoke the
  production-backed setup entry point instead of constructing setup
  transactions inline in `SmokeSpec.hs`.
- **FR-006**: The command MUST reject non-DevNet networks before
  signing, submission, node connection, or success-artifact writes.
- **FR-007**: The setup result MUST emit structured artifacts with setup
  tx ids, prepared reward accounts, script hashes, verification status,
  and the registry artifact source.
- **FR-008**: Failure paths MUST use typed diagnostics and MUST NOT
  leave misleading success artifacts.
- **FR-009**: Disburse permissions reward-account parsing MUST be
  network-aware for mainnet and testnet-family networks including
  DevNet.
- **FR-010**: Documentation MUST explain how a maintainer runs both the
  shipped DevNet setup command and the live smoke proof, and what
  artifacts they emit.
- **FR-011**: This slice MUST NOT submit governance funding, treasury
  withdrawal materialization, disburse actions, swap orders, or
  external-role transactions; those remain #149, #150, and separate
  external-role work.

### Key Entities

- **StakeRewardInitRun**: One command execution with network identity,
  registry source, funding input, setup tx id, and artifact paths.
- **PreparedRewardAccount**: Treasury or permissions script reward
  account with script hash, ledger network, setup status, and observed
  rewards.
- **StakeRewardSetupTransaction**: DevNet transaction that registers or
  prepares the script reward accounts needed by later treasury actions.
- **StakeRewardDiagnostic**: Typed failure record for invalid network,
  missing registry, funding shortfall, submission rejection, or
  verification timeout.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A maintainer can identify and run the shipped
  stake/reward setup command from README or docs without reading
  `SmokeSpec.hs`.
- **SC-002**: The setup command rejects non-DevNet networks before
  effects.
- **SC-003**: Successful setup output includes a setup tx id, treasury
  reward account, permissions reward account, summary path, and accounts
  artifact path.
- **SC-004**: `just devnet-smoke stake-reward-init` passes on a fresh
  local DevNet and proves the same command runner path.
- **SC-005**: A DevNet disburse intent translates its permissions reward
  account as ledger `Testnet`.
- **SC-006**: README, local DevNet docs, contracts, quickstart, tasks,
  and PR metadata do not claim #149 governance/withdrawal setup or #150
  disburse behavior.

## Assumptions

- The approved local network remains `cardano-node-clients` DevNet with
  magic `42`.
- #147 registry-init artifacts are available before this setup command
  runs.
- The production command may use DevNet-only signing/submission because
  parent #151 explicitly recovers operator-created bootstrap commands.
- The smoke may compose registry-init and stake/reward setup in one
  fresh run, but the stake/reward proof must go through the shipped
  command runner.
