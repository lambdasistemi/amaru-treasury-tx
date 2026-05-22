# Feature Specification: wizard input control via `--exclude-utxo` / `--extra-tx-in`

**Feature Branch**: `184-exclude-utxo`
**Created**: 2026-05-22
**Status**: Draft
**GitHub Issue**: [#184](https://github.com/lambdasistemi/amaru-treasury-tx/issues/184)
**Sibling Issue**: [#183](https://github.com/lambdasistemi/amaru-treasury-tx/issues/183) (auto-detect in-flight reservations; survives independently)
**Draft PR**: [#200](https://github.com/lambdasistemi/amaru-treasury-tx/pull/200)

**Input**: Every `*-wizard`'s wallet/treasury selection runs a fresh
chain query and picks biggest-pure-ADA first. There is no way to tell
the wizard to skip a specific UTxO; the operator's only escape today
is to run the wizard, then hand-edit `intent.json` (`.wallet.txIn` and
`.wallet.extraTxIns`), which defeats the wizard's purpose. Add a
per-build, repeatable `--exclude-utxo TX_HASH#IX` flag that filters
the given outref(s) from the candidate set **before** the biggest-first
selection runs, plus a paired `--extra-tx-in TX_HASH#IX` flag that
forces specific outref(s) as additional wallet inputs (emitted into
`intent.json`'s `extraTxIns` array). The two flags must error
explicitly when the same outref appears in both. Concrete drivers:
in-flight multi-sig builds racing for the same wallet UTxO, reserving
a UTxO for a parallel flow, and routing around an operationally
damaged UTxO. See the issue body for the original incident
([`59e10ca5…#2` vs `swap-wizard`](https://github.com/lambdasistemi/amaru-treasury-tx/issues/184)).

## User Scenarios & Testing

### User Story 1 - Operator excludes a specific UTxO during wizard input selection (Priority: P1)

As an operator running any `*-wizard`, I need a way to tell the wizard
"skip this outref" so that the produced `intent.json` does not bake in
a UTxO I know is unavailable (in-flight build, parallel-flow
reservation, operationally damaged), without having to hand-edit
`intent.json` afterwards.

**Why this priority**: This is the paramount user story of the ticket.
Today's only escape (hand-editing `.wallet.txIn` after the fact)
defeats the wizard's typed, byte-stable contract and is exactly what
the wizard was built to eliminate. Hand-editing also bypasses the
wizard's selection invariants (minimum balance, asset-set filter,
script-vs-pure-ADA classification) and is error-prone under time
pressure.

**Independent Test**: A focused regression test runs a wizard against
a fixture wallet with several candidate UTxOs, passes
`--exclude-utxo` for the largest pure-ADA UTxO, and asserts the
emitted `intent.json` selects the next-largest eligible UTxO. The same
fixture without the flag selects the excluded UTxO.

**Acceptance Scenarios**:

1. **Given** a wallet has UTxOs `A` (92.56 ADA) and `B` (19.76 ADA),
   **When** the operator runs `swap-wizard … --exclude-utxo <A>`,
   **Then** the emitted `intent.json` has `wallet.txIn = B` and the
   wizard log records a line naming the excluded outref.
2. **Given** the operator passes `--exclude-utxo` multiple times,
   **When** the wizard runs, **Then** every excluded outref is
   filtered from the candidate pool(s) before biggest-first selection.
3. **Given** the exclusion set leaves no eligible candidates, **When**
   the wizard runs, **Then** it errors with the existing wallet or
   treasury shortfall error shape and the error message names every
   excluded outref so the operator knows whether to lift one.

---

### User Story 2 - Operator forces specific UTxOs as additional wallet inputs (Priority: P1)

As an operator running any `*-wizard`, I need a way to tell the wizard
"also include these specific outrefs as wallet inputs" so I can
explicitly bind known UTxOs into the build (consolidating dust,
reserving change behavior, asserting an asset-bearing UTxO is
present), without having to hand-edit
`intent.json`'s `extraTxIns` array afterwards.

**Why this priority**: This story is the explicit counterpart to
P1's exclusion. Together they are the operator's input-control
surface, and they are necessary for the P3 contradiction check to
have a real target inside this ticket (the issue body assumes a
`--extra-tx-in` flag exists; today it does not). Without P2 the
contradiction check would be unenforceable and the operator would
still need to hand-edit `intent.json` for the symmetric inclusion
case.

**Independent Test**: A focused regression test runs a wizard with a
single `--extra-tx-in <ref>` for a known wallet UTxO and asserts the
emitted `intent.json` carries the ref in `wallet.extraTxIns` (and
nowhere else), without changing `wallet.txIn` selection.

**Acceptance Scenarios**:

1. **Given** the operator passes `--extra-tx-in <ref>`, **When** the
   wizard emits `intent.json`, **Then** `wallet.extraTxIns` contains
   `<ref>` exactly once and the primary `wallet.txIn` selection runs
   unchanged on the remaining candidate pool.
2. **Given** the operator passes `--extra-tx-in` multiple times,
   **When** the wizard emits `intent.json`, **Then** every named
   outref appears in `wallet.extraTxIns` in input order, with no
   duplicates and no silent reordering.
3. **Given** an `--extra-tx-in` ref does not exist on chain at the
   wizard's wallet address, **Then** the wizard errors with a clear
   "extra input not found on wallet" message naming the ref.

---

### User Story 3 - Contradictory inclusion/exclusion fails loudly (Priority: P1)

As an operator who may compose the two flags by mistake, I need the
wizard to refuse to silently pick one over the other when the same
outref appears in both `--exclude-utxo` and `--extra-tx-in`.

**Why this priority**: Silent precedence (either direction) would
produce an `intent.json` the operator did not intend, with no log
signal that the contradiction was resolved. The whole point of the
exclusion flag is to be authoritative; the whole point of the
inclusion flag is to be authoritative. They cannot both be
authoritative for the same outref in the same run.

**Independent Test**: A focused regression test passes the same
outref to both flags on the same wizard invocation and asserts the
wizard exits non-zero with a structured "contradictory
inclusion/exclusion" error naming the conflicting outref.

**Acceptance Scenarios**:

1. **Given** the operator passes `--exclude-utxo <R>` and
   `--extra-tx-in <R>` on the same wizard invocation, **When** the
   wizard validates flags, **Then** it errors *before* querying the
   chain or doing selection, and the error names `<R>`.
2. **Given** a contradiction error fires, **When** the operator reads
   `stderr`, **Then** the message states clearly which outref is in
   conflict and which two flags supplied it.

---

### User Story 4 - Coverage across every wizard that does input selection (Priority: P1)

As an operator running any of the project's wizards, I need
`--exclude-utxo` / `--extra-tx-in` to behave identically on every
wizard that does wallet or treasury input selection, so I do not have
to remember which wizards support it and which need hand-editing.

**Why this priority**: A flag that lands on `swap-wizard` only would
still leave the operator hand-editing `intent.json` after every
`disburse-wizard` / `withdraw-wizard` / `contingency-disburse-wizard`
run that hit the same race or reservation. The ticket's value is
ratcheted only when coverage is total across the input-selecting
surface.

**Independent Test**: For each in-scope wizard, a focused regression
test exercises `--exclude-utxo` on a wallet (and, where applicable,
treasury) candidate set and asserts the same selection-then-filter
behavior. A grep over `lib/Amaru/Treasury/Cli/*.hs` confirms every
in-scope wizard parses both flags.

**Acceptance Scenarios**:

1. **Given** the in-scope wizard list below, **When** the operator
   runs `<wizard> --help`, **Then** both `--exclude-utxo` and
   `--extra-tx-in` are documented with identical phrasing across
   wizards.
2. **Given** the in-scope wizard list below, **When** each wizard is
   exercised by its focused test with `--exclude-utxo` and
   `--extra-tx-in`, **Then** the behavior matches P1, P2, and P3
   above.

In-scope wizards (operator decision recorded 2026-05-22 during
clarify):

- `swap-wizard` (wallet + treasury selection)
- `disburse-wizard` (wallet + per-unit treasury selection)
- `contingency-disburse-wizard` (same selection code as `disburse-wizard`)
- `withdraw-wizard` (wallet selection)
- `registry-init-wizard` (wallet selection via `selectWallet 1`)
- `stake-reward-init-wizard` (wallet selection via `selectWallet 1`)
- `governance-withdrawal-init-wizard` (wallet selection via
  `firstPureAdaRef` — different selector, same exclusion/inclusion
  semantics)

Out-of-scope commands (no wallet or treasury input selection):

- `reorganize-wizard` — at HEAD this is a typed-answers scaffold
  (`lib/Amaru/Treasury/Tx/ReorganizeWizard.hs`) and does not yet
  call any selector. Wiring `--exclude-utxo` / `--extra-tx-in` here
  would expose flags that have nothing to filter. The flag wires can
  be added in the same PR that turns the scaffold into a live
  selecting wizard (see #185–#187 / parent #189).
- `swap-quote`, `swap-cancel`, `tx-build`, `treasury-inspect`,
  `attach-witness`, `witness`, `submit`, `vault`, envelope helpers,
  `report-render`.

---

### Edge Cases

- An `--exclude-utxo` outref that is not present in the candidate set
  at wizard time is silently a no-op (with a log line that records
  the inert exclusion) — operators commonly pass excludes
  defensively, and erroring on "not currently present" would force
  them to re-check chain state before every run.
- An `--exclude-utxo` outref matches both a wallet candidate and a
  treasury candidate in the same run (rare; would require operator
  to be using the same key for both). The exclusion filters from both
  pools and the log line records that it hit both pools.
- An `--extra-tx-in` outref that already appears in the chain-query
  candidate set is not double-counted: it is removed from the
  selection pool and only emitted into `extraTxIns`.
- Parsing errors on the `TX_HASH#IX` outref format (non-hex, wrong
  length, missing `#`, negative or non-numeric index) fail at flag
  validation time with a clear error pointing at the offending
  argument.
- The contradiction check runs before any chain query so the wizard
  fails fast and does not incur a node round-trip on a definitely
  invalid invocation.

## Requirements

### Functional Requirements

- **FR-001**: Every in-scope wizard (see User Story 4) MUST accept a
  repeatable `--exclude-utxo TX_HASH#IX` flag that adds the given
  outref to an exclusion set.
- **FR-002**: Every in-scope wizard MUST accept a repeatable
  `--extra-tx-in TX_HASH#IX` flag that adds the given outref to a
  forced-inclusion set.
- **FR-003**: Both flags MUST validate `TX_HASH#IX` as a Conway
  outref (64-char lowercase hex transaction id + `#` + non-negative
  integer index) at parse time and fail with a structured error
  before any chain query when validation fails.
- **FR-004**: The exclusion set MUST be applied to the candidate set
  passed into each selector — wallet selection for all in-scope
  wizards, and treasury selection for `swap-wizard`,
  `disburse-wizard`, and `contingency-disburse-wizard` — **before**
  any largest-first selection runs.
- **FR-005**: For each excluded outref the wizard MUST emit a log
  line of the form `<wizard>: excluded utxo <outref> (operator-supplied)`
  identifying which pool(s) the ref hit (wallet, treasury, or both).
- **FR-006**: For each `--extra-tx-in` outref the wizard MUST emit
  the ref into the wizard output's `extraTxIns` (or per-wizard
  equivalent) array exactly once in input order, after removing it
  from the wallet selection pool to avoid double-counting.
- **FR-007**: If `--exclude-utxo` and `--extra-tx-in` are passed the
  same outref on the same wizard invocation, the wizard MUST exit
  non-zero with a structured "contradictory inclusion/exclusion"
  error naming the conflicting outref, before querying the chain.
- **FR-008**: If the exclusion set leaves no eligible candidates for
  a required pool, the wizard MUST surface the existing wallet or
  treasury shortfall error shape (e.g. `WalletNoPureAda`,
  `WalletShortfall`, treasury equivalents) and the error message
  MUST list every excluded outref that filtered against that pool.
- **FR-009**: An `--extra-tx-in` outref that cannot be resolved
  against the wizard's wallet address at chain-query time MUST
  produce a clear "extra input not found on wallet" error naming the
  ref; the wizard MUST NOT silently drop it.
- **FR-010**: The new flags MUST not change the selection behavior
  when neither is passed. Existing wizard focused-test fixtures and
  golden `intent.json` files MUST be untouched by this ticket
  (except for any wizard's `--help` output if it is golden-tested).
- **FR-011**: Every in-scope wizard's user-visible CLI help text
  MUST document both flags with identical phrasing, so the operator
  reads the same contract across all wizards.
- **FR-012**: The exclusion/inclusion logic MUST live in a shared
  helper module that every wizard consumes, so the seven wizards do
  not duplicate the parsing, validation, contradiction-check, or
  filter behavior.
- **FR-013**: The branch-local `./gate.sh` MUST be the local pre-push
  gate for every accepted slice; `nix flake check` remains the
  parallel CI proof.

### Key Entities

- **Outref**: A `TX_HASH#IX` pair identifying a single UTxO on chain;
  a 64-char lowercase hex `TX_HASH` and a non-negative integer `IX`.
- **Exclusion set**: The set of outrefs supplied via `--exclude-utxo`
  on a single wizard invocation; filters wallet and treasury
  candidate pools before selection.
- **Forced-inclusion set**: The set of outrefs supplied via
  `--extra-tx-in` on a single wizard invocation; emitted into the
  wizard's output `extraTxIns` array.
- **Candidate pool**: The set of UTxOs returned by the wizard's
  chain query for either the wallet address or the per-scope
  treasury address, before any selection runs.
- **Wizard selector**: The function each wizard calls to pick a
  primary input from a candidate pool (`selectWallet`,
  `selectTreasury`, `selectTreasuryForUnit`, `firstPureAdaRef`).
  The exclusion filter applies before the selector runs.
- **Contradiction error**: The structured error fired when the same
  outref appears in both the exclusion set and the forced-inclusion
  set on the same wizard invocation.

## Deliverables

- New shared helper module under `lib/Amaru/Treasury/Wizard/` (per
  the project's "separate modules always" convention; sibling to
  [`Wizard/Common.hs`](../../lib/Amaru/Treasury/Wizard/Common.hs))
  that owns: outref parsing/validation, exclusion-set type,
  forced-inclusion-set type, contradiction check, and the pool-filter
  function used by every wizard.
- `--exclude-utxo` and `--extra-tx-in` flags wired into the CLI
  option parser for every in-scope wizard:
  - `lib/Amaru/Treasury/Cli/SwapWizard.hs` (`wizardOptsP`)
  - `lib/Amaru/Treasury/Cli/DisburseWizard.hs` (`disburseWizardOptsP`,
    `contingencyDisburseOptsP`)
  - `lib/Amaru/Treasury/Cli/WithdrawWizard.hs` (`withdrawOptsP`)
  - `lib/Amaru/Treasury/Cli/RegistryInitWizard.hs`
    (`registryInitWizardOptsP`)
  - `lib/Amaru/Treasury/Cli/StakeRewardInitWizard.hs`
    (`stakeRewardInitWizardOptsP`)
  - `lib/Amaru/Treasury/Cli/GovernanceWithdrawalInitWizard.hs`
    (`governanceWithdrawalInitWizardOptsP`)
- Selector call sites in each wizard's `Tx/*Wizard.hs` runner
  updated to apply the exclusion filter before calling the
  selector, and to thread the forced-inclusion set into the emitted
  intent.
- Updated error shape (or wrapping) for the seven wizards' shortfall
  paths so the existing structured error names excluded outrefs.
- Focused regression tests (TDD) per in-scope wizard exercising
  exclusion, forced inclusion, contradiction, and shortfall-with-excludes.
- Documentation in the wizard-facing pages
  ([`docs/swap.md`](../../docs/swap.md),
  [`docs/disburse.md`](../../docs/disburse.md),
  [`docs/withdraw.md`](../../docs/withdraw.md),
  and a new short shared section linked from
  [`docs/index.md`](../../docs/index.md)) describing both flags,
  their format, and the contradiction error.
- README quickstart updates wherever a wizard command example is
  shown.
- PR metadata naming the seven in-scope wizards, the shared helper
  module, the deferred asciinema follow-up (see Non-Goals), and the
  sibling relationship to #183.

This ticket does not introduce a new executable, release asset,
package, or distribution surface. The existing
`amaru-treasury-tx` Linux/Darwin/Homebrew/AppImage release matrix
continues to consume the same project package after the flag
additions; no release-pipeline edits are required.

The asciinema first-class doc deliverable rule applies to "modified
user-facing surface of an existing exe". This ticket modifies the
flag surface of eight wizards. The project has not adopted the
mkdocs `asciinema-player` plugin yet (no `docs/assets/asciinema/`,
no plugin registration in `mkdocs.yml`, no env-overridable
`site_url`). Bootstrapping the plugin infrastructure plus an
env-overridable `MKDOCS_SITE_URL` plumb for PR previews is
non-trivial vertical scope, materially larger than the flag
additions themselves and orthogonal to #184's incident-driven
value. This spec records the asciinema cast as a named operator
follow-up (see Non-Goals below) so the deliverable is not lost,
and proposes a tracking issue rather than absorbing the plugin
bootstrap into this ticket. **Operator override at spec review is
welcome** — if the asciinema bootstrap should land in this PR, the
spec needs to grow correspondingly.

## Success Criteria

- **SC-001**: For each of the seven in-scope wizards, a focused
  regression test fails before the new flags are wired and passes
  after, demonstrating exclusion, forced inclusion, the
  contradiction error, and the shortfall-with-excludes error.
- **SC-002**: `./gate.sh` passes at every accepted slice commit.
- **SC-003**: `nix flake check` passes after the changes.
- **SC-004**: A grep over `lib/Amaru/Treasury/Cli/*.hs` and
  `lib/Amaru/Treasury/Tx/*Wizard*.hs` shows every in-scope wizard
  consumes the shared helper module's exclusion/inclusion API
  (no duplicated parser, filter, or contradiction logic).
- **SC-005**: Running any in-scope wizard with no new flag set
  produces byte-identical `intent.json` against the existing golden
  fixtures.
- **SC-006**: A second wizard run on the same wallet, with the
  prior build's UTxO supplied via `--exclude-utxo`, never selects
  that UTxO — reproducing the issue's resolution path without any
  hand-edit of `intent.json`.

## Assumptions

- The `txIn` outref format used in `intent.json` today
  (`TX_HASH#IX`, 64-char lowercase hex + `#` + non-negative integer)
  is the format both flags accept; no lookup against alternative
  formats (TextEnvelope, CBOR-hex outref) is required.
- The intent.json schema already supports an `extraTxIns` array per
  the existing parser
  ([`IntentJSON.hs`](../../lib/Amaru/Treasury/IntentJSON.hs) lines
  299/306) and per the schema
  ([`IntentJSON/Schema.hs`](../../lib/Amaru/Treasury/IntentJSON/Schema.hs)
  line 167). No schema bump is required to emit operator-supplied
  forced inclusions.
- Existing wizard focused-test fixtures and golden `intent.json`
  files remain valid; the new flags are additive and behavior is
  unchanged when neither flag is set.
- The shared helper module belongs under
  `lib/Amaru/Treasury/Wizard/` (sibling to `Wizard/Common.hs`) per
  the "separate modules always" project convention; the exact
  module name is a plan-phase decision.

## Non-Goals

- The auto-detection of in-flight build reservations from the
  `transactions/` archive (the principled fix in #183) is out of
  scope and tracked there. This ticket is the manual escape hatch
  that survives independently of #183.
- An `--include-only-utxo` whitelist flag is out of scope and may
  be filed separately if wanted.
- Auto-population of the exclusion list from chain-side hints
  (e.g., mempool-but-not-confirmed UTxOs) is out of scope (hard to
  do reliably from N2C).
- Treasury-side `--extra-tx-in` (forcing a specific treasury UTxO
  into the build) is out of scope; treasury inputs are selected
  per-scope, and a forced-inclusion semantics for the treasury
  pool needs its own design pass.
- Bootstrapping the mkdocs `asciinema-player` plugin and recording
  a cast for the new flags is recorded as a named follow-up rather
  than absorbed into this PR. **Operator follow-up owner**: the
  ticket author at spec-review time. **Verifiable artifact**: a
  new tracking issue filed before this PR is marked ready, named
  in the PR body, scoped to "adopt asciinema plugin + record
  wizard input-control cast", and linked from
  `docs/swap.md` once it lands.
- Renaming, removing, or repurposing the existing
  `wallet.extraTxIns` field semantics in `intent.json`. The flag
  only populates it; downstream `tx-build` consumption is
  unchanged.
- Cross-wizard behavior changes outside the
  selection/forced-inclusion seam (no change to fee model, asset
  filter, script-vs-pure-ADA classification, scope-owner
  resolution, registry verification, or any other wizard step).
