# Feature Specification: DevNet Governance And Withdrawal Setup

**Feature Branch**: `149-devnet-governance-withdrawal`
**Created**: 2026-05-16
**Status**: Draft
**GitHub Issue**: [#149](https://github.com/lambdasistemi/amaru-treasury-tx/issues/149)
**Parent Issue**: [#151](https://github.com/lambdasistemi/amaru-treasury-tx/issues/151)
**Input**: User description: "Provide a production-backed DevNet initiator that performs the governance/reward flow needed to materialize ADA at the treasury spending validator." Parent issue #151 requires operator-created bootstrap transactions to be recovered as shipped commands; the command is the ticket, and smoke is only proof.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Materialize Treasury ADA With A Shipped Command (Priority: P1)

As a maintainer preparing the local DevNet for submitted treasury
actions, I need a shipped `amaru-treasury-tx` DevNet command that
submits the governance funding flow and the treasury reward withdrawal
flow, so the ADA needed by later disburse proof is locked at the Amaru
treasury spending validator through an operator-facing path.

**Why this priority**: Parent issue #151 is command recovery. #149 is
not complete if the only successful path remains embedded in
`SmokeSpec.hs`; the crucial user story is that an operator can run the
production command.

**Independent Test**: Run the shipped DevNet governance/withdrawal
setup command against a governance-enabled local DevNet after #147
registry-init and #148 stake-reward-init artifacts exist. Verify that
it rejects non-DevNet networks before effects, consumes both
prerequisite artifacts, submits the governance proposal and vote, waits
for the expected reward-account state, builds/signs/submits the
withdrawal materialization transaction, and emits structured artifacts
including the resulting treasury UTxO.

**Acceptance Scenarios**:

1. **Given** a local DevNet with registry artifacts from #147 and
   stake/reward artifacts from #148, **When** an operator runs the
   shipped DevNet governance/withdrawal setup command with an explicit
   socket, registry file, stake/reward file, funding address, signing
   key, and run directory, **Then** it submits the governance funding
   flow through production-backed code.
2. **Given** the governance action is accepted, **When** the command
   waits across the required ledger epochs and submits the vote, **Then**
   it observes the treasury script reward account increase by the
   configured withdrawal amount.
3. **Given** the reward account is funded, **When** the command
   materializes the reward, **Then** it builds a schema-v1 withdrawal
   transaction through the existing production withdraw/tx-build path,
   signs and submits it through the DevNet bootstrap exception, and
   verifies ADA locked at the treasury spending validator.
4. **Given** the command is invoked for a non-DevNet network or with
   mismatched prerequisite artifacts, **When** validation runs, **Then**
   it fails before reading signing-key material, opening the node
   socket, submitting transactions, or writing success artifacts.

---

### User Story 2 - Keep Smoke A Thin Command Proof (Priority: P1)

As a reviewer of the recovery work, I need the DevNet smoke layer to
prepare the local node and call the production command, so transaction
construction no longer lives in the spec layer.

**Why this priority**: PR #145 and the current smoke show that registry
publication, reward setup, governance, voting, intent creation,
tx-build, signing, submission, and materialization are interleaved in
`SmokeSpec.hs`. #149 must remove governance/withdrawal construction
from smoke except for node setup, prerequisite orchestration, command
invocation, and assertions.

**Independent Test**: Run `just devnet-smoke governance-withdrawal-init`
and verify that it starts a governance-enabled local DevNet, produces
#147 and #148 prerequisites through their shipped commands, calls the
#149 command runner, and asserts the command artifacts plus final chain
state.

**Acceptance Scenarios**:

1. **Given** the smoke starts from a fresh local DevNet, **When** the
   governance/withdrawal proof runs, **Then** it invokes the shipped
   command path instead of constructing governance or withdrawal
   transactions inline.
2. **Given** the proof succeeds, **When** a reviewer inspects the run
   directory, **Then** the command artifacts identify the registry
   source, stake/reward source, governance proposal, vote, reward state,
   withdrawal tx, submission result, and materialized treasury UTxO.
3. **Given** existing release notes still reference `withdraw`, **When**
   this ticket lands, **Then** documentation either updates that phase
   to the new command proof or preserves it as a compatibility alias
   that calls the same production runner.

---

### User Story 3 - Hand Off A Treasury UTxO To Disburse Proof (Priority: P2)

As the maintainer of the next child ticket, I need #149 artifacts to
publish the exact treasury UTxO and metadata #150 consumes, so the
submitted disburse slice starts from a real DevNet treasury balance
instead of replaying or rediscovering bootstrap state.

**Why this priority**: #149 is the direct prerequisite for #150. If the
resulting treasury UTxO is not machine-readable, #150 will drift back
into smoke-local discovery and lose the parent command-recovery story.

**Independent Test**: Inspect the command summary and materialization
artifacts after a successful run and verify that #150 can identify the
treasury script address, materialized TxIn, ADA value, registry source,
and reward-account history without parsing logs.

**Acceptance Scenarios**:

1. **Given** command success, **When** #150 reads the artifact set,
   **Then** it can locate the treasury UTxO locked by the spending
   validator and the registry/reference-script anchors used to build
   the withdrawal.
2. **Given** the command fails after partial submission, **When** a
   maintainer inspects the failure artifact, **Then** the failed step,
   observed tx ids, last reward state, epoch, and tip slot are recorded.
3. **Given** the PR is ready for review, **When** README, docs, release
   notes, specs, contracts, quickstart, tasks, and PR body are compared,
   **Then** they all describe the shipped command first and smoke proof
   second.

### Edge Cases

- Registry-init artifacts are missing, stale, malformed, or for a
  network other than DevNet.
- Stake/reward artifacts are missing, stale, malformed, not from #148,
  not DevNet, or contain a treasury script hash that does not match the
  registry artifact.
- The #148 treasury reward account is not marked registered or cannot
  be observed through the provider within the wait budget.
- The command accidentally re-registers the treasury or permissions
  reward account instead of consuming #148 state.
- The funding address has no pure ADA UTxO large enough for deposits,
  fees, collateral, vote output, and change.
- The local DevNet is not governance-enabled or uses governance deposit,
  committee, epoch, or treasury settings incompatible with the proof.
- The governance proposal is accepted but no vote UTxO appears, the
  vote is rejected, or the expected reward increase does not arrive
  before timeout.
- The withdrawal intent resolves a reward account or network that does
  not match the prerequisite artifacts.
- `tx-build` fails script evaluation, returns a failed report, or
  builds a tx whose id does not match the signed/submitted tx.
- The submitted withdrawal tx is accepted but the materialized treasury
  UTxO does not appear, has the wrong address, has assets, or has the
  wrong lovelace value.
- The run directory contains stale success artifacts from a previous
  run.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The system MUST provide a shipped
  `amaru-treasury-tx --network devnet ... devnet
  governance-withdrawal-init ...` command. A smoke-only path is not
  sufficient for #149 under parent #151.
- **FR-002**: The command MUST consume #147 registry/reference-script
  artifacts and verify that they describe DevNet registry state.
- **FR-003**: The command MUST consume #148 stake/reward artifacts,
  verify that the treasury reward account is registered on DevNet, and
  verify that the treasury script hash matches the registry artifact.
- **FR-004**: The command MUST NOT re-register the treasury reward
  account or register the permissions reward account; #148 owns
  stake/reward setup.
- **FR-005**: The command MUST submit the Conway treasury-withdrawal
  governance proposal and the required vote through production-backed
  DevNet code.
- **FR-006**: The command MUST wait for or verify the ledger state
  needed before withdrawal materialization, including reward-account
  before/after balances and relevant epochs.
- **FR-007**: The command MUST create the withdrawal intent through the
  existing production withdraw resolver/translator rather than
  hand-writing intent JSON in the smoke layer.
- **FR-008**: The command MUST build the unsigned withdrawal transaction
  through the production tx-build path, write the standard report
  artifacts, sign with the supplied DevNet bootstrap signing key, submit
  the signed tx, and verify materialization at the treasury spending
  validator.
- **FR-009**: The command MUST reject non-DevNet networks before
  signing, submission, node connection, or success-artifact writes.
- **FR-010**: The command MUST emit structured artifacts with registry
  source, stake/reward source, governance proposal tx id, governance
  action id, vote tx id, reward state before/after, withdrawal tx id,
  submit result, materialized treasury TxIn, treasury address, and ADA
  value.
- **FR-011**: Failure paths MUST use stable diagnostics and MUST NOT
  leave misleading success artifacts.
- **FR-012**: The smoke layer MUST invoke the production command runner
  for #149 behavior; it may only own DevNet process setup, prerequisite
  orchestration, and assertions.
- **FR-013**: README, `docs/local-devnet-smoke.md`, `docs/release.md`,
  quickstart, contracts, tasks, and PR metadata MUST be aligned before
  the PR is marked ready.
- **FR-014**: This slice MUST NOT submit disburse transactions, swap
  orders, external scooper activity, order spends, or reorganize
  transactions; those remain #150 and later tickets.

### Key Entities

- **GovernanceWithdrawalInitRun**: One command execution with network
  identity, prerequisite artifact paths, amount, tx ids, artifact paths,
  and final status.
- **GovernanceProposal**: The Conway treasury-withdrawal governance
  proposal, including tx id, action id, target reward account, requested
  amount, deposit return account, setup epoch, and vote epoch.
- **GovernanceVote**: The DRep vote transaction and voting identity used
  by the DevNet bootstrap path.
- **RewardObservation**: Reward-account before/after balances, final
  epoch, tip slot, and timeout diagnostics.
- **WithdrawalMaterialization**: The built, signed, submitted, and
  observed withdrawal tx plus the resulting treasury UTxO.
- **GovernanceWithdrawalFailure**: Typed failure record with failed
  step, code, message, observed tx ids, last reward state, epoch, and
  tip slot.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A maintainer can identify and run the shipped
  governance/withdrawal setup command from README or docs without
  reading `SmokeSpec.hs`.
- **SC-002**: The command rejects non-DevNet networks before effects.
- **SC-003**: Successful stdout includes proposal tx id, governance
  action id, vote tx id, treasury reward account, reward before/after,
  withdrawal tx id, submitted tx id, materialized TxIn, materialized ADA,
  summary path, and materialization path.
- **SC-004**: `just devnet-smoke governance-withdrawal-init` passes on
  a fresh governance-enabled local DevNet and proves the same command
  runner path.
- **SC-005**: Successful artifacts include a machine-readable treasury
  UTxO handoff sufficient for #150 disburse proof.
- **SC-006**: `SmokeSpec.hs` no longer owns governance proposal/vote or
  withdrawal materialization construction for #149 behavior.
- **SC-007**: README, docs, release notes, contracts, quickstart,
  tasks, and PR metadata do not describe old smoke-only governance or
  withdrawal setup as the primary operator path.

## Assumptions

- The approved local network remains `cardano-node-clients` DevNet with
  magic `42`.
- The #149 command runs against a governance-enabled local DevNet. The
  smoke harness may still copy and patch genesis files to create that
  short-epoch environment.
- #147 and #148 artifacts are produced in the same fresh run when the
  smoke proof executes, but manual operators may pass existing artifact
  paths from an already prepared local DevNet.
- DevNet bootstrap commands are explicit exceptions to the normal
  build-only rule because parent #151 is about recovering
  operator-created local bootstrap transactions.
- The default local proof amount remains `2_000_000` lovelace unless
  the command exposes and records an explicit override.
