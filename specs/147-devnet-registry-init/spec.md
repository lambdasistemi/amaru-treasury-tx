# Feature Specification: DevNet Registry Initiator

**Feature Branch**: `147-devnet-registry-init`  
**Created**: 2026-05-16  
**Status**: Draft  
**GitHub Issue**: [#147](https://github.com/lambdasistemi/amaru-treasury-tx/issues/147)  
**Parent Issue**: [#151](https://github.com/lambdasistemi/amaru-treasury-tx/issues/151)  
**Input**: User description: "Move the DevNet registry/reference-script publication setup out of specs and into production-backed code that can be invoked by the CLI or by a thin smoke layer." Parent issue #151 requires the operator-created bootstrap transactions to be recovered as production commands, so the CLI command surface is required for #147.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Publish Registry State From Production Code (Priority: P1)

As a release maintainer recovering the DevNet bootstrap path, I need a
shipped `amaru-treasury-tx` DevNet command to publish the local DevNet
scopes NFT, registry NFT, permissions reference script, and treasury
reference script through production-backed code, so later DevNet slices
can start from real on-chain registry state without constructing those
transactions inside `SmokeSpec.hs`.

**Why this priority**: Parent issue #151 is command recovery. Later
withdrawal, governance-funding, treasury-withdrawal, and disburse
slices depend on the registry and reference-script anchors. If those
anchors are created only by test-only code or by an unshipped smoke
harness, the DevNet proof does not demonstrate a reusable operator path.

**Independent Test**: Run the shipped `amaru-treasury-tx` DevNet
registry-init command against a local DevNet and verify that it invokes
the production initiator, submits the publication transactions, emits
the structured artifacts, and observes the expected UTxOs on the local
DevNet. The `just devnet-smoke registry-init` phase remains the live
proof harness, but it is not the only acceptable command surface.

**Acceptance Scenarios**:

1. **Given** a fresh short-epoch local DevNet with usable bootstrap
   ADA, **When** an operator runs the shipped DevNet registry-init
   command with an explicit socket, funding address, signing source,
   and run directory, **Then** it submits the seed split, registry NFT
   mint, and reference-script publication transactions through
   production-backed code.
2. **Given** the submitted transactions are accepted, **When** the smoke
   or command runner queries the local node, **Then** it observes scopes,
   registry, permissions, and treasury anchors at the expected script
   addresses.
3. **Given** the node rejects a publication transaction or the expected
   UTxOs never appear, **When** the initiator records the failure,
   **Then** it writes a typed diagnostic without success artifacts.
4. **Given** the command is invoked for a non-DevNet network or without
   required signing/funding inputs, **When** argument validation runs,
   **Then** it fails before submission and does not write success
   artifacts.

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
- The CLI command is run without an explicit funding address, signing
  source, or run directory.
- A stale run directory contains success artifacts from a prior run.
- A downstream phase requests registry fields that the artifact contract
  did not preserve.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The system MUST provide a shipped `amaru-treasury-tx`
  DevNet registry-init command. A smoke-only command is not sufficient
  for #147 under parent #151.
- **FR-002**: The initiator MUST publish scopes and registry NFT UTxOs
  using derived DevNet policy scripts.
- **FR-003**: The initiator MUST publish permissions and treasury
  reference-script UTxOs needed by later bootstrap slices.
- **FR-004**: The CLI command and smoke layer MUST invoke the
  production-backed entry point instead of constructing registry
  publication transactions inline.
- **FR-005**: The smoke layer MUST verify that the expected registry and
  reference-script UTxOs exist on the local DevNet after submission.
- **FR-006**: The initiator MUST emit structured artifacts with tx ids,
  anchor TxIns, script refs/hashes, registry policy id, owner key hash,
  and treasury-related addresses.
- **FR-007**: The artifact projection MUST be sufficient to construct
  the registry views consumed by withdrawal and disburse DevNet slices.
- **FR-008**: Failure paths MUST use typed diagnostics and MUST NOT
  leave misleading success artifacts.
- **FR-009**: Documentation MUST explain how a maintainer runs both the
  shipped DevNet registry-init CLI command and the live smoke proof, and
  what artifacts they emit.
- **FR-010**: The initiator MUST NOT include external-role transaction
  behavior, synthetic scooper execution, swap order execution, or
  disburse action submission.
- **FR-011**: Normal release-facing treasury build commands remain
  build-only; the registry-init command is an explicit reviewed DevNet
  bootstrap exception and MUST reject non-DevNet networks before signing
  or submitting.
- **FR-012**: The command MUST require explicit operator inputs for the
  live node socket, funding address, signing source, and run directory,
  and MUST write the same registry-init artifact contract as the smoke
  proof.

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

- **SC-001**: The shipped `amaru-treasury-tx` DevNet registry-init
  command either completes with registry artifacts or fails with a typed
  diagnostic within the configured wait budget.
- **SC-002**: On success, the run directory contains machine-readable
  artifacts with all required registry anchors and submitted tx ids.
- **SC-003**: On success, the smoke verifies scopes, registry,
  permissions, and treasury anchors from local node queries, not only
  from constructed values.
- **SC-004**: `SmokeSpec.hs` no longer owns the registry publication
  transaction construction; reusable builders and artifact projection
  live under production `lib/` modules.
- **SC-005**: README and local DevNet documentation describe the
  registry-init command and proof phase without claiming the staking,
  governance funding, treasury withdrawal, or disburse effects tracked
  by #148, #149, and #150.
- **SC-006**: `just devnet-smoke registry-init` remains green and proves
  the same production command path on a live local DevNet.

## Assumptions

- Issue #147 is the first child of parent issue #151 and must be
  completed before #148 starts.
- The shipped registry-init command is a DevNet-only bootstrap command.
  It does not broaden the build-only boundary for normal mainnet,
  preprod, or preview treasury transaction builders.
- The command should remain a thin wrapper around the production
  registry-init module; it must not recreate transaction construction in
  CLI or smoke code.
- The checked-in Amaru registry and treasury script constants remain
  the source for deriving DevNet scripts.
