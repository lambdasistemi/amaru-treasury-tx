# Tasks: Local Devnet Smoke

**Input**: Design documents from `/home/paolino/amaru-treasury-tx-repo/specs/080-local-devnet-smoke/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/
**Tests**: Required by the project constitution and the feature's
independent test scenarios. Write failing tests before each green step.
Red proof and green implementation are folded into the same reviewed
commit slice; do not commit red-only broken tests as standalone history.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel with other tasks in the same phase when
  files do not overlap.
- **[Story]**: User-story label for story-specific work.
- Every task names the concrete repository path it changes or verifies.

## Phase 1: Setup

**Purpose**: Add the opt-in devnet smoke surface without changing
default CI behavior.
These tasks fold into the node smoke slice unless they are committed as
part of the non-runtime Spec Kit planning slice.

- [x] T001 Add `test/devnet/Spec.hs` and `test/devnet/Amaru/Treasury/Devnet/SmokeSpec.hs` skeletons for the new live smoke suite
- [x] T002 Update `amaru-treasury-tx.cabal` with a manual `devnet-tests` test-suite depending on `cardano-node-clients:devnet`
- [x] T003 Update `flake.nix` so `nix develop` exposes the `cardano-node` binary required by `cardano-node-clients:devnet`
- [x] T004 Add `scripts/smoke/devnet-local` as the stable script entrypoint for the contract in `specs/080-local-devnet-smoke/contracts/local-devnet-smoke.md`
- [x] T005 Add a `devnet-smoke phase="node"` recipe to `justfile` and keep it out of `just ci`

---

## Phase 2: Foundational

**Purpose**: Support a local-only `devnet` network identity while
preserving public-network validation.

**CRITICAL**: User-story work depends on these shared network
boundaries.
Tasks T006-T015 form one vertical reviewed commit: RED tests plus the
GREEN network identity implementation.

- [x] T006 [P] Add failing unit coverage for `--network devnet`, magic `42`, and unknown-network errors in `test/unit/Amaru/Treasury/BuildSpec.hs`
- [x] T007 [P] Add failing reward-account coverage showing `devnet` maps to ledger `Testnet` in `test/unit/Amaru/Treasury/IntentJSONSpec.hs`
- [ ] T008 [P] Add failing wizard network-family coverage for `devnet` in `test/unit/Amaru/Treasury/Tx/DisburseWizardSpec.hs`
- [x] T009 [P] Add failing wizard network-family coverage for `devnet` in `test/unit/Amaru/Treasury/Tx/WithdrawWizardSpec.hs`
- [x] T010 Add `devnet` name/magic support to `lib/Amaru/Treasury/Cli/Common.hs`
- [x] T011 Add `devnet` to socket probing and known network magic resolution in `lib/Amaru/Treasury/Backend/N2C.hs` and `lib/Amaru/Treasury/Cli/TxBuild.hs`
- [x] T012 Add `devnet` reward-account parsing as `Testnet` in `lib/Amaru/Treasury/IntentJSON/Common.hs`
- [x] T013 Add `devnet` network-family support in `lib/Amaru/Treasury/Tx/DisburseWizard.hs` and `lib/Amaru/Treasury/Tx/WithdrawWizard.hs`
- [x] T014 Add `devnet` report network magic support in `lib/Amaru/Treasury/Report.hs` and matching report unit coverage in `test/unit/Amaru/Treasury/ReportSpec.hs`
- [x] T015 Run `just unit "network"` to prove the network alias tests now pass

**Checkpoint**: `devnet` is accepted as a local-only testnet network
name without changing mainnet/preprod/preview behavior.

---

## Phase 3: User Story 1 - Start a Short-Epoch Local Network (Priority: P1)

**Goal**: Start the `cardano-node-clients` devnet, verify socket
readiness and magic `42`, and write timing evidence before any
treasury-specific action runs.

**Independent Test**: `just devnet-smoke node` returns node-ready or
node-failed within 2 minutes and prints the run directory, socket,
network magic, tip, and epoch duration.

### Tests for User Story 1

- [x] T016 [US1] Add a failing node-phase live smoke test in `test/devnet/Amaru/Treasury/Devnet/SmokeSpec.hs`
- [x] T017 [US1] Run `cabal test devnet-tests -O0 --test-show-details=direct --test-option=--match --test-option node` and capture node-boundary gate evidence

### Implementation for User Story 1

- [x] T018 [US1] Implement run-directory creation and stale-artifact rejection in `test/devnet/Amaru/Treasury/Devnet/SmokeSpec.hs`
- [x] T019 [US1] Use `Cardano.Node.Client.E2E.Devnet.withCardanoNode` from `cardano-node-clients:devnet` in `test/devnet/Amaru/Treasury/Devnet/SmokeSpec.hs`
- [x] T020 [US1] Read and record `epochLength`, `slotLength`, and network magic from the devnet genesis in `test/devnet/Amaru/Treasury/Devnet/SmokeSpec.hs`
- [x] T021 [US1] Probe the started socket with magic `42` using existing N2C helpers in `test/devnet/Amaru/Treasury/Devnet/SmokeSpec.hs`
- [x] T022 [US1] Make `scripts/smoke/devnet-local` run the node phase through `cabal test devnet-tests` and forward `--run-dir`
- [x] T023 [US1] Run `just devnet-smoke node` and verify the node-ready output and artifacts

**Checkpoint**: The local devnet boundary is proven independently.
Tasks T016-T023 form one vertical reviewed commit with the setup tasks
needed to make `devnet-tests` executable.

---

## Phase 4: User Story 2 - Exercise Withdrawal With Accrued Rewards (Priority: P2)

**Goal**: Observe positive rewards on the short-epoch devnet and emit
a withdrawal intent only after live rewards are greater than zero.

**Independent Test**: `just devnet-smoke withdraw` either writes a
positive-rewards intent or fails with `REWARDS_TIMEOUT` including the
last reward value, tip, epoch, and wait budget.

### Tests for User Story 2

- [ ] T024 [P] [US2] Add failing timeout contract coverage for reward waiting in `test/devnet/Amaru/Treasury/Devnet/SmokeSpec.hs`
- [ ] T025 [P] [US2] Add failing positive-reward intent coverage in `test/devnet/Amaru/Treasury/Devnet/SmokeSpec.hs`

### Implementation for User Story 2

- [ ] T026 [US2] Implement reward-source discovery for the pinned devnet genesis in `test/devnet/Amaru/Treasury/Devnet/SmokeSpec.hs`
- [ ] T027 [US2] Implement reward polling through `queryStakeRewardsLovelace` in `test/devnet/Amaru/Treasury/Devnet/SmokeSpec.hs`
- [ ] T028 [US2] Implement `REWARDS_TIMEOUT` summaries with last reward, tip, epoch, and wait budget in `test/devnet/Amaru/Treasury/Devnet/SmokeSpec.hs`
- [ ] T029 [US2] Emit `withdraw/intent.json` only after rewards are positive in `test/devnet/Amaru/Treasury/Devnet/SmokeSpec.hs`
- [ ] T030 [US2] Run `just devnet-smoke withdraw` and verify the positive path or typed timeout evidence

**Checkpoint**: Withdrawal reward observation is live-chain evidence,
not a synthetic fixture claim.
Tasks T024-T030 form one vertical reviewed commit or, if reward-source
preparation proves too large, two reviewer-approved vertical commits:
timeout contract first, positive-reward path second.

---

## Phase 5: User Story 3 - Exercise Disburse and Build Steps Against Live State (Priority: P3)

**Goal**: Prepare or require local treasury state and run a
wizard-to-build flow against live local chain queries.

**Independent Test**: `just devnet-smoke disburse` writes intent,
build log, unsigned CBOR, and report artifacts, or fails with
`MISSING_TREASURY_STATE` before partial build output.

### Tests for User Story 3

- [ ] T031 [P] [US3] Add failing missing-state coverage for `MISSING_TREASURY_STATE` in `test/devnet/Amaru/Treasury/Devnet/SmokeSpec.hs`
- [ ] T032 [P] [US3] Add failing artifact-layout coverage for the disburse/build phase in `test/devnet/Amaru/Treasury/Devnet/SmokeSpec.hs`

### Implementation for User Story 3

- [ ] T033 [US3] Implement prepared-state discovery for wallet, treasury, registry, and permissions UTxOs in `test/devnet/Amaru/Treasury/Devnet/SmokeSpec.hs`
- [ ] T034 [US3] Implement local metadata generation for the devnet registry anchors in `test/devnet/Amaru/Treasury/Devnet/SmokeSpec.hs`
- [ ] T035 [US3] Run `amaru-treasury-tx disburse-wizard --network devnet` from `scripts/smoke/devnet-local`
- [ ] T036 [US3] Run `amaru-treasury-tx tx-build` against the generated devnet intent from `scripts/smoke/devnet-local`
- [ ] T037 [US3] Write `disburse/build.log`, `disburse/unsigned.cbor`, `disburse/report.json`, and `disburse/report.md` in the current run directory
- [ ] T038 [US3] Run `just devnet-smoke disburse` and verify either successful artifacts or `MISSING_TREASURY_STATE`

**Checkpoint**: Disburse/build local smoke has live socket evidence and
typed missing-state failures.
Tasks T031-T038 form one vertical reviewed commit or, if local treasury
state preparation proves too large, two reviewer-approved vertical
commits: missing-state diagnostics first, successful build artifacts
second.

---

## Phase 6: Documentation and Release Checklist

**Purpose**: Make the smoke usable as release evidence without
confusing it with deterministic CI.
Documentation may be its own reviewed docs slice when it does not alter
runtime behavior; docs for changed command contracts should travel with
the behavior slice that introduces them.

- [x] T039 [P] Add operator documentation in `docs/local-devnet-smoke.md`
- [x] T040 [P] Add the local devnet smoke page to `mkdocs.yml`
- [x] T041 [P] Link the devnet smoke from `README.md`
- [x] T042 Update `docs/release.md` with a manual release-evidence checklist item for `just devnet-smoke node|withdraw|disburse`
- [ ] T043 Run `just format` for Haskell/Cabal/Nix formatting
- [ ] T044 Run `just unit`
- [x] T045 Run `cabal test devnet-tests -O0 --test-show-details=direct --test-option=--match --test-option node`
- [ ] T046 Run `just smoke`
- [ ] T047 Run `just cabal-check`

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: no dependencies.
- **Foundational (Phase 2)**: depends on Setup and blocks all user
  stories.
- **US1 (Phase 3)**: depends on Foundational.
- **US2 (Phase 4)**: depends on US1 node readiness.
- **US3 (Phase 5)**: depends on US1 and the shared devnet network
  alias; it may be implemented after or in parallel with US2 once node
  readiness is proven.
- **Documentation/Release (Phase 6)**: depends on the implemented
  phases being documented.

### User Story Dependencies

- **US1**: independent MVP. Proves the node boundary only.
- **US2**: requires US1 and reward-source state.
- **US3**: requires US1 and prepared treasury/registry state.

### Parallel Opportunities

- T006-T009 can be written in parallel because they touch separate
  unit test files.
- T024-T025 can be written in parallel before the withdrawal
  implementation.
- T031-T032 can be written in parallel before the disburse/build
  implementation.
- T039-T041 can be written in parallel after the command contract is
  stable.

## Parallel Example: Foundational Network Tests

```bash
Task: "Add failing unit coverage for --network devnet in test/unit/Amaru/Treasury/BuildSpec.hs"
Task: "Add failing reward-account coverage in test/unit/Amaru/Treasury/IntentJSONSpec.hs"
Task: "Add failing disburse wizard network-family coverage in test/unit/Amaru/Treasury/Tx/DisburseWizardSpec.hs"
Task: "Add failing withdraw wizard network-family coverage in test/unit/Amaru/Treasury/Tx/WithdrawWizardSpec.hs"
```

## Implementation Strategy

### MVP First: US1 Only

1. Complete Setup and Foundational phases.
2. Implement US1 with a failing live smoke test first.
3. Run `just devnet-smoke node` before touching withdrawal/disburse.

### Incremental Delivery

1. Ship `devnet` network identity support with unit coverage.
2. Ship node-phase live smoke.
3. Ship withdrawal reward observation.
4. Ship disburse/build once local treasury state preparation is
   explicit and typed.

### Validation Before Completion

At minimum for the MVP:

```bash
just unit "network"
cabal test devnet-tests -O0 --test-show-details=direct --test-option=--match --test-option node
just devnet-smoke node
```

For full feature completion:

```bash
just unit
cabal test devnet-tests -O0 --test-show-details=direct
just devnet-smoke node
just devnet-smoke withdraw
just devnet-smoke disburse
just smoke
just cabal-check
```
