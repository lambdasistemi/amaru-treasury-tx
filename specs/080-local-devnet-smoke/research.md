# Research: DevNet Governance Action Slice

## Decision 1: Use `cardano-node-clients:devnet`

**Decision**: Build the local smoke around the public
`cardano-node-clients:devnet` sublibrary pinned in `cabal.project`.
Use the existing DevNet helpers instead of recreating node process
management.

**Rationale**: The dependency already provides the approved local
network, genesis assets, network magic, and N2C readiness helpers.

**Alternatives considered**:

- Custom node launcher: rejected because it duplicates the dependency
  boundary selected for this experiment.
- `cardano-testnet`: rejected because the user explicitly selected
  the `cardano-node-clients` DevNet.

## Decision 2: Keep `devnet` As A Local-Only Network Alias

**Decision**: Keep `devnet` as the documented local network name. It
maps to network magic `42` and ledger testnet semantics.

**Rationale**: Governance, withdrawal, and swap artifacts need a stable
network identity that does not pretend to be preview or preprod.

**Alternatives considered**:

- Pass only a raw network magic: rejected because intent and report
  artifacts still need a named network.
- Reuse `preview`: rejected because it would make diagnostics
  misleading.

## Decision 3: Governance Comes Before Withdrawal

**Decision**: The first DevNet experiment slice is governance action
submission, not withdrawal.

**Rationale**: Amaru withdrawal consumes a script reward account.
Positive delegated key rewards do not prove that path. The local chain
must first fund the script reward account through a treasury-withdrawal
governance action.

**Alternatives considered**:

- Start with `withdraw`: rejected because it would either observe zero
  rewards or prove the wrong key-backed reward path.
- Start with swap: rejected because it does not answer how treasury
  reward state is provided.

## Decision 4: Match The Original Script Credential Setup

**Decision**: The DevNet setup must register the treasury script stake
credential with vote delegation to always-abstain, matching the
original Amaru registration recipe.

**Rationale**: The original repository uses
`registration-and-vote-delegation-certificate --always-abstain` for
the treasury scripts. A plain registration certificate is not faithful
to the production setup.

**Alternatives considered**:

- Plain stake registration: rejected because it diverges from the
  original treasury setup.
- Key-backed stake registration: rejected because the withdrawal path
  uses script credentials.

## Decision 5: Push Missing Governance Capabilities Upstream

**Decision**: Required Conway certificate, proposal, and query support
belongs in `cardano-node-clients`, not in permanent Amaru shell-outs.

**Rationale**: The DevNet experiment should exercise the same library
boundary the Haskell tool depends on. Permanent `cardano-cli` assembly
would hide missing API support and make tomorrow's withdrawal slice
fragile.

**Upstream references**:

- lambdasistemi/cardano-node-clients#130: Conway stake certificates and
  treasury-withdrawal proposals.
- lambdasistemi/cardano-node-clients#131: node queries needed by local
  DevNet smoke tests.

## Decision 6: Keep DevNet Setup Separate From Release CLI Behavior

**Decision**: Any local signing/submission required to seed DevNet
state stays inside the smoke harness.

**Rationale**: `amaru-treasury-tx` remains a build-only release tool
that emits unsigned transactions. The DevNet harness can submit setup
transactions because it is a test environment, not operator-facing
behavior.

## Decision 7: Split Follow-Up DevNet Work Into Separate Tickets

**Decision**: Track the experiment as six DevNet slices:

- #82 governance action
- #83 withdrawal
- #86 disburse
- #84 SundaeSwap V3 order build/funding
- #85 SundaeSwap V3 order spend
- #87 reorganize

**Rationale**: Each slice has a distinct boundary and may require its
own upstream support. Keeping them separate gives tomorrow a clear
first target and avoids turning the smoke branch into a large mixed
transaction experiment.
