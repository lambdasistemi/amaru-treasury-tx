# Feature Specification: registry-init fresh DevNet bootstrap mode

**Feature Branch**: `175-registry-bootstrap-mode`
**Created**: 2026-05-20
**Status**: Draft
**GitHub Issue**: [#175](https://github.com/lambdasistemi/amaru-treasury-tx/issues/175)
**Parent Issue**: [#156](https://github.com/lambdasistemi/amaru-treasury-tx/issues/156)
**Blocked Sibling**: [#161](https://github.com/lambdasistemi/amaru-treasury-tx/issues/161)

**Input**: #161 Slice 3 proved that a fresh DevNet cannot reach
`registry-init-wizard seed-split` through the shipped CLI. The current
runner verifies existing registry metadata before it emits the first
bootstrap intent, so a fresh chain fails with
`missing-shipped-registry-bootstrap`.

## User Scenarios & Testing

### User Story 1 - Fresh registry bootstrap intents (Priority: P1)

As a DevNet operator, I can run `registry-init-wizard` in an explicit
bootstrap mode on a fresh chain and produce the three registry-init
intent JSON files without requiring existing registry anchors.

**Independent Test**: Invoke the bootstrap resolver/tests with a mock
fresh-chain environment where registry verification would fail if
called. The bootstrap path still emits seed-split, mint, and
reference-scripts `SomeTreasuryIntent` JSON values that decode and build
through the existing `tx-build` translators.

**Acceptance Scenarios**:

1. **Given** a funded DevNet wallet and no registry anchors on chain,
   **When** the operator runs `amaru-treasury-tx --network devnet
   registry-init-wizard seed-split --bootstrap ...`, **Then** the
   command emits a `registry-init-seed-split` intent and does not call
   `verifyRegistry`.
2. **Given** the submitted seed-split TxIns and owner key hash, **When**
   the operator runs `registry-init-wizard mint --bootstrap ...`, **Then**
   the command emits a `registry-init-mint` intent without reading
   registry metadata from chain.
3. **Given** the submitted seed TxIns and funding seed UTxO, **When** the
   operator runs `registry-init-wizard reference-scripts --bootstrap ...`,
   **Then** the command emits a `registry-init-reference-scripts` intent
   without requiring registry metadata from chain.

### User Story 2 - Registry artifact handoff (Priority: P1)

As the #161 smoke runner, I can write the registry handoff artifact from
the real submitted tx ids and seed refs after the shipped CLI submits the
three registry-init transactions.

**Independent Test**: A unit test feeds deterministic submitted tx ids,
seed TxIns, owner key hash, and network magic into the shipped artifact
writer. It writes the same `registry.json` fields that later smoke phases
consume, with anchors derived from the submitted tx ids:
registry mint outputs `#0/#1`, reference-scripts outputs `#0/#1`.

**Acceptance Scenarios**:

1. **Given** seed-split, registry-mint, and reference-scripts tx ids from
   live submissions, **When** the operator runs the shipped artifact
   writer, **Then** it writes `registry-init/registry.json`,
   `registry-init/summary.json`, `registry-init/provenance.json`, and the
   top-level smoke summary paths needed by #161.
2. **Given** scopes and registry seed TxIns, **When** artifacts are
   written, **Then** the script hashes and policy ids are derived from the
   same `deriveDevnetScripts` function the registry-init builders use.
3. **Given** malformed tx ids, seed refs, owner key hash, or non-DevNet
   network input, **When** the artifact writer runs, **Then** it fails
   before writing partial artifacts.

### User Story 3 - Verified mode remains unchanged (Priority: P1)

As an operator using the existing post-deployment registry path, I can
keep running the default `registry-init-wizard` subcommands against an
already deployed registry, and they still verify metadata before writing
intents.

**Independent Test**: Existing #158 parser, network guard, round-trip,
and golden tests continue to pass. A focused source test proves
`verifyRegistry` remains on the default path and is absent from the new
bootstrap resolver path.

### User Story 4 - #161 can resume (Priority: P1)

As the epic orchestrator, I can rerun #161's `registry-stake` live smoke
after #175 lands and replace `missing-shipped-registry-bootstrap` with a
passing shipped-CLI registry bootstrap sequence.

**Independent Test**: #175 documents the command sequence and exposes the
CLI surface. The actual live end-to-end proof remains in #161, where the
smoke owns DevNet lifecycle, build/sign/submit, chain verification, and
phase summaries.

## Requirements

### Functional Requirements

- **FR-001**: The three existing `registry-init-wizard` subcommands MUST
  support an explicit bootstrap mode for DevNet, for example
  `--bootstrap`. Bootstrap mode MUST be opt-in.
- **FR-002**: Bootstrap mode MUST fail closed for non-DevNet networks
  before chain queries, metadata verification, or file writes.
- **FR-003**: Bootstrap mode MUST NOT call `verifyRegistry` before
  emitting seed-split, mint, or reference-scripts intents.
- **FR-004**: Bootstrap seed-split MUST select a funding wallet UTxO,
  sample/compute the validity upper bound, and emit one bare
  `registry-init-seed-split` intent.
- **FR-005**: Bootstrap mint MUST accept operator-supplied
  `--scopes-seed-txin`, `--registry-seed-txin`, and `--owner-key-hash`,
  then emit one bare `registry-init-mint` intent.
- **FR-006**: Bootstrap reference-scripts MUST accept operator-supplied
  `--scopes-seed-txin`, `--registry-seed-txin`, and
  `--funding-seed-txin`, then emit one bare
  `registry-init-reference-scripts` intent.
- **FR-007**: Bootstrap intents MUST remain consumable by the existing
  `tx-build --intent` registry-init translators and builders. No new
  transaction construction path is allowed in the wizard.
- **FR-008**: A shipped artifact writer MUST create registry-init
  artifacts from submitted tx ids, seed refs, owner key hash, network,
  network magic, and output/run directory.
- **FR-009**: The artifact writer MUST use real submitted tx ids for
  anchors and MUST NOT write placeholder anchors into runtime artifacts.
- **FR-010**: The existing verified/default mode MUST keep using
  `verifyRegistry` and remain compatible with #158 behavior.
- **FR-011**: #175 MUST NOT modify #161's smoke branch directly. It
  exposes the surface that #161 will consume after this PR lands.

### Non-Functional Requirements

- **NFR-001**: No mainnet or preprod semantics are introduced.
- **NFR-002**: No resumable state file, append-only register, state
  machine, typed bundle, or intent envelope is introduced. Those remain
  #163.
- **NFR-003**: No `amaru-treasury-tx devnet <...>` command is restored.
- **NFR-004**: The wizard still emits intents only. Build, witness,
  attach-witness, submit, and chain verification remain outside the
  wizard.
- **NFR-005**: `tx-build`, `IntentJSON`, and the registry-init build
  runners are reused, not forked.

## Success Criteria

- **SC-001**: Focused unit tests prove bootstrap resolver paths do not
  call `verifyRegistry` and still fail closed for non-DevNet networks.
- **SC-002**: Golden/round-trip coverage proves all three bootstrap
  intents decode and build through the existing registry-init path.
- **SC-003**: Artifact writer tests prove `registry.json` uses real tx-id
  derived anchors and derived script/policy fields.
- **SC-004**: Existing #158 tests continue to pass, proving verified mode
  was not regressed.
- **SC-005**: `./gate.sh` is green on every accepted behavior commit.

## Non-Goals

- Full #161 live smoke update. That happens on PR #171 after #175 lands.
- Mainnet/preprod registry bootstrap.
- Resumability or application state design.
- New transaction builders, direct signing, or direct submission in the
  wizard.
- Changing stake/reward, governance, disburse, or #163 scope.
