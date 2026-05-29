# Operator Quickstart: in-process indexer in `amaru-treasury-tx-api`

**Branch**: `feat/242-api-indexer-embed` | **Date**: 2026-05-24
**Plan**: [plan.md](./plan.md) | **Spec**: [spec.md](./spec.md)

Targeted at the operator who will deploy the post-#242
container to the lambdasistemi production NixOS host running
the Amaru mainnet treasury dashboard at
<https://amaru-treasury.plutimus.com/>. Devnet / preprod
operators substitute the obvious paths.

## What changes for the operator

| Before #242 | After #242 |
|---|---|
| Every dashboard refresh hit `cardano-node` over N2C for `GetUTxOByAddress` × 4 scopes + swap-order. | All UTxO reads served from an in-process RocksDB indexer. `cardano-node` sees only `GetChainPoint` (cheap) per request. |
| Server-side 30 s TTL `IORef` cache hid the per-request cost but could serve stale data after a chain rollback. | No server-side cache. Indexer is rollback-aware via `utxo-indexer-lib`. |
| Container had no persistent state. | Container needs a persistent volume for the indexer RocksDB. |
| Boot was fast; first request paid full N2C scan cost. | Cold boot waits for the indexer to catch up. Subsequent requests are microsecond-class. |
| No fail-closed gate; stale data could be served indefinitely. | Lag above `--indexer-lag-threshold-slots` returns HTTP 503 with a structured body. |

## One-time host preparation

1. **Allocate disk for the indexer volume.** Initial sizing
   target: 10 GiB. The indexer stores RocksDB column families
   `utxo-indexer.{txin,address,rollback}`. Grows roughly
   linearly with chain activity touching the indexed
   addresses; this slice indexes the full chain (no
   interest-set filtering), so size is dominated by the chain
   size beyond the start slot.

2. **Pull the new image.** The docker-compose recipe in
   `deploy/compose/amaru-treasury/docker-compose.yaml` is
   updated by this PR. The container image pulls from the
   project's GHCR registry (see PR #240 for the publication
   workflow). No new registry credentials are required.

3. **Decide RocksDB volume backing.** The compose file
   declares a named volume `amaru-treasury-indexer`. The
   default is Docker-managed local storage; operators who
   want explicit control over the host path can override the
   volume's driver options in a side compose file or
   `docker volume create amaru-treasury-indexer` ahead of
   first boot.

## Cold-boot procedure (first deploy after #242)

```bash
# 0. SSH to production. cd to the deploy directory.
cd /etc/nixos/production/compose/amaru-treasury

# 1. (Optional) pre-create the volume to control storage location.
docker volume create amaru-treasury-indexer \
  --opt type=none --opt o=bind \
  --opt device=/var/lib/amaru-treasury/indexer-rocksdb

# 2. Pull the new image.
docker compose pull amaru-treasury

# 3. Bring the container up. Detached — it will refuse TCP
#    connections to :8080 during the cold-sync phase.
docker compose up -d amaru-treasury

# 4. Watch logs. Cold-sync from the configured start slot
#    typically completes in 10–30 minutes on a healthy host
#    + mainnet node (function of network bandwidth and disk
#    throughput, not of indexer code).
docker compose logs -f amaru-treasury
```

Look for log lines roughly of the form:

```
amaru-treasury-tx-api: indexer cold-sync starting at slot
  149000000
amaru-treasury-tx-api: indexer processed_slot=149100000
  tip_slot=187920000 lag_slots=38820000
…
amaru-treasury-tx-api: indexer Ready
  (processed_slot=187919950, tip_slot=187920000, lag_slots=50)
amaru-treasury-tx-api: warp binding 0.0.0.0:8080
```

After the `warp binding` line:

```bash
# 5. Smoke-check the dashboard endpoint.
curl -sS http://localhost:8080/v1/treasury-inspect?scope=middleware \
  | jq '.chain_tip, .scopes[0].treasury_totals'
```

A 200 response with populated totals confirms the slice is
working.

## Steady-state operation

- The dashboard refreshes every 30 s. Each refresh issues
  one HTTP request per scope to `/v1/treasury-inspect`. The
  container handles each in microseconds (RocksDB prefix
  scan) plus one cheap `GetChainPoint` (~few ms over the
  unix socket). Production node load attributable to the
  dashboard drops to "≈ zero" measured in scans.
- Indexer cold-sync only happens once per RocksDB volume.
  Container restart (image bump, host reboot, OOM kill)
  resumes from the on-disk cursor and reaches readiness in
  seconds.

## What to do when …

### The container returns HTTP 503 with `error: indexer_lagging`

The follower is behind tip. Read the response body for the
exact lag:

```bash
curl -sS http://localhost:8080/v1/version | jq
# {
#   "error": "indexer_lagging",
#   "processed_slot": 187915800,
#   "tip_slot": 187916181,
#   "lag_slots": 381,
#   "threshold_slots": 60,
#   "updated_at": "2026-05-24T14:22:18.041Z"
# }
```

If `lag_slots` is **steadily decreasing** between successive
requests, no action — the follower is catching up. The 503
will clear on its own.

If `lag_slots` is **steadily increasing** or stalled:

```bash
# Check if the upstream node is healthy.
docker compose logs --tail 50 cardano-node | grep -iE 'error|fail'

# Inspect the container's recent stderr.
docker compose logs --tail 100 amaru-treasury | tail -40
```

Most common causes:

- Upstream node restart / cold-sync of its own. The follower
  will reconnect and catch up; 503 clears once the node
  reaches tip and the follower catches up to it.
- Disk pressure on the RocksDB volume. Free space:
  `docker system df` / `df -h /var/lib/docker/volumes`.
- Follower thread crashed; the container exit-codes
  non-zero on crash, so `docker compose ps` shows it
  restarting. The container runtime restart-loop recovers.

### The dashboard is loading but every response is HTTP 503

Likely the lag-threshold is set too tight for this host's
sustained throughput. Two corrective moves:

```bash
# Temporary: bump --indexer-lag-threshold-slots to 300
# (~5 min). Edit the compose file's command override or set
# AMARU_INDEXER_LAG_THRESHOLD_SLOTS env if the deploy
# overrides via env (check the compose file). Reboot the
# container.

# Permanent: open a follow-up ticket to bump the default
# upstream after measurement.
```

### A new mainnet treasury is deployed before #247 lands

This slice's `mainnetIndexerStartSlot` constant is
deployment-snapshot specific. If a new treasury is registered
at a slot earlier than the indexer's RocksDB cursor, its
historical UTxOs will not be visible to this container until
the volume is wiped and re-synced from a slot before the new
deployment.

Mitigation: bump the constant in a hotfix PR or pass
`--indexer-start-slot` in the compose command override,
then:

```bash
docker compose down amaru-treasury
docker volume rm amaru-treasury-indexer
docker compose up -d amaru-treasury
```

(Cold-sync follows — same procedure as first deploy above.)

### RocksDB volume corrupt

Symptom: container exits non-zero immediately on boot with a
log line naming the RocksDB path and a corruption-class
error. The container runtime restart-loop will keep failing
the same way; manual intervention required.

Recovery (data is rebuildable from the chain):

```bash
docker compose down amaru-treasury
docker volume rm amaru-treasury-indexer
docker compose up -d amaru-treasury
# Cold-sync as in the "first deploy" section.
```

The recovery procedure is the same as the "new treasury
deployed" case — wipe + restart.

## Verification artifacts

After deploy, two things to file alongside the deploy
record:

1. **Cold-sync time** measured from container start to the
   `warp binding 0.0.0.0:8080` log line. Useful to budget
   the next deploy's downtime window.
2. **A `curl /v1/treasury-inspect?scope=middleware`
   response** captured 1 h post-deploy, compared to the
   equivalent capture taken pre-#242. The two JSON bodies
   should be byte-identical (per the same chain state),
   minus chain_tip slot drift.

## Out of scope for this quickstart

- Multi-tenant onboarding (epic slice H, #249).
- Tx-history queries (epic slices B-E, #243-#246).
- Wizard interactions (epic slice F, #247).
- Frontend changes to render 503 responses gracefully — the
  dashboard's current behaviour on 503 is acceptable for
  this slice; refinement belongs to a polish ticket if
  needed.
