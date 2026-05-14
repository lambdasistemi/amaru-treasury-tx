# Phase 0 — Research

Design decisions reached during planning. Each entry: **Decision** /
**Rationale** / **Alternatives considered**.

## R1. Scope-attribution field in the SundaeSwap order datum

**Decision**: A pending SundaeSwap order is attributed to the scope whose
**treasury script hash** appears as the destination credential in the order's
inline datum (`Constr 0` at index 3 → `Constr 0` → `Constr 1 [B
treasuryScriptHash]`, mirroring `lib/Amaru/Treasury/Tx/Swap.hs:259`).

**Rationale**: The order datum produced by `swapOrderDatum`
(`Tx/Swap.hs:230–282`) embeds the same cancel-owner policy for every
scope (`AtLeast 2 [core_development, ops_and_use_cases,
network_compliance, middleware]`). So the owner-list field cannot
disambiguate scopes. The destination credential, by contrast, is the
script hash of the **funding** scope's treasury — it is the address USDM
is returned to once SundaeSwap fills the order. That field uniquely
identifies which scope funded the order.

**Alternatives considered**:

- **Match by owner key hash**: rejected — every order datum already contains
  the same cancel-owner key hashes; matching one of them would mean "this
  order was built by the Amaru treasury system", not "this order belongs to scope
  X".
- **Match by funding tx ID**: would work but requires history (the producing
  tx of a pending UTxO is not in the current LSQ snapshot). Same gap as
  settled-swaps; out of scope for v1.
- **Match by destination bech32 address**: same fact, but bech32 brings in
  network-magic-dependent encoding. Hashing once is simpler and is what the
  datum encodes natively.

## R2. SundaeSwap order address is a single project-level constant

**Decision**: The inspect command resolves the SundaeSwap order address from
the existing project constants — the same address `Tx/Swap.hs` uses when
building orders. Not a CLI flag, not a metadata field.

**Rationale**: The order address is the SundaeSwap V3 order-script address on
mainnet, identical for every scope. Adding a CLI flag would expose a foot-gun
(operator types the wrong address and the report silently shows nothing).
Adding a metadata field would mean editing every metadata.json file the
wizards already consume.

**Alternatives considered**:

- `--swap-order-address` CLI flag: rejected, surface area for misconfiguration.
- New metadata field `swap_order_address`: rejected, gratuitous churn.

## R3. Contingency scope and pending orders

**Decision**: The pending-orders subsection renders for every scope including
contingency. For contingency the list is empty (always), and that empty state
renders as an explicit "no pending orders" line for uniformity.

**Rationale**: `SwapWizard.hs:449` rejects `Contingency` at the validation
step, so no swap can ever be built with the contingency treasury as
destination, so the destination-credential filter for contingency always
returns the empty list. The simplest behaviour is: do the same filter for
every scope, no special-casing in the inspect code.

**Alternatives considered**:

- Skip the pending-orders subsection for contingency: rejected — adds a
  case in the renderer for no behavioural difference.

## R4. USDM identification

**Decision**: USDM is identified as the asset whose `(policyId, assetName)`
matches the constants `usdmPolicy` / `usdmToken` already defined in
`lib/Amaru/Treasury/Constants.hs` (referenced by `Tx/Swap.hs` as
`sodUsdmPolicy` / `sodUsdmToken`).

**Rationale**: A single canonical USDM definition lives in the project. The
inspect totals must agree with what the swap wizard treats as USDM, so the
inspect code reads the same constants.

**Alternatives considered**:

- Take USDM identifier from metadata: rejected — current metadata.json does
  not carry it; introducing a field doubles the surface for no gain.

## R5. Backend additions

**Decision**: No Backend extension. The two LSQ queries needed
(`queryUTxOsAtH addr` for both the treasury address and the SundaeSwap order
address; chain-tip query) are already available through `Backend = Provider
IO` (re-exported in `lib/Amaru/Treasury/Backend.hs`). Inspect's IO layer
calls them directly inside `singleShotWithAcquired`.

**Rationale**: The Explore agent's repo map confirmed `queryUTxOsAtH` is in
the Provider interface. No history walk is needed (settled-swaps deferred).
This keeps the change purely additive at the application layer.

**Alternatives considered**:

- Add a `queryUTxOsAt :: Address -> m [Utxo]` wrapper on Backend: rejected
  unless duplication shows up in practice — the existing re-export is
  sufficient.

## R6. `--format` and `--out` semantics

**Decision**:

- `--format` defaults to `human` when stdout is a TTY (via
  `hIsTerminalDevice stdout`), otherwise `json`.
- `--out PATH` always writes the JSON document to PATH. When `--out` is
  set and `--format human`, the human view still renders on stdout. When
  `--out` is set and `--format json`, stdout is silent (the JSON is on
  disk, no need to duplicate to the terminal).
- Setting `--out` while not redirecting stdout and not passing `--format`:
  the auto-detected format applies — TTY → human on stdout + JSON to file;
  pipe → JSON to file, stdout silent (already redirected, presumably).

**Rationale**: Matches what operators already do with other tools — the
"interactive view" lives on the terminal, the "structured artifact" lives in
a file. Treating stdout as the human channel and `--out` as the file channel
keeps the rules orthogonal.

**Alternatives considered**:

- Always echo JSON to stdout when `--out` is set: rejected — clutters the
  human channel and breaks the "single source of truth, in the file" mental
  model.
- Make `--out` imply `--format json`: rejected — taking that option away
  loses the legitimate "save JSON for the bot, show me the summary on
  screen" workflow.

## R7. Error taxonomy

**Decision**: The command distinguishes four exit-code-bearing error
classes:

1. `BadInvocation` (exit 2): unknown scope name, conflicting flags,
   missing `--metadata`. Detected before any I/O.
2. `BadMetadata` (exit 2): metadata.json missing, unreadable, or
   malformed. Detected before contacting the node.
3. `NodeUnreachable` (exit 3): socket path missing, connection refused,
   protocol handshake failure.
4. `NetworkMismatch` (exit 3): the network magic in metadata does not
   match the connected node.

Successful run exits 0. The JSON output does not embed error data —
errors go to stderr in a `key: value` plain-text line.

**Rationale**: Three exit codes is the minimum needed to let scripts
distinguish "bad inputs, fix locally" from "can't reach the node, retry
later" from "wrong network, big problem". Putting errors in the JSON
output makes the schema branchy for no real benefit.

**Alternatives considered**:

- Single exit code 1: rejected — automation needs to tell input errors
  apart from infrastructure errors.
- JSON-shaped errors on stdout: rejected — operators piping the output
  to `jq` would receive structured "error" objects that confuse a
  successful pipeline.

## R8. Test strategy adapted from constitution §V

**Decision**: One golden JSON snapshot under `test/fixtures/treasury-inspect/`
covering one realistic scope (network_compliance), built from a checked-in
metadata.json + canned UTxOs at the two queried addresses. Plus one
schema-consistency test asserting the embedded schema matches the on-disk
`docs/assets/treasury-inspect-schema.json`. Tests written **before**
production code, per the constitution.

**Rationale**: Inspect produces JSON, not CBOR, so the literal "golden CBOR"
clause doesn't apply, but the spirit — test-first, snapshot the real output
shape — is preserved. The schema-consistency test is an internal contract:
if `docs/assets/treasury-inspect-schema.json` drifts from the binary's
embedded schema, the build fails.

**Alternatives considered**:

- Property tests instead of golden snapshot: rejected for v1 — generators
  for realistic UTxO sets are non-trivial and the snapshot test catches
  what we care about (the user-visible output shape).
- Live-node integration test in CI: rejected for v1 — CI runs in a sealed
  sandbox; live-node smoke is operator-run, captured in `docs/inspect.md`.

## R9. Schema generation pattern (mirrors IntentJSON)

**Decision**: A new executable
`app/amaru-treasury-inspect-schema/Main.hs` dumps the embedded JSON Schema
to stdout. The justfile gets two recipes: `update-schema-inspect` (writes
to `docs/assets/treasury-inspect-schema.json`) and an extension to the
existing `schema-check` recipe (diffs the in-tree file against the
binary's output).

**Rationale**: This is exactly the existing `IntentJSON` pattern. Mirroring
it keeps reviewers' mental model singular ("schemas are dumped by an exe,
checked by `just schema-check`").

**Alternatives considered**:

- Inline the schema as a string literal in source: rejected — encoder + AST
  is the existing pattern; consistency wins.
