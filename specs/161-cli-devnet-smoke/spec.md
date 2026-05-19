# Feature Specification: CLI DevNet Smoke Proof

**Feature Branch**: `161-cli-devnet-smoke`  
**Created**: 2026-05-19  
**Status**: Draft  
**GitHub Issue**: [#161](https://github.com/lambdasistemi/amaru-treasury-tx/issues/161)  
**Parent Issue**: [#156](https://github.com/lambdasistemi/amaru-treasury-tx/issues/156)

**Input**: Add `scripts/smoke/smoke.sh`: a bash entrypoint that proves the shipped `amaru-treasury-tx` CLI can run the full local DevNet bootstrap and disburse play end to end. This is the CLI/operator proof layer. `SmokeSpec` remains the library proof layer and must not be rewritten into a shell harness.

## User Scenarios & Testing

### User Story 1 - Full CLI Bootstrap Smoke (Priority: P1)

As a release maintainer, I need one command to start a fresh local DevNet and drive the shipped CLI through registry init, stake/reward init, governance withdrawal materialization, and disburse submission, so a false-positive library-only proof cannot ship.

**Why this priority**: Parent #156 exists because `SmokeSpec` can prove library functions while the operator CLI remains incomplete. The MVP must execute the operator path, not just inspect fixtures.

**Independent Test**: Run `nix develop --quiet -c just devnet-cli-smoke` from a clean worktree. The command must produce a run directory with tx ids, intent files, unsigned txs, witnesses, signed txs, submit logs, and verification artifacts for every bootstrap phase.

**Acceptance Scenarios**:

1. **Given** a clean worktree in the Nix dev shell, **When** the maintainer runs `just devnet-cli-smoke`, **Then** a real local DevNet starts and `scripts/smoke/smoke.sh` drives only shipped `amaru-treasury-tx` commands for transaction creation, signing, witness attachment, and submission.
2. **Given** the smoke reaches registry init, **When** it completes `registry-init-wizard seed-split`, `mint`, and `reference-scripts`, **Then** it records and verifies the registry artifact, reference-script anchors, and seed handoffs needed by later phases.
3. **Given** the smoke reaches stake/reward init, **When** it completes `stake-reward-init-wizard script-account` and `plain-account`, **Then** it records and verifies the treasury and permissions reward-account artifact.
4. **Given** the smoke reaches governance withdrawal init, **When** it completes `governance-withdrawal-init-wizard proposal` and then materialization, **Then** it records and verifies reward materialization into the treasury contract and proves no required governance step was only available through `runDevnet*`.
5. **Given** the smoke reaches disburse, **When** it runs `disburse-wizard` against the materialized treasury UTxO, **Then** it records and verifies beneficiary receipt and treasury reduction.

---

### User Story 2 - No In-Process Fallback (Priority: P1)

As the epic orchestrator, I need the smoke to fail loudly if any required transaction can still only be reached through `SmokeSpec`, `Amaru.Treasury.Devnet.Runner`, or another in-process Haskell runner, so the PR cannot mask an incomplete shipped CLI surface.

**Why this priority**: This is the explicit acceptance criterion for #161. A shell wrapper around `cabal test devnet-tests` would preserve the false-positive gap.

**Independent Test**: Run the script lint/unit checks without a DevNet. They must reject `scripts/smoke/smoke.sh` and its helper entrypoints if they call `runDevnet*`, `cabal test devnet-tests`, or `Amaru.Treasury.Devnet.Runner`.

**Acceptance Scenarios**:

1. **Given** the smoke implementation, **When** a developer greps the script and helper host, **Then** there are zero calls to `runDevnet*`, zero calls to `cabal test devnet-tests`, and zero imports of `Amaru.Treasury.Devnet.Runner`.
2. **Given** the legacy library smoke submits a follow-up governance vote internally, **When** the CLI smoke checks governance enactment, **Then** it either proves the patched DevNet genesis allows proposal enactment without an in-process vote or fails with a diagnostic naming the missing shipped governance vote surface.
3. **Given** any phase failure, **When** the script exits non-zero, **Then** the run directory keeps the last intent, unsigned tx, witness, submit log, chain query, and diagnostic file needed to see which shipped CLI boundary failed.

---

### User Story 3 - Documentation Separates Proof Layers (Priority: P2)

As an operator, I need the README and local smoke docs to distinguish the Haskell library proof from the bash CLI/operator proof, so I know which command proves the shipped surface.

**Independent Test**: Read `README.md` and `docs/local-devnet-smoke.md`; both name `SmokeSpec` as library proof and `scripts/smoke/smoke.sh` / `just devnet-cli-smoke` as CLI proof, with runner retention explained.

**Acceptance Scenarios**:

1. **Given** #161 is merged, **When** an operator reads the local smoke docs, **Then** the primary CLI proof command is visible and the old `just devnet-smoke` phases are described as library proof only.
2. **Given** `lib/Amaru/Treasury/Devnet/*` runners remain, **When** a reviewer reads the PR, **Then** the docs state which runners remain and why `SmokeSpec` still consumes them.

### Edge Cases

- Missing `jq`, `cardano-cli`, `cardano-node`, or `amaru-treasury-tx` in `PATH` fails during preflight before starting DevNet.
- A requested run directory that already exists and is non-empty fails unless the operator passes the documented force/clean option.
- A tx-build report tx id that differs from `submit` output fails the phase immediately.
- A `witness` identity whose key hash is not required by the unsigned tx fails the phase immediately; the script must not use `--allow-unlisted-key` for bootstrap txs.
- Governance reward polling can time out; the failure must name whether the missing boundary is proposal submission, governance enactment/reward accrual, or materialization.
- The smoke may use a Haskell helper for DevNet lifecycle, patched genesis preparation, deterministic DevNet key fixture generation, and chain assertions. That helper must not construct, sign, or submit the bootstrap transactions in process.

## Requirements

### Functional Requirements

- **FR-001**: `scripts/smoke/smoke.sh` MUST exist, be executable, and be the public entrypoint for the CLI DevNet smoke.
- **FR-002**: `just devnet-cli-smoke` MUST invoke `scripts/smoke/smoke.sh`; `gate.sh` MUST run the ticket-specific proof before the PR is ready, either directly or through `just`.
- **FR-003**: The script MUST start a fresh DevNet through `cardano-node-clients` `withCardanoNode` or a scripted equivalent, using the governance-patched short-epoch genesis required by the existing governance smoke.
- **FR-004**: Transaction phases MUST use the shipped `amaru-treasury-tx` CLI commands: `*-wizard` or `disburse-wizard`, `tx-build`, `vault create`, `witness`, `attach-witness`, and `submit`.
- **FR-005**: The script and helper host MUST NOT call `runDevnet*`, `Amaru.Treasury.Devnet.Runner`, or `cabal test devnet-tests`.
- **FR-006**: The smoke MUST create DevNet-only vault identities from deterministic smoke keys and sign via `witness` plus `attach-witness`; direct in-process signing is forbidden for bootstrap txs.
- **FR-007**: The smoke MUST verify registry, stake/reward accounts, governance materialization, disburse artifact, beneficiary receipt, and treasury reduction.
- **FR-008**: If governance materialization requires a transaction that has no shipped CLI path, the smoke MUST fail with an explicit missing-shipped-surface diagnostic instead of falling back to the library runner.
- **FR-009**: `SmokeSpec` MUST remain as the library proof layer; no body rewrite is allowed as part of this ticket.
- **FR-010**: README and local DevNet smoke docs MUST identify the two proof layers and state whether the relocated DevNet runners remain.

### Key Entities

- **Smoke Run Directory**: The on-disk evidence bundle for one CLI smoke run: intents, tx bodies, witnesses, signed txs, submit logs, chain query JSON, phase summaries, and final summary.
- **DevNet Host Helper**: A narrow process that owns node lifecycle and deterministic smoke fixtures. It is allowed to export environment variables and run the bash script inside the node callback; it is not allowed to build or submit bootstrap transactions.
- **Phase Artifact**: A JSON or text file emitted per bootstrap phase that links inputs, tx ids, chain observations, and downstream handoff fields.
- **Missing Surface Diagnostic**: A structured failure explaining which required operator action is not reachable through shipped CLI commands.

## Success Criteria

### Measurable Outcomes

- **SC-001**: `just devnet-cli-smoke` exits `0` on a fresh local run and writes a final summary naming all submitted tx ids and verified artifact paths.
- **SC-002**: The no-fallback check exits `0` only when script/helper sources have zero forbidden runner calls/imports.
- **SC-003**: A failed phase exits non-zero and writes a diagnostic naming the failed command or missing CLI surface.
- **SC-004**: Existing `just smoke`, `just devnet-smoke <phase>`, unit tests, and golden tests continue to pass.

## Assumptions

- The local Nix dev shell is the supported environment for this live smoke.
- The CLI smoke is opt-in and may be slower than `just ci`; `gate.sh` can include it for this PR because #161 is specifically a live-boundary ticket.
- A Haskell host/helper is acceptable for DevNet lifecycle and assertions as long as the transaction pipeline is shelling out to shipped CLI commands.
- Under the patched governance genesis, proposal enactment may not require the legacy in-process follow-up vote. The first implementation slice must prove that assumption or surface the missing CLI vote gap.
