# Tasks — #494 indexer-backed API tip

Artifact ceiling: 2,000 bytes / 50 lines.

## S-494-001 — remove API LocalStateQuery tip dependency

- [ ] **T-494-001** — Freeze and falsify the focused gate against the
  untouched `1960da80` base for INV-494-001 through INV-494-005.
- [ ] **T-494-002** — Add permanent regression proof that both API tip
  surfaces use an explicit readiness tip and do not invoke provider
  `posixMsToSlot`.
- [ ] **T-494-003** — Make readiness state the wired source for
  `/v1/tip` and inspector `chain_tip` while preserving the lag guard and
  non-API `nowTip` behavior.
- [ ] **T-494-004** — Preserve a structured `NowTipTimeout` HTTP 503 at
  both API tip boundaries and prove it cannot flatten to generic 500.
- [ ] **T-494-005** — Update API/indexer operator documentation and the
  executable description for the new source boundary.
- [ ] **T-494-006** — Pass focused verification, format checking, and
  full local CI; submit the exact candidate for fresh audit.
- [ ] **T-494-007** — Accept, push, and pass all PR checks for the exact
  audited commit.
- [ ] **T-494-008** — Deploy the accepted SHA through the image workflow
  and pass immutable-identity plus public live-boundary smoke checks.
