# Feature Specification: Treasury Inspect

**Feature Branch**: `feat/109-treasury-inspect`
**Created**: 2026-05-14
**Status**: Draft
**Input**: User description from issue [#109](https://github.com/lambdasistemi/amaru-treasury-tx/issues/109): add a `treasury-inspect` subcommand that reports treasury balances and pending SundaeSwap orders for each scope, replacing the manual `cardano-cli query utxo` workflow operators run after firing a swap.

## User Scenarios & Testing *(mandatory)*

### User Story 1 — Confirm a freshly submitted swap landed in the treasury (Priority: P1)

A treasury operator has just submitted a swap or disburse transaction for one
of the scopes (e.g. `network_compliance`). They want a single command that
answers two questions in seconds, against the live node, without learning new
flags: "did the body input get spent?" and "are the swap-order outputs sitting
at the SundaeSwap order address?".

**Why this priority**: This is the entire motivation of the issue. Today
operators run two `cardano-cli query utxo` invocations and mentally diff
against `report.json`. The first command we add must collapse that loop into
one step, or there is no reason to ship this feature.

**Independent Test**: Run `treasury-inspect --metadata mainnet.json --scope
network_compliance` against the live `cardano-mainnet` socket immediately
after the swap submitted as
[`b5716ae9…`](https://cardanoscan.io/transaction/b5716ae98bb41b53c5fa2ebc6e8d5558879dc86d14fb998333e643095c6b233e).
The output names the treasury leftover UTxO at `b5716ae9…#2` and lists the
two pending swap-order outputs sitting at the SundaeSwap order address that
name the `network_compliance` treasury as the swap-payout destination.

**Acceptance Scenarios**:

1. **Given** the metadata.json that the wizards already consume and a
   running cardano-node socket, **When** the operator runs the command for
   one scope, **Then** the output names every treasury-script UTxO for that
   scope, the ADA total, the USDM total (if any), and every pending
   swap-order UTxO whose datum names that scope's treasury as the
   swap-payout destination.
2. **Given** the same inputs but no `--scope`, **When** the operator runs
   the command, **Then** the output covers every scope listed in the
   metadata in a stable order.
3. **Given** the operator passes a `--scope` name that the metadata does
   not contain, **When** the command runs, **Then** it exits with a clear
   error naming the available scopes and does not contact the node.

### User Story 2 — Pipe the report into automation (Priority: P1)

The same operator (or a CI job, or a Slack bot) wants to consume the result
in a script: did the swap settle, are there pending orders, what is the
treasury balance now? They need a stable JSON shape they can rely on.

**Why this priority**: Without machine-readable output the command is
useful only at a terminal. Operators have already asked for a structured
artifact alongside the human view; matching the JSON shape to a checked-in
schema lets downstream tooling (alerts, dashboards) build on it.

**Independent Test**: Run the command with `--format json` (or pipe its
default output, where the format auto-selects JSON because stdout is not a
TTY) and validate the output against `docs/assets/treasury-inspect-schema.json`
with the project's existing schema-check pattern. The JSON contains the same
facts as the human output — treasury UTxOs, totals, and pending swap orders
per scope — plus the chain tip and the deployment anchor (the
scope-owners-NFT UTxO outref pinned in metadata).

**Acceptance Scenarios**:

1. **Given** stdout is not a TTY, **When** the operator runs the command
   without `--format`, **Then** the output is JSON conforming to the
   checked-in schema.
2. **Given** stdout is a TTY, **When** the operator passes `--format json`,
   **Then** the output is the same JSON document a pipe would produce.
3. **Given** the operator passes `--out report.json`, **When** the command
   runs, **Then** the JSON document is written to `report.json` (regardless
   of TTY) and the human summary still goes to stdout when the format is
   human, or stdout is silent when the format is JSON.
4. **Given** the checked-in `docs/assets/treasury-inspect-schema.json`,
   **When** the project's `just schema-check` recipe runs, **Then** the
   schema embedded in the binary matches the file on disk.

### User Story 3 — Confirm "I ran inspect against the right deployment" (Priority: P2)

A treasury operator manages mainnet and preprod deployments from the same
laptop. They want a quick safety net: a one-line line of evidence that the
metadata.json they passed in matches the deployment they expected to inspect.

**Why this priority**: Mis-pointing inspect at the wrong metadata is silent
today. Surfacing the scope-owners-NFT UTxO outref (which the metadata
pins as the deployment anchor) is a cheap belt-and-braces check; it is
not the headline feature but it removes a real foot-gun.

**Independent Test**: Run the command twice — once with `mainnet.json` and
once with `preprod.json` — and confirm the bookkeeping section shows a
different scope-owners-NFT outref each time.

**Acceptance Scenarios**:

1. **Given** any metadata.json, **When** the command runs, **Then** the
   bookkeeping section names the scope-owners-NFT UTxO outref pinned in
   the metadata and the current chain tip (slot and block).

### Edge Cases

- A scope has zero UTxOs at its treasury address: the section MUST render
  with explicit "no UTxOs" wording and the totals MUST be zero, not absent.
- A scope has zero pending swap orders: the section MUST render with
  explicit "no pending orders" wording rather than omitting the section.
- The `contingency` scope cannot fund swaps (the swap wizard rejects
  it). Its pending-orders subsection therefore always renders as
  "no pending orders". The treasury-balance subsection MUST still
  render normally.
- A treasury UTxO holds an unexpected asset (neither ADA nor USDM): the
  output MUST still show ADA and USDM totals and MUST also report the
  unexpected assets so the operator notices.
- The node socket is unreachable, or the network magic in metadata does
  not match the connected node: the command MUST exit non-zero with an
  error that distinguishes "could not connect" from "wrong network".
- The metadata.json is malformed or missing required fields: the command
  MUST exit non-zero before contacting the node, naming the offending
  field.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST add a top-level subcommand `treasury-inspect`
  to the `amaru-treasury-tx` executable.
- **FR-002**: System MUST accept `--metadata PATH` (required) pointing at
  the same metadata.json shape the existing wizards consume.
- **FR-003**: System MUST accept `--scope NAME` to filter the report to a
  single scope; without it the report covers every scope listed in the
  metadata, in the stable order they appear.
- **FR-004**: System MUST accept `--format human|json`. When the flag is
  omitted, the format defaults to `human` if stdout is a TTY and `json`
  otherwise.
- **FR-005**: System MUST accept `--out PATH` to write the JSON document
  to a file. When `--out` is set with `--format json`, stdout MUST be
  silent. When `--out` is set with `--format human`, the human view MUST
  still render on stdout in addition to the JSON document being written
  to PATH.
- **FR-006**: For each selected scope, the report MUST list every UTxO at
  that scope's treasury script address with: tx-id and output index,
  total lovelace, USDM amount (when present), and a list of any other
  assets held.
- **FR-007**: For each selected scope, the report MUST compute total ADA
  and total USDM across the scope's treasury UTxOs.
- **FR-008**: For each selected scope, the report MUST list every UTxO
  at the SundaeSwap order address whose inline datum identifies that
  scope's treasury as the swap-payout destination (the destination
  credential embedded in the order datum is the scope's 28-byte
  treasury script hash). For each pending order, the report MUST show:
  tx-id and output index, ADA in, declared minimum USDM out, and the
  SundaeSwap fee embedded in the datum.
- **FR-009**: The pending-orders subsection MUST render uniformly for
  every scope, including ones that cannot fund swaps today (the
  contingency scope is rejected by the swap wizard, so its pending
  list is always empty). An empty list MUST render as an explicit
  "no pending orders" line rather than being omitted.
- **FR-010**: The report MUST include a bookkeeping section naming
  the current chain tip slot (with the block hash when the Backend
  can supply it; the field is permitted to be absent otherwise) and
  the scope-owners-NFT UTxO outref pinned in the metadata as the
  deployment anchor.
- **FR-011**: System MUST be read-only: no transaction is signed,
  submitted, or written to the chain. No private key material is
  consulted.
- **FR-012**: System MUST exit non-zero with a clear, single-paragraph
  error when: the metadata.json is missing or malformed; the requested
  scope is not in the metadata; the node socket is unreachable; the
  network magic in metadata does not match the connected node.
- **FR-013**: A JSON Schema describing the report MUST be checked in at
  `docs/assets/treasury-inspect-schema.json` and validated by an
  extension of the existing `just schema-check` recipe so the embedded
  and on-disk schemas cannot drift.
- **FR-014**: An operator walkthrough MUST be checked in at
  `docs/inspect.md` and linked from the main docs index.
- **FR-015**: The command MUST default to the project's local-node (N2C)
  backend, in line with the existing wizards.

### Key Entities *(include if feature involves data)*

- **InspectReport**: The full report for one invocation. Names the chain
  tip, the deployment identifier, and a collection of per-scope sections.
- **ScopeSection**: The report for a single scope. Names the scope, its
  treasury script address, its treasury script hash (used to attribute
  pending orders), the list of treasury UTxOs, the totals, and the list
  of pending orders.
- **TreasuryUtxo**: A UTxO at the treasury script address. Names the
  outref, the lovelace, the USDM amount, and any other assets.
- **PendingSwapOrder**: A UTxO at the SundaeSwap order address whose
  inline datum names the scope's treasury script hash as the
  swap-payout destination. Names the outref, the ADA in, the minimum
  USDM out, and the embedded SundaeSwap fee.
- **DeploymentAnchor**: The scope-owners-NFT UTxO outref pinned in the
  metadata.json (the `scope_owners` field — already the project-level
  deployment identity, used by `Report.Identity:152`). Surfaces in the
  bookkeeping section so operators can confirm they inspected the
  deployment they intended.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: An operator who has just submitted a swap can answer "did
  the swap settle?" with one command invocation, replacing the prior
  workflow of two `cardano-cli query utxo` calls plus manual diffing
  against `report.json`.
- **SC-002**: A continuous-integration job can consume the JSON output
  and assert against the checked-in schema without modification each
  time the binary is rebuilt.
- **SC-003**: Running the command against the live `cardano-mainnet`
  node with the production metadata.json — immediately after the swap
  submitted as `b5716ae98bb41b53c5fa2ebc6e8d5558879dc86d14fb998333e643095c6b233e`
  — produces an output that names two pending swap-order outputs and
  the treasury leftover UTxO at the expected outref.
- **SC-004**: An operator who points the command at a different
  metadata.json sees a different scope-owners-NFT outref in the
  bookkeeping section, so misdirected runs against the wrong deployment
  are detectable in seconds.

## Assumptions

- The metadata.json shape consumed by the existing wizards already
  enumerates every scope the inspect command needs to report on, names
  the treasury script address for each scope, and names the
  per-scope treasury script hash that the inspector uses to attribute
  pending swap orders. No new metadata fields are introduced by this
  feature.
- Pending-order attribution uses the destination credential embedded
  in the order's inline datum (the funding scope's treasury script
  hash), not the four-scope authorised-signers list (which is shared
  across every order built by the existing swap wizard).
- The set of scopes the metadata exposes today (CoreDevelopment,
  OpsAndUseCases, NetworkCompliance, Middleware, Contingency) is the
  set the report covers. The "four" in the issue was an over-count; the
  spec follows the metadata.
- USDM is the only non-ADA asset the report calls out by name. Any
  other asset on a treasury UTxO is grouped under a generic "other
  assets" line.
- "Recent settled swaps" detection — the third subsection mentioned in
  the issue — is **out of scope for v1**: the cardano-node-clients
  backend the project uses today does not expose block-walking or
  tx-by-hash lookup, and pulling that primitive in is a larger,
  separate change. v1 ships the treasury and pending-orders subsections
  only. A follow-up issue captures the settled-swaps work.
- Aux-data label 1694 rationale lookup for pending swap orders is also
  **out of scope for v1** for the same reason — surfacing the rationale
  requires fetching the producing transaction's aux-data, which is
  blocked on the same primitive. Pending orders are identified by their
  outref and datum-derived fields only.
- The SundaeSwap order address used to look up pending orders is
  derived from the project's existing constants (the same address the
  swap wizard writes to) and is not configurable at the command line.
- The command runs as a single-shot query against a node the operator
  is already running locally. No persistent state, daemon, or
  background watcher is introduced.
- The deployment anchor surfaced in the bookkeeping section is the
  `scope_owners` outref already pinned in metadata.json — read directly
  from the file, no node round-trip needed. (An earlier draft of this
  spec said "instance NFT policy id"; that field is not in metadata —
  recovering it would have cost a chain query. The outref serves the
  same operator purpose: it is unique per deployment.)

## Out of Scope (v1)

- Recent settled-swaps detection by walking back N blocks.
- Aux-data label 1694 rationale lookup for pending swap orders.
- Cross-network drift checks (mainnet vs preprod side-by-side).
- Historic graph rendering — text and JSON only.
- Off-chain settlement watchers and persistent state of any kind.

## References

- Issue: [lambdasistemi/amaru-treasury-tx#109](https://github.com/lambdasistemi/amaru-treasury-tx/issues/109)
- Downstream consumer: [#116 — swap-cancel command](https://github.com/lambdasistemi/amaru-treasury-tx/issues/116) (blocked-by #109; consumes `pendingOrders[].outref` from this report to drive cancellation tx-build).
- Acceptance smoke tx: [`b5716ae9…`](https://cardanoscan.io/transaction/b5716ae98bb41b53c5fa2ebc6e8d5558879dc86d14fb998333e643095c6b233e)
- Project constitution: `.specify/memory/constitution.md`
