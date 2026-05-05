# Feature Specification: Swap Wizard

**Feature Branch**: `002-swap-wizard`
**Created**: 2026-05-05
**Status**: Draft
**Input**: User description: "swap-wizard subcommand that produces intent.json from a small typed questionnaire (see issue #27). The CLI prompts the user for ~7 real-intent answers (scope, total ADA, chunk size or slippage, min rate or slippage %, validity window in hours, rationale description+justification, optional signer override) and resolves all derivable fields (treasuryAddress, *DeployedAt, owner key hashes, swapOrderAddress, USDM policy/token, sundae fee, treasuryUtxos selection, leftover lovelace, wallet UTxO) via the existing Provider IO and a curated network-constants table. Output is a JSON file that round-trips through decodeSwapIntent + translateIntent. The build path stays JSON-only — the wizard is purely a JSON producer, never calls runSwapBuild directly."

Tracking issue: [#27](https://github.com/lambdasistemi/amaru-treasury-tx/issues/27)

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Produce a valid intent.json from a guided questionnaire (Priority: P1)

A scope owner wants to swap treasury ADA for USDM via SundaeSwap. Today
they must hand-write a 35-field `intent.json` that includes registry
addresses, deployed-at references, owner key hashes, USDM policy/token,
the SundaeSwap order address, protocol fees, treasury UTxO selection,
and leftover arithmetic. With the wizard, they answer a short typed
questionnaire and receive a complete `intent.json` ready for
`amaru-treasury-tx swap`.

**Why this priority**: This is the entire user-visible value of the
feature. Without it the wizard does nothing.

**Independent Test**: Run `amaru-treasury-tx swap-wizard --out
intent.json` against a known-state network. The produced JSON must
round-trip through `decodeSwapIntent` followed by `translateIntent`
without errors and yield a `SwapIntent` whose typed fields match the
answers and the resolved registry/network state.

**Acceptance Scenarios**:

1. **Given** a connected `Provider IO` and a registry in a known state,
   **When** the user answers all required questions and confirms,
   **Then** the wizard writes a JSON file that decodes and translates
   without errors.
2. **Given** the same answers and the same registry/network state,
   **When** the wizard runs again, **Then** the produced JSON has
   identical typed content (deterministic translation; cosmetic JSON
   key order is not load-bearing).

---

### User Story 2 - Pure, testable translation from answers to JSON (Priority: P1)

The translation from the typed answer ADT and a `WizardEnv` (carrying
everything resolved from chain/registry/network constants) to
`SwapIntentJSON` must be a pure function so it can be golden-tested
without IO.

**Why this priority**: Without a pure translation step the wizard
cannot be regression-tested and any change risks producing JSON that
diverges from what the build path expects.

**Independent Test**: Construct a fixture `WizardEnv` and a fixture
`SwapWizardQ`. Call the pure translation. Compare the result to a
checked-in golden `SwapIntentJSON` (or its rendered JSON).

**Acceptance Scenarios**:

1. **Given** a fixture `WizardEnv` and `SwapWizardQ`,
   **When** the pure translation runs,
   **Then** the resulting JSON matches the golden byte-for-byte (modulo
   a stable encoder).

---

### User Story 3 - Audit artifact preserved (Priority: P2)

The wizard never calls `runSwapBuild` directly. It only writes JSON.
Operators inspect, version, and replay the JSON; rationale metadata is
derived from it during the build phase exactly as today.

**Why this priority**: Bypassing the JSON would lose the audit trail
the rationale metadata depends on and would split the build path in
two.

**Independent Test**: After the wizard writes `intent.json`, an
operator runs the existing `amaru-treasury-tx swap` against that file
and obtains a transaction equivalent to one built from a hand-written
JSON with the same answers.

**Acceptance Scenarios**:

1. **Given** wizard-produced `intent.json` and a hand-written
   `intent.json` with the same answers and same network state,
   **When** both are fed to `amaru-treasury-tx swap`,
   **Then** the produced transaction CBOR is byte-identical (or
   differs only in fields that are intrinsically non-deterministic,
   e.g. UTxO selection order, which the wizard fixes by selection
   policy).

---

### Edge Cases

- The user picks a scope that has no spendable treasury UTxOs — the
  wizard must abort with a clear error before writing anything.
- Total ADA exceeds the sum of selectable treasury UTxOs — abort with
  a clear shortfall message.
- The wallet has no pure-ADA UTxO suitable as fuel/collateral — abort
  with a message naming the wallet address.
- Total ADA is not divisible by chunk size — the wizard records the
  remainder as a final smaller chunk (matches existing
  `mkChunks` behavior).
- The user requests a validity window of zero hours — reject with an
  explicit minimum.
- USDM policy/token is unknown for the selected network — abort with
  "no USDM constants for network N".
- The registry walk returns an unexpected number of owner keys for the
  selected scope — abort rather than silently truncating.
- Network mismatch: wallet address belongs to mainnet but the resolver
  is configured for preprod (or vice versa) — abort.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST expose a `swap-wizard` subcommand under
  `amaru-treasury-tx`.
- **FR-002**: System MUST collect, at minimum, these answers from the
  user: scope (Core / Ops / NetworkCompliance / Middleware), total
  ADA to swap, chunk size (lovelace), minimum acceptable rate as
  numerator and denominator, validity window in hours, rationale
  description, rationale justification, optional signer override.
  Slippage-tolerance and slippage-percent shortcuts are deferred
  per the Assumptions section. The CLI prompt schema in
  [contracts/swap-wizard-cli.md §2](./contracts/swap-wizard-cli.md)
  expands the rationale and signer answers into individually-prompted
  sub-fields with sensible defaults; that expansion is the
  *presentation* of FR-002, not an extension of it.
- **FR-003**: System MUST resolve the following fields without asking
  the user, using the registry NFT walk and a curated
  network-constants table: `treasuryAddress`, `treasuryScriptHash`,
  `permissionsRewardAccount`, `scopesDeployedAt`,
  `permissionsDeployedAt`, `treasuryDeployedAt`, `registryDeployedAt`,
  `registryPolicyId`, `coreOwner`, `opsOwner`,
  `networkComplianceOwner`, `middlewareOwner`, `swapOrderAddress`,
  `usdmPolicy`, `usdmToken`, `sundaeProtocolFeeLovelace`,
  `extraPerChunkLovelace`, `poolId`.
- **FR-004**: System MUST select treasury UTxOs and compute leftover
  lovelace such that selected inputs minus the sum of swap chunks
  equals `treasuryLeftoverLovelace`, with a deterministic selection
  policy (e.g. largest-first until sum ≥ total).
- **FR-005**: System MUST select the wallet UTxO from the configured
  signing key as the largest pure-ADA UTxO at the wallet address.
- **FR-006**: System MUST default `signers` to the scope's owner set
  — the scope's primary owner key plus the witness scope owner keys
  per `journal/2026/lib/swap_order.sh` — and accept an explicit
  override answer that replaces (not extends) the default.
- **FR-007**: System MUST compute `validityUpperBoundSlot` by adding
  the answered hours (translated to slots) to the current chain tip.
- **FR-008**: System MUST write the result as a JSON file at a
  user-specified path (e.g. `--out intent.json`).
- **FR-009**: System MUST NOT invoke `runSwapBuild` or otherwise build
  a transaction; the wizard's only output is the JSON file.
- **FR-010**: The translation from answers + resolved environment to
  `SwapIntentJSON` MUST be a pure function with no IO, suitable for
  golden testing.
- **FR-011**: The produced JSON MUST round-trip through
  `decodeSwapIntent` followed by `translateIntent` without errors.
- **FR-012**: System MUST abort with a clear error (not silently fall
  back) when any resolved field cannot be obtained — missing scope,
  empty UTxO set, unknown network constants, registry walk
  inconsistencies.
- **FR-013**: The wizard MUST log every resolved derivable field to
  stderr (controlled by a `--verbose` flag) so the operator can
  verify what was filled in before answering "confirm". Stdout is
  reserved for the success line and the `--dry-run` JSON payload
  per [contracts/swap-wizard-cli.md §3](./contracts/swap-wizard-cli.md).
- **FR-014**: The wizard MUST require explicit confirmation before
  writing the JSON file (unless invoked with a `--yes` flag for
  scripted use).

### Key Entities

- **SwapWizardQ**: The typed answers ADT — exactly the fields the
  human decides. Mirrors FR-002 one-to-one.
- **WizardEnv**: The resolved environment — registry walk results,
  network constants, selected UTxOs, current chain tip. All values
  needed to translate `SwapWizardQ` to `SwapIntentJSON` purely.
- **NetworkConstants**: Per-network table of `swapOrderAddress`,
  `usdmPolicy`, `usdmToken`, `sundaeProtocolFeeLovelace`,
  `extraPerChunkLovelace`, default pool id (and possibly a curated
  list).
- **ScopeId**: Enum for Core / Ops / NetworkCompliance / Middleware,
  used to project the registry walk into the right owner key and
  treasury references.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A first-time scope owner can produce a valid
  `intent.json` in under 5 minutes by answering the wizard, without
  consulting the registry layout, the SundaeSwap V3 contract address,
  USDM constants, or the deployed-at chain references.
- **SC-002**: 100% of wizard-produced JSON files round-trip through
  `decodeSwapIntent + translateIntent` in the unit test suite.
- **SC-003**: Wizard-produced JSON and an equivalent hand-written JSON
  produce byte-identical transaction CBOR through the existing build
  path on a fixed `WizardEnv` (covered by a golden test).
- **SC-004**: When the wizard cannot resolve a derivable field, it
  exits with a non-zero status and a message naming the missing piece
  — never writes a partial JSON.

## Assumptions

- The existing `Provider IO` already exposes (or trivially can expose)
  the queries needed to resolve registry contents, treasury UTxOs,
  wallet UTxOs, and the current chain tip.
- A curated `NetworkConstants` table is acceptable as the source of
  truth for SundaeSwap V3 order address, USDM policy/token, and
  protocol fee for each supported network. Updating this table when
  upstream values change is a maintenance task, not a wizard concern.
- The configured signing key (and therefore the fuel/collateral wallet
  address) is already established by the surrounding CLI; the wizard
  does not introduce new key management.
- "Slippage tolerance" as an alternative to a hard-coded chunk size or
  hard-coded minimum rate is acceptable as a future ergonomic
  improvement; the v1 wizard MAY require explicit chunk size and
  explicit numerator/denominator and still satisfy SC-001.
- This feature is additive; the existing `swap` subcommand and
  `intent.json` schema do not change.
