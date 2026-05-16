# Feature Specification: DevNet Registry Initiator

**Feature Branch**: `147-devnet-registry-init`  
**Created**: 2026-05-16  
**Status**: Draft  
**GitHub Issue**: [#147](https://github.com/lambdasistemi/amaru-treasury-tx/issues/147)  
**Parent Issue**: [#151](https://github.com/lambdasistemi/amaru-treasury-tx/issues/151)  
**Input**: User description: "Move the DevNet registry/reference-script publication setup out of specs and into production-backed code that can be invoked by the CLI or by a thin smoke layer."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Publish Registry State From Production Code (Priority: P1)

As a release maintainer recovering the DevNet bootstrap path, I need a
production-backed initiator to publish the local DevNet scopes NFT,
registry NFT, permissions reference script, and treasury reference
script, so later DevNet slices can start from real on-chain registry
state without constructing those transactions inside `SmokeSpec.hs`.

**Why this priority**: Later withdrawal, governance-funding,
treasury-withdrawal, and disburse slices depend on the registry and
reference-script anchors. If those anchors are created by test-only
code, the DevNet proof does not demonstrate a reusable operator path.

**Independent Test**: Run the new registry-init DevNet phase and verify
that the smoke invokes the production initiator, submits the publication
transactions, and observes the expected UTxOs on the local DevNet.

**Acceptance Scenarios**:

1. **Given** a fresh short-epoch local DevNet with usable bootstrap
   ADA, **When** the registry initiator runs, **Then** it submits the
   seed split, registry NFT mint, and reference-script publication
   transactions through production-backed code.
2. **Given** the submitted transactions are accepted, **When** the smoke
   queries the local node, **Then** it observes scopes, registry,
   permissions, and treasury anchors at the expected script addresses.
3. **Given** the node rejects a publication transaction or the expected
   UTxOs never appear, **When** the initiator records the failure,
   **Then** it writes a typed diagnostic without success artifacts.

---

### User Story 2 - Emit Bootstrap Artifacts For Later Slices (Priority: P1)

As an operator or maintainer running the DevNet bootstrap sequence, I
need the registry initiator to emit structured artifacts containing
transaction ids, script references, policy ids, script hashes, owner
hashes, and treasury addresses, so the next child tickets can consume
the same state without rediscovering it from logs.

**Why this priority**: The parent recovery ticket requires every
operator-created bootstrap transaction to leave documented artifacts for
the following slice. The registry initiator is the first handoff.

**Independent Test**: Inspect the registry-init run directory after the
phase passes; the artifact JSON must include all anchor fields required
by withdraw and disburse registry views.

**Acceptance Scenarios**:

1. **Given** registry publication succeeds, **When** artifacts are
   written, **Then** they include submitted tx ids, anchor TxIns,
   registry policy id, permissions script hash, treasury script hash,
   treasury address, and owner key hash.
2. **Given** later DevNet phases need a registry view, **When** they
   consume the artifact projection, **Then** they do not reimplement
   registry datum/script construction in the smoke layer.
3. **Given** a stale run directory already contains registry artifacts,
   **When** a new run starts, **Then** stale success artifacts are
   removed or overwritten before the new result is reported.

---

### User Story 3 - Keep DevNet Smoke Thin (Priority: P2)

As a reviewer of the recovery work, I need the DevNet smoke code to be
an orchestration and verification layer only, so transaction
construction for operator-created bootstrap actions remains in
production modules or commands.

**Why this priority**: PR #145 showed that moving more bootstrap logic
into `test/devnet/Amaru/Treasury/Devnet/SmokeSpec.hs` makes the proof
unusable as an operator path.

**Independent Test**: Review the implementation diff; registry
publication builders and artifact projection live under `lib/`, while
`SmokeSpec.hs` calls the production entry point and verifies ledger
effects.

**Acceptance Scenarios**:

1. **Given** the implementation lands, **When** reviewers inspect
   `SmokeSpec.hs`, **Then** the file contains orchestration,
   diagnostics, and chain-effect assertions, not the registry
   transaction builders.
2. **Given** future child tickets #148, #149, and #150 need registry
   anchors, **When** they start, **Then** they can reuse the production
   artifact type or artifact JSON emitted by #147.
3. **Given** external-role work such as synthetic scooper execution is
   handled elsewhere, **When** the registry initiator is reviewed,
   **Then** it contains no swap execution, order spending, or other
   external-role transaction behavior.

### Edge Cases

- No pure ADA bootstrap UTxO is available for registry publication.
- The seed split transaction is accepted but one expected seed output is
  not observed before the wait budget expires.
- Registry NFT minting succeeds but one NFT is missing, duplicated, or
  present at the wrong script address.
- A reference-script publication transaction is accepted but the UTxO
  lacks the expected reference script.
- The derived policy id or script hash does not match the script placed
  on chain.
- The run is pointed at a non-DevNet network or a socket with the wrong
  network magic.
- A stale run directory contains success artifacts from a prior run.
- A downstream phase requests registry fields that the artifact contract
  did not preserve.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The system MUST provide a production-backed DevNet
  registry initiator callable by the opt-in DevNet smoke layer.
- **FR-002**: The initiator MUST publish scopes and registry NFT UTxOs
  using derived DevNet policy scripts.
- **FR-003**: The initiator MUST publish permissions and treasury
  reference-script UTxOs needed by later bootstrap slices.
- **FR-004**: The smoke layer MUST invoke the production-backed entry
  point instead of constructing registry publication transactions
  inline.
- **FR-005**: The smoke layer MUST verify that the expected registry and
  reference-script UTxOs exist on the local DevNet after submission.
- **FR-006**: The initiator MUST emit structured artifacts with tx ids,
  anchor TxIns, script refs/hashes, registry policy id, owner key hash,
  and treasury-related addresses.
- **FR-007**: The artifact projection MUST be sufficient to construct
  the registry views consumed by withdrawal and disburse DevNet slices.
- **FR-008**: Failure paths MUST use typed diagnostics and MUST NOT
  leave misleading success artifacts.
- **FR-009**: Documentation MUST explain how a maintainer runs the
  registry initiator and what artifacts it emits.
- **FR-010**: The initiator MUST NOT include external-role transaction
  behavior, synthetic scooper execution, swap order execution, or
  disburse action submission.
- **FR-011**: Release-facing treasury commands remain build-only unless
  a later reviewed ticket explicitly changes that boundary; local
  DevNet signing/submission remains scoped to bootstrap proof.

### Key Entities

- **Registry Init Run**: One local DevNet smoke execution with node
  socket, timing evidence, registry publication attempts, diagnostics,
  and artifacts.
- **Registry Publication**: The submitted seed split, NFT mint, and
  reference-script publication actions with their tx ids and resulting
  anchor TxIns.
- **DevNet Registry Artifact**: The JSON handoff containing policy ids,
  script hashes, TxIns, owner hash, treasury address, and provenance.
- **Registry Projection**: The in-memory registry view later phases use
  to build withdraw and disburse intents without reconstructing the
  registry publication transactions.
- **Registry Init Diagnostic**: A typed failure record identifying the
  failed phase, observed tx ids or UTxOs, and the missing or mismatched
  chain effect.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: `just devnet-smoke registry-init` either completes with
  registry artifacts or fails with a typed diagnostic within the
  configured wait budget.
- **SC-002**: On success, the run directory contains machine-readable
  artifacts with all required registry anchors and submitted tx ids.
- **SC-003**: On success, the smoke verifies scopes, registry,
  permissions, and treasury anchors from local node queries, not only
  from constructed values.
- **SC-004**: `SmokeSpec.hs` no longer owns the registry publication
  transaction construction; reusable builders and artifact projection
  live under production `lib/` modules.
- **SC-005**: README and local DevNet documentation describe the
  registry-init phase without claiming the staking, governance funding,
  treasury withdrawal, or disburse effects tracked by #148, #149, and
  #150.

## Assumptions

- Issue #147 is the first child of parent issue #151 and must be
  completed before #148 starts.
- The existing local DevNet harness may sign and submit bootstrap
  transactions for proof purposes; that does not broaden the
  release-facing build-only boundary for normal treasury commands.
- The current production-backed entry point can be a library module
  called by the thin smoke layer. A broader public CLI wrapper is a
  follow-up only if the operator UX needs command-line invocation
  outside the DevNet harness.
- The checked-in Amaru registry and treasury script constants remain
  the source for deriving DevNet scripts.
