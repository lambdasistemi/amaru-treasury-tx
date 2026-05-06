# Feature Specification: Unified intent JSON + single tx-build subcommand

**Feature Branch**: `005-unified-tx-build`
**Created**: 2026-05-06
**Status**: Draft
**Input**: User description: "Pause #47 (feature 004) and attack the architecture issue: the wizard already commits to an action, so there should be a single tx-build command that reads the action from the intent JSON. Likewise, network should live in the intent — duplicating it on the builder's CLI creates a silent mismatch surface. Replace SwapIntentJSON + DisburseIntentJSON with one TreasuryIntent (tagged union over actions). Land before features 005 and 006 so withdraw and reorganize design under the unified shape from day one."

Tracking issue: [#51](https://github.com/lambdasistemi/amaru-treasury-tx/issues/51).

Pauses [#44](https://github.com/lambdasistemi/amaru-treasury-tx/issues/44) (feature 004, PR
[#47](https://github.com/lambdasistemi/amaru-treasury-tx/pull/47)) and blocks
[#45](https://github.com/lambdasistemi/amaru-treasury-tx/issues/45) (withdraw-wizard) and
[#46](https://github.com/lambdasistemi/amaru-treasury-tx/issues/46) (reorganize-wizard).

## User Scenarios & Testing *(mandatory)*

### User Story 1 - One build command for any treasury action (Priority: P1)

A scope owner runs *any* of the four wizards (swap, disburse, withdraw,
reorganize) and pipes its `intent.json` into a single build command.
There is no per-action build subcommand to remember; the build path
dispatches on the intent's `action` field.

**Why this priority**: This is the entire architectural payoff. If the
operator still has to pick between `swap`, `disburse`, `withdraw`,
`reorganize` on the build side, the redundancy that motivated this
feature is preserved.

**Independent Test**: Run each of the four wizards in turn against the
local mainnet node, pipe each into the same `tx-build` invocation, and
verify each pipeline emits an unsigned hex CBOR on stdout. The
`tx-build` command line is *identical* across all four runs.

**Acceptance Scenarios**:

1. **Given** a connected node and any of the four wizards' typed
   answers, **When** the operator runs `<action>-wizard ... | tx-build`,
   **Then** stdout is one line of hex CBOR for the corresponding
   transaction kind.
2. **Given** an `intent.json` whose `action` field is missing or
   unknown, **When** `tx-build` reads it, **Then** the build exits
   non-zero with a typed error citing the offending value.

---

### User Story 2 - Network in the intent (single source of truth) (Priority: P1)

Operators specify `--network` exactly once: when running the wizard.
The wizard writes the network into the intent. The build command reads
it and uses it to negotiate the N2C handshake against the node socket.
Operators do not pass `--network` to the build command at all.

**Why this priority**: Today (in feature 002) the network must be
typed twice (`--network` on both sides of the pipe). Mismatch is
silent until the handshake fails for a confusing reason. This is also
the smaller of the two changes so it can ship as part of the same
unification.

**Independent Test**: Run a wizard with `--network preprod` and pipe
into `tx-build --node-socket <preprod-socket>` (no `--network` flag).
Build succeeds. Then re-run the same intent against
`--node-socket <mainnet-socket>` (intentional mismatch). Build fails
fast at the N2C handshake with a clear "wrong network" message.

**Acceptance Scenarios**:

1. **Given** an intent declaring `network: "preprod"` and a preprod
   socket, **When** `tx-build` runs, **Then** the handshake succeeds
   and the tx is built.
2. **Given** an intent declaring `network: "mainnet"` and a preprod
   socket, **When** `tx-build` runs, **Then** the handshake fails fast
   with a "network mismatch" stderr message and exit code ≥ 3.
3. **Given** any wizard, **When** the operator passes `--network
   mainnet` to the wizard, **Then** the produced intent's `network`
   field is `"mainnet"`.

---

### User Story 3 - Single intent shape (Priority: P1)

The `intent.json` contract is *one* tagged union, not two (or four)
sibling records. The shared blocks (wallet, scope, signers,
validityUpperBoundSlot, rationale) appear at the top level for every
action; the action-specific block (swap | disburse | withdraw |
reorganize) is nested under a key named by the `action` field.

**Why this priority**: Without one shape, the unification is leaky —
operators inspecting an intent file still have to know which kind it
is to make sense of it. With one shape, a code review of the JSON is
mechanical.

**Independent Test**: Decode any wizard's output through a single
`decodeTreasuryIntent :: ByteString -> Either String TreasuryIntent`
parser. Encode it back via `encodeTreasuryIntent` — round-trip
identity holds for any wizard's output.

**Acceptance Scenarios**:

1. **Given** any wizard's output, **When** parsed by
   `decodeTreasuryIntent`, **Then** the resulting `TreasuryIntent`
   decodes/encodes round-trip without loss.
2. **Given** an intent whose `action` is `"disburse"` but the JSON
   contains a `swap` block instead of a `disburse` block, **When**
   parsed, **Then** the parser fails with a typed error naming the
   inconsistency.

---

### User Story 4 - Schema versioning hook (Priority: P2)

The intent JSON carries a top-level `schema: 1` integer. The build
command refuses to run an intent whose schema is unknown to it. This
unblocks future shape changes without silent corruption.

**Why this priority**: This is a small addition that pays back the
first time we need to change the intent shape after this PR ships. We
expect to need it at least once (e.g. when reorganize lands and we
discover a missing field).

**Independent Test**: Hand-edit an intent to set `schema: 99`; run
`tx-build`. The command exits non-zero with a "unknown intent schema
version" message.

**Acceptance Scenarios**:

1. **Given** any intent with `schema: 1`, **When** `tx-build` runs,
   **Then** it accepts the intent.
2. **Given** an intent with `schema: 2` (or any unknown value),
   **When** `tx-build` runs, **Then** it exits non-zero before
   touching the chain.

---

### User Story 5 - Migration of feature 002 swap quickstart (Priority: P2)

The published quickstart for feature 002 (swap-wizard) currently uses
`swap-wizard ... | swap`. After this feature lands, it must read
`swap-wizard ... | tx-build`. The quickstart, the README, and any
other operator-visible docs are updated in lockstep with the code.

**Why this priority**: An operator following an old README + new
binary gets confused error messages ("unknown subcommand `swap`").
Documentation drift here is the most operator-visible cost of the
breaking change.

**Independent Test**: Search the docs site (`docs/`) and the README
for any occurrence of `| swap ` or `| disburse ` or `swap-wizard … |
swap`. After this feature lands, no occurrences remain.

**Acceptance Scenarios**:

1. **Given** any quickstart, README, or specs/ artifact in the
   repository, **When** searched for `swap` as a subcommand, **Then**
   no operator-facing instruction asks the operator to invoke `swap`
   directly. Every pipeline ends in `| tx-build`.

---

### Edge Cases

- **Mixed action / payload**: intent declares `action: "disburse"` but
  carries a `swap` payload block. Parser surfaces a typed error
  before any chain query.
- **Missing payload block**: intent declares `action: "swap"` but no
  `swap` block is present. Parser surfaces a typed error.
- **Unknown action**: intent declares `action: "frob"`. Parser
  surfaces a typed error listing the four supported actions.
- **Network mismatch**: intent claims `network: "mainnet"` but the
  socket is preprod. N2C handshake fails fast with a single-line
  stderr message and exit code ≥ 3.
- **Old swap intent (no `network` field)**: the loose
  pre-unification swap intent format is rejected at parse time
  (operator must re-run the wizard). No silent migration.
- **`schema` field missing**: intent has no `schema` key. Parser
  defaults to `schema: 1` for usability — the field is required only
  after a future bump.
- **Builder run with `--network` flag**: the flag is removed from the
  build subcommand; operators who pass it get an
  `optparse-applicative` parse error.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The CLI MUST expose exactly one transaction-build
  subcommand named `tx-build` that consumes any intent produced by
  any of the four wizards.
- **FR-002**: The legacy subcommands `swap` and `disburse` (the
  latter never shipped) MUST be removed. `tx-build` is the sole
  transaction-build entry point.
- **FR-003**: The `intent.json` contract MUST be a tagged-union shape
  with a top-level `action` field selecting the action, an `action`-
  specific block named after the action, and shared blocks at the top
  level (`wallet`, `scope`, `signers`, `validityUpperBoundSlot`,
  `rationale`, `network`, `schema`).
- **FR-004**: `tx-build` MUST read `network` from the intent JSON and
  use it to derive the N2C handshake magic.
- **FR-005**: `tx-build` MUST NOT accept a `--network` or
  `--network-magic` flag; `--node-socket` is the only operator-
  supplied connection input.
- **FR-006**: Each wizard MUST emit `network` into its intent JSON.
- **FR-007**: The build path MUST validate that the intent's `action`
  field matches the action-specific block present (e.g. `action:
  "disburse"` requires a `disburse` block) and reject mismatches with
  a typed error.
- **FR-008**: The intent JSON MUST carry a top-level `schema :: Int`
  field. `tx-build` MUST refuse to run an intent whose schema is not
  in its allow-list. The first allow-list value is `1`.
- **FR-009**: `tx-build` MUST work as a stdin filter when `--intent`
  is omitted, mirroring the existing pipe contract.
- **FR-010**: The shared structural blocks (wallet, scope, signers,
  validityUpperBoundSlot, rationale) MUST be defined exactly once in
  the codebase. The action-specific blocks MAY remain per-action but
  MUST live behind a single `data ActionPayload` sum.
- **FR-011**: Parser helpers (`parseAddr`, `parseTxIn`,
  `parseRewardAccount`, `parseGuardKeyHash`, `decodeHexBytes`,
  `mkHash28`, `mkHash32`) MUST live in exactly one shared module.
  Per-action modules MUST import them, not duplicate them.
- **FR-012**: Signer-resolver helpers (`signerScopeFromText`,
  `normaliseSignerToken`, `isHex28`, `ownerForScope`) MUST live in
  exactly one shared module.
- **FR-013**: The existing swap golden + the in-flight ada-disburse
  golden MUST be re-recorded against the new intent shape. The CBOR
  bodies MUST NOT change as a result of this feature; only the JSON
  inputs change.
- **FR-014**: The published quickstart, README, and any other
  operator-visible documentation MUST be updated in lockstep with
  the code change. No operator-visible doc may instruct the
  operator to invoke `| swap` or `| disburse` after this feature
  lands.
- **FR-015**: Feature 004's spec, plan, contracts, data-model,
  research, and tasks artifacts MUST be updated to reflect the
  unified shape. The branch under PR
  [#47](https://github.com/lambdasistemi/amaru-treasury-tx/pull/47)
  MUST rebase on top of this feature once it lands and adapt
  accordingly.

### Key Entities

- **TreasuryIntent**: the unified on-disk JSON contract. Carries the
  shared blocks plus exactly one action-specific payload determined
  by `action`.
- **ActionPayload**: typed sum over the four action variants
  (`SwapPayload`, `DisbursePayload`, `WithdrawPayload`,
  `ReorganizePayload`). Only the variants for actions whose feature
  has shipped are populated; the others are placeholders.
- **TranslatedTreasuryIntent**: the typed lift to ledger types
  consumed by `runTreasuryBuild`.
- **TreasuryBuildResult**: the build pipeline's output
  (`cborBytes`, `feeLovelace`, `totalCollateralLovelace`,
  `scriptResults`). Identical shape to today's per-action results.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: After this feature lands, the CLI exposes exactly one
  build subcommand (`tx-build`) and four wizard subcommands. No
  per-action build subcommand exists.
- **SC-002**: An intent JSON produced by *any* of the four wizards
  decodes through `decodeTreasuryIntent` and round-trips through
  `decodeTreasuryIntent . encodeTreasuryIntent` byte-for-byte
  (modulo deterministic key ordering) for at least 100 random
  shapes.
- **SC-003**: 100% of pipelines `<action>-wizard ... | tx-build`
  produce a valid unsigned hex CBOR on stdout for any of the four
  actions whose feature has shipped at the time of measurement.
- **SC-004**: The swap golden and ada-disburse golden re-record
  identically (CBOR bodies match the previous bytes) against the
  new intent shape. Any byte-level diff is a regression and blocks
  merge.
- **SC-005**: After this feature lands, the codebase contains zero
  duplicate definitions of `parseAddr`, `parseTxIn`,
  `parseRewardAccount`, `parseGuardKeyHash`, `decodeHexBytes`,
  `signerScopeFromText`, `normaliseSignerToken`, `isHex28`,
  `ownerForScope`. (Searchable via `grep`.)

## Assumptions

- The CBOR bodies of the existing swap golden and the in-flight
  ada-disburse golden are correct as recorded — the unification
  changes only the JSON we feed in, not the resulting transaction.
- Operators following the published quickstart for feature 002 are
  willing to update their pipelines to `| tx-build`. We do not need
  to ship a backwards-compatible `swap` alias.
- The `schema: 1` allow-list is sufficient for v0; the next bump
  is a separate change.
- Re-recording fixtures is mechanical (`UPDATE_GOLDENS=1`).
- Feature 004's PR
  [#47](https://github.com/lambdasistemi/amaru-treasury-tx/pull/47)
  is paused until this feature ships and rebases on top of it.
- The existing
  [`Amaru.Treasury.Tx.SwapBuild`](https://github.com/lambdasistemi/amaru-treasury-tx/blob/main/lib/Amaru/Treasury/Tx/SwapBuild.hs)
  and
  [`Amaru.Treasury.Tx.DisburseBuild`](https://github.com/lambdasistemi/amaru-treasury-tx/blob/004-disburse-wizard/lib/Amaru/Treasury/Tx/DisburseBuild.hs)
  drivers can be merged into a single `runTreasuryBuild` that
  dispatches on the action variant. The IO-side plumbing
  (`ChainContext`, the balancer call, the re-eval pass) is
  unchanged.
- Feature 002's published `intent.json` files (if any operators
  have hand-curated copies) are *not* migrated. Operators re-run
  the wizard to obtain a v1 intent.
