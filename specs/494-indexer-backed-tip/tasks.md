# Tasks — #494 indexer-backed API tip

Artifact ceiling: 2,000 bytes / 50 lines.

## S-494-001 — remove API LocalStateQuery tip dependency

- [x] **T49401** — Freeze and falsify the focused gate against the
  untouched `1960da80` base for INV-494-001 through INV-494-005.
- [x] **T49402** — Add permanent regression proof that both API tip
  surfaces use an explicit readiness tip and do not invoke provider
  `posixMsToSlot`.
- [x] **T49403** — Make readiness state the wired source for
  `/v1/tip` and inspector `chain_tip` while preserving the lag guard and
  non-API `nowTip` behavior.
- [x] **T49404** — Preserve a structured `NowTipTimeout` HTTP 503 at
  both API tip boundaries and prove it cannot flatten to generic 500.
- [x] **T49405** — Update API/indexer operator documentation and the
  executable description for the new source boundary.
- [x] **T49406** — Pass focused verification, format checking, and
  full local CI; submit the exact candidate for fresh audit.
- [x] **T49407** — Accept and push the exact audited commit; pass every
  deploy-path check and document any unrelated CI failure.
- [x] **T49408** — Deploy the accepted SHA through the image workflow
  and pass immutable-identity plus public live-boundary smoke checks.
