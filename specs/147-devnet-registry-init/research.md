# Research: DevNet Registry Initiator

## Decision: Production module plus shipped CLI command

**Decision**: Implement #147 as a production library entry point under
`lib/Amaru/Treasury/Devnet/RegistryInit.hs`, expose it through a
shipped `amaru-treasury-tx` DevNet registry-init command, then prove the
same command path from the opt-in smoke phase.

**Rationale**: Issue #147 says the code may be invoked by the CLI or a
thin smoke layer, but parent #151 is explicitly command recovery for
operator-created bootstrap transactions. A library entry point removes
transaction construction from `SmokeSpec.hs`; the shipped command is the
operator path required by the parent ticket.

**Alternatives considered**:

- Put only a smoke phase in #147. Rejected after orchestration review:
  it proves production-backed code exists, but it does not satisfy the
  command-recovery user story in #151.
- Put the command in a broad operator UX redesign. Rejected because #147
  only needs a narrow DevNet bootstrap command that wraps the production
  module and preserves the existing build-only boundary for normal
  treasury transaction builders.
- Keep helpers in `test/devnet`. Rejected because it repeats the PR #145
  failure mode.

## Decision: Artifact JSON is the handoff contract

**Decision**: Write a stable `registry-init/registry.json` plus
`registry-init/summary.json` containing anchors, tx ids, script hashes,
policy ids, owner key hash, treasury address, and provenance.

**Rationale**: Later child tickets need a clear handoff. JSON artifacts
are already how the DevNet smoke records withdrawal and swap-readiness
state.

**Alternatives considered**:

- Require later phases to re-query and reconstruct everything. Rejected
  because it hides handoff assumptions and risks rebuilding transaction
  construction in the smoke layer.
- Only print values to stdout. Rejected because stdout is not durable
  enough for later run-directory evidence.

## Decision: Live node proof remains opt-in

**Decision**: Keep live registry-init proof under
`just devnet-smoke registry-init`; keep default `just ci` free of local
node startup.

**Rationale**: The existing project pattern keeps DevNet checks manual
and opt-in. The required proof is chain-effect evidence, so the live
phase must be run before final #147 handoff even though it is not part
of default CI.

**Alternatives considered**:

- Add DevNet startup to `just ci`. Rejected because existing CI is
  deterministic and should not depend on a live local node harness.

## Decision: No external-role behavior in registry-init

**Decision**: The registry initiator publishes only registry/scopes NFT
state and permissions/treasury reference scripts.

**Rationale**: Parent issue #151 explicitly separates later bootstrap
transactions and external-role behavior. Keeping #147 narrow preserves
the child-ticket sequence.

**Alternatives considered**:

- Fold staking, governance funding, withdrawal materialization, or
  disburse setup into this PR. Rejected because those are #148, #149,
  and #150.
