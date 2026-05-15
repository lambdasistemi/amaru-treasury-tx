# Research: DevNet Swap Contract Readiness Slice

## R1. Ticket Boundary

**Decision**: Create #132 as a readiness prerequisite before #84.

**Rationale**: Issue #84 currently includes order build/funding. The
new work described here stops earlier: it registers or verifies the
order-validator reference artifacts and writes metadata that #84 can
consume. That keeps one vertical commit reviewable and prevents #84
from mixing contract publication with the order build proof.

**Alternatives considered**:

- Fold readiness into #84. Rejected because the first acceptance proof
  would not yet build/fund an order and would blur review semantics.
- Fold readiness into #85. Rejected because #85 consumes an already
  funded order; it is too late for build-readiness metadata.

## R2. Public SundaeSwap V3 Source

**Decision**: Use `SundaeSwap-finance/sundae-contracts` main as the
public source for the order validator, specifically the `order.spend`
entry in `plutus.json`. At planning time, upstream `main` resolves to
`be33466b7dbe0f8e6c0e0f46ff23737897f45835`.

**Rationale**: The upstream repository describes V3 as Aiken contracts
and lists `order.ak` as the current order contract. Its `plutus.json`
contains an `order.spend` compiled validator entry. This is the real
compatibility target requested by the user.

**Alternatives considered**:

- Use the existing mainnet `sundaeOrderScriptRefMainnet` constant as a
  local DevNet reference. Rejected because it points at mainnet state,
  not a local DevNet UTxO.
- Implement a minimal local validator. Rejected by the issue boundary;
  it would not prove SundaeSwap V3 compatibility.

## R3. Existing Repository State

**Decision**: Reuse existing constants and verification helpers, but add
the missing local order-validator artifact/reference readiness surface.

**Rationale**: The repository already pins mainnet Sundae order address,
script hash, and reference UTxO in `Amaru.Treasury.Constants`; tests
verify the address/hash alignment. The repo also has DevNet helpers for
publishing reference scripts. It does not currently embed the Sundae V3
order validator blob under `assets/plutus/`, and `scripts/smoke/devnet-local`
does not accept a `swap-ready` phase.

**Alternatives considered**:

- Extend `networkConstants "devnet"` immediately. Rejected for this
  readiness slice unless it is required by the artifact contract; #84
  is the better place to thread readiness into order building.
- Store readiness only in logs. Rejected because #84 needs a stable
  machine-readable handoff.

## R4. DevNet Publication Pattern

**Decision**: Publish the order validator as a reference script in the
DevNet harness using the same transaction-building pattern as existing
reference-script publication.

**Rationale**: `test/devnet/Amaru/Treasury/Devnet/SmokeSpec.hs` already
constructs reference-script outputs with `refScriptTxOut`, submits them
through `cardano-node-clients`, and waits for the resulting UTxOs. The
new readiness phase can follow that pattern without changing the
release-facing CLI.

**Alternatives considered**:

- Use `cardano-cli` for the setup transaction. Rejected because the
  current DevNet harness already uses library APIs for setup and
  evidence.
- Query only, with no local publication. Rejected unless the reference
  UTxO already exists on the fresh DevNet, which it does not.

## R5. Diagnostics

**Decision**: Failure artifacts should be typed JSON, matching the
withdrawal phase style.

**Rationale**: A readiness failure can mean missing public artifact,
wrong script hash, failed publication, wrong network, stale run
directory, or a fixture-only boundary. Typed diagnostics make those
states distinguishable before any later order-build slice consumes
bad data.

**Alternatives considered**:

- Shell-only stderr. Rejected because release evidence and #84 handoff
  need machine-readable failure context.
