# Cross-Artifact Analysis (#239)

A single pass over spec.md, plan.md, research.md, data-model.md, contracts/, quickstart.md, and tasks.md.

## Coverage matrix: every FR maps to a task

| FR | Covered by tasks | Notes |
|---|---|---|
| FR-001 (HTTPS at public URL) | T024–T025 | Traefik labels per compose recipe. |
| FR-002 (`/` returns SPA) | T010, T012, T013 | Static serving + bundled index.html. |
| FR-003 (404 on `/create-tx` and others) | T010 | servant API mounts only documented routes; default servant 404 otherwise. |
| FR-004 (header + footer with docs link) | T013, T021 | Page chrome + build identity chip. |
| FR-005 (responsive 320–2560 px) | T022 | Style.purs. |
| FR-006 (balance summary per scope) | T014, T015 | App fetches + renders. |
| FR-007 (largest UTxO per scope) | T015 | Top-N sortable table includes max. |
| FR-008 (top-N sortable) | T015 | Default N=20, sort = USDM desc. |
| FR-009 (pending SundaeSwap orders) | T019 | Pending-orders rendering. |
| FR-010 (inline drill-down) | T016 | No navigation, same page. |
| FR-011 (10 recent txs / cardanoscan) | T002, T009, T020 | Manifest derivation + handler + frontend consumption. |
| FR-012 (auto-refresh 30 s) | T017 | Single-flight guard. |
| FR-013 (no stacking) | T017 | Same task. |
| FR-014 (stale indicator > 5 min) | T018 | Visible banner. |
| FR-015 (`GET /v1/treasury-inspect`) | T006 | Handler. |
| FR-016 (byte-identity with CLI) | T006 RED + quickstart §4 | Hspec golden uses `Inspect.Render.encodeReport` directly. |
| FR-017 (400 on missing/unknown scope) | T007 | Validation + error mapping. |
| FR-018 (no POST in this slice) | T005, T011 | API surface only declares GET endpoints. |
| FR-019 (public read; no auth) | T024 (compose) | No auth middleware. |
| FR-020 (metadata pinned via flake) | T001 | `nix/metadata.nix`. |
| FR-021 (metadata read-only in image) | T023, T024 | Nix-store layer + compose `read_only: true`. |
| FR-022 (build identity surfaced) | T003, T008, T021 | Embedded JSON + handler + footer chip. |
| FR-022a (recent-txs sourced from in-repo archive) | T002, T009 | Build-time derivation. |
| FR-022b (read-only recent-txs) | T002, T023, T024 | Identical baking pattern. |
| FR-023 (N2C socket mount) | T024 | Compose volume bind. |
| FR-024 (refuse to serve on unreachable socket) | T011 | Smoke covers; UI "node unreachable" is in T013/T017 (degraded card). |
| FR-025 (mainnet only) | T011 | CLI flag refuses non-mainnet magic. |
| FR-026 (single Nix derivation; reproducible) | T001–T003, T023 | Content-addressed inputs. |
| FR-027 (deploy expressed in code) | T024 | Compose under deploy/. |
| FR-028 (deploy in one command) | T025 + quickstart | `scripts/update.sh amaru-treasury`. |

**Gap found / closed**: FR-024's UI affordance ("node unreachable" banner) is implicit in T013/T017. **Closing**: T017's RED gains a case for "API returns 502 / network error → banner replaces spinner."

| SC | Covered by |
|---|---|
| SC-001 (≤ 5 s cold paint) | T015 (full fetch path), measured in quickstart. |
| SC-002 (byte-identity diff) | T006 hspec golden + quickstart §4 diff step. |
| SC-003 (320 px no horizontal scroll) | T022 + quickstart §5. |
| SC-004 (redeploy ≤ 10 min) | quickstart §1–§3 measured wall-clock. |
| SC-005 (100% metadata write failures) | quickstart §6 probe. |
| SC-006 (refresh keeps ≤ 35 s lag) | T017 hspec timing. |
| SC-007 (unknown scope → 400 always) | T007 hspec property. |
| SC-008 (reproducible image hash) | T023 image-smoke + manual rerun. |

## Consistency checks

- **Endpoint names** consistent across spec (FR-015), plan (slice 3), data-model (carrier types per endpoint), contracts (three OpenAPI files), and tasks (T006–T009).
- **JSON field names** in data-model (`irChainTip`, `biGitCommit`, `rtmEntries`, `aeMessage`) match contracts/ schemas and existing `Inspect.Render` field prefixes.
- **Scope enum** consistent: four registered scopes appear in spec FR-006, contracts schema, and the validator in T007. `contingency` appears in the recent-txs contract because the local archive at `transactions/2026/contingency/` exists; this is documented in research R2.
- **Read-only invariant** consistent: image layer (R6), compose `read_only: true` (R8), runtime write-attempt probe (quickstart §6), success criterion (SC-005).
- **Refresh / stale** consistent: spec (FR-012/FR-014), clarifications, plan, tasks T017/T018, success criterion SC-006.

## Potential drift to watch

- `transactions/2026/contingency/` is committed and contains real txids, but spec lists only the four operative scopes (FR-006). The recent-txs manifest legitimately surfaces `contingency` entries since they are part of the deployed history. The OpenAPI contract for `/v1/recent-txs` already includes `contingency` in the enum. **No change needed**, but the dashboard footer label should not break when surfacing a `contingency` cardanoscan link — covered in T020.
- Constitution Principle V mandates RED-before-GREEN with golden CBOR fixtures. The new layer has no CBOR; the golden surface for this slice is the JSON byte-identity test in T006. **No conflict** — Principle V's intent is "test-first with bytes as the arbiter," which the JSON golden honors.
- Plan slice 9 ("first card data binding") and tasks T014 use slightly different framing. **Aligned**: same scope; tasks.md is canonical.

## Conclusion

Spec, plan, data-model, contracts, and tasks are mutually consistent. One closure (T017 banner case for unreachable-node) added. Ready to implement.
