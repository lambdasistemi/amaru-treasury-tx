# Research: DevNet Registry Initiator

## Decision: Production module before CLI wrapper

**Decision**: Implement #147 as a production library entry point under
`lib/Amaru/Treasury/Devnet/RegistryInit.hs`, then call it from the
opt-in smoke phase.

**Rationale**: The acceptance criteria require production-backed code
callable by a CLI or thin smoke layer. A library entry point removes
transaction construction from `SmokeSpec.hs` immediately and can be
wrapped by a public command later without changing the DevNet proof.

**Alternatives considered**:

- Put a full public CLI command in #147. Rejected for this slice because
  the DevNet proof still relies on local bootstrap signing/submission
  and a broader operator UX would add option parsing and key handling
  before the production ownership problem is solved.
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
