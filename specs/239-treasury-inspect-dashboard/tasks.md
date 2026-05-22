---
description: "Bisect-safe TDD task breakdown for #239"
---

# Tasks: treasury-inspect dashboard end-to-end (#239)

**Input**: design documents in `specs/239-treasury-inspect-dashboard/`
**Prerequisites**: spec.md, plan.md, research.md, data-model.md, contracts/, quickstart.md

**Tests**: yes — RED before GREEN on every slice; gate via `nix flake check --no-eval-cache`.

## Format

Each task is one bisect-safe commit: RED test, GREEN implementation, REFACTOR if needed. Conventional Commits. Closes a clearly-defined chunk of plan.md.

Layout legend: `[F]` = flake / nix wiring; `[H]` = Haskell; `[P]` = PureScript; `[D]` = deploy.

---

## Phase 1 — Setup

- [ ] **T001 [F]** Add `pragma-org/amaru-treasury` as a flake input pinned to a specific commit. Expose `nix/metadata.nix` exporting the file path. **RED**: `nix/checks.nix` adds `metadata-pin` runCommand that asserts `sha256sum $(nix eval --raw .#metadata-file) == 8ea2c53b…`. Commit: `chore(239): pin pragma-org/amaru-treasury metadata flake input`.

- [ ] **T002 [F]** Add `nix/recent-txs.nix` runCommand that walks `transactions/2026/<scope>/<txid>/` and emits `recent-txs.json` (newest 10 by `tx.envelope.json` mtime; sorted desc; deterministic). **RED**: `nix/checks.nix` adds `recent-txs-manifest` runCommand asserting (a) the JSON parses, (b) `length <= 10`, (c) entries carry the four required fields, (d) the txid hex matches the dir name. Commit: `feat(239): derive recent-txs manifest at build time`.

- [ ] **T003 [F]** Add `nix/build-identity.nix` runCommand that emits `build-identity.json` with the five `BuildIdentity` fields, embedded via `file-embed` into the future API binary. **RED**: `build-identity` check asserts JSON shape + sha256 matches. Commit: `feat(239): bake build identity into the image`.

---

## Phase 2 — Foundational

- [ ] **T004 [H]** Add a new library exposed module `Amaru.Treasury.Api.Types` to `amaru-treasury-tx.cabal` with `BuildIdentity`, `RecentTxManifest`, `RecentTxEntry`, `ApiError` and their `ToJSON`/`FromJSON`. **RED**: hspec round-trip property over decoded JSON. Commit: `feat(239): api carrier types`.

- [ ] **T005 [H]** Add `Amaru.Treasury.Api.Server` defining the servant API type (`/v1/treasury-inspect`, `/v1/recent-txs`, `/v1/version`, static under `/`) and the `Handlers` record. **RED**: hspec asserts the servant API type compiles and the OpenAPI surface matches the contracts/ YAML keys. Commit: `feat(239): servant api surface`.

---

## Phase 3 — User Story 2 (HTTP endpoint, P1) — the JSON contract

These slices ship the endpoint before the page, since the page is a consumer of the endpoint.

- [ ] **T006 [H]** `Amaru.Treasury.Api.Inspect`: wire `GET /v1/treasury-inspect?scope=<name>` to the existing `Amaru.Treasury.Inspect.runInspect` against a `Provider IO`. **RED**: hspec runs the handler with a stub provider returning a fixed `InspectReport` and asserts the response body equals `Amaru.Treasury.Inspect.Render.encodeReport report` byte-for-byte. Commit: `feat(239): /v1/treasury-inspect handler`.

- [ ] **T007 [H]** Scope validation + 400 mapping. **RED**: hspec on `?scope=` missing → 400 with `aeField=Just "scope"`; `?scope=foo` → 400 listing valid scopes. Commit: `feat(239): scope query validation`.

- [ ] **T008 [H]** `Amaru.Treasury.Api.Version`: read embedded build identity, return verbatim. **RED**: hspec asserts the embedded JSON parses into a `BuildIdentity` and the response body equals the embedded bytes. Commit: `feat(239): /v1/version handler`.

- [ ] **T009 [H]** `Amaru.Treasury.Api.RecentTxs`: read the manifest file at startup (path from CLI flag), serve as JSON. **RED**: hspec runs the handler against a fixture manifest and asserts the response matches. Commit: `feat(239): /v1/recent-txs handler`.

- [ ] **T010 [H]** `Amaru.Treasury.Api.Static`: serve a directory at `/` via `WaiAppStatic`. **RED**: hspec asserts `/` returns the bundled `index.html` and `/missing.txt` returns 404. Commit: `feat(239): static asset serving`.

- [ ] **T011 [H]** `app/amaru-treasury-tx-api/Main.hs`: thin CLI binding `--socket`, `--bind`, `--metadata`, `--manifest`, `--static`. **RED**: live-boundary smoke runCommand boots the binary on a free port against an in-process stub provider; curls every endpoint; asserts HTTP + JSON shape. Commit: `feat(239): amaru-treasury-tx-api executable`.

---

## Phase 4 — User Story 1 (Halogen dashboard, P1)

The frontend consumes the now-live endpoint. Slices stack monotonically — every commit produces a working page.

- [ ] **T012 [F]** Add `frontend/` workspace: `flake.nix` (purescript-overlay + mkSpagoDerivation), `spago.yaml` (registry pin 72.1.0), `spago.lock`, `package.json`, `package-lock.json`, `dist/index.html`. **RED**: `frontend-bundle` runCommand check asserts `dist/index.html` + `dist/index.js` produced reproducibly. Commit: `feat(239): frontend workspace skeleton`.

- [ ] **T013 [P]** `frontend/src/Main.purs` + `App.purs` skeleton: header (site title), footer (docs link + repo link + placeholder for build identity), four empty scope cards. **RED**: purescript-spec asserts component renders without runtime exceptions; bundle size sanity check. Commit: `feat(239): halogen page chrome`.

- [ ] **T014 [P]** `frontend/src/Api.purs`: Affjax wrapper for `/v1/treasury-inspect` + decoder; `App.purs` fetches `core_development` on mount and renders balance + UTxO count. **RED**: purescript-spec decodes the recorded JSON fixture (sourced from contracts/) into the typed record. Commit: `feat(239): frontend fetches first scope`.

- [ ] **T015 [P]** All four scopes fetched in parallel; each card renders summary + top-N sortable table. **RED**: spec covers sort-order toggles + top-N defaults. Commit: `feat(239): four scope cards with sortable tables`.

- [ ] **T016 [P]** Inline UTxO drill-down on click (no navigation). **RED**: spec asserts state transition reveals + hides UTxO detail panel. Commit: `feat(239): inline utxo drill-down`.

- [ ] **T017 [P]** Auto-refresh tick (30 s default) with single-flight guard (FR-013). **RED**: spec asserts a second tick while a fetch is in flight is dropped. Commit: `feat(239): auto-refresh with single-flight`.

- [ ] **T018 [P]** Stale indicator on tip-lag > 5 min (FR-014). **RED**: spec asserts a stub slot-now and ChainTip.ctSlot derive a "stale" banner. Commit: `feat(239): stale-data indicator`.

- [ ] **T019 [P]** Pending-orders rendering per scope. **RED**: spec asserts each PendingSwapOrder renders a row with order id + asset summary. Commit: `feat(239): pending swap orders`.

- [ ] **T020 [P]** `/v1/recent-txs` consumption: render last 10 cardanoscan links in footer. **RED**: spec asserts cardanoscan URL building per txid. Commit: `feat(239): recent-txs footer`.

- [ ] **T021 [P]** `/v1/version` consumption: build identity in footer. **RED**: spec asserts decoded BuildIdentity renders short sha + metadata sha prefix. Commit: `feat(239): build identity footer chip`.

- [ ] **T022 [P]** Responsive layout (320 px → 2560 px) + lambdasistemi house style (Style.purs / external CSS). **RED**: bundle size delta within budget; manual mobile check noted in quickstart. Commit: `feat(239): responsive layout`.

---

## Phase 5 — Image + Deploy (User Story 3, P2)

- [ ] **T023 [F]** `nix/docker.nix` → `dockerTools.streamLayeredImage` with API binary + static bundle + metadata + manifest + build-identity; container `Cmd` per the runbook. **RED**: `image-smoke` runCommand boots the image (in a sandboxed network namespace where available; otherwise documents the manual `docker load && docker run` step). Commit: `feat(239): nix-built docker image`.

- [ ] **T024 [D]** `deploy/compose/amaru-treasury/docker-compose.yaml` + a one-line addition to `lambdasistemi/infrastructure/scripts/deploy.sh`. **RED**: nothing automatable; quickstart.md curl-suite IS the test. Commit: `feat(239): production compose recipe`.

- [ ] **T025 [D]** Push image to ghcr.io, run `scripts/update.sh amaru-treasury` on `production`, run the quickstart curl suite from a clean machine. On success, update README with the public URL. Commit: `docs(239): live at amaru-treasury.plutimus.com`.

---

## Phase 6 — Close

- [ ] **T026** Open PR for `feat/239-treasury-inspect-dashboard` against `main`. PR description carries the curl-suite output as evidence of the live deploy. After CI green and merge, close #239 (auto-closed by the PR body's `Closes #239`).

---

## Independent-test mapping

| User story | Tasks delivering it | Test |
|---|---|---|
| US2 — external tool reads HTTP | T001–T011 | `quickstart.md` §4 curl-suite, including byte-identity diff |
| US1 — operator sees live state in browser | T012–T022 (on top of US2) | Browser visit at the public URL, viewport check at 320 px |
| US3 — operator hits fresh deployment | T023–T025 | `curl /v1/version` before/after redeploy; read-only invariant probe (quickstart §6) |

Bisect safety: every task closes the `nix flake check` gate; reverting any single task does not break a downstream gate (failing tests are owned by the task that introduces the feature they test).
