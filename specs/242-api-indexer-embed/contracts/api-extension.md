# API extension contracts

**Branch**: `feat/242-api-indexer-embed` | **Date**: 2026-05-24
**Plan**: [../plan.md](../plan.md)

What this slice adds to `amaru-treasury-tx-api`'s operator-
visible contract surface, and what it explicitly does not
change.

## CLI flag additions

Three new flags on `amaru-treasury-tx-api`. Existing flags
(`--bind`, `--socket`, `--metadata`, `--manifest`,
`--build-identity`, `--static`) are unchanged.

| Flag | Required | Default | Effect |
|---|---|---|---|
| `--indexer-db PATH` | **yes** | — | RocksDB directory backing the embedded indexer. Created if missing. Must point at a writable directory (typically the container's persistent volume mount, see `nix/docker.nix`). |
| `--indexer-lag-threshold-slots SLOTS` | no | `60` | Slot delta above which every endpoint returns HTTP 503. Default ≈ 60 s on mainnet. See [research.md §2](../research.md). |
| `--indexer-start-slot SLOT` | no | `mainnetIndexerStartSlot` constant | Override the cold-boot starting slot for the chain-sync follower. Ignored when RocksDB has a prior cursor. See [research.md §1](../research.md). |

Behavioural changes triggered by these flags:

- At boot the container **does not bind its HTTP listener**
  until the indexer's readiness predicate is satisfied
  (`processed_slot ≥ tip_slot − lagThreshold`). TCP connects
  to `:8080` are refused during cold-sync.
- During steady-state serving, if the readiness predicate
  flips to `Lagging`, every endpoint short-circuits with the
  HTTP 503 body described below until readiness returns.

## New error response: HTTP 503 lagging body

Returned by **every** endpoint (`/v1/treasury-inspect`,
`/v1/recent-txs`, `/v1/version`) while the indexer's
`lag_slots > lagThreshold`.

**Content-Type**: `application/json; charset=utf-8`.

**Schema** (JSON Schema draft 2020-12, informal):

```json
{
  "type": "object",
  "required": [
    "error",
    "processed_slot",
    "tip_slot",
    "lag_slots",
    "threshold_slots",
    "updated_at"
  ],
  "properties": {
    "error":            { "const": "indexer_lagging" },
    "processed_slot":   { "type": "integer", "minimum": 0 },
    "tip_slot":         { "type": "integer", "minimum": 0 },
    "lag_slots":        { "type": "integer", "minimum": 0 },
    "threshold_slots":  { "type": "integer", "minimum": 0 },
    "updated_at":       { "type": "string",
                          "format": "date-time",
                          "description":
                            "ISO 8601 timestamp of the most \
                             recent follower update." }
  },
  "additionalProperties": false
}
```

**Example**:

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

**Status transitions**:

- 200 → 503: triggered on the first request after the
  readiness `TVar` reports `Lagging`. No grace period or
  hysteresis in this slice.
- 503 → 200: subsequent request finds the readiness `TVar`
  back to `Ready`. No operator action required; no container
  restart needed.

**Notes**:

- `Accept: text/html` requests get the same JSON body. The
  dashboard frontend is expected to detect the 503 status
  and surface an appropriate error state — frontend polish is
  out of scope for this PR.
- Liveness vs readiness is **not** split in this slice
  (intake decision). `/v1/version` returns 503 during drift
  along with the data endpoints. Operator visibility into
  the container's actual state during drift comes via
  container logs, not via the HTTP surface.

## Success-path wire shapes — unchanged

This slice MUST NOT change the JSON shape of any 200 response.
Verification:

- `/v1/treasury-inspect?scope=<scope>` → byte-identical to
  pre-#242 response for the same chain state. The handler
  computes from a different data source (indexer vs node)
  but produces the same `InspectReport` shape.
- `/v1/recent-txs` → unchanged (handler doesn't touch the
  chain; reads the baked-in manifest).
- `/v1/version` → unchanged (build-identity payload).

The devnet smoke (see [research.md §6](../research.md))
exercises `/v1/treasury-inspect` and asserts wire-shape parity
against the pre-#242 implementation on the same fixture
chain state.

## Negotiation / versioning

- No new endpoints (`/v1/history` etc. belong to later epic
  slices).
- No version bump on the `/v1` prefix.
- No new request headers required; no new response headers
  added on the success path. The 503 path may carry
  `Retry-After: <lag-derived seconds>` in a future polish
  ticket; this slice does not.
