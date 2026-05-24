# Implementation Plan: in-process indexer embed inside `amaru-treasury-tx-api`

**Branch**: `feat/242-api-indexer-embed` | **Date**: 2026-05-24
**Spec**: [spec.md](./spec.md) | **Ticket**: [#242](https://github.com/lambdasistemi/amaru-treasury-tx/issues/242) | **Parent**: epic [#241](https://github.com/lambdasistemi/amaru-treasury-tx/issues/241)
**Paired upstream PR**: TBD in [`lambdasistemi/cardano-node-clients`](https://github.com/lambdasistemi/cardano-node-clients) — opened during Slice 0.

## Summary

Embed `utxo-indexer-lib` inside the long-running `amaru-treasury-tx-api`
binary that serves <https://amaru-treasury.plutimus.com/>. A
chain-sync follower runs in a background thread and writes UTxO
events into a RocksDB store on a persistent container volume.
The warp HTTP handlers query the same `IndexerHandle` directly
via `snapshotAt`, eliminating per-request `GetUTxOByAddress`
calls against the production node socket. Boot blocks until the
indexer is caught up; runtime lag spikes fail-close every
endpoint with a structured 503 body. The 30 s TTL `IORef` cache
introduced in [0c1d7e61](https://github.com/lambdasistemi/amaru-treasury-tx/commit/0c1d7e6121db8cc045bb912db200236b04ea6af7)
is removed in the same slice — the indexer is a strict
improvement (microsecond reads, rollback-aware, no
stale-while-revalidate correctness risk after a chain rollback).

## Technical Context

**Language/Version**: Haskell GHC 9.6 (matches `cardano-node-clients`).
**Primary Dependencies (Haskell, new)**:

- `utxo-indexer-lib` sublibrary from `cardano-node-clients` (CHaP +
  SRP pin; see Slice 0).
- `stm` for the readiness `TVar`.
- `async` (already present transitively) for the follower thread.

**Primary Dependencies (Haskell, existing)**: `servant-server`,
`warp`, `wai`, `aeson`, `cardano-node-clients` Provider/Submitter,
`optparse-applicative`.

**Storage**: RocksDB at `/var/lib/amaru-treasury/indexer-rocksdb`
inside the container, backed by a persistent Docker named
volume `amaru-treasury-indexer`. Cold-boot starting slot:
constant in `Amaru.Treasury.Constants`, operator-overridable
via `--indexer-start-slot`. See [research.md §1](./research.md).

**Testing**: Hspec unit suite under
`test/unit/Amaru/Treasury/Api/IndexerSpec.hs`. Live-boundary
devnet smoke under `test/devnet` that boots the full container
against a devnet node + N2C socket trace recorder and asserts
zero `GetUTxOByAddress` on the request path. See
[research.md §6](./research.md).

**Target Platform**: Linux x86_64 production container (Docker
via `streamLayeredImage`); developer machines on Linux/macOS via
`nix develop`.

**Project Type**: long-running web service.

**Performance Goals**: per-request `snapshotAt` ≤ 1 ms across the
four scope addresses + swap-order address (microsecond-class RocksDB
prefix scans). Cold-boot to readiness from a clean volume on
mainnet: ≤ 30 min (function of the chosen starting slot and
network bandwidth, not of indexer code).

**Constraints**:

- Container filesystem outside `/var/lib/amaru-treasury` stays
  read-only.
- Production node socket must continue to see zero
  `GetUTxOByAddress` from this binary after the slice lands.
- No JSON wire-shape changes to the success paths of
  `/v1/treasury-inspect`, `/v1/recent-txs`, `/v1/version`.

**Scale/Scope**: one container instance per deployment; one
RocksDB volume; one chain-sync follower thread; ~4 scope
addresses + 1 swap-order address queried per request.

## Constitution Check

| Principle | Verdict | Notes |
|---|---|---|
| I. Faithful port of bash recipes | N/A | No tx authoring. |
| II. Pure builders, impure shell | Pass | Indexer lives in the impure shell (`Amaru.Treasury.Api.Indexer`, new); pure modules untouched. |
| III. Pluggable data source, local-node default | Pass | Indexer is a *local* cache of node state, fed by the existing N2C chain-sync. The default operator deployment still uses one local node; the new module does not introduce a hosted/third-party backend. |
| IV. Build, never sign or submit | Pass — by exclusion | API binary doesn't author or submit txs. |
| V. Test-first with golden CBOR fixtures | Pass (adapted) | No CBOR change. RED-first unit covers the readiness predicate + handler-on-indexer path; live-boundary smoke covers the zero-`GetUTxOByAddress` claim. Existing CBOR goldens stay green untouched. |
| VI. Hackage-ready Haskell | Pass | New module with Haddock on every export; fourmolu 70-col; `-Werror`; clean `cabal check`. |
| VII. Label-1694 metadata: bash parity | N/A | No metadata authoring. |
| VIII. IPFS-anchored disbursement evidence | N/A | No disburse here. |

No violations → Complexity Tracking table omitted.

## Project Structure

### Documentation (this feature)

```text
specs/242-api-indexer-embed/
├── spec.md
├── plan.md
├── research.md          # Phase 0 — design decisions for the open seams
├── data-model.md        # types added by Amaru.Treasury.Api.Indexer
├── quickstart.md        # operator runbook (deploy → verify readiness → smoke)
├── contracts/
│   └── api-extension.md # new CLI flags, 503 body schema, no-success-shape-change attestation
└── tasks.md             # produced by speckit-tasks (next phase)
```

### Source code (added/edited by this slice)

```text
lib/Amaru/Treasury/Api/
├── Indexer.hs           # NEW — runner module, readiness type, lag predicate
└── Server.hs            # EDIT — handlers now take IndexerHandle + Readiness

lib/Amaru/Treasury/
└── Constants.hs         # EDIT — add mainnetIndexerStartSlot :: SlotNo

app/amaru-treasury-tx-api/
└── Main.hs              # EDIT — add CLI flags, open indexer at boot,
                         #   gate warp bind on readiness, REMOVE
                         #   InspectCache + refreshLoop + cachedInspect +
                         #   refreshAll + refreshIntervalSeconds +
                         #   background withAsync worker

test/unit/Amaru/Treasury/Api/
└── IndexerSpec.hs       # NEW — readiness predicate, lag-gate transitions,
                         #   handler-with-indexer integration (no node)

test/devnet/Amaru/Treasury/Api/
└── IndexerSmokeSpec.hs  # NEW — live-boundary smoke (boots the binary,
                         #   N2C trace assertion, hit /v1/treasury-inspect)

nix/
└── docker.nix           # EDIT — declare RocksDB volume mount point

deploy/compose/amaru-treasury/
└── docker-compose.yaml  # EDIT — bind named volume amaru-treasury-indexer

deploy/compose/amaru-treasury-dev/
└── docker-compose.yaml  # EDIT — same, dev variant

docs/
├── api-container-indexer.md            # NEW — operator doc page
└── assets/asciinema/
    └── amaru-treasury-tx-api.cast      # NEW — boot + curl + lag-503 demo

mkdocs.yml                              # EDIT (if needed) —
                                        #   site_url env-overridable,
                                        #   asciinema-player plugin block,
                                        #   docs/api-container-indexer.md
                                        #   in nav

cabal.project                           # EDIT — SRP pin on
                                        #   cardano-node-clients
                                        #   (branch during review,
                                        #   merged commit at "ready")

amaru-treasury-tx.cabal                 # EDIT — add Amaru.Treasury.Api.Indexer
                                        #   to library exposed-modules; add
                                        #   utxo-indexer-lib dependency to
                                        #   library + amaru-treasury-tx-api
                                        #   executable; add new test stanzas
                                        #   if needed

CHANGELOG.md                            # EDIT — release-please-managed entry
```

### Paired upstream change (separate PR in `cardano-node-clients`)

```text
cardano-node-clients/lib-utxo-indexer/lib/Cardano/Node/Client/UTxOIndexer/
├── Daemon.hs            # EDIT — refactor runDaemon to use
│                        #   withChainSyncFollower
└── Follower.hs          # NEW — extracted follower (bracketed resource
                         #   with caller-owned IndexerHandle, exposes
                         #   FollowerHandle for readiness polling)
```

## Slice plan (vertical, bisect-safe)

Per resolve-ticket, every behavior-changing slice ships as ONE
bisect-safe commit with a `Tasks: T###` trailer. Slices are
ordered so the build is green at every commit and the operator
behavior is well-defined at every commit (no half-wired
indexer).

The downstream PR's slices below depend on the upstream PR
being either (a) merged, or (b) opened with a stable branch we
SRP-pin to. Slice 0 covers either path.

### Slice 0 — Upstream `withChainSyncFollower` (paired PR)

**Repo**: `lambdasistemi/cardano-node-clients`.
**Shape**: one commit in the upstream PR that extracts the
chain-sync follower from `runDaemon` into a bracketed
`withChainSyncFollower` resource action, leaving `runDaemon`
re-implemented in terms of it. Daemon binary behavior unchanged;
upstream tests (incl. the reconnect e2e) stay green.

**RED**: extend the existing daemon unit suite (or add a new
spec) that calls `withChainSyncFollower` directly without
starting the NDJSON server, asserts the follower reaches
readiness against a fixture chain-sync server, and tears down
cleanly.

**GREEN**: extract; re-implement `runDaemon` on top of it.

**Downstream gate**: this PR's `cabal.project` SRP pin moves
from `main` to the upstream PR's branch. Re-pinned to the
merged commit hash before "ready". The downstream PR's body
links the upstream PR (T-stamped).

**Tasks**: T001 (upstream extract + RED + GREEN). Tracked in
the downstream `tasks.md` as a single bookkeeping entry; the
real review happens upstream.

### Slice 1 — `Amaru.Treasury.Api.Indexer` runner module

**RED**:
`test/unit/Amaru/Treasury/Api/IndexerSpec.hs` — open a tmpfs
RocksDB, start `withApiIndexer` against an in-memory chain-sync
fixture, observe readiness transitions (`Pending` → `Ready` →
`Lagging` → `Ready`). Asserts the lag predicate and the
`Readiness` `TVar` updates fire on `applyAtSlot` boundaries.

**GREEN**: implement
`lib/Amaru/Treasury/Api/Indexer.hs`:

```haskell
data IndexerConfig    -- db path, socket, magic, start slot, lag threshold
data Readiness        -- processed_slot, tip_slot, lag_slots, last update time
data ApiIndexer       -- handle bundle: IndexerHandle + Readiness TVar

withApiIndexer
  :: IndexerConfig
  -> (ApiIndexer -> IO a)
  -> IO a

waitReady   :: ApiIndexer -> IO ()         -- block until first Ready
checkReady  :: ApiIndexer -> IO ReadyState -- snapshot for handler use
snapshotAt  :: ApiIndexer -> Address -> IO [(TxIn, TxOut)]
```

This slice does NOT wire the runner into Main yet — the module
compiles, is unit-tested, but no production code path uses it.
Build green; existing behavior of the API container preserved.

**Tasks**: T002 (RED), T003 (GREEN). Folded into one commit
per resolve-ticket's "if RED and GREEN are listed separately,
the tasks must say how they fold". The commit subject:
`feat(242): Amaru.Treasury.Api.Indexer runner + readiness gate`.

### Slice 2 — Wire indexer into `Handlers`, remove the IORef cache, add CLI flags

**RED**: extend `IndexerSpec.hs` (or new
`HandlersIndexerSpec.hs`) — given a stub `ApiIndexer` populated
with a fixture UTxO set + the existing `nowTip backend` mocked,
assert `inspectScope` returns the same `InspectReport` the
pre-cache implementation would have returned for the same chain
state.

**GREEN**:

1. Extend `Amaru.Treasury.Api.Server.Handlers` with
   `IndexerHandle` + `Readiness` (or wrap them in an `ApiEnv`
   record — see [research.md §3](./research.md)).
2. Rewrite the inspect handler to call `snapshotAt apiIdx
   scopeAddr` + `snapshotAt apiIdx swapAddr` instead of going
   through the IORef cache.
3. Delete from `app/amaru-treasury-tx-api/Main.hs`:
   `type InspectCache`, `refreshIntervalSeconds`, `cachedInspect`,
   `refreshAll`, `refreshLoop`, the `withAsync` worker, the
   `cache <- newIORef Map.empty` line, the `Handlers
   { hInspect = cachedInspect cache … }` wiring.
4. Add CLI flags to `Main.hs`:
   `--indexer-db PATH` (required),
   `--indexer-lag-threshold-slots NAT` (default per
   [research.md §2](./research.md)),
   `--indexer-start-slot SLOT` (optional override).
5. Open `withApiIndexer` at boot; gate warp bind on
   `waitReady`; thread the `ApiIndexer` into `Handlers`.
6. Add the 503-on-drift middleware (or per-handler guard).

This is the behavior-changing slice. Bisect-safe because the
container still boots and serves; the only contract change is
the 503 body (newly possible) and the source of the inspect
data (now indexer, not cache). FR-017 satisfied (no
success-path wire-shape change).

**Tasks**: T004 (RED), T005 (GREEN). Folded into one commit.
Subject: `feat(242): API container reads from in-process indexer;
remove IORef cache`.

### Slice 3 — Container packaging (RocksDB volume + compose binding + flags wired through)

**RED**: minimal — extend
`test/devnet/Amaru/Treasury/Api/IndexerSmokeSpec.hs` (added in
Slice 4) is the real proof. For Slice 3 a focused test that the
nix-built container declares the volume mount point and the new
CLI flag surface is exposed via `--help`.

**GREEN**:

1. `nix/docker.nix` — declare the RocksDB volume mount point
   `/var/lib/amaru-treasury/indexer-rocksdb` and add it to the
   image's `Volumes` directive. Pass `--indexer-db
   /var/lib/amaru-treasury/indexer-rocksdb` into the
   default Cmd.
2. `deploy/compose/amaru-treasury/docker-compose.yaml` — add
   a top-level named volume `amaru-treasury-indexer` and bind
   it to the image volume.
3. `deploy/compose/amaru-treasury-dev/docker-compose.yaml` —
   same for the dev variant.

**Tasks**: T006 (RED), T007 (GREEN). Folded. Subject:
`feat(242): persistent RocksDB volume for the embedded indexer`.

### Slice 4 — Live-boundary devnet smoke + `gate.sh` extension

**RED**: write the smoke that fails initially — boots the
container, hits `/v1/treasury-inspect`, asserts the N2C trace
captured by a side recorder contains zero `GetUTxOByAddress`.
Asserts also: 503 body shape during forced indexer pause, 200
response after resume.

**GREEN**: pass — naturally, because Slices 1–3 already
implemented the behavior the smoke proves. This slice is the
**evidence** slice.

Also extends `./gate.sh` to invoke the smoke.

**Tasks**: T008 (RED smoke), T009 (gate extension). Folded.
Subject: `feat(242): devnet smoke proves zero-GetUTxOByAddress
on the request path`.

### Slice 5 — Documentation + asciinema cast

**Not behavior-changing.** Allowed as orchestrator-mechanical
commits per resolve-ticket, but easier to brief a doc-writer
worker pair to keep the orchestrator off prose duty.

Two `docs(242):` commits:

1. `docs/api-container-indexer.md` (operator runbook) +
   `mkdocs.yml` nav entry + `site_url` env-overridable.
2. `docs/assets/asciinema/amaru-treasury-tx-api.cast` +
   embedding block in the prose page + the
   [`asciinema-player` mkdocs plugin](https://github.com/paolino/dev-assets)
   registration in `mkdocs.yml` if not yet present.

**Tasks**: T010 (prose doc), T011 (asciinema cast + plugin wiring).

### Slice 6 — Issue body refresh + PR-ready

Edit GitHub issue #242 body to replace wizard framing with
API-container framing (old text moved to a history note).
`gh issue edit 242 --body-file <draft>`.

Run finalization audit (see `gate-script` skill).
`git rm gate.sh` in a final
`chore: drop gate.sh (ready for review)` commit.
`gh pr ready 254`.

**Tasks**: T012 (issue body refresh). The gate-drop is mechanical;
no Tasks: trailer required by the commit message gate.

## Slice gating rules

- **Build green at every commit.** `nix build .#default` must
  succeed at every slice's commit SHA.
- **Tests required by `./gate.sh` pass at every commit.**
- **No success-path JSON change** at any commit (FR-017).
- **No new endpoints** at any commit (FR-018).
- **No wizard code touched** at any commit (FR-019).
- **Cache removal is in Slice 2 only** — earlier slices keep
  the cache (Slice 1 doesn't wire the indexer), later slices
  don't reintroduce it.

## Live-boundary proof strategy

Per resolve-ticket plan-review checklist:
*"What system boundary does this exercise that the unit suite
cannot?"*

Two boundaries:

1. **Chain-sync follower writing into RocksDB concurrently
   with `snapshotAt` reads from the same handle.** The
   `utxo-indexer-lib` survey says reads are STM-backed and
   thread-safe; unit tests with in-memory backend cover the
   API surface. The real proof is the **devnet smoke**
   (Slice 4) running both threads against a live chain-sync
   stream from a real (devnet) node.

2. **Production code path issues `snapshotAt` instead of
   `GetUTxOByAddress`.** Unit tests with a stubbed `ApiIndexer`
   can prove the handler calls the new function, but not that
   the wired-up binary does. The N2C trace assertion in the
   devnet smoke (Slice 4) is the load-bearing proof of the
   "zero `GetUTxOByAddress`" claim.

Slice 4's smoke runs inside `./gate.sh`. No operator follow-up
is acceptable as a substitute.

## Risks & mitigations

| Risk | Mitigation |
|---|---|
| Upstream `withChainSyncFollower` PR review takes longer than the downstream slices | Downstream pins to the upstream PR's branch; can iterate downstream while the upstream PR is in review. Re-pin to merged commit at "ready" — gate has a check for "no branch-pinned SRPs at PR-ready". |
| Indexer follower crashes mid-flight, container appears half-serving | Follower runs under `withAsync + link` so its exception propagates to the main thread; container exits non-zero; container runtime restart-loop reboots. The readiness gate in Slice 2 doubles as defense-in-depth. |
| RocksDB volume corruption on first deploy after volume migration | Operator doc (Slice 5) names the "wipe + restart, accept cold-sync" procedure. Container fails fast on corrupt store with a distinct exit code. |
| Cold-sync from configured start slot exceeds container-runtime restart timeout | Use a recent enough `mainnetIndexerStartSlot` constant (post-treasury-deployment), measured cold-sync time documented in research.md §1, surfaced in quickstart.md. |
| Lag-threshold flapping during epoch boundaries causes 503 bursts | Default threshold sized conservatively (research.md §2). Operator can tune via flag. Frontend gracefully degrades on 503 (existing behavior — the dashboard renders an error state, not silently-wrong totals). |
| Forgetting to remove the cache leaves dead code | Slice 2's diff is reviewed as a single commit; the cache removal is in the same commit as the rewire. `git grep IORef` after the slice should return nothing in `app/amaru-treasury-tx-api/`. Add this check to the slice's review checklist. |
| Frontend dashboard polishes 503 display poorly | Out of scope per spec §"Out of scope". A polish ticket can refine after measurement. |

## Open seams resolved

The spec listed four open seams for plan phase. All resolved:

- **§1 — Mainnet starting slot**: constant in
  `Amaru.Treasury.Constants` (`mainnetIndexerStartSlot ::
  SlotNo`). Concrete value picked in [research.md §1](./research.md).
- **§2 — `lagThreshold` default**: see [research.md §2](./research.md).
- **§3 — `Handlers` shape**: extend the existing `Handlers`
  record with `ApiIndexer` (no new typeclass, no env wrapper);
  see [research.md §3](./research.md).
- **§4 — Upstream `withChainSyncFollower` API**: see
  [data-model.md](./data-model.md) for the signature and
  [research.md §4](./research.md) for the alternatives.

## Re-evaluation: Constitution Check (post-design)

Still no violations. The design adds one new module, edits the
existing API server + Main, and pins an upstream dependency.
The pure builder layer is untouched. The local-node default
remains intact (the indexer is local infrastructure, not an
alternate hosted backend). Hackage-readiness preserved
(Haddock on every export, fourmolu, `-Werror`).
