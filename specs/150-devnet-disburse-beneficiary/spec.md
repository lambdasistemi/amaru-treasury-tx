# Feature Specification: DevNet Disburse Action And Beneficiary Receipt

**Feature Branch**: `150-devnet-disburse-beneficiary`
**Created**: 2026-05-16
**Status**: Draft
**Input**: Issue #150 under parent #151. Parent invariant: every
operator-created DevNet bootstrap transaction must be available through a
production command and proven by thin DevNet smoke. The command is the
ticket; smoke is proof.

## User Stories And Tests

### User Story 1 - Submit Disburse Command (Priority: P1)

As a DevNet treasury operator, I can run a shipped command that consumes
the #149 materialized treasury UTxO handoff and submits a DevNet
disburse transaction to a beneficiary, so the bootstrap sequence reaches
the first beneficiary receipt proof without spec-owned transaction
construction.

**Independent Test**: Run the shipped DevNet disburse command after
#147, #148, and #149 artifacts exist. Verify that it builds through the
production disburse/tx-build path, signs/submits the transaction, writes
structured artifacts, and records chain-state proof for treasury debit
and beneficiary receipt.

**Acceptance Scenarios**:

1. **Given** a fresh DevNet run with `registry-init`,
   `stake-reward-init`, and `governance-withdrawal-init/materialized.json`,
   **When** the operator runs `devnet disburse-submit`, **Then** the
   command submits one ADA disburse transaction and prints stable
   command-prefixed success lines.
2. **Given** the submitted transaction is accepted, **When** the command
   verifies chain state, **Then** it proves the selected treasury input
   was consumed or reduced as expected and the beneficiary received the
   configured lovelace amount.
3. **Given** submission or verification fails, **When** artifacts are
   written, **Then** the command writes a stable failure artifact with
   failed step, observed tx ids, and paths to partial evidence.

---

### User Story 2 - Thin Smoke Proof (Priority: P1)

As a maintainer, I can run `just devnet-smoke disburse-submit` and know
the smoke harness invokes the shipped command path, not bespoke
transaction construction.

**Independent Test**: `just devnet-smoke disburse-submit` starts a
fresh DevNet, runs the three prerequisite commands, invokes the #150
production command runner, and asserts emitted artifacts and observed
ledger effects.

**Acceptance Scenarios**:

1. **Given** the smoke proof runs, **When** it reaches #150 behavior,
   **Then** it calls the production command runner with prerequisite
   artifact paths.
2. **Given** the command succeeds, **When** smoke inspects artifacts,
   **Then** it sees registry source, #149 materialized source,
   submitted disburse tx id, beneficiary output, treasury before/after
   state, signed tx path, and submit log.

---

### User Story 3 - Documentation And Handoff (Priority: P2)

As an operator or reviewer, I can read README/docs/release notes and see
how to run the #150 command, what artifacts it emits, and how it relates
to #151.

**Independent Test**: README, local DevNet smoke docs, release notes,
quickstart, contract, tasks, and PR body all describe the same command,
artifact paths, live evidence, and remaining boundaries.

## Requirements

- **FR-001**: The shipped command MUST be
  `amaru-treasury-tx --network devnet --node-socket <socket> devnet
  disburse-submit ...`.
- **FR-002**: The command MUST reject non-DevNet networks before reading
  signing keys, opening sockets, submitting transactions, or writing
  success artifacts.
- **FR-003**: The command MUST consume #147 `registry-init/registry.json`
  and #149 `governance-withdrawal-init/materialized.json`.
- **FR-004**: The command MUST build the disburse intent/transaction
  through existing production disburse and tx-build paths, or through a
  production DevNet module that delegates to those paths.
- **FR-005**: The command MUST sign and submit the disburse transaction
  on DevNet using the provided funding signing key.
- **FR-006**: The command MUST verify treasury state after submission:
  the selected treasury input is spent or reduced as expected, and the
  remaining treasury value is recorded.
- **FR-007**: The command MUST verify beneficiary receipt at the
  configured beneficiary address for the configured lovelace amount.
- **FR-008**: The command MUST emit structured success artifacts:
  `summary.json`, `disburse.json`, `beneficiary.json`,
  `treasury.json`, `provenance.json`, unsigned tx body, report JSON/MD,
  signed tx, submit log, and any intent JSON used.
- **FR-009**: Failure artifacts MUST include stable code, message,
  failed step, observed tx ids, and paths to partial artifacts.
- **FR-010**: Smoke MUST be a thin proof layer that prepares DevNet and
  prerequisites, invokes the production command runner, and asserts
  artifacts/effects.
- **FR-011**: README, `docs/local-devnet-smoke.md`,
  `docs/release.md`, contract, quickstart, tasks, and PR body MUST be
  aligned before PR ready.

## Non-Goals

- No mainnet/preprod disburse submission command.
- No USDM disburse live proof unless explicitly added after ADA
  beneficiary receipt passes.
- No synthetic scooper, swap order, swap spend, or reorganize proof.
- No reimplementation of #147, #148, or #149 setup inside #150.

## Success Criteria

- **SC-001**: `devnet disburse-submit` submits one ADA disburse on
  DevNet and exits 0 with stable command-prefixed success lines.
- **SC-002**: `just devnet-smoke disburse-submit` passes on a fresh
  DevNet and proves the same command path.
- **SC-003**: Artifacts record submitted tx id, beneficiary address,
  beneficiary TxIn/output value, treasury before/after state, signed tx,
  submit log, and #149 materialized source.
- **SC-004**: `SmokeSpec.hs` does not own #150 transaction
  construction.
- **SC-005**: Docs and PR metadata lead with the shipped command and
  describe smoke as proof.
