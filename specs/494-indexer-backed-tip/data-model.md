# Data model — #494 indexer-backed API tip

Artifact ceiling: 2,000 bytes / 50 lines.

## D-494-001 — readiness tip projection

- Source field: existing `Readiness.rTipSlot`.
- Value type: existing absolute `SlotNo` / `Word64` projection.
- Validity: the surrounding readiness/lag gate remains authoritative;
  the projection does not independently declare a snapshot fresh.
- Consumers: `/v1/tip` and inspector `chain_tip.slot`.

## D-494-002 — API tip payloads

- Existing `TipResponse` and `InspectReport` shapes are unchanged.
- Both payloads receive their slot value from D-494-001.
- The inspector's absent block hash behavior is unchanged.

## D-494-003 — typed timeout HTTP error

- Existing `NowTipTimeout` carries the configured timeout seconds.
- Existing `ApiError` JSON shape remains `{message, field}`.
- HTTP status is 503 when the typed timeout crosses either API tip
  boundary.
- No catch-all error shape is introduced.

## Persistence and migration

No new field, table, file format, schema, cache, migration, or retained
state is introduced. The existing readiness TVar is the only runtime
source involved.
