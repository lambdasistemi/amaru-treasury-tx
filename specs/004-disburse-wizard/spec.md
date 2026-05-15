# Feature Specification: Disburse Wizard

**Feature Branch**: `004-disburse-wizard`
**Created**: 2026-05-06
**Status**: Draft
**Input**: User description: "`disburse-wizard` plus the unified
`tx-build` dispatcher for the disburse action. Wizard takes typed Q&A
— scope, beneficiary address, unit (ada|usdm), amount, validity-hours,
rationale (description, justification, destination-label) — and
resolves all derivable fields via the existing Provider IO and the
verified registry. `tx-build` consumes unified intent.json and emits
unsigned Conway hex CBOR. Replaces the positional CLI from spec 001
for the disburse case."

Tracking issue: [#44](https://github.com/lambdasistemi/amaru-treasury-tx/issues/44).

Mirrors the architecture established in [feature 002 (swap-wizard)](../002-swap-wizard/spec.md). Replaces the
positional-CLI design described in [spec 001 §`disburse`](../001-treasury-tx-cli/contracts/cli.md#disburse).

Post-#52 update: [#52](https://github.com/lambdasistemi/amaru-treasury-tx/pull/52)
merged first and introduced `TreasuryIntent` plus `tx-build`. Feature
004 now emits `TreasuryIntent 'Disburse` (`schema = 1`,
`action = "disburse"`) and pipes into `tx-build`, not a per-action
`disburse` builder subcommand.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Produce a valid ADA disburse intent.json from a guided questionnaire (Priority: P1)

A scope owner wants to pay a vendor in ADA out of one of the five
treasury scopes. Today they must hand-write a 30+-field `intent.json`
that includes the scope's treasury address, deployed-script
references, registry reference, owner key hashes, the validity-bound
slot, and the leftover-vs-beneficiary lovelace split. With the wizard,
they answer a short typed questionnaire and receive a complete
`intent.json` ready for `amaru-treasury-tx tx-build`.

**Why this priority**: This is the marquee flow for the upstream
[`disburse.sh`](https://github.com/pragma-org/amaru-treasury/blob/main/journal/2026/bin/disburse.sh)
recipe (per [`journal/2025/marketing.md`](https://github.com/pragma-org/amaru-treasury/blob/main/journal/2025/marketing.md))
and the feature's primary user value.

**Independent Test**: Run `amaru-treasury-tx disburse-wizard --network mainnet
--wallet-addr <addr> --metadata <path> --scope core_development
--beneficiary-addr <addr> --unit ada --amount 50000000 --validity-hours 6
--description ... --justification ... --destination-label ... --out intent.json`
against a connected node. The produced JSON must validate against
`docs/assets/intent-schema.json`, round-trip through
`decodeTreasuryIntent` followed by `translateIntent SDisburse`
without errors, and yield a typed disburse intent whose fields match
the answers and the resolved registry/network state.

**Acceptance Scenarios**:

1. **Given** a connected `Provider IO` and a registry in a known state,
   **When** the user supplies all required wizard arguments and
   confirms, **Then** the wizard writes a JSON file that decodes and
   translates without errors.
2. **Given** the same answers and the same registry/network state,
   **When** the wizard runs again, **Then** the produced JSON has
   identical typed content (deterministic translation; cosmetic JSON
   key order is not load-bearing).

---

### User Story 2 - Produce a valid USDM disburse intent.json (Priority: P1)

The same operator flow as US1, but the unit is `usdm`. The wizard must
select treasury UTxOs by USDM quantity, attach a min-ADA lovelace
allowance to the beneficiary output, and route any spent ADA back to
the treasury along with the leftover USDM.

**Why this priority**: USDM disbursements are the second-most-common
action. The MVP for this feature is "pay a vendor", which means both
units must work on day one.

**Independent Test**: Run the wizard with `--unit usdm --amount <Q>` against a
treasury scope holding USDM. The produced `intent.json` must:

- Pick treasury UTxO(s) whose total USDM ≥ requested amount.
- Encode a beneficiary output carrying USDM + the protocol's
  `getMinCoinTxOut` lovelace.
- Encode a leftover treasury output carrying every ADA spent + any
  remaining USDM + every other asset present on the inputs.

**Acceptance Scenarios**:

1. **Given** a treasury scope with USDM-bearing UTxOs and a wallet
   UTxO usable as fuel + collateral, **When** the wizard runs with
   `--unit usdm --amount Q`, **Then** the resulting intent's
   beneficiary output carries `Q` USDM plus the min-ADA allowance, the
   leftover output carries the remaining USDM plus all other assets
   spent, and `runFromIntent` / `runDisburse` produces a balanced
   unsigned tx.
2. **Given** insufficient USDM in the selected scope, **When** the
   wizard runs, **Then** it exits non-zero with a single human-readable
   message on stderr (no JSON written).

---

### User Story 3 - Pure, testable translation from answers to JSON (Priority: P1)

The translation from the typed answer record (scope, unit, amount,
validity, rationale, signers) and a `DisburseEnv` (carrying everything
resolved from chain/registry/network constants) to
`TreasuryIntent 'Disburse`
must be a pure function so it can be golden-tested without IO.

**Why this priority**: Without a pure translation step the wizard
cannot be regression-tested and any change risks producing JSON that
diverges from what the build path expects. This mirrors the design
choice in feature 002.

**Independent Test**: Construct a fixture `DisburseEnv` (registry refs,
selected wallet UTxO, selected treasury UTxOs + leftover, current tip,
network constants) and a fixture answer record. Call the pure
translation. Compare the result against a checked-in golden
`TreasuryIntent 'Disburse` (or its rendered JSON).

**Acceptance Scenarios**:

1. **Given** a fixture environment + answer record, **When** the pure
   translation runs, **Then** the output matches a checked-in golden
   byte-for-byte (modulo deterministic JSON key ordering).
2. **Given** a fixture in which `--unit usdm` is selected but the
   `DisburseEnv` has no USDM-bearing treasury UTxOs, **When** the
   translation runs, **Then** it returns a typed error rather than
   producing malformed JSON.

---

### User Story 4 - Pipe `disburse-wizard | tx-build` end-to-end (Priority: P2)

The two subcommands must compose as a Unix pipe: the wizard writes
`intent.json` to stdout (or `--out`), the builder reads it on stdin
(or `--intent`), and the builder emits unsigned hex CBOR on stdout (or
`--out`). Operators must be able to run the full pipeline as one
command line: `disburse-wizard ... | tx-build > tx.cbor.hex`.

**Why this priority**: This is the operator-facing UX guarantee. If
either side breaks the pipe contract (wizard writing trace lines to
stdout, builder requiring an `--intent` flag) the value of the
wizard architecture collapses.

**Independent Test**: Run the full pipe against a mainnet node, redirect
the result to a file, and verify the file contains exactly one line of
hex characters (no prefix, no whitespace, no JSON, no trace text).

**Acceptance Scenarios**:

1. **Given** a connected node and a valid wizard answer set,
   **When** the operator runs `disburse-wizard ... | tx-build`,
   **Then** stdout is the unsigned hex CBOR (exactly one line).
2. **Given** the same pipe with `--log` flags directed to a file on
   each side, **When** the pipe runs, **Then** stderr is empty on
   success and the log files contain typed trace events.

---

### User Story 5 - Summary sidecar for inspection before signing (Priority: P3)

Every successful disburse build writes a JSON summary alongside
the CBOR (default path: `disburse.summary.json` in CWD; overridable
via `--summary-out`) describing inputs, outputs, fee, total
collateral, and a per-redeemer breakdown including ExUnits.

**Why this priority**: Operators want to verify the high-level shape
of the tx before signing it, without decoding CBOR. This is a
quality-of-life feature, not a blocker for any other story.

**Independent Test**: After running the pipe, validate the emitted
summary JSON against the existing
[`summary-schema.json`](../001-treasury-tx-cli/contracts/summary-schema.json).

**Acceptance Scenarios**:

1. **Given** a successful disburse build, **When** the builder
   completes, **Then** a summary JSON file exists at the configured
   path and validates against the schema.
2. **Given** a build that fails after re-evaluation (script failure),
   **When** the builder exits, **Then** the summary still records the
   per-script failure detail.

---

### Edge Cases

- **Insufficient treasury balance**: Wizard exits non-zero with a
  single-line stderr message; no JSON written.
- **Beneficiary address on a different network than `--network`**:
  Wizard rejects at parse/resolve time with a clear stderr message.
- **`--scope` not present in `metadata.json`**: Wizard fails at
  registry-verify time with a typed error citing the missing scope.
- **`--unit usdm` against a scope with no USDM holdings**: Wizard
  fails at translation time, not at build time.
- **Wallet UTxO carries native assets other than fuel ADA**: Wizard
  picks a different wallet UTxO if one exists; otherwise fails with a
  message naming the constraint.
- **Validity-hours outside operator-acceptable bounds (e.g. 0 or > 48)**:
  Wizard rejects at parse time.
- **Builder receives malformed `intent.json` on stdin**: Builder exits
  non-zero with a single-line stderr message identifying the parse
  position; no CBOR written.
- **Builder receives a valid intent but on-chain state has shifted
  (treasury UTxO already spent)**: Builder fails at re-evaluation with
  a typed error; summary captures the failure.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: `disburse-wizard` MUST accept the answer record via
  command-line flags (no interactive prompts) and emit a single JSON
  document on stdout (or to `--out`).
- **FR-002**: `disburse-wizard` MUST resolve the scope's
  treasury contract address, deployed-script references, registry
  reference, and owner keyhashes from the verified registry —
  operators must not type any of these.
- **FR-003**: `disburse-wizard` MUST select wallet and treasury UTxOs
  via the existing `Provider IO` query, applying the same blacklist
  semantics as the swap wizard.
- **FR-004**: `disburse-wizard` MUST compute the validity upper-bound
  slot from the current chain tip plus `--validity-hours` × 3600s.
- **FR-005**: `disburse-wizard` MUST support both `--unit ada` and
  `--unit usdm`, with selection rules and leftover semantics matching
  the upstream
  [`disburse.sh`](https://github.com/pragma-org/amaru-treasury/blob/main/journal/2026/bin/disburse.sh)
  recipe.
- **FR-006**: `disburse-wizard` MUST accept zero or more `--extra-signer`
  flags identifying co-approving scope owners (by scope name or 28-byte
  hex keyhash). For owned scopes, the selected scope's owner is always
  required and must not need to be passed explicitly. The public
  `disburse-wizard` CLI MUST reject `contingency`; contingency reserve
  movements are handled by `contingency-top-up-wizard`.
- **FR-006a**: `contingency-top-up-wizard` MUST source funds from
  `contingency`, MUST move ADA only, MUST accept a destination scope
  limited to `core_development`, `ops_and_use_cases`,
  `network_compliance`, or `middleware`, MUST resolve the destination
  treasury address from verified metadata/registry state, and MUST infer
  all four owned scope owners as required signers.
- **FR-007**: `disburse-wizard` output JSON MUST validate against
  `docs/assets/intent-schema.json` and round-trip through
  `decodeTreasuryIntent` + `translateIntent SDisburse` without loss.
- **FR-008**: The translation step (typed answers + env →
  `TreasuryIntent 'Disburse`) MUST be a pure function with no IO and no
  hidden randomness.
- **FR-009**: `tx-build` MUST read the intent JSON either from
  `--intent <path>` or from stdin when the flag is omitted.
- **FR-010**: `tx-build` MUST emit unsigned Conway transaction hex CBOR
  on stdout (or to `--out`) as a single line with no prefix, suffix, or
  surrounding whitespace.
- **FR-011**: `tx-build` MUST re-evaluate every redeemer against the
  built tx and exit non-zero on any script failure, with the failure
  recorded in the summary.
- **FR-012**: `tx-build` MUST emit a JSON summary sidecar conforming to
  the existing
  [`summary-schema.json`](../001-treasury-tx-cli/contracts/summary-schema.json)
  (default path `disburse.summary.json`, overridable via `--summary-out`).
- **FR-013**: Both subcommands MUST send all step-by-step trace events
  to stderr by default and to a file when `--log <path>` is supplied
  (mirroring 002).
- **FR-014**: Both subcommands MUST exit with code `0` on success and
  a non-zero code on any error, with a single-line human-readable
  message on stderr.
- **FR-015**: The pipe `disburse-wizard ... | tx-build` MUST work
  with no intermediate files: the wizard's stdout is exactly the
  intent JSON when `--out` is omitted; the builder's stdin is read
  when `--intent` is omitted.

### Key Entities

- **DisburseAnswers**: typed record of operator inputs (scope, unit,
  amount, beneficiary address, validity-hours, rationale fields, extra
  signers).
- **DisburseEnv**: typed record of chain-resolved values (registry
  view for the selected scope, selected wallet UTxO, selected treasury
  UTxOs + leftover totals, current tip slot, network constants).
- **TreasuryIntent 'Disburse**: the on-disk JSON contract — what the
  wizard writes and `tx-build` reads. Shares the unified top-level
  `schema`, `action`, `network`, `wallet`, `scope`, `signers`,
  `validityUpperBoundSlot`, and `rationale` shape with other actions.
- **DisburseIntent (typed)**: the translated form consumed by the
  pure builder; carries already-resolved ledger values.
- **DisburseSummary**: the JSON sidecar written by the build path,
  conforming to the existing summary schema.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: An operator can produce a valid disburse `intent.json` for
  any of the five scopes using only `metadata.json`, a wallet bech32
  address, a beneficiary bech32 address, and the seven typed answer
  values — without writing JSON by hand.
- **SC-002**: The full pipe `disburse-wizard ... | tx-build` against
  the local mainnet node completes in under 10 seconds end-to-end on
  the operator's workstation.
- **SC-003**: 100% of disburse `intent.json` documents produced by
  the wizard against a valid registry validate against
  `docs/assets/intent-schema.json` and round-trip through
  `decodeTreasuryIntent` + `translateIntent SDisburse` without error.
- **SC-004**: The pure translation step is covered by golden tests for
  both `--unit ada` and `--unit usdm`, and these tests run in under 1
  second locally.
- **SC-005**: The `tx-build` disburse branch re-evaluates every redeemer
  against the final tx and surfaces any script failure in the summary
  sidecar in 100% of failure cases.

## Assumptions

- The verified-registry pipeline used by the swap wizard
  ([`Amaru.Treasury.Registry.Verify`](https://github.com/lambdasistemi/amaru-treasury-tx/blob/main/lib/Amaru/Treasury/Registry/Verify.hs))
  is reusable as-is; this feature does not introduce new
  registry-walk semantics.
- The pure builder
  [`disburseAdaProgram`](https://github.com/lambdasistemi/amaru-treasury-tx/blob/main/lib/Amaru/Treasury/Tx/Disburse.hs)
  is correct as written and stays the source of truth for the ADA case.
  A new `disburseUsdmProgram` is added in this feature for the USDM case.
- The existing `runFromIntent` / `runSwap` IO pipeline factors
  cleanly into a disburse branch named `runDisburse`.
- The summary JSON schema in spec 001 already covers the disburse case
  unchanged; this feature does not alter the schema.
- Operators run `tx-build` against the local mainnet
  cardano-node socket (`/code/cardano-mainnet/ipc/node.socket`) for
  goldens and against preprod for live smoke tests; no other networks
  are required for v0 of this feature.
- The legacy positional `disburse` design from spec 001 is fully
  replaced by `disburse-wizard | tx-build`. No migration path or
  backwards-compatible alias is shipped.
