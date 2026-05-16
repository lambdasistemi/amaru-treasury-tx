# Research: DevNet Governance And Withdrawal Setup

## Decision: Ship `devnet governance-withdrawal-init`

**Decision**: Add a nested DevNet command named
`governance-withdrawal-init`.

**Rationale**: The issue combines governance funding and treasury
withdrawal materialization into one setup initiator. The command name
keeps the operator story explicit and distinguishes this recovery
command from release-facing `withdraw-wizard` and `tx-build`, which
build normal unsigned treasury transactions.

**Alternatives considered**:

- Reuse `just devnet-smoke withdraw`: rejected because parent #151
  requires a shipped command, and smoke is proof only.
- Add separate `governance-init` and `withdrawal-init` commands:
  deferred because #149 acceptance asks for one initiator that reaches
  ADA locked at the treasury validator.

## Decision: Consume #147 and #148 artifacts

**Decision**: The command consumes `registry-init/registry.json` from
#147 and `stake-reward-init/accounts.json` from #148.

**Rationale**: #147 owns registry/reference-script publication. #148
owns treasury reward-account registration and permissions
withdraw-zero handoff. #149 must verify and continue from those
artifacts instead of recreating their state.

**Alternatives considered**:

- Re-derive registry and reward accounts from checked-in scripts only:
  rejected because it would bypass the child-ticket artifact handoff.
- Re-register the treasury credential inside governance setup:
  rejected because #148 already registered it and the parent sequence
  must remain meaningful.

## Decision: Keep DevNet submission as an explicit bootstrap exception

**Decision**: The command may sign and submit governance and withdrawal
transactions, but only after proving the global network is exactly
DevNet.

**Rationale**: The repository constitution normally keeps
release-facing commands build-only. Parent #151 is a narrow recovery of
operator-created local DevNet bootstrap transactions, so signing and
submission are allowed only at this DevNet command boundary.

**Alternatives considered**:

- Split build/sign/submit across existing public commands: rejected for
  this ticket because the acceptance criteria require an initiator that
  waits for ledger state and emits one coherent setup artifact set.
- Let the smoke sign/submit after command build: rejected because it
  would leave the operator path incomplete.

## Decision: Use production withdraw and tx-build paths

**Decision**: Withdrawal intent creation must use the production
withdraw resolver/translator, and transaction construction must use the
production tx-build path.

**Rationale**: The current smoke already proves `withdraw-wizard` and
`tx-build`, but it does so through smoke-local orchestration. Moving the
orchestration into a DevNet production module preserves the real build
path while removing transaction construction from `SmokeSpec.hs`.

**Alternatives considered**:

- Hand-write `intent.json` in the new DevNet module: rejected because it
  would duplicate the withdraw resolver contract.
- Hand-build the withdrawal tx in a DevNet-only module: rejected because
  it would skip the transaction builder that release-facing commands
  use.

## Decision: Record a #150 handoff artifact

**Decision**: Successful runs write a machine-readable materialization
artifact with treasury address, materialized TxIn, ADA value, registry
source, stake/reward source, and reward state history.

**Rationale**: #150 needs submitted disburse proof from a real treasury
UTxO. A handoff artifact prevents the next ticket from parsing stdout or
rediscovering chain state in smoke-only code.

**Alternatives considered**:

- Rely on `summary.log`: rejected because logs are not stable
  contracts.
- Let #150 query the chain from scratch: rejected because the child
  sequence should have explicit artifact boundaries.

## Decision: Add a new smoke phase and preserve compatibility deliberately

**Decision**: Add `governance-withdrawal-init` as the direct proof
phase. If the existing `withdraw` phase remains listed in README,
release docs, or `just devnet-smoke all`, it must call the same
production command runner or be removed from the documented passing
phase list.

**Rationale**: The new phase maps to the shipped command. Existing
documentation still names `withdraw`, so finalization must remove
terminology drift before the PR is marked ready.

**Alternatives considered**:

- Keep only `withdraw`: rejected because it hides the command that
  fulfills #149.
- Keep both with separate implementations: rejected because it would
  create two proof paths.
