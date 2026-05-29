# API container's in-process indexer

`amaru-treasury-tx-api` — the container that serves the dashboard
at <https://amaru-treasury.plutimus.com/> — embeds a chain-sync
follower in-process. Every `GET /v1/treasury-inspect` is served
from a local RocksDB store; the production `cardano-node` only
sees a single cheap `GetChainPoint` per request. The container
boots blocked until the follower catches up to tip and
fail-closes with HTTP 503 if it drifts.

This page is the operator's guide to the new shape — what's new
on the wire, what the new CLI flags do, how the readiness probe
behaves, and the wipe-and-resync procedure when the on-disk
state needs to be rebuilt. The engineering-side notes live in
[`specs/242-api-indexer-embed/quickstart.md`](https://github.com/lambdasistemi/amaru-treasury-tx/blob/main/specs/242-api-indexer-embed/quickstart.md).

```asciinema-player
{
  "file": "assets/asciinema/amaru-treasury-tx-api.cast"
}
```

## What's new

| Before #242 | After #242 |
|---|---|
| Every dashboard refresh hit `cardano-node` over N2C for `GetUTxOByAddress` × 4 scopes + swap-order. | All UTxO reads served from an in-process RocksDB indexer. `cardano-node` sees only one `GetChainPoint` (cheap) per request. |
| Server-side 30 s TTL `IORef` cache hid the per-request cost but could serve stale data after a chain rollback. | No server-side cache. Indexer is rollback-aware via `utxo-indexer-lib`. |
| Container had no persistent state. | Container needs a persistent volume for the indexer RocksDB. |
| Boot was fast; first request paid full N2C scan cost. | Cold boot waits for the indexer to catch up. Subsequent requests are microsecond-class. |
| No fail-closed gate; stale data could be served indefinitely. | Lag above `--indexer-lag-threshold-slots` returns HTTP 503 with a structured body. |

## New CLI flags

Three flags on `amaru-treasury-tx-api`. The existing flag set
(`--host`, `--port`, `--socket`, `--metadata`, `--manifest`,
`--build-identity`, `--static`) is unchanged.

| Flag | Required | Default | Effect |
|---|---|---|---|
| `--indexer-db PATH` | yes | — | RocksDB directory backing the embedded indexer. Created if missing. Points at the container's persistent volume mount in compose. |
| `--indexer-lag-threshold-slots SLOTS` | no | `60` | Slot delta above which every endpoint returns HTTP 503. Default ≈ 60 s on mainnet. |
| `--indexer-start-slot SLOT` | no | `mainnetIndexerStartSlot` constant | Override the cold-boot starting slot for the chain-sync follower. Ignored when the RocksDB volume has a prior cursor. |

The compose recipes in
[`deploy/compose/amaru-treasury/docker-compose.yaml`](https://github.com/lambdasistemi/amaru-treasury-tx/blob/main/deploy/compose/amaru-treasury/docker-compose.yaml)
and `deploy/compose/amaru-treasury-dev/docker-compose.yaml`
already bind `/var/lib/amaru-treasury/indexer-rocksdb` to the
named volume `amaru-treasury-indexer` (production) /
`amaru-treasury-indexer-dev` (dev) and pass
`--indexer-db /var/lib/amaru-treasury/indexer-rocksdb` in the
container's default Cmd. Operators don't normally pass these
flags directly.

## Readiness probe

The container has three observable states. The transitions are
operator-meaningful:

### Boot — blocked until ready

On a fresh RocksDB volume (or after a wipe), the container does
**not** bind its `:8080` TCP listener until the follower
reaches `processed_slot ≥ tip_slot − lagThreshold`. TCP
connections during cold-sync are refused; the dashboard renders
its "connecting…" state.

Watch progress in the container log:

```sh
docker compose logs -f amaru-treasury \
  | grep -E 'indexer|warp binding'
```

Steady cold-sync on mainnet from `mainnetIndexerStartSlot`
typically reaches readiness in 10–30 minutes; the exact number
depends on network bandwidth and disk throughput, not on the
indexer code path.

### Ready — HTTP 200

Steady-state. Each request to `/v1/treasury-inspect` takes
microseconds (a RocksDB prefix scan per scope address + one
`GetChainPoint` over the N2C socket).

### Lagging — HTTP 503 (fail-closed)

If the follower drifts more than `lagThreshold` slots behind
tip — node restart, upstream stall, RocksDB I/O storm — **every
endpoint** (including `/v1/version`) returns HTTP 503 with a
structured JSON body. Operators don't need to do anything if
the lag is decreasing; it clears on its own as the follower
catches up.

#### The 503 body

`Content-Type: application/json; charset=utf-8`. Six required
keys, no extras:

```json
{
  "error":          "indexer_lagging",
  "processed_slot": 187915800,
  "tip_slot":       187916181,
  "lag_slots":      381,
  "threshold_slots": 60,
  "updated_at":     "2026-05-24T14:22:18.041Z"
}
```

| Key | Type | Meaning |
|---|---|---|
| `error` | string, const `"indexer_lagging"` | Stable wire tag for client routing. |
| `processed_slot` | integer ≥ 0 | Highest slot the follower has applied. |
| `tip_slot` | integer ≥ 0 | Latest tip observed from the upstream node. |
| `lag_slots` | integer ≥ 0 | `tip_slot − processed_slot`, the lag. |
| `threshold_slots` | integer ≥ 0 | Configured `--indexer-lag-threshold-slots`. |
| `updated_at` | RFC 3339 string | When the follower last wrote readiness. |

The full schema is locked in
[`contracts/api-extension.md`](https://github.com/lambdasistemi/amaru-treasury-tx/blob/main/specs/242-api-indexer-embed/contracts/api-extension.md).

### Recovery — back to 200

Once `lag_slots` drops back below `threshold_slots`, subsequent
requests succeed without any operator intervention. No
container restart is needed.

## Persistent RocksDB volume

The on-disk store lives at
`/var/lib/amaru-treasury/indexer-rocksdb` inside the container,
backed by the Docker named volume `amaru-treasury-indexer` (or
`amaru-treasury-indexer-dev` in the dev compose). The volume
survives `docker compose down`, image bumps, host reboots.

### Sizing

Initial budget: **10 GiB** for mainnet. The volume only stores
UTxOs touching the configured interest set — 4 treasury
addresses plus the SundaeSwap order address — so growth is
linear with treasury activity, not with the full chain UTxO
set. The actual disk pressure on a quiet treasury day is
single-digit megabytes; the 10 GiB headroom is for sustained
activity windows.

### Wipe-and-resync procedure

Wipe the volume and resync from `mainnetIndexerStartSlot` (or
the operator override) when:

* The volume is corrupted — container exits non-zero on boot
  with a `RocksDB ... corrupt` log line. The Docker
  restart-loop will keep failing the same way; manual
  intervention required.
* A new mainnet treasury is registered at a slot earlier than
  the current RocksDB cursor. Its historical UTxOs aren't
  visible until the volume is rebuilt from a slot before the
  new deployment.
* A new container image bumps `mainnetIndexerStartSlot` to an
  earlier value (rare; happens when the constant is hot-fixed
  to capture an older deployment).

The procedure is identical in all three cases:

```sh
cd /etc/nixos/production/compose/amaru-treasury
docker compose down amaru-treasury
docker volume rm amaru-treasury-indexer
docker compose up -d amaru-treasury
# Cold-sync: 10-30 min on mainnet.
docker compose logs -f amaru-treasury | grep -E 'indexer|warp binding'
```

When the `warp binding 0.0.0.0:8080` line appears, smoke-check:

```sh
curl -sS http://localhost:8080/v1/treasury-inspect?scope=middleware \
  | jq '.chain_tip, .scopes[0].treasury_totals'
```

A 200 with populated totals confirms the new volume is healthy.

## Out of scope

* Multi-tenant onboarding — covered by epic slice H (#249).
* Tx-history queries — epic slices B–E (#243 – #246).
* Wizard interactions — epic slice F (#247).
* Frontend rendering of the 503 body — the dashboard's current
  generic error state is acceptable. A polish ticket can refine.

For deeper engineering context — the upstream
`withChainSyncFollower` factor-out, the interest-set filter,
the boundary CBOR conversion at `snapshotUtxosAt`, the
readiness bridge thread — read
[`specs/242-api-indexer-embed/spec.md`](https://github.com/lambdasistemi/amaru-treasury-tx/blob/main/specs/242-api-indexer-embed/spec.md)
and its sibling artefacts under `specs/242-api-indexer-embed/`.
