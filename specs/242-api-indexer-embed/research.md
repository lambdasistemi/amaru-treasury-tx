# Research Notes: in-process indexer embed inside `amaru-treasury-tx-api`

**Branch**: `feat/242-api-indexer-embed` | **Date**: 2026-05-24
**Plan**: [plan.md](./plan.md) | **Spec**: [spec.md](./spec.md)

Phase 0 design decisions resolving the spec's "Open seams for
plan phase". Each entry: **Decision** → **Rationale** →
**Alternatives considered**.

---

## §1. Mainnet starting slot

**Decision**: Hard-code a constant
`mainnetIndexerStartSlot :: SlotNo` in
`lib/Amaru/Treasury/Constants.hs`, surface a CLI override
`--indexer-start-slot SLOT` in
`app/amaru-treasury-tx-api/Main.hs`. The constant value is
**149_000_000** — a slot a few epochs before the Amaru 2026
treasury was created, recoverable from any of the `deployed_at`
TxIns in
[`metadata.json`](https://github.com/pragma-org/amaru-treasury/blob/main/journal/2026/metadata.json)
by looking up the producing block on cardanoscan.

Concrete pre-merge measurement: the operator (or a maintenance
runbook step) confirms the exact slot is ≤ the earliest
treasury `deployed_at` slot, then bumps the constant if a
better-grounded value is found. The CLI flag exists so devnet
and reprod environments can override without recompiling.

**Rationale**:

- Operationally self-contained: no dependency on upstream
  metadata schema changes in
  [`pragma-org/amaru-treasury`](https://github.com/pragma-org/amaru-treasury),
  which is governed by Cardano Foundation cadence rather than
  this repo's PR review cadence.
- Honest: the treasury didn't exist before its deployment; any
  pre-deployment indexed blocks would be wasted disk + wasted
  cold-sync time without changing query semantics.
- Reversible: the override flag means a misconfigured constant
  can be patched at deploy-time without a code change.

**Alternatives considered**:

- *Upstream metadata field*: cleanest in principle (each
  treasury knows its own deployment slot), but couples this
  ticket to a governance-process change in another repo and
  delays the slice. Can be added later — Slice F (#247) is a
  better venue since it brings every wizard onto the indexer
  and would benefit symmetrically.
- *Slot recovery from `deployed_at` TxIns at boot*: would
  require an N2C `GetUTxOByTxIn` (allowed by the epic's
  allow-list) plus a "find block by TxIn" lookup that
  `cardano-node` does not expose directly. Buys nothing the
  constant doesn't.
- *Sync from genesis*: hours-long cold-sync on every fresh
  volume. Painful first-deploy experience for zero correctness
  gain.

---

## §2. `lagThreshold` default

**Decision**: Default `--indexer-lag-threshold-slots` to
**60 slots** (≈ 60 seconds wall-clock on mainnet, where
slot-length is 1 s). Operator override via CLI flag.

**Rationale**:

- Mainnet active-slot coefficient ≈ 5 %, so blocks arrive every
  ~20 s on average. 60 slots is ~3 average block intervals,
  comfortably above natural follower lag during a normal block
  arrival cycle, but well under the 5 min stale-data threshold
  the spec's Edge Cases section cites for the existing
  dashboard.
- Tight enough that a follower stall is observable within ~1
  min — operator-actionable.
- Loose enough to avoid 503-flapping during the per-epoch
  cardano-node nonce-rotation pause (typically < 30 s) or
  brief network blips.

**Alternatives considered**:

- *20 slots* (~20 s, one block interval): too tight, risk of
  spurious 503 during normal block arrival jitter.
- *300 slots* (~5 min): matches the dashboard's "stale"
  display threshold but defeats the purpose of fail-closed
  serving — operators would not notice an hour-long follower
  stall.
- *Time-based threshold* (e.g., `--indexer-lag-threshold-seconds`):
  would have to translate seconds to slots via the era summary,
  which is interpreter-bound and changes per era boundary. Slot-
  based is simpler and matches the chain-sync follower's native
  unit.

---

## §3. `Handlers` shape after cache removal

**Decision**: Extend the existing `Handlers` record in
`lib/Amaru/Treasury/Api/Server.hs` with two new fields:

```haskell
data Handlers = Handlers
  { hInspect    :: ScopeId -> Servant.Handler InspectReport
  , hRecentTxs  :: Servant.Handler RecentTxManifest
  , hVersion    :: Servant.Handler BuildIdentity
  , -- existing fields preserved
  }
```

— but populate `hInspect` from a closure that captures the
`ApiIndexer` + the existing `Provider IO` backend:

```haskell
mkInspectHandler
  :: ApiIndexer
  -> Provider IO
  -> TreasuryMetadata
  -> DeploymentAnchor
  -> Addr
  -> ScopeId
  -> Servant.Handler InspectReport
```

The lag-503 guard sits in a small `Servant` middleware (or a
shared helper called at the top of every handler) that reads
`checkReady apiIdx` and short-circuits with a `throwError
err503 { errBody = encodeLaggingBody readiness }` when
`lag_slots > threshold`.

**Rationale**:

- Smallest possible diff against the existing `Handlers`
  surface introduced by [PR #240](https://github.com/lambdasistemi/amaru-treasury-tx/pull/240).
- The `Handlers` record is already the abstraction layer; no
  need for a new `ApiEnv` wrapper or `InspectSource`
  typeclass.
- Keeps the lag-guard in one place (middleware or helper),
  not duplicated per handler.

**Alternatives considered**:

- *`ApiEnv` record wrapper*: marginally cleaner conceptually
  but requires changing every handler's signature and the
  `mkApplication` call site. More LOC for no concrete benefit
  this slice. Defer until a future slice needs more shared
  state.
- *`InspectSource` typeclass with a `from-cache` and
  `from-indexer` instance*: would let the cache stay live as a
  fallback. We explicitly chose (intake interview) to remove
  the cache; a fallback would be dead code from day 1 and
  invite re-introducing the correctness risk we are removing.
- *Servant-level `Reader` monad*: idiomatic but introduces a
  new monad transformer dependency this codebase doesn't use.
  Closure capture is sufficient.

---

## §4. Upstream `withChainSyncFollower` API

**Decision**: Open paired PR in
[`lambdasistemi/cardano-node-clients`](https://github.com/lambdasistemi/cardano-node-clients)
extracting the chain-sync follower from `runDaemon` into a
new module
`lib-utxo-indexer/lib/Cardano/Node/Client/UTxOIndexer/Follower.hs`
with this signature:

```haskell
withChainSyncFollower
  :: Tracer IO N2CEvent
  -> ChainSyncConfig
       -- socket path, network magic, starting slot
  -> IndexerHandle
       -- caller-owned; the follower writes via applyAtSlot /
       --  rollbackTo
  -> (FollowerHandle -> IO a)
  -> IO a

data FollowerHandle = FollowerHandle
  { fhReadiness :: STM Readiness
  , fhAsync     :: Async ()      -- the follower thread itself
  }

data Readiness = Readiness
  { rProcessedSlot :: SlotNo
  , rTipSlot       :: SlotNo
  , rUpstreamUp    :: Bool
  , rUpdatedAt     :: UTCTime
  }
```

`runDaemon` is re-implemented in terms of this primitive:
`runDaemon cfg = withRocksDBIndexer cfg.dbPath $ \handle ->
withChainSyncFollower tracer (chainSyncCfg cfg) handle $ \fh ->
withNdjsonServer cfg handle fh (forever (threadDelay maxBound))`.
The existing `runDaemon` integration tests stay green
unchanged.

**Rationale**:

- Matches the "library exposes primitives, daemon binary
  composes them" pattern already used in the codebase.
- Bracket-style: caller controls lifetime; resource cleanup
  is exception-safe.
- `STM Readiness` lets downstream consumers (the API
  container, future tx-history runner) implement their own
  ready-gating without polling.
- `fhAsync` exposed so `link` is the caller's choice — we
  link in the API container so follower exceptions propagate.

**Alternatives considered**:

- *Add a `dcDisableServer :: Bool` field to `DaemonConfig`*:
  smallest upstream change, but produces a half-functional
  daemon (binds a tcp port, ignores it). Ugly.
- *Run a unix-socket NDJSON daemon as a sidecar child process*:
  rejected at intake interview ("shared DB handle"). Adds an
  IPC boundary we don't need.
- *In-process NDJSON over a `pipe`*: same drawback as
  sidecar; no win.

---

## §5. RocksDB volume layout

**Decision**:

- In-image mount point:
  `/var/lib/amaru-treasury/indexer-rocksdb`.
- Named Docker volume:
  `amaru-treasury-indexer` (production)
  / `amaru-treasury-indexer-dev` (dev).
- Owner inside container: the unprivileged user that runs
  `amaru-treasury-tx-api` today (per `nix/docker.nix`).
- Backup story: deferred to operator runbook (the volume is
  rebuildable from the chain; not load-bearing for data
  integrity).

**Rationale**:

- `/var/lib/<app>` matches FHS conventions and is the
  established lambdasistemi house pattern.
- Named volume (not bind mount) keeps the host-side
  filesystem layout an operator concern, not a
  container-image concern.

**Alternatives considered**:

- *Bind-mount on host*: more visible to operators, but ties
  the image to a host path. Named volume composes better.
- *Ephemeral tmpfs volume*: would force full cold-sync on
  every container restart. Defeats Story 3.

---

## §6. Live-boundary smoke shape

**Decision (revised in slice-4)**: ship a **mid-fidelity
opt-in smoke** in `test/devnet/Amaru/Treasury/Api/IndexerSmokeSpec.hs`
that proves the binary's **lifecycle** end-to-end against a
live devnet, and **defer** the byte-level N2C trace recorder
to follow-up issue [#293](https://github.com/lambdasistemi/amaru-treasury-tx/issues/293).

The original plan called for a full byte-level recorder + CBOR-
frame analyzer asserting zero `GetUTxOByAddress` on the wire.
The slice-4 driver's Q-001 surfaced that ~2 days of new
infrastructure (socat bridge + LSQ frame scanner) would be
needed for that, and that the FR-004 invariant is already
proved at the **Provider boundary** by slice-2's
`trappedProvider` (every Provider field except `nowTip` traps
with `error "BUG: …"` if called). The orchestrator picked
**Option B** (mid-fidelity lifecycle + 503 body + recovery)
and filed #293 to track the deferred byte-level layer.

### What ships in slice-4

The spec, gated behind the `DEVNET_API_SMOKE_OPT_IN` env var
so default `cabal test devnet-tests` skips it (gate stays
cheap), and operator-invokable via `just devnet-api-smoke`:

1. Boots a devnet via the existing
   `Cardano.Node.Client.E2E.Devnet.withCardanoNode` harness.
2. Boots `amaru-treasury-tx-api` against the **real** node
   socket + tmpfs RocksDB at `$tmpdir/rocksdb` + a devnet
   metadata fixture.
3. Waits for readiness via TCP-connect on the bound port.
4. Issues `curl :<port>/v1/treasury-inspect?scope=<some-scope>`.
   **Assertion 1**: HTTP 200, body parses as a JSON object.
5. Forces `Lagging` via `setReadinessForTest`.
   **Assertion 2**: HTTP 503, body matches the 6-key schema
   from [contracts/api-extension.md](./contracts/api-extension.md)
   exactly.
6. Restores `Ready`. **Assertion 3**: subsequent request
   returns 200.

### What's explicitly NOT in slice-4 (deferred to #293)

- The transparent N2C socket trace recorder (socat bridge or
  Haskell pass-through).
- The LSQ frame analyzer that walks the recorded byte
  stream and identifies `GetUTxOByAddress` /
  `GetUTxOByTxIn` constructors.
- A wire-level "exactly one `GetChainPoint` and zero scans"
  assertion.

These all live in [#293](https://github.com/lambdasistemi/amaru-treasury-tx/issues/293).

### Why the layered proof is acceptable

FR-004 is proved at two layers:

| Layer | What it covers | Cost |
|---|---|---|
| Unit: `trappedProvider` (slice 2) | The handler closure cannot call `queryUTxOs` / `queryUTxOByTxIn` / any field except `nowTip` without crashing the unit test | Cheap (in-process, deterministic) |
| Live-boundary smoke (slice 4) | The wired-up binary boots, serves a real request, returns 200 (and 503 on drift, and 200 on recovery) end-to-end | Medium (live devnet, opt-in) |
| Byte-level recorder (deferred to #293) | The actual N2C wire bytes show no `GetUTxOByAddress` from ANY code path — middleware, background threads, future additions | High (~2 days infra) |

The deferred layer adds **independence** from the unit
suite's assumptions about where queries are issued. The
current two layers cover the handler explicitly + the
binary's lifecycle implicitly. #293 closes the gap when
prioritized.

**Rationale for the deferral**:

- The slice loop must stay livable; absorbing ~2 days into
  any single slice violates the bisect-safe-per-commit
  cadence we've held throughout #242.
- The unit's `trappedProvider` catches the most likely
  regression (a handler edit smuggles a Provider scan call
  back in) at lower cost than the byte recorder would.
- The byte recorder is genuinely useful for FUTURE slices
  too (the tx-history indexer in epic slice B+ will want the
  same machinery), so building it as its own first-class
  ticket is better leverage than rushing it into #242.

**Alternatives considered (and rejected)**:

- *Full byte recorder in slice 4*: too expensive for the
  proof-delta over slice-2's unit trap. Option A in slice-4
  Q-001.
- *Lifecycle-only smoke (skip 503 / recovery)*: too thin;
  the 503 body shape is operator-visible and worth a live
  proof. Option C in slice-4 Q-001.
- *Trace assertion via fake Provider*: misses the whole
  point — proves only that the handler calls the new
  function, doesn't prove the wired-up binary works
  end-to-end.
