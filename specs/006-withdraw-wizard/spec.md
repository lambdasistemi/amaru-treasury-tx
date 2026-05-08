# Feature Specification: Withdraw Wizard

**Feature Branch**: `006-withdraw-wizard`
**Created**: 2026-05-07
**Status**: Draft
**Input**: User description: "Implement the next transaction intent/builder
up to the Speckit tasks only; do not implement code."

Tracking issue: [#45](https://github.com/lambdasistemi/amaru-treasury-tx/issues/45).

This feature mirrors the `swap-wizard | tx-build` shape for treasury
reward withdrawals. The release-facing path is:

```bash
amaru-treasury-tx withdraw-wizard ... | amaru-treasury-tx tx-build
```

There is no per-action `withdraw` builder command. `withdraw-wizard`
emits a unified `TreasuryIntent 'Withdraw` (`schema = 1`,
`action = "withdraw"`); `tx-build` consumes that intent and dispatches
to the withdraw builder.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Build a withdraw intent from a guided command (Priority: P1)

A scope operator wants to sweep accumulated rewards from a treasury
reward account back into that scope's treasury contract. The operator
should provide the wallet address, scope, metadata file, network, and
validity window; the wizard should resolve the treasury reward account,
treasury contract address, deployed treasury script reference, registry
reference, current rewards balance, and upper validity slot.

**Why this priority**: This is the user-facing value of the feature.
Without a wizard-produced `intent.json`, `tx-build` cannot safely build
withdraw transactions under the unified intent contract.

**Independent Test**: Run `withdraw-wizard` against a controlled fixture
or stubbed provider with a positive rewards balance. The emitted JSON
must validate against the generated intent schema, decode as
`TreasuryIntent 'Withdraw`, and translate to a typed `WithdrawIntent`
whose reward account, reward amount, references, wallet input, treasury
address, and validity slot match the resolved state.

**Acceptance Scenarios**:

1. **Given** a connected provider, verified registry metadata, a wallet
   with a usable fuel UTxO, and a treasury reward account with positive
   rewards, **When** the operator runs `withdraw-wizard`, **Then** the
   wizard writes one unified `intent.json` document and no CBOR.
2. **Given** the same intent, **When** the operator passes it to
   `tx-build`, **Then** `tx-build` produces unsigned Conway CBOR for a
   transaction that withdraws the rewards and pays them to the treasury
   contract address.

---

### User Story 2 - Fail closed when rewards are zero (Priority: P1)

An operator may run the withdrawal command before rewards have accrued.
The tool must report that there is nothing to withdraw without
producing an intent that later builders might mistake for a real
payment.

**Why this priority**: Mainnet treasury reward accounts currently read
zero in the issue context, and false-positive transaction artifacts
would be operationally dangerous.

**Independent Test**: Run `withdraw-wizard` against a fixture or stubbed
provider returning a zero reward balance for the selected scope. The
command must exit 0 with a typed "nothing to withdraw" trace event and
must not write JSON.

**Acceptance Scenarios**:

1. **Given** a selected scope whose treasury reward account has zero
   rewards, **When** `withdraw-wizard` runs, **Then** it exits 0, emits
   a clear trace message, and writes no `intent.json`.
2. **Given** `--out intent.json` was provided, **When** the reward
   balance is zero, **Then** the target file is not created or modified.

---

### User Story 3 - Reproduce a withdraw body from a frozen fixture (Priority: P1)

Developers need evidence that the Haskell builder creates the intended
withdraw transaction, even before a live preprod reward balance is
available. A synthetic frozen fixture should pin all chain context and
the intended reward amount so the builder path can be tested offline.

**Why this priority**: Constitution V requires golden CBOR fixtures for
every supported action. The real on-chain golden is blocked by
reward accrual; the synthetic golden is the MVP evidence until issue
[#17](https://github.com/lambdasistemi/amaru-treasury-tx/issues/17)
can record a live preprod oracle.

**Independent Test**: Run the golden suite for the withdraw fixture.
It must decode the unified withdraw intent, build with a frozen
`ChainContext`, and compare the resulting CBOR to a checked-in
synthetic oracle.

**Acceptance Scenarios**:

1. **Given** a committed frozen fixture with a positive synthetic
   `rewardsLovelace`, **When** the withdraw golden runs, **Then** it
   rebuilds the expected CBOR byte-for-byte.
2. **Given** the fixture's expected CBOR changes, **When** the golden
   runs without an explicit update flag, **Then** it fails and reports
   the byte mismatch.

---

### User Story 4 - Validate the machine-readable intent contract (Priority: P2)

Operators and downstream tools need a published JSON Schema that
accepts valid withdraw intents and rejects action/payload mismatches.

**Why this priority**: `tx-build` is the public boundary. Schema drift
between wizard output, fixtures, and parser code would make archived
intents unreliable.

**Independent Test**: Validate the generated schema against the
withdraw fixture intent and against fresh JSON emitted by the
withdraw wizard translation. Mutate action/payload fields and confirm
the schema rejects them.

**Acceptance Scenarios**:

1. **Given** a valid withdraw intent, **When** it is checked against
   `docs/assets/intent-schema.json`, **Then** validation succeeds.
2. **Given** `action = "withdraw"` with a `swap`, `disburse`, or
   `reorganize` payload block, **When** schema validation runs,
   **Then** validation fails.

---

### User Story 5 - Preserve the operator pipe contract (Priority: P2)

The wizard and builder must compose in the same way as swap and
disburse: wizard JSON on stdout, traces on stderr or `--log`, builder
CBOR on stdout or `--out`.

**Why this priority**: The command surface should remain uniform across
treasury actions, and traces must never contaminate pipe payloads.

**Independent Test**: Run `withdraw-wizard ... | tx-build --out
withdraw.cbor.hex` against a fixture or live provider with positive
rewards. Verify stdout/stderr behavior and output files.

**Acceptance Scenarios**:

1. **Given** a positive rewards fixture, **When** the operator pipes
   `withdraw-wizard` into `tx-build`, **Then** the final output is one
   hex-encoded unsigned CBOR transaction.
2. **Given** `--log` is supplied on both commands, **When** the pipe
   succeeds, **Then** trace lines are written only to those log files.

### Edge Cases

- Reward balance is zero: exit 0, no intent file, clear trace.
- Reward query returns no row or malformed data: non-zero setup error,
  no intent file.
- Wallet has no pure ADA fuel/collateral UTxO: non-zero setup error,
  no intent file.
- Metadata and on-chain registry disagree: registry verification fails
  before the intent is emitted.
- Network magic reported by the socket differs from the intent network:
  `tx-build` exits 6 before any chain query.
- Reward-account parsing must respect the selected network; preprod
  fixtures must not be parsed as mainnet reward accounts.
- The upstream bash script currently passes `--withdrawal <stake>+0`
  while the existing pure builder carries the positive reward amount.
  The feature must record the chosen parity rule before implementation.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: `withdraw-wizard` MUST produce a unified
  `TreasuryIntent 'Withdraw` JSON document with `schema = 1` and
  `action = "withdraw"` when rewards are positive.
- **FR-002**: `withdraw-wizard` MUST resolve the treasury reward
  account from the selected scope's treasury script hash and selected
  network; operators MUST NOT type the reward account manually.
- **FR-003**: `withdraw-wizard` MUST query the selected treasury reward
  account balance and include the resolved positive amount in the
  withdraw payload.
- **FR-004**: If the reward balance is zero, `withdraw-wizard` MUST
  exit successfully without writing an intent.
- **FR-005**: The withdraw intent MUST carry the wallet fuel UTxO,
  treasury address, treasury script reference, registry reference,
  validity upper bound, network, and rationale fields needed by
  `tx-build`.
- **FR-006**: `tx-build` MUST accept `action = "withdraw"` and dispatch
  to the withdraw builder instead of the current fail-closed stub.
- **FR-007**: The withdraw builder MUST produce an unsigned Conway
  transaction that spends wallet fuel/collateral, references the
  deployed treasury and registry scripts, withdraws from the treasury
  reward account, pays the reward amount to the treasury contract
  address, attaches rationale metadata, and sets the validity bound.
- **FR-008**: The generated JSON Schema MUST define a non-empty
  withdraw payload and reject action/payload mismatches.
- **FR-009**: The feature MUST ship a synthetic frozen withdraw golden
  until a live preprod reward oracle is available under issue #17.
- **FR-010**: `withdraw-wizard` traces MUST go to stderr by default or
  `--log` when provided; stdout MUST contain only JSON when an intent is
  emitted.
- **FR-011**: All new failures MUST be typed and rendered as a single
  human-readable line suitable for operator logs.

### Key Entities

- **WithdrawAnswers**: Operator-provided inputs: wallet address, scope,
  validity hours, rationale overrides, output/log paths, and metadata
  path.
- **WithdrawEnv**: Resolved state: network, registry/scope view, wallet
  fuel selection, reward account, rewards lovelace, current tip, and
  deployed references.
- **WithdrawInputs**: The action payload inside the unified intent:
  reward account identifier and reward amount.
- **WithdrawIntent**: Ledger-level typed intent consumed by the pure
  builder after JSON translation.
- **WithdrawFixture**: Frozen context used by the golden test:
  intent, UTxOs, protocol parameters, synthetic reward balance, ExUnits,
  expected CBOR, and provenance notes.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A valid withdraw fixture intent decodes, translates, and
  validates against `docs/assets/intent-schema.json` with zero schema
  errors.
- **SC-002**: The withdraw golden rebuilds the synthetic oracle CBOR
  byte-for-byte from committed fixtures with no live node dependency.
- **SC-003**: A zero-rewards wizard run writes no JSON and exits 0 in
  under 10 seconds on the standard operator workstation.
- **SC-004**: `withdraw-wizard --help` and `tx-build --help` both
  complete in under 10 seconds in the release smoke path.
- **SC-005**: A network mismatch between intent and socket exits 6
  before UTxO or reward queries are made.

## Assumptions

- The feature follows the current unified `TreasuryIntent` schema rather
  than the older issue text that named a per-action `withdraw` command.
- The MVP uses a synthetic reward fixture because live mainnet rewards
  are zero and preprod rewards require an epoch wait tracked by issue
  #17.
- The withdraw intent uses an empty `signers` array for required signer
  hashes; ordinary wallet payment witnesses are still required by the
  signer outside this tool.
- Rationale metadata remains part of the unified intent even though the
  upstream `withdraw.sh` takes only wallet address and scope.
