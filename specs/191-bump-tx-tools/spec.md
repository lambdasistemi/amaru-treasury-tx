# Feature Specification: bump cardano-tx-tools reward-state validation

**Feature Branch**: `191-bump-tx-tools`  
**Created**: 2026-05-21  
**Status**: Draft  
**GitHub Issue**: [#191](https://github.com/lambdasistemi/amaru-treasury-tx/issues/191)  
**Parent Issue**: [#189](https://github.com/lambdasistemi/amaru-treasury-tx/issues/189)  
**Draft PR**: [#192](https://github.com/lambdasistemi/amaru-treasury-tx/pull/192)

**Input**: Bump the `cardano-tx-tools` source-repository-package pin
past the reward-state fix from upstream PR
[#62](https://github.com/lambdasistemi/cardano-tx-tools/pull/62),
then remove or reassess downstream Phase-1 validation skips that were
only present because the old validator could not seed reward-account
state. The target release is
[`v0.2.0.0`](https://github.com/lambdasistemi/cardano-tx-tools/releases/tag/v0.2.0.0),
published 2026-05-20T20:31:13Z and currently tagged at
`d53943d842b740b313b6b67c7784f4308e5847f0`; the required fix merged in
PR #62 at `6a7a7d424594e8d891dd2b7df5c4e9a7884e6779`.

## User Scenarios & Testing

### User Story 1 - Maintainer runs Phase-1 on withdrawal-bearing transactions (Priority: P1)

As an `amaru-treasury-tx` maintainer, I need the final Phase-1
pre-flight to run for every built treasury transaction, including
transactions with withdrawals, without reporting false
reward-account-state failures from the old validation context.

**Why this priority**: This is the ticket's primary unblocker for
reorganize work under #189. The skipped validation path hid structural
Phase-1 failures on withdrawal-bearing transactions.

**Independent Test**: A focused regression test proves that a
withdrawal-bearing transaction reaches the final Phase-1 validation path
and passes when the validation context has the reward-account support
provided by the bumped dependency.

**Acceptance Scenarios**:

1. **Given** the dependency pin is still before PR #62, **When** a
   withdrawal-bearing final transaction is validated, **Then** the old
   reward-state false failure is reproducible or the stale hash/build
   prevents the bump from being accepted.
2. **Given** the dependency pin is at or past PR #62, **When** the same
   class of transaction is validated, **Then** the final Phase-1
   pre-flight runs and returns success when only witness-completeness
   noise remains.
3. **Given** a final treasury transaction has no withdrawals, **When**
   the maintainer runs the existing unit and golden suites, **Then** its
   validation behavior remains unchanged.

### User Story 2 - Dependency pin is reproducible (Priority: P1)

As a maintainer reviewing the branch, I need the `cardano-tx-tools` pin
and its fixed-output hash to be updated together so the Nix and Cabal
builds fetch the same audited upstream revision on every machine.

**Why this priority**: A tag bump without the matching hash either fails
the build or makes the dependency update non-reproducible.

**Independent Test**: `nix flake check` and `./gate.sh` both run from a
clean checkout with the new pin and hash.

**Acceptance Scenarios**:

1. **Given** the branch is checked out from scratch, **When** Nix fetches
   `cardano-tx-tools`, **Then** the fetched revision is at or past PR
   #62 and the fixed-output hash matches.
2. **Given** the branch is checked out from scratch, **When** Cabal
   resolves source-repository packages, **Then** it uses the same
   `cardano-tx-tools` revision as Nix.

### User Story 3 - Governance withdrawal init skip is explicitly resolved (Priority: P1)

As a maintainer of the DevNet bootstrap path, I need the
governance-withdrawal-init Phase-1 skip to be removed if the bumped
validator can now validate the existing fixtures, or retained with a
precise residual-rule explanation if a separate upstream gap remains.

**Why this priority**: The ticket must not leave a vague or stale skip
behind. Either the workaround is gone, or the remaining reason is tied
to a concrete ledger rule and follow-up.

**Independent Test**: Existing governance-withdrawal-init fixtures are
run through the bumped final Phase-1 validation path.

**Acceptance Scenarios**:

1. **Given** the existing governance-withdrawal-init fixtures pass final
   Phase-1 validation after the bump, **When** the maintainer reviews
   the branch, **Then** the skip helper and call site are removed and the
   normal materialization path is used.
2. **Given** any governance-withdrawal-init fixture still fails final
   Phase-1 validation after the bump, **When** the maintainer reviews
   the branch, **Then** the skip remains only for that residual rule, the
   comment names the failing ledger rule, and the upstream tracking issue
   is linked.
3. **Given** the residual failure would require files outside #191's
   owned scope, **When** it is discovered, **Then** implementation stops
   for parent-owner clarification before editing outside the boundary.

### Edge Cases

- The target upstream tag exists but resolves to a revision before PR
  #62; the bump must be rejected.
- The dependency bump compiles but changes APIs outside the expected
  validation surface; implementation stops for clarification before
  touching unrelated modules.
- The fixed-output hash is regenerated for the wrong commit; the Nix
  fetch must fail rather than silently accepting a different source.
- Governance-withdrawal-init proposal validation may still require
  reward-account or deposit state that is not present in the offline
  context; the retained skip, if any, must name the specific residual
  rule.
- Existing `ccEvaluateTx` execution-unit checks in other builders remain
  in place and are not treated as substitutes for final Phase-1
  validation.

## Requirements

### Functional Requirements

- **FR-001**: The project MUST pin `cardano-tx-tools` to a revision at
  or past upstream PR #62's merge commit
  `6a7a7d424594e8d891dd2b7df5c4e9a7884e6779`; the preferred target is
  tag `v0.2.0.0`.
- **FR-002**: The fixed-output hash associated with the
  `cardano-tx-tools` source-repository-package MUST be regenerated for
  the selected revision and committed with the pin.
- **FR-003**: Final Phase-1 validation MUST no longer skip transactions
  solely because the transaction body contains withdrawals.
- **FR-004**: The final Phase-1 validation helper MUST still accept
  unsigned-transaction witness-completeness failures as signing-step
  noise while rejecting structural ledger failures.
- **FR-005**: A regression test MUST prove a withdrawal-bearing final
  transaction reaches the final Phase-1 validation path and succeeds
  with the bumped dependency.
- **FR-006**: Governance-withdrawal-init fixtures MUST be reassessed
  against the bumped final Phase-1 validation path.
- **FR-007**: If governance-withdrawal-init fixtures pass, the
  governance-specific Phase-1 skip MUST be removed and the normal
  materialization path used.
- **FR-008**: If any governance-withdrawal-init fixture still fails,
  the retained skip MUST name the concrete residual ledger rule and
  link the upstream tracking issue before implementation proceeds.
- **FR-009**: The PR description MUST name the selected upstream SHA,
  version delta, and final disposition of each downstream workaround.
- **FR-010**: The branch-local `./gate.sh` MUST be the local pre-push
  gate for every accepted slice; `nix flake check` remains the parallel
  CI proof for the dependency bump.

### Key Entities

- **Dependency Pin**: The selected `cardano-tx-tools` git revision and
  matching fixed-output hash consumed by Cabal and Nix.
- **Final Phase-1 Validation**: The maintainer-visible pre-flight that
  runs on final unsigned treasury transactions and filters only
  witness-completeness noise.
- **Governance Withdrawal Init Disposition**: The explicit result of
  retesting the governance-withdrawal-init path after the dependency
  bump: skip removed, or skip retained for a named residual ledger rule.

## Deliverables

- `cabal.project` pin update for
  [`cardano-tx-tools`](https://github.com/lambdasistemi/cardano-tx-tools)
  plus the regenerated fixed-output hash.
- Final Phase-1 validation behavior that covers withdrawal-bearing
  transactions instead of skipping them.
- Governance-withdrawal-init Phase-1 skip disposition: removed if the
  bumped validator passes existing fixtures, or retained with a precise
  residual-rule comment and follow-up link.
- Focused regression proof for the withdrawal-bearing validation path,
  plus existing unit/golden/gate evidence.
- PR metadata naming the upstream version delta and workaround
  disposition.

No new executable, flag surface, release asset, package, or operator
documentation surface is introduced by this ticket. Existing release and
CI surfaces continue to consume the same project package after the
dependency bump.

## Success Criteria

- **SC-001**: The selected `cardano-tx-tools` revision is verifiably at
  or past PR #62 and the fixed-output hash matches that revision.
- **SC-002**: A focused regression test fails before the withdrawal skip
  is removed and passes after final Phase-1 validation runs on the
  withdrawal-bearing transaction.
- **SC-003**: Existing governance-withdrawal-init fixtures either pass
  normal final Phase-1 validation or produce a documented residual-rule
  finding tied to an upstream issue.
- **SC-004**: `./gate.sh` passes at each accepted slice commit.
- **SC-005**: `nix flake check` passes after the dependency bump.

## Assumptions

- `v0.2.0.0` remains the intended target unless planning discovers a
  conflicting release-note or API reason to choose a newer commit.
- Existing fixtures are sufficient to reassess
  governance-withdrawal-init unless the investigation proves a narrow
  additional fixture is required.
- No operator live-chain smoke is required for this ticket unless local
  or CI validation exposes a boundary that unit/golden tests cannot
  cover.
- Sibling #185 remains parked until #191 merges, so this branch must not
  edit reorganize implementation files.

## Non-Goals

- Removing or weakening `ccEvaluateTx` execution-unit checks in other
  builders.
- Bumping any dependency other than `cardano-tx-tools`.
- Editing reorganize modules or creating new reorganize modules.
- Reworking transaction builders outside the validation-skip paths
  covered by this ticket.
- Modifying existing fixtures except for assertion changes directly tied
  to Phase-1 success.
- Running mainnet or preprod operator workflows.
