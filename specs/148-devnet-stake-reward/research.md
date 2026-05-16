# Research: DevNet Stake And Reward Setup

## Decision 1: Ship A DevNet Setup Command

**Decision**: Expose the #148 setup as a shipped
`amaru-treasury-tx devnet stake-reward-init` command.

**Rationale**: Parent #151 requires operator-created bootstrap
transactions to be available as production commands. `just devnet-smoke`
is evidence, not the command surface.

**Alternatives considered**:

- Smoke-only setup: rejected because it repeats the #147 command gap.
- A generic public-network command: rejected because this is a reviewed
  DevNet bootstrap exception and must reject non-DevNet networks.

## Decision 2: Build On #147 Registry Artifacts

**Decision**: The setup command consumes the registry-init artifact or
production projection from #147 to identify treasury and permissions
script hashes.

**Rationale**: #148 is ordered after #147. Re-deriving unrelated
registry state in the setup command would duplicate the prior slice and
make later child tickets ambiguous.

**Alternatives considered**:

- Hardcode hashes inside the command: rejected because the registry
  artifact is the handoff contract.
- Query everything from logs: rejected because logs are not a stable
  machine-readable interface.

## Decision 3: Prepare Both Treasury And Permissions Reward Accounts

**Decision**: The setup prepares the treasury script reward account and
the permissions script reward account.

**Rationale**: #149 needs the treasury reward account for governance
funding and withdrawal materialization. #150 needs the permissions
reward account for the zero-withdrawal witness path.

**Alternatives considered**:

- Treasury account only: rejected because PR #145 exposed the
  permissions zero-withdrawal boundary.
- Permissions account only: rejected because #149 must fund and
  materialize treasury rewards next.

## Decision 4: Fix Disburse Reward Account Parsing In This Slice

**Decision**: Make disburse permissions reward-account parsing use the
intent network, matching the existing withdraw parser behavior.

**Rationale**: A prepared DevNet account is not usable if the disburse
translator constructs `AccountAddress Mainnet`. Issue #32 already
records the underlying bug class.

**Alternatives considered**:

- Defer parser fix to #150: rejected because #148's acceptance criteria
  include permissions reward-account handling on DevNet.
- Patch only smoke inputs: rejected because the bug is in production
  translation.

## Decision 5: Keep Governance Funding Out Of #148

**Decision**: #148 stops after reward-account setup. Governance funding
and treasury withdrawal materialization remain #149.

**Rationale**: Parent #151 orders #149 as the governance funding and
treasury withdrawal setup child. Mixing it into #148 would make the
next child ticket meaningless and broaden review scope.

**Alternatives considered**:

- Reuse the existing `submitTreasuryWithdrawal` smoke path wholesale:
  rejected because it mixes account setup with governance funding.

## Decision 6: Smoke Composes, Production Owns Construction

**Decision**: The smoke phase may start a fresh DevNet and run
registry-init as a prerequisite, but stake/reward setup transaction
construction lives in production code and is invoked through the same
command runner.

**Rationale**: This preserves the thin-smoke invariant and gives later
child tickets stable artifacts.

**Alternatives considered**:

- Move setup builders into `SmokeSpec.hs`: rejected because PR #145
  already demonstrated that path is not reusable as operator recovery.
