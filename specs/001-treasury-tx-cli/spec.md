# Feature Specification: Treasury Transaction CLI

**Feature Branch**: `001-treasury-tx-cli`
**Created**: 2026-05-04
**Status**: Draft
**Input**: Port the Amaru treasury bash recipes from
[`pragma-org/amaru-treasury/journal/2026/`](https://github.com/pragma-org/amaru-treasury/tree/main/journal/2026)
to a CLI with three subcommands (`disburse`, `reorganize`, `withdraw`)
that each emit an unsigned Conway transaction. The bash recipes are
the behavioural source of truth.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Disburse ADA to a vendor (Priority: P1)

An Amaru scope owner needs to pay an external vendor in ADA from
their scope's treasury contract. They invoke the CLI with the wallet
address that holds the fee/collateral UTxO, the amount, the vendor
address, the scope identifier, and the keyhashes of the additional
scope owners co-approving the payment. The CLI prints the unsigned
transaction CBOR and a summary describing the txid, fee, and per-script
execution units. The scope owner takes that CBOR to a separate
signing tool (hardware wallet, MPC service, or air-gapped signer) and
broadcasts it.

**Why this priority**: This is the most frequent operation — actually
moving funds out of a scope to pay vendors. It is the reason the
treasury contract exists.

**Independent Test**: Run `disburse` against a fixture
metadata file describing a known scope, with synthetic wallet/treasury
UTxOs supplied by a stub backend, and verify the emitted CBOR matches
the checked-in golden body byte-for-byte (excluding ExUnits placeholders).

**Acceptance Scenarios**:

1. **Given** a metadata file describing the `core_development` scope,
   a wallet UTxO with at least 5 ADA, and a treasury UTxO holding 10
   ADA, **When** the user runs
   `disburse <wallet> 1 ada <vendor> core_development <witness>`,
   **Then** the CLI emits an unsigned Conway transaction whose body
   carries: a 1 ADA output to `<vendor>`; a leftover output back to
   the treasury address holding 9 ADA; the wallet UTxO as fuel and
   collateral; the deployed treasury, registry, scope-owners, and
   permissions reference inputs; a withdraw-zero against the
   permissions reward account; the scope owner and witness keyhashes
   as required signers; and an `invalid_hereafter` slot inside the
   current epoch.
2. **Given** the same setup but a witness keyhash that does not match
   any configured scope owner in the metadata, **When** the user runs
   the command, **Then** the CLI exits non-zero with a message
   identifying the offending keyhash.
3. **Given** a treasury UTxO holding 0.5 ADA, **When** the user
   requests a 1 ADA disburse, **Then** the CLI exits non-zero with a
   message indicating the missing amount.

---

### User Story 2 - Disburse USDM to a vendor (Priority: P1)

Same flow as Story 1 but the vendor is paid in USDM, the on-chain
stablecoin token. The leftover USDM stays at the treasury address;
the leftover ADA on the spent treasury UTxOs stays alongside it
(treasury UTxOs that mix ADA and USDM must keep their ADA when only
USDM is being disbursed, and vice versa).

**Why this priority**: Vendors increasingly invoice in stablecoin.
This is exercised by real Amaru disbursements (see
[`journal/2025/consensus.md`](https://github.com/pragma-org/amaru-treasury/blob/main/journal/2025/consensus.md)).

**Independent Test**: Same as Story 1, with a USDM-bearing treasury
UTxO fixture and golden CBOR.

**Acceptance Scenarios**:

1. **Given** a treasury UTxO holding 100 USDM and 2 ADA and a
   metadata file describing the `ops_and_use_cases` scope, **When**
   the user runs
   `disburse <wallet> 50 usdm <vendor> ops_and_use_cases <witness>`,
   **Then** the emitted body contains an output to `<vendor>` with 50
   USDM (plus the protocol-required min-ADA), a leftover output to
   the treasury address with 50 USDM and the treasury UTxO's 2 ADA,
   and the same script-input / signer / reference shape as the ADA
   case.

---

### User Story 3 - Reorganize fragmented treasury UTxOs (Priority: P2)

Over time a scope's treasury accumulates many small UTxOs. The scope
owner wants to merge a subset of them into a single output of at
least the requested amount, so future disbursements can be served by
a single input. Reorganize is authorized by the scope owner alone (no
witness scope owner required) per the Amaru permissions design.

**Why this priority**: Operationally important but not on the critical
path of any single payment. Can be deferred without blocking
disbursements.

**Independent Test**: Build a `reorganize` tx from a fixture with
three small treasury UTxOs and verify the body has those three as
inputs and a single merged output back to the treasury.

**Acceptance Scenarios**:

1. **Given** a scope with three treasury UTxOs of 2, 3, and 4 ADA,
   **When** the user runs `reorganize <wallet> 6 ada <scope>`,
   **Then** the body contains those three treasury UTxOs as inputs
   and a single output back to the treasury address holding 9 ADA.
2. **Given** the same scope but a request for 10 ADA, **When** the
   user runs the command, **Then** the CLI exits non-zero with a
   missing-amount message.

---

### User Story 4 - Withdraw treasury rewards into the contract (Priority: P3)

The treasury contract address has a stake credential receiving
staking rewards. Periodically those rewards need to be pulled into
the treasury reward account, then moved into the contract address as
a regular UTxO. This is a single-purpose tx that does not need
permissions co-approval.

**Why this priority**: Useful but infrequent and small in value
relative to disbursements.

**Independent Test**: Build a `withdraw` tx from a fixture metadata
plus a stubbed reward-account balance and verify the body has a
single withdrawal entry, a single output to the treasury address with
the rewards amount, and the treasury reference input.

**Acceptance Scenarios**:

1. **Given** the `network_compliance` scope with 12.5 ADA in its
   treasury reward account, **When** the user runs
   `withdraw <wallet> network_compliance`, **Then** the body contains
   a single withdrawal of 12.5 ADA against the treasury stake
   address, a single output of 12.5 ADA to the treasury contract
   address, and uses the treasury reference UTxO as a read-only
   reference.
2. **Given** the same scope with zero rewards, **When** the user runs
   the command, **Then** the CLI exits zero with a message
   "nothing to withdraw" and no transaction is emitted.

---

### User Story 5 - Inspect a built transaction before signing (Priority: P3)

After building, the user reads the JSON summary to verify the
transaction does what they expect (txid, fee, per-script ExUnits,
which redeemer applies to which input/withdrawal index) before
handing the CBOR to a signing tool.

**Why this priority**: A safety net rather than a primary flow; the
golden tests catch most regressions before users ever see them.

**Independent Test**: For each of the four golden fixtures, parse the
emitted summary JSON and verify it contains the expected txid, a
non-zero fee, and one entry per script execution.

**Acceptance Scenarios**:

1. **Given** any successful build, **When** the user reads the
   summary JSON, **Then** it contains `txid`, `fee_lovelace`,
   `redeemers[]` (each with `purpose`, `index`, and `ex_units`).

---

### Edge Cases

- Wallet address has no UTxOs available for fuel.
- The selected fuel UTxO is too small to cover fee + min-utxo on
  outputs.
- A treasury UTxO matches the configured blacklist (e.g. an UTxO
  reserved for a different operation) and must be skipped during
  selection.
- The metadata file is missing the requested scope.
- A reference UTxO listed as `deployed_at` no longer exists on chain
  (script was redeployed at a new UTxO).
- The witness keyhash list contains the scope owner itself (the bash
  recipe treats this as redundant; the CLI must mirror that).
- The treasury contract has expired: `withdraw` must still work after
  expiration per the validator; `disburse` after expiration is
  disallowed by the validator and must surface as a build-time
  evaluation failure.
- The `contingency` scope has no `owner` keyhash — only certain
  operations are valid for it (per the permissions validator).

## Requirements *(mandatory)*

### Functional Requirements

#### Inputs and configuration

- **FR-001**: The CLI MUST read a `metadata.json` file matching the
  shape used by the bash recipes
  ([`journal/2026/metadata.json`](https://github.com/pragma-org/amaru-treasury/blob/main/journal/2026/metadata.json)):
  one `scope_owners` reference UTxO at the top level, plus a
  `treasuries` map keyed by scope name with per-scope `owner`,
  `address`, and the `treasury_script` / `permissions_script` /
  `registry_script` records carrying `hash` and `deployed_at`.
- **FR-002**: The CLI MUST support exactly five scope identifiers:
  `core_development`, `ops_and_use_cases`, `network_compliance`,
  `middleware`, `contingency`.
- **FR-003**: The CLI MUST support exactly two units in disburse and
  reorganize: `ada` and `usdm`.

#### Subcommands

- **FR-004**: The CLI MUST expose three subcommands with positional
  arguments matching the bash recipes 1:1: `disburse <WALLET> <AMOUNT>
  <UNIT> <BENEFICIARY> <SCOPE> <WITNESS_SCOPE>...`,
  `reorganize <WALLET> <AMOUNT> <UNIT> <SCOPE>`,
  `withdraw <WALLET> <SCOPE>`.
- **FR-005**: All three subcommands MUST accept `--metadata <path>`.

#### Redeemer Plutus-data shapes (external contract with the on-chain validators)

- **FR-006**: The `disburse` redeemer MUST be Plutus data of the
  form `Constr 3 [Map [(BS <policy>, Map [(BS <asset>, I <amount>)])]]`,
  with `<policy>` and `<asset>` empty bytestrings for ADA. This
  matches the Sundae `TreasurySpendRedeemer.Disburse` constructor
  used by the [treasury validator](https://github.com/SundaeSwap-finance/treasury-contracts/blob/main/validators/treasury.ak).
- **FR-007**: The `reorganize` redeemer MUST be `Constr 0 []`
  (Sundae `Reorganize`).
- **FR-008**: The Amaru permissions withdraw-zero redeemer attached
  to every disburse and reorganize transaction MUST be `Constr 0 []`
  encoded as the empty list — matching
  [`build_transaction.sh`](https://github.com/pragma-org/amaru-treasury/blob/main/journal/2026/lib/build_transaction.sh)
  which passes `--withdrawal-reference-tx-in-redeemer-value '[]'`.
- **FR-009**: The treasury `withdraw` (rewards → contract) redeemer
  MUST also be the empty list, per
  [`withdraw.sh`](https://github.com/pragma-org/amaru-treasury/blob/main/journal/2026/bin/withdraw.sh).

#### Transaction shape

- **FR-010**: A `disburse` body MUST contain: every selected treasury
  UTxO as a script input witnessed by the disburse redeemer; a
  withdraw-zero entry against the permissions reward account
  witnessed by the empty-list redeemer; the wallet's fuel UTxO as a
  regular input and as the sole collateral input; read-only reference
  inputs for the registry and the scope-owners NFT; the deployed
  treasury and permissions scripts as reference inputs; one output to
  the beneficiary; one leftover output back to the treasury address;
  a change output to the wallet address; required-signer keyhashes
  for the scope owner and each witness scope owner; an
  `invalid_hereafter` upper bound; and an auxiliary-data section
  carrying the treasury-instance metadata referenced by the registry.
- **FR-011**: A `reorganize` body MUST contain the same shape as
  `disburse` except: no beneficiary output; the leftover output
  carries the full merged value; required signers list contains only
  the scope owner.
- **FR-012**: A `withdraw` body MUST contain: the wallet's fuel UTxO
  as input and collateral; a single withdrawal against the treasury
  stake address (rewards → 0); the treasury and registry deployed
  references as the withdrawal reference and read-only reference
  respectively; one output to the treasury contract address with the
  rewards amount; an auxiliary-data section with the treasury-instance
  metadata.

#### Selection and balancing

- **FR-013**: For ADA disburse and reorganize, the CLI MUST select
  treasury UTxOs in the order returned by the backend until the
  accumulated lovelace is at least the requested amount, skipping
  UTxOs in a configurable blacklist (matching
  [`select_treasury_utxos.sh`](https://github.com/pragma-org/amaru-treasury/blob/main/journal/2026/lib/select_treasury_utxos.sh)).
- **FR-014**: For USDM disburse and reorganize, selection MUST filter
  treasury UTxOs to those carrying USDM and accumulate by USDM
  quantity until target is met.
- **FR-015**: Leftover output value MUST preserve all assets carried
  by the spent treasury UTxOs that were not part of the disbursed
  amount: ADA disburse keeps all USDM at the treasury, USDM disburse
  keeps all ADA at the treasury, plus any other native assets present.
- **FR-016**: The fee, the change output, and per-script ExUnits MUST
  be computed by the build pipeline so that the resulting transaction
  passes ledger validation against the supplied protocol parameters.

#### Validity bound

- **FR-017**: The `invalid_hereafter` upper bound MUST be derived
  from the current tip and the network identifier, mirroring
  [`compute_validity_period.sh`](https://github.com/pragma-org/amaru-treasury/blob/main/journal/2026/lib/compute_validity_period.sh):
  end of current epoch by default, with one extra epoch added when
  the current slot is within the last epoch's worth of slots.

#### Output

- **FR-018**: On success, the CLI MUST write the unsigned Conway
  transaction CBOR as hex to stdout (one line, no surrounding
  whitespace).
- **FR-019**: On success, the CLI MUST also write a JSON summary
  alongside (path supplied via `--summary-out <path>` or defaulting
  to `<action>.summary.json` in the working directory) containing:
  `txid`, `fee_lovelace`, an array of `redeemers` each with
  `purpose` (`spend|withdraw|mint|publish`), `index`, and
  `ex_units` (`mem`, `steps`).
- **FR-020**: On any error, the CLI MUST exit with a non-zero status
  and emit a single human-readable error message to stderr.

#### Backend abstraction

- **FR-021**: The CLI MUST expose a `--backend` flag with the
  default value `local-node` and an optional value `blockfrost`. The
  selection MUST NOT change the body CBOR for the same logical inputs
  (excluding ExUnits, which depend on the script evaluator).
- **FR-022**: The `local-node` backend MUST connect over Node-to-Client
  to a cardano-node socket given by `--node-socket <path>` (or
  `CARDANO_NODE_SOCKET_PATH`) and obtain protocol parameters, UTxO
  resolution, and script evaluation by querying the local node, in
  the same trust model as the `cardano-cli` invocations used by the
  bash recipes.
- **FR-023**: The `blockfrost` backend MUST read its project ID from
  `--blockfrost-token-file <path>` (or `BLOCKFROST_TOKEN`) and
  resolve the same data from the Blockfrost HTTP API.

#### Scope behaviour

- **FR-024**: The CLI MUST NOT sign the transaction.
- **FR-025**: The CLI MUST NOT submit the transaction.
- **FR-026**: The CLI MUST NOT support the Sundae `Fund` redeemer:
  the bash recipes disable it for Amaru, so the CLI rejects it.
- **FR-027**: The CLI MUST NOT manage script registration, reference
  script publishing, or registry/scopes minting — these are one-off
  setup transactions handled by the existing
  [`recipes`](https://github.com/pragma-org/amaru-treasury/tree/main/recipes).

### Key Entities *(include if feature involves data)*

- **Scope metadata**: per-scope record holding the owner keyhash,
  contract address, and three (script hash, deployed-at UTxO) pairs
  for treasury, permissions, and registry.
- **Wallet UTxO (fuel)**: a regular UTxO at the user's wallet
  address that pays the fee and serves as collateral.
- **Treasury UTxO**: a UTxO at a scope's treasury address; may carry
  ADA only, USDM only, or both.
- **Withdrawal intent**: a tuple of (subcommand, scope, amount, unit,
  beneficiary?, witness scope owners) that fully describes one tx.
- **Unsigned Conway transaction**: the CBOR-encoded output, ready
  for an external signer.
- **Transaction summary**: the JSON sidecar describing the unsigned
  transaction in human-readable form.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: For every supported subcommand, the CLI builds a
  transaction in under 30 seconds against a working backend on
  preprod.
- **SC-002**: All four golden fixtures (ADA disburse, USDM disburse,
  reorganize, withdraw) pass with a body-CBOR match (excluding
  ExUnits placeholders) — pass rate 100%.
- **SC-003**: A scope owner can build, sign (with their existing
  signer), and submit a disbursement end-to-end without consulting
  any documentation outside `--help` and the project README.
- **SC-004**: Switching the backend between `local-node` and
  `blockfrost` for the same logical inputs produces byte-identical
  transaction bodies (excluding ExUnits and witness-set placeholders).
- **SC-005**: A transaction submitted to preprod from this CLI is
  accepted by the on-chain validators on the first attempt for at
  least one ADA disburse, one USDM disburse, one reorganize, and one
  withdraw, captured as evidence in the project journal.

## Assumptions

- The
  [bash recipes in `journal/2026/`](https://github.com/pragma-org/amaru-treasury/tree/main/journal/2026)
  are the behavioural source of truth. Any divergence requires a
  follow-up update either in this spec or in the bash recipes
  upstream.
- All Amaru treasury contracts target the Conway era and Plutus v3.
- The user has a separate signing tool for the unsigned CBOR output
  (hardware wallet, MPC, or air-gapped signer).
- The wallet address holds at least one UTxO sufficient to cover
  fees, min-utxo on outputs, and serve as collateral. Multi-UTxO fuel
  selection is out of scope.
- USDM uses the deployed `USDM_POLICY` and `USDM_TOKEN` constants
  baked into the bash recipes (
  [`defaults.sh`](https://github.com/pragma-org/amaru-treasury/blob/main/journal/2026/defaults.sh)).
  These are mirrored in the CLI as compile-time constants and updated
  in lockstep with the upstream recipes.
- The blacklist of treasury UTxO ids is supplied via a CLI flag or
  environment variable; it is not part of `metadata.json`.
- The on-chain validator behaviour (when each redeemer is accepted,
  expiration semantics, scope-owner approvals) is taken as given;
  this CLI builds transactions that pass these validators rather than
  re-implementing their logic.
- Network selection (`mainnet` / `preprod`) is supplied via the
  backend's existing mechanism (`CARDANO_NODE_NETWORK_ID` for
  `local-node`, the project ID prefix for `blockfrost`).

## Out of Scope

- Signing the unsigned CBOR.
- Submitting the signed transaction.
- The Sundae `Fund` redeemer (Amaru disables it).
- Registry / scopes NFT minting and policy registration.
- Reference-script publishing (initial deployment of treasury,
  permissions, registry, and scope-owners scripts).
- Multi-UTxO fuel selection.
- Mainnet promotion: the CLI is expected to work on mainnet when the
  backend is configured for it, but the project ships preprod fixtures
  and documentation only.
- Stake-pool or DRep delegation of the treasury stake credential.
