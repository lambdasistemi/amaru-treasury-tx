# Specification — #494 indexer-backed API tip

Issue: https://github.com/lambdasistemi/amaru-treasury-tx/issues/494

Artifact ceiling: 5,500 bytes / 110 lines.

## Problem

The production API has two sources for the current chain tip. The
embedded indexer publishes a healthy upstream tip through its readiness
state, while `/v1/tip` and the inspector `chain_tip` independently call
the live provider's `posixMsToSlot`. That provider call blocks inside the
API process and reaches the existing ten-second timeout before any query
arrives at the node. `/v1/tip` then exposes Warp's generic HTTP 500.

The deployed `1960da80` image is affected. Restarting the container did
not restore service, while `/v1/health` remained ready with zero lag and
an advancing `tipSlot`.

## User story

As an operator using the treasury dashboard, I can load every inspector
pane and read the current chain tip promptly whenever the embedded
indexer is ready, without depending on a separate LocalStateQuery call.

## Functional requirements

- **FR-494-001** — `/v1/tip` obtains its slot from the embedded
  indexer's readiness state and returns HTTP 200 without calling the
  live provider's `posixMsToSlot`.
- **FR-494-002** — every `/v1/treasury-inspect` report obtains its
  `chain_tip.slot` from the same readiness-state source and does not call
  the live provider's `posixMsToSlot`.
- **FR-494-003** — the existing indexer lag guard remains the freshness
  authority. A lagging indexer continues to reject requests with its
  structured `indexer_lagging` HTTP 503 response.
- **FR-494-004** — if a `/v1/tip` handler action throws the existing
  typed `NowTipTimeout`, the HTTP boundary returns a structured
  `ApiError` HTTP 503 that names the chain-tip timeout and its bound,
  never a generic HTTP 500.
- **FR-494-005** — CLI `treasury-inspect` and other non-API callers keep
  the existing bounded live-provider `nowTip` behavior.
- **FR-494-006** — operator documentation identifies readiness state as
  the API tip source and distinguishes it from CLI live-node tip lookup.

## Invariants

- **INV-494-001 — one API authority:** both successful API tip surfaces
  read `Readiness.rTipSlot`; neither reaches a provider tip conversion.
- **INV-494-002 — fail closed on stale state:** the API never treats the
  new source as permission to bypass the existing readiness/lag gate.
- **INV-494-003 — explicit dependency:** report construction receives a
  tip slot explicitly; the provider used for indexed UTxO reads no
  longer implicitly owns API tip acquisition.
- **INV-494-004 — diagnostic boundary:** `NowTipTimeout` at either API
  tip boundary is an HTTP 503 `ApiError` with a meaningful timeout
  message.
- **INV-494-005 — CLI isolation:** the shared `nowTip` timeout and its
  CLI-visible failure semantics are unchanged.

## Rejection behavior

- Before initial readiness, Warp remains unbound as today.
- Beyond the configured lag threshold, requests retain the existing
  structured `indexer_lagging` HTTP 503 response.
- A typed chain-tip timeout reaching an API boundary becomes a
  structured HTTP 503, not a generic HTTP 500.
- Unrelated provider failures retain their existing behavior; this
  ticket does not introduce a catch-all exception mapper.

## Observable success

- The focused regression gate proves the API tip paths succeed with a
  provider whose `posixMsToSlot` fails if called.
- The HTTP boundary proof distinguishes `NowTipTimeout` from a generic
  server failure.
- Full local CI and pull-request CI are green.
- The deployed commit is reported by `/v1/version`.
- In production, `/v1/health` is ready, `/v1/tip` returns HTTP 200 well
  below the former ten-second bound, and every registered inspector
  scope returns HTTP 200 with a tip bounded by health snapshots taken
  immediately before and after it.

## Non-goals

- Repairing the separate LocalStateQuery blockage in
  `cardano-node-clients`.
- Removing or changing `nowTip` for CLI/build callers.
- Changing the `TipResponse`, `InspectReport`, `HealthResponse`, or
  `ApiError` JSON shapes.
- Changing lag thresholds, frontend behavior, node configuration, or
  the production compose topology.
