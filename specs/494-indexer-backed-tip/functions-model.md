# Functions model — #494 indexer-backed API tip

Artifact ceiling: 3,500 bytes / 80 lines.

Only new or changed signatures are listed. Names may be refined by the
commit owner only if module responsibility and argument meaning remain
identical.

## F-494-001 — readiness projection

`readTipSlot :: ReadinessHandle -> IO Word64`

- `readinessHandle`: the shared embedded-indexer readiness handle.
- Result: the latest `rTipSlot` projected to the API's wire slot type.
- Effect: non-blocking local snapshot read; no node query.

## F-494-002 — reusable inspection

`runInspectFromBackend :: TreasuryMetadata -> DeploymentAnchor -> Addr -> Maybe ScopeId -> Word64 -> Provider IO -> IO InspectReport`

- `tipSlot`: explicit current slot supplied by the caller.
- `provider`: source for treasury and pending-order reads only in this
  report path; not the current-tip authority.

## F-494-003 — indexed inspection handler

`mkInspectHandler :: Severity -> ApiIndexer cf op -> Provider IO -> Word64 -> TreasuryMetadata -> DeploymentAnchor -> Addr -> ScopeId -> Handler InspectReport`

- `realProvider`: retained for indexed-provider delegation of unrelated
  fields.
- `tipSlot`: explicit readiness-derived slot for the report.

## F-494-004 — tip HTTP boundary

`tipH :: Handler TipResponse`

- Result: `hTip` success value.
- Failure effect: maps only `NowTipTimeout` to structured HTTP 503.

## F-494-005 — API inspector wiring

`runInspectScope :: Severity -> ApiIndexer cf op -> ReadinessHandle -> Provider IO -> TreasuryMetadata -> DeploymentAnchor -> Addr -> ScopeId -> IO InspectReport`

- `readinessHandle`: source of the explicit report tip.
- `provider`: source of indexed adapter and unrelated live queries, not
  API tip acquisition.
