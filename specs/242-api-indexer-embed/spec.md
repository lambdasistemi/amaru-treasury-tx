# Feature Specification: in-process indexer embed inside `amaru-treasury-tx-api`

**Feature Branch**: `feat/242-api-indexer-embed`
**Created**: 2026-05-23
**Status**: Draft
**Input**: GitHub issue [#242](https://github.com/lambdasistemi/amaru-treasury-tx/issues/242) (Slice A of epic [#241](https://github.com/lambdasistemi/amaru-treasury-tx/issues/241))

## Pivot note (carry to plan + tasks)

The issue body frames Slice A around `disburse-wizard`. After
intake interview the actual pilot is the **HTTP service container
`amaru-treasury-tx-api`** (deployed at
<https://amaru-treasury.plutimus.com/>, shipped in
[PR #240](https://github.com/lambdasistemi/amaru-treasury-tx/pull/240)).
Reason: the service is long-running and re-queries the mainnet
node on every request; the wizards are one-shot CLIs where the
per-invocation cost is negligible. Wiring the indexer where it
matters most — the long-running consumer — is the meaningful
proof for the epic invariant *"the production node serves no
scans"*. The issue body will be updated together with the spec
commit; this spec is the source of truth.

## User Scenarios & Testing *(mandatory)*

### User Story 1 — Live dashboard request served without scanning the production node (Priority: P1)

A treasury operator opens
<https://amaru-treasury.plutimus.com/> in a browser, which hits
`GET /v1/treasury-inspect?scope=<name>` against the deployed
`amaru-treasury-tx-api` container. The container computes the
per-scope `InspectReport` by reading the scope's treasury-address
UTxOs and the SundaeSwap order-address UTxOs from an
**in-process embedded indexer** that follows the mainnet chain
into a local RocksDB store; the only call the request issues
against the production node socket is a single cheap
`GetChainPoint` (`nowTip`) for the response's `chain_tip` field.
The response body is byte-identical to the pre-indexer behaviour
for every well-typed field.

**Why this priority**: This is the entire purpose of the slice
under epic #241's "production node serves no scans" invariant.
The dashboard request path is the highest-traffic consumer of
node scans today; replacing it is the meaningful proof.

**Independent Test**: Run the deployed container against a
devnet node with a side N2C-socket trace recorder (e.g.,
`socat` or the project's existing trace mechanism). Issue
`curl /v1/treasury-inspect?scope=middleware`. Assert: response
status 200; response body deep-equal to the pre-indexer
behaviour for the same chain state; the captured socket trace
contains **zero** `GetUTxOByAddress` queries during the request
window.

**Acceptance Scenarios**:

1. **Given** the container has booted, the indexer has reached
   readiness (`processed_slot ≥ tip − lagThreshold`), and the
   node is healthy, **When** an operator issues
   `GET /v1/treasury-inspect?scope=middleware`, **Then** the
   response status is 200 and the body deep-equals what the
   pre-#242 implementation would have returned for the same
   chain state.
2. **Given** the container is serving normally, **When** an HTTP
   request to `/v1/treasury-inspect` is issued, **Then** the
   captured N2C socket trace for that request contains exactly
   one `GetChainPoint` call and zero `GetUTxOByAddress` /
   `GetUTxOByTxIn` calls.
3. **Given** the container is serving normally, **When** the
   same request is repeated against four distinct scopes
   sequentially, **Then** the indexer is queried four times via
   `snapshotAt` (one per scope address) and the swap-order
   address is queried at most once per request — never via N2C.

---

### User Story 2 — Container boot waits for indexer readiness; drift makes the service fail-closed (Priority: P1)

A redeploy or cold-boot of the container starts the embedded
indexer, which catches up from its starting slot (see FR-006) to
the node's current tip. **Warp does not bind its listening
port** until the indexer's `processed_slot` is within
`lagThreshold` slots of the node's tip. During steady-state
serving, if the indexer's lag exceeds the threshold for any
reason (node restart, follower stall, RocksDB I/O storm), every
endpoint returns HTTP 503 with a structured body naming the lag
until readiness is restored.

**Why this priority**: Equal priority to Story 1 because the
"strict improvement over the existing cache" claim depends on
not silently serving stale data after a rollback or follower
stall. Without a fail-closed gate the indexer is a *correctness
regression* relative to the cache, which at least refreshes on
a fixed tick.

**Independent Test**:

- **Boot gate**: start the container against a node that is
  itself behind tip; assert the container's `:8080` port refuses
  TCP connections until the indexer reaches readiness, then
  begins accepting them.
- **Drift gate**: with the container serving normally, kill the
  upstream cardano-node and wait long enough for the indexer's
  lag to exceed `lagThreshold` slots; assert every endpoint
  returns 503 with body shape
  `{processed_slot, tip_slot, lag_slots, threshold_slots}`.
  Restart the node; assert 200 responses resume once the
  indexer catches up.

**Acceptance Scenarios**:

1. **Given** a cold boot of the container, **When** the indexer
   has not yet reached `processed_slot ≥ tip − lagThreshold`,
   **Then** the container does not bind its HTTP listener and
   TCP connections to `:8080` are refused.
2. **Given** the indexer reaches readiness, **When** warp binds,
   **Then** `GET /v1/version` returns 200 and the build identity.
3. **Given** the service is serving normally, **When** the
   indexer's lag exceeds `lagThreshold` slots, **Then** every
   endpoint (including `/v1/version`) returns 503 with body
   `{"error":"indexer_lagging","processed_slot":N,
   "tip_slot":M,"lag_slots":K,"threshold_slots":T}`.
4. **Given** the service is returning 503 due to lag, **When**
   the indexer's lag returns below `lagThreshold`, **Then**
   subsequent requests return 200 again without operator
   intervention.

---

### User Story 3 — Operator restarts the container and the indexer resumes from RocksDB (Priority: P2)

After a container restart (image bump, host reboot, OOM kill),
the embedded indexer reopens its RocksDB volume, finds the most
recent applied slot, and resumes chain-sync from a resume point
derived from on-disk state — not from genesis, not from the
metadata's pinned start slot. Boot is fast (seconds to a few
minutes) instead of the multi-hour cold-sync that would happen
if the RocksDB volume were lost.

**Why this priority**: P2 because P1 (Story 2) already covers
the readiness contract; this story names the persistence layer
required to make that contract usable in production.

**Independent Test**: Run the container until ready; record the
indexer's `processed_slot`. Stop the container, restart it
against the same RocksDB volume. Assert that boot reaches
readiness in less time than a cold-sync from the metadata
start slot would have taken, and that `processed_slot` resumes
within `k` slots of where it left off.

**Acceptance Scenarios**:

1. **Given** the container has previously run and its RocksDB
   volume is intact, **When** the container restarts, **Then**
   the indexer reopens the volume and resumes from a recent
   slot (per `getResumePoints`).
2. **Given** the RocksDB volume is empty (fresh install or
   volume wipe), **When** the container starts on mainnet,
   **Then** the indexer starts from the configured starting
   slot (FR-006) and only the slots after that are scanned.
3. **Given** chain rollback during follower operation,
   **When** the rollback is observed by the chain-sync client,
   **Then** the indexer's `rollbackTo` invariants apply and a
   subsequent `snapshotAt` reflects post-rollback state.

---

### Edge Cases

- **Node socket missing at boot.** Container fails with a clear
  error and exit code; does not bind the HTTP port. Distinct
  exit code from "indexer corrupt" so operators can triage.
- **RocksDB volume corrupt or wrong on-disk format.** Container
  fails closed with a clear log line naming the path. Operator
  procedure (in docs deliverable) is "wipe the volume, restart,
  accept the cold-sync".
- **Indexer-internal exception in the follower thread.** The
  follower's exception propagates to the main thread, the
  container exits non-zero, container runtime restarts it. The
  service does not enter a half-serving zombie state.
- **Indexer lag spike on epoch boundary or rollback.** Lag gate
  kicks in (FR-008), 503 for the duration, no operator action
  required if lag recovers within the container runtime's
  restart-loop budget.
- **Two requests served concurrently from the same indexer
  handle.** `snapshotAt` is thread-safe (`STM`-backed in the
  upstream library); no locking is required in handlers.
- **Old cardanoscan / dashboard frontends sending no `Accept`
  header during 503.** 503 body is `application/json`; the
  dashboard frontend is in scope for confirming it surfaces the
  lag fields legibly. Per-frontend display polish belongs to a
  separate downstream ticket if needed.

## Requirements *(mandatory)*

### Functional Requirements

**In-process indexer integration**

- **FR-001**: The `amaru-treasury-tx-api` container MUST embed
  the `utxo-indexer-lib` chain-following indexer in the same OS
  process as the warp HTTP server.
- **FR-002**: At boot, the container MUST open a single
  `IndexerHandle` via `withRocksDBIndexer <db-path>` and pass
  that same handle into both (a) a background chain-sync
  follower thread and (b) the servant `Handlers` record consumed
  by `mkApplication`. There MUST be no NDJSON server, no socket,
  and no IPC between the indexer and the request handlers.
- **FR-003**: The container MUST take its node socket path,
  network magic, RocksDB directory path, and lag threshold as
  CLI flags (extending the existing flag set:
  `--socket`, `--metadata`, `--manifest`, `--build-identity`,
  `--static`, `--bind`). New flags: `--indexer-db`,
  `--indexer-start-slot` (optional override), and
  `--indexer-lag-threshold-slots` (default to be set in plan
  phase, surfaced in docs).

**HTTP request hot path**

- **FR-004**: For every request to `GET /v1/treasury-inspect`,
  the per-scope UTxO list and the swap-order UTxO list MUST be
  computed by calling `snapshotAt` on the embedded indexer
  handle. The container MUST NOT issue `GetUTxOByAddress`
  against the node socket for either source.
- **FR-005**: For every request to `GET /v1/treasury-inspect`,
  the response's `chain_tip` field MUST continue to be sourced
  from a single `GetChainPoint` (`nowTip`) call on the existing
  N2C `Backend` session. The N2C session stays open across
  requests as it does today.

**Cold-boot starting point**

- **FR-006**: When the RocksDB volume is empty, the indexer MUST
  start chain-sync from a configured **mainnet starting slot**
  that is recent enough to skip irrelevant pre-deployment
  history but conservative enough to include every treasury
  deployment transaction. The starting slot's exact value and
  its source (constant in `Amaru.Treasury.Constants`, optional
  metadata.json field, or CLI flag) is an **open seam for the
  plan phase** — see §"Open seams for plan phase" below.
- **FR-007**: When the RocksDB volume is non-empty, the indexer
  MUST resume from the on-disk state via `getResumePoints` and
  MUST NOT re-sync from FR-006's starting slot.

**Readiness gate**

- **FR-008**: At boot, warp MUST NOT bind its listening socket
  until the indexer reports `processed_slot ≥ node_tip_slot −
  lagThreshold`. Until then the container holds an internal
  ready signal `Pending`.
- **FR-009**: During steady-state operation, if any handler
  observes `node_tip_slot − processed_slot > lagThreshold`, it
  MUST short-circuit and return HTTP 503 with body
  `{"error":"indexer_lagging","processed_slot":<N>,
  "tip_slot":<M>,"lag_slots":<K>,"threshold_slots":<T>}`. This
  applies to **every** endpoint, including `/v1/version` (the
  fail-closed contract is service-wide).
- **FR-010**: When `lag_slots` returns below `lagThreshold`,
  subsequent requests MUST return 200 without operator
  intervention or container restart.

**Cache removal (b0ad2b77 server-side cache)**

- **FR-011**: The per-scope `IORef`-backed `InspectCache` and
  its background `refreshLoop` (introduced in
  [b0ad2b77](https://github.com/lambdasistemi/amaru-treasury-tx/commit/0c1d7e6121db8cc045bb912db200236b04ea6af7))
  MUST be removed in this slice. The indexer is a strict
  improvement: in-process `snapshotAt` is microsecond-fast,
  rollback-aware, and removes the stale-while-revalidate
  correctness risk after a chain rollback.
- **FR-012**: The handler MUST compute the `InspectReport` per
  request from current indexer state — there MUST be no
  in-memory `IORef` cache layered between the handler and
  `snapshotAt`.

**Container packaging**

- **FR-013**: `nix/docker.nix` MUST mount or declare a
  persistent volume at the in-image path used by the indexer's
  RocksDB store. The volume MUST be configured for read-write
  and MUST persist across container restarts. The exact path
  and compose-file binding will be set in the plan phase.
- **FR-014**: `deploy/compose/amaru-treasury/docker-compose.yaml`
  and the dev variant under `deploy/compose/amaru-treasury-dev/`
  MUST be extended with the RocksDB volume binding. The host
  path is a deployment-environment concern (named in the docs
  deliverable, not in the spec).
- **FR-015**: Cabal MUST pin `cardano-node-clients` via
  `source-repository-package` to the branch carrying the paired
  upstream PR (see FR-016) for the duration of the review. The
  pin MUST be moved to the merged upstream commit hash before
  this PR is marked ready.

**Upstream paired change in `cardano-node-clients`**

- **FR-016**: A paired PR in
  [`lambdasistemi/cardano-node-clients`](https://github.com/lambdasistemi/cardano-node-clients)
  MUST expose a `withChainSyncFollower` resource action (or
  equivalent) that runs the chain-sync follower against a
  caller-supplied `IndexerHandle` *without* starting the
  NDJSON server thread that `runDaemon` currently bundles. The
  exact signature is a plan-phase decision but the contract is:
  "follower only, no protocol surface". This PR is opened only
  if the survey-identified gap genuinely blocks the embed; the
  spec does not pre-commit to the API shape.

**Forbidden surface changes**

- **FR-017**: This slice MUST NOT change the JSON wire shape of
  `GET /v1/treasury-inspect`, `GET /v1/recent-txs`, or
  `GET /v1/version` for the success path. The only contractual
  change is the 503 body added in FR-009.
- **FR-018**: This slice MUST NOT introduce new HTTP endpoints.
  New endpoints (`/v1/history`, indexer-introspection) are
  later-slice scope (#243 / #248).
- **FR-019**: This slice MUST NOT touch wizard code paths
  (`disburse-wizard`, `withdraw-wizard`, `reorganize-wizard`,
  `swap-wizard`, `swap-cancel`). Their move to the indexer is
  Slice F (#247).

### Key Entities *(include if feature involves data)*

- **`IndexerHandle`** (from `Cardano.Node.Client.UTxOIndexer.Indexer`):
  the shared resource the follower writes to and the handlers
  read from. Created via `withRocksDBIndexer`. Thread-safe.
- **Readiness signal**: an in-process `TVar` (or equivalent) the
  follower updates with `processed_slot` and `tip_slot` after
  each batch; the handlers consult it to decide 200 vs 503.
- **`lagThreshold`**: configured slot delta beyond which the
  service fail-closes. CLI flag, no default value committed
  in this spec; plan phase sets one.

## Deliverables *(mandatory)*

For every artifact below, the table also names the canonical
peer surface(s) this ticket extends and confirms this PR ships
to all of them. Peer surfaces verified empirically with
`git grep -l '<peer>' .github/ flake.nix nix/ docs/ README.md`.

### Code artifacts

| # | Artifact | Peer surface it joins | Wire-up obligation |
|---|---|---|---|
| D1 | New module `lib/Amaru/Treasury/Api/Indexer.hs` exposing the runner: `withApiIndexer :: IndexerConfig -> (IndexerHandle -> Readiness -> IO a) -> IO a` (signature to be finalized in plan) | Lives next to `Amaru.Treasury.Api.Server` and is consumed by `app/amaru-treasury-tx-api/Main.hs` | New exposed-module in cabal under `library` `exposed-modules`. |
| D2 | Edits to `app/amaru-treasury-tx-api/Main.hs` to (a) open the indexer at boot, (b) gate warp bind on readiness, (c) wire the handle into `Handlers`, (d) **remove** `InspectCache`, `refreshLoop`, `cachedInspect`, `refreshAll`, `refreshIntervalSeconds`, and the background `withAsync` worker | The same `Main.hs` PR #240 introduced | Replaces dead code; no other consumer. |
| D3 | Edits to `lib/Amaru/Treasury/Api/Server.hs` to (a) accept `IndexerHandle` and `Readiness` in `Handlers`, (b) compute reports per-request from indexer + `nowTip` | Same module PR #240 introduced | One-shot refactor; no parallel consumer. |
| D4 | New cabal stanza dependencies on the `utxo-indexer-lib` sublibrary | `amaru-treasury-tx.cabal` `library` and the `amaru-treasury-tx-api` `executable` stanzas | Plan phase decides whether the library is depended on by `library` (re-exported via `Amaru.Treasury.Api.Indexer`) or by the `executable` directly. |
| D5 | Upstream paired PR in `cardano-node-clients` exposing `withChainSyncFollower` (if survey-identified gap holds) | The existing `runDaemon` in `lib-utxo-indexer/.../Daemon.hs` | Refactor: extract follower from `runDaemon`, keep `runDaemon` working for the NDJSON daemon binary. |
| D6 | `cabal.project` SRP pin update to the upstream PR branch, then to the merged commit hash before "ready" | `cabal.project` (existing CHaP + SRP block) | Two PR-life changes; bookkeeping noted in this PR's body. |

### Verification artifacts

| # | Artifact | Peer surface it joins | Wire-up obligation |
|---|---|---|---|
| V1 | Unit suite under `test/unit/Amaru/Treasury/Api/IndexerSpec.hs` covering (a) the runner module's bring-up, (b) the readiness predicate, (c) lag-gate transitions | `test/unit` (existing hspec) | New `Spec.hs` discovery; will appear in `just unit`. |
| V2 | **Live-boundary smoke** under `test/devnet` (or extension to it): boot the API container against a devnet node with N2C-socket trace recording, issue `GET /v1/treasury-inspect`, assert zero `GetUTxOByAddress` in the captured trace and 200 response | `test/devnet` (existing) | New hspec spec; `gate.sh` extended to run it. See `live-boundary-smoke` skill. |
| V3 | `./gate.sh` extension committing the new unit pattern and the devnet smoke | The branch's existing `gate.sh` | One `chore: extend gate.sh with <pattern>` commit per extension. |

### Container + deployment artifacts

| # | Artifact | Peer surface it joins | Wire-up obligation |
|---|---|---|---|
| C1 | `nix/docker.nix` edit declaring the RocksDB volume in-image path and ensuring it is on a writable layer | The existing `streamLayeredImage` in `nix/docker.nix` | Same file PR #240 introduced. |
| C2 | `deploy/compose/amaru-treasury/docker-compose.yaml` edit binding a named volume for RocksDB | The existing compose file from PR #240 | Same file. |
| C3 | `deploy/compose/amaru-treasury-dev/docker-compose.yaml` edit for the dev variant | The existing dev compose file from PR #240 | Same file. |

### Documentation artifacts

| # | Artifact | Peer surface it joins | Wire-up obligation |
|---|---|---|---|
| Doc1 | Prose doc page at `docs/api-container-indexer.md` (or equivalent under the existing docs tree) describing the embed model, CLI flags, RocksDB volume sizing guidance, readiness probe semantics, and operator procedure for "wipe RocksDB and re-sync" | The existing mkdocs surface under `docs/` (look at the existing docs tree for the right home) | New `docs/` page + `mkdocs.yml` nav entry. |
| Doc2 | **Asciinema cast** at `docs/assets/asciinema/amaru-treasury-tx-api.cast` showing the container boot (readiness gate), a steady-state `curl /v1/treasury-inspect`, and a forced lag-503 with the JSON body. Recorded with the lambdasistemi `dev-assets/asciinema/compress` flake; embedded in Doc1 via the `asciinema-player` mkdocs plugin block | First asciinema cast in this repo's `docs/assets/asciinema/` (verify via `find docs/assets/asciinema/ -name '*.cast' 2>/dev/null \| head`). If empty, ship the `mkdocs.yml` plugin registration and the directory bootstrap together with this PR (see resolve-ticket Deliverables enumeration rule for executables) | New file + plugin wiring if absent. **Recording scope**: cast focuses on the container's flag surface + boot semantics + endpoint behaviour. Prerequisites (a running node, a RocksDB volume) acknowledged via a single preamble comment, not demonstrated. No secrets recorded. |
| Doc3 | `mkdocs.yml` MUST make `site_url` env-overridable (`!ENV [MKDOCS_SITE_URL, "<production-url>"]`) and the docs CI workflow MUST set `MKDOCS_SITE_URL` to the preview prefix on PRs, so the asciinema-player `.cast` URL resolves on preview deploys | `mkdocs.yml` + the deploy-docs GitHub Actions workflow | If the env-overridable pattern is not yet adopted, ship it as part of this PR. |
| Doc4 | `CHANGELOG.md` entry under the next release section describing the user-visible change ("dashboard requests now served from in-process indexer; no node scans on the request path") | The existing `CHANGELOG.md` (release-please managed) | One conventional-commit entry; release-please picks it up. |

### Issue body refresh

| # | Artifact | Peer surface it joins | Wire-up obligation |
|---|---|---|---|
| I1 | Updated GitHub issue body for #242 replacing the wizard framing with the API-container framing; old wizard text moved to a "history" note at the bottom | GitHub issue #242 itself | `gh issue edit 242 --body-file …` after spec is approved. |

## Command-Recovery Rule

Per resolve-ticket, the shipped operator command is the P1 user
story; smoke proves the command path; smoke does not replace it.

The operator command:

```bash
amaru-treasury-tx-api \
  --bind 0.0.0.0:8080 \
  --socket /n2c/node.socket \
  --metadata /etc/amaru-treasury/metadata.json \
  --manifest /etc/amaru-treasury/recent-txs.json \
  --build-identity /etc/amaru-treasury/build-identity.json \
  --static /var/lib/amaru-treasury/static \
  --indexer-db /var/lib/amaru-treasury/indexer-rocksdb \
  --indexer-lag-threshold-slots <T>
```

- The command exists in the shipped `amaru-treasury-tx-api`
  executable (PR #240 introduced the binary; this PR extends
  its flag set).
- The command's request handlers call production modules:
  `Amaru.Treasury.Api.Server.mkApplication`,
  `Amaru.Treasury.Cli.TreasuryInspect.runInspectFromBackend` (or
  its post-#242 successor), and `Amaru.Treasury.Api.Indexer`
  (new).
- The smoke layer (V2) invokes the same binary; it asserts the
  N2C trace contains no `GetUTxOByAddress` for the request.
  Smoke is evidence, not a substitute, for the binary.

## Live-boundary smoke (mandatory acknowledgement)

This slice changes the request hot-path's chain-read boundary.
Per resolve-ticket's plan-review checklist:
*"What system boundary does this exercise that the unit suite
cannot?"* — the chain-sync follower writing into RocksDB
concurrently with `snapshotAt` reads from the same handle,
plus the N2C-vs-indexer dispatch decision in the handler.

V2 (the devnet smoke) is the in-gate proof; no operator
follow-up is acceptable as a substitute for V1+V2.

## Open seams for plan phase

These are decisions deliberately deferred from spec to plan:

1. **Mainnet starting slot source.** Three candidates:
   (a) constant in `Amaru.Treasury.Constants` (e.g.,
   `mainnetIndexerStartSlot :: SlotNo`);
   (b) new field per-treasury in
   `pragma-org/amaru-treasury` metadata.json (requires upstream
   change);
   (c) operator-supplied `--indexer-start-slot` flag with no
   default. Spec calls FR-006 satisfied by ANY of these; plan
   picks one. Constants is the working assumption since the
   user's intake answer said "baked into metadata.json" and
   metadata.json today carries `deployed_at` TxIns but no slot.
2. **`lagThreshold` default value.** A function of mainnet block
   time (~20s) and the dashboard's auto-refresh cadence (30s).
   Plan picks a default with a comment that links the
   reasoning to a measurable acceptance.
3. **`Handlers` shape after cache removal.** Whether to thread
   `IndexerHandle` + `Readiness` directly into `Handlers`, wrap
   them in an `ApiEnv` record, or build an `InspectSource`
   typeclass for future swap. Plan picks the simplest shape
   that the slice loop can land in 1–2 commits.
4. **Upstream PR API.** Exact shape of `withChainSyncFollower`
   (bracket vs spawn-and-link, error contract, observability
   tap). Decided during the upstream PR's own design pass.

## Out of scope (carry to plan + tasks)

- Wizards consuming the indexer (Slice F, #247).
- Tx-history indexer or `tx-history-indexer-lib` (Slice B, #243).
- New HTTP endpoints (Slice G, #248).
- Multi-tenant onboarding (Slice H, #249).
- Mainnet-grade backfill performance tuning beyond "boots in a
  reasonable time on a clean volume from the configured start
  slot".
- Pruning of RocksDB beyond what the upstream indexer library
  exposes by default.
- Frontend changes to surface the 503 body legibly. If the
  current dashboard renders 503s as a generic error, that's
  acceptable for this slice; a polish ticket can refine it.
