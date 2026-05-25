---
description: "Bisect-safe TDD task breakdown for #242 (in-process indexer embed inside amaru-treasury-tx-api)"
---

# Tasks: in-process indexer embed inside `amaru-treasury-tx-api` (#242)

**Input**: design documents in `specs/242-api-indexer-embed/`
**Prerequisites**: spec.md, plan.md, research.md, data-model.md, contracts/, quickstart.md

**Tests**: yes — RED before GREEN on every behaviour-changing
slice; gate via `./gate.sh` (extended in Slice 4 to include the
devnet smoke).

## Format

Each task is one bisect-safe commit: RED test, GREEN
implementation, REFACTOR if needed. Conventional Commits.
Closes a clearly-defined chunk of plan.md.

Layout legend:
`[F]` = flake / nix wiring,
`[H]` = Haskell,
`[D]` = deploy / docker,
`[U]` = upstream (cardano-node-clients),
`[O]` = orchestrator-owned mechanical commit.

---

## Phase 0 — Baseline unblock

- [~] **T000a [F]** ~~Bump the stale `cardano-foundation/cardano-ledger-read` SRP pin.~~ **Cancelled** on 2026-05-24. The orchestrator initially observed `fatal: remote error: upload-pack: not our ref 34d0767bd5…` during a pre-commit gate run and assumed the pinned commit had been GC'd upstream. Slice 0a driver investigated: the pinned commit IS still reachable upstream via the `node-10.5.4` tag (visible in `git fetch` output for the SRP); the failure I observed was a transient parallel-fetch race in cabal-git (the failing sub-directory was `typed-pro_-…` while the error message named a `cuddle-1.1.1.0` ref — the diagnostic telltale of concurrent fetches interfering). A subsequent full `./gate.sh` ran clean from the worktree (`GATE_EXIT=0`, 47 unit+golden tests, fourmolu + hlint clean). No commit produced for T000a; the pair stood down. Evidence: `/tmp/atx-242/slice-0a-driver/handoffs/gate-baseline.txt`.

## Phase 1 — Upstream paired PRs

- [X] **T001 [U]** Open paired PR in [`lambdasistemi/cardano-node-clients`](https://github.com/lambdasistemi/cardano-node-clients) extracting `withChainSyncFollower` from `runDaemon` per [data-model.md §"Paired upstream types"](./data-model.md). The signature is bracketed-resource style returning a `FollowerHandle` that exposes `STM Readiness`. `runDaemon` is re-implemented atop it; existing daemon tests stay green. **Landed**: [`cardano-node-clients@bb0b8c38`](https://github.com/lambdasistemi/cardano-node-clients/commit/bb0b8c38) ([PR #157](https://github.com/lambdasistemi/cardano-node-clients/pull/157), branched off `main@38fc1917`). Re-pin to merged commit hash before this PR is marked ready. Worker: driver + navigator pair (slice-upstream-driver / slice-upstream-navigator).

- [X] **T001b [U]** Open second paired PR in `cardano-node-clients` adding an **interest-set address filter** on `withChainSyncFollower` per [issue #158](https://github.com/lambdasistemi/cardano-node-clients/issues/158). Extends `ChainSyncConfig` with `csInterestSet :: InterestSet` (`IndexAll | IndexAddressSet (Set Address)`), default `IndexAll` preserves current `runDaemon` behaviour. Apply-time semantics: `UtxoCreate` stored only if addr in set; `UtxoSpend` always processed (no-op if filtered-out at creation). Disk bound `O(|interestSet|)` instead of `O(entire chain)`. **Landed**: [`cardano-node-clients@2884f0f8`](https://github.com/lambdasistemi/cardano-node-clients/commit/2884f0f8) ([PR #159](https://github.com/lambdasistemi/cardano-node-clients/pull/159), branched off T001 at `bb0b8c38`). Re-pin to merged commit hash before this PR is marked ready. Worker: driver + navigator pair (slice-interest-set-upstream-driver / slice-interest-set-upstream-navigator).

## Phase 2 — Downstream runner module

- [X] **T002 [H]** **RED** for the runner module. Add
  `test/unit/Amaru/Treasury/Api/IndexerSpec.hs` exercising:
  (a) `withApiIndexer` opens a tmpfs RocksDB and starts a
  follower against an in-memory chain-sync fixture,
  (b) `Readiness` `TVar` transitions `Pending → Ready` after the
  follower processes its first batch,
  (c) `Lagging → Ready` round-trip when the follower pauses then
  resumes,
  (d) `snapshotAt` returns the same UTxO set the fixture wrote.
  Observe RED failure (`Variable not in scope: withApiIndexer`).

- [X] **T003 [H]** **GREEN** for the runner module. Implement
  `lib/Amaru/Treasury/Api/Indexer.hs` per
  [data-model.md §"Amaru.Treasury.Api.Indexer"](./data-model.md).
  Add the module to `library` `exposed-modules` in
  `amaru-treasury-tx.cabal`; add `utxo-indexer-lib` to the
  library's `build-depends`. Tests from T002 pass.

  **Fold T002 + T003 into one bisect-safe commit.** RED is
  observed in the worker pair's STATUS log (with the failing
  output); GREEN flips the same test. Commit:
  `feat(242): Amaru.Treasury.Api.Indexer runner + readiness gate`.
  Tasks trailer: `Tasks: T002, T003`. Worker pair (re-briefed
  in-place — see [[feedback-persistent-worker-panes]]).

## Phase 3 — Wire-up + cache removal (the behaviour-changing slice)

- [X] **T004 [H]** **RED** for the integrated handler. Add a
  fixture-backed test asserting that
  `inspectScope`-equivalent code paths, given an `ApiIndexer`
  populated with a known UTxO set + a mocked
  `nowTip backend`, produce the same `InspectReport` the
  pre-cache implementation would have produced for the same
  chain state. The test fails because the handler is still
  reading from `cachedInspect`.

- [X] **T005 [H]** **GREEN** for the integrated handler. Single
  commit covering:
  - extend `Amaru.Treasury.Api.Server.Handlers` with
    `ApiIndexer` per [data-model.md §"Amaru.Treasury.Api.Server"](./data-model.md),
  - add `mkInspectHandler` capturing the indexer + backend,
  - add the lag-503 guard helper (per
    [contracts/api-extension.md §"New error response"](./contracts/api-extension.md)),
  - add CLI flag parser `indexerOptsP` to
    `app/amaru-treasury-tx-api/Main.hs` per data-model.md,
  - thread `withApiIndexer` + `waitReady` through `main`,
  - **delete** from `Main.hs`: `type InspectCache`,
    `refreshIntervalSeconds`, `cachedInspect`, `refreshAll`,
    `refreshLoop`, the `withAsync` worker, the
    `cache <- newIORef Map.empty` boot line,
  - add `mainnetIndexerStartSlot :: SlotNo` to
    `lib/Amaru/Treasury/Constants.hs`.

  **Verification**: `git grep IORef app/amaru-treasury-tx-api/`
  returns nothing post-commit.

  **Fold T004 + T005 into one bisect-safe commit.** Commit:
  `feat(242): API container reads from in-process indexer; remove IORef cache`.
  Tasks trailer: `Tasks: T004, T005`. Worker pair.

## Phase 3.5 — Downstream interest-set plumb (consumes T001b)

- [X] **T006 [H]** Bump `cabal.project` SRP pin for `cardano-node-clients` from T001's `bb0b8c38` to T001b's `2884f0f8` (with recomputed `--sha256`). Extend `IndexerConfig` with `icInterestSet :: !InterestSet`; thread into `toChainSyncCfg`. Add `aiBridge :: !(Async ())` field to `ApiIndexer` so the readiness-mirror thread handle is captured (was previously ignored). Refactor `setReadinessForTest` to `cancel (aiBridge apiIdx)` before writing the TVar — fixes a latent race in slice 3 (T004+T005) where the bridge could overwrite the test's `Lagging` injection between the write and `withLagGuard`'s read, producing intermittent 404-instead-of-503 failures. Race was won by luck at slice-3 commit time (`7a7f4ed3`); the cabal pin bump in this slice perturbed scheduling enough to lose it consistently (2/3 fail), driving the fix. In `app/amaru-treasury-tx-api/Main.hs`, compute `interestSet = IndexAddressSet (Set.fromList (sundaeOrderAddressMainnet : map smAddress (Map.elems (tmTreasuries metadata))))`; on mainnet that's 5 treasuries + 1 swap address = 6 entries. Container RocksDB volume now bounded to `O(|interestSet|)`. **Landed**: [`24d6a58f`](https://github.com/lambdasistemi/amaru-treasury-tx/commit/24d6a58f). Tasks trailer: `Tasks: T006`. Worker pair (slice-interest-set-downstream-driver / slice-interest-set-downstream-navigator).

## Phase 4 — Container packaging

- [ ] **T007 [D]** **RED**: a `runCommand` Nix check that
  inspects the built image's manifest and asserts the volume
  mount point `/var/lib/amaru-treasury/indexer-rocksdb`
  appears in the `Volumes` directive, and asserts
  `--indexer-db /var/lib/amaru-treasury/indexer-rocksdb` is
  in the image Cmd. Add to `nix/checks.nix`. Fails before the
  image is edited.

- [ ] **T008 [F][D]** **GREEN**:
  - `nix/docker.nix` — add `Volumes` directive +
    `--indexer-db <path>` to Cmd,
  - `deploy/compose/amaru-treasury/docker-compose.yaml` —
    add named volume + binding,
  - `deploy/compose/amaru-treasury-dev/docker-compose.yaml`
    — same for dev variant.

  **Fold T007 + T008 into one bisect-safe commit.** Commit:
  `feat(242): persistent RocksDB volume for the embedded indexer`.
  Tasks trailer: `Tasks: T007, T008`. Worker pair.

## Phase 5 — Live-boundary devnet smoke

- [ ] **T009 [H]** **RED** + **GREEN** in one commit. Write
  `test/devnet/Amaru/Treasury/Api/IndexerSmokeSpec.hs` per
  [research.md §6](./research.md). The smoke boots the
  container against a devnet node with N2C trace recording,
  hits `/v1/treasury-inspect`, asserts:
  (a) HTTP 200 with a well-formed `InspectReport`,
  (b) the captured N2C trace contains exactly one
  `GetChainPoint` and ZERO `GetUTxOByAddress` /
  `GetUTxOByTxIn`,
  (c) HTTP 503 with the lagging body shape during a forced
  follower pause,
  (d) HTTP 200 returns within ~1 lag-threshold after
  follower resume.

- [ ] **T010 [F]** Extend `./gate.sh` to run the smoke. Single
  commit. Subject:
  `chore: extend gate.sh with devnet indexer smoke`.

  **Fold T009 + T010 into one bisect-safe commit.** Tasks
  trailer: `Tasks: T009, T010`. Worker pair.

## Phase 6 — Documentation + asciinema cast

- [ ] **T011 [O]** Prose doc page at
  `docs/api-container-indexer.md` covering the embed model,
  CLI flags, RocksDB volume sizing, readiness probe
  semantics, operator procedure for "wipe RocksDB and
  re-sync". Add to `mkdocs.yml` nav. Commit (orchestrator-
  mechanical, no behaviour change):
  `docs(242): operator doc for the in-process indexer embed`.

- [ ] **T012 [O]** Asciinema cast at
  `docs/assets/asciinema/amaru-treasury-tx-api.cast` showing
  container boot (readiness gate) + steady-state `curl
  /v1/treasury-inspect` + forced lag-503 with the JSON body.
  Recorded with the [`dev-assets/asciinema/compress`](https://github.com/paolino/dev-assets)
  flake. Embed in T010's doc page via the
  `asciinema-player` mkdocs plugin block. If the plugin is
  not yet registered in `mkdocs.yml`, add it together with
  the cast. Make `site_url` env-overridable
  (`!ENV [MKDOCS_SITE_URL, "<prod-url>"]`) and update the
  docs CI workflow to set `MKDOCS_SITE_URL` for PR previews
  (see spec.md §"Deliverables" Doc3). Commit:
  `docs(242): asciinema cast + plugin wiring for api container`.

## Phase 7 — PR finalization

- [ ] **T013 [O]** Edit GitHub issue #242 body via
  `gh issue edit 242 --body-file …` to replace the wizard
  framing with the API-container framing (old text moved to
  a history note at the bottom). Run finalization audit (see
  [[gate-script]] §"Finalization audit") against the current
  ticket's tasks.md. Drop `gate.sh` in a final commit:
  `chore: drop gate.sh (ready for review)`. `gh pr ready 254`.

  Tasks trailer: none on the gate-drop commit (chore exempted
  by the commit message gate).

## Task ↔ slice mapping

| Slice | Tasks | Commit |
|---|---|---|
| ~~0a — baseline unblock~~ | ~~T000a~~ | **Cancelled** — see Phase 0 note. No commit. |
| 1 — upstream withChainSyncFollower PR | T001 | (cardano-node-clients) `refactor: factor withChainSyncFollower out of runDaemon` — `bb0b8c38` (#157) |
| 1.5 — upstream interest-set filter PR | T001b | (cardano-node-clients) `feat(utxo-indexer): interest-set address filter on withChainSyncFollower` — `2884f0f8` (#159) |
| 2 — runner module | T002 + T003 | `feat(242): Amaru.Treasury.Api.Indexer runner + readiness gate` — `bc45a0dd` |
| 3 — rewire + cache removal | T004 + T005 | `feat(242): API container reads from in-process indexer; remove IORef cache` — `94990c28` |
| 3.5 — downstream interest-set plumb + slice-3 race fix | T006 | `feat(242): plumb treasury interest set into the embedded indexer` — `24d6a58f` |
| 4 — container packaging | T007 + T008 | `feat(242): persistent RocksDB volume for the embedded indexer` |
| 5 — devnet smoke | T009 + T010 | `feat(242): devnet smoke proves zero-GetUTxOByAddress on the request path` |
| 6 — docs page | T011 | `docs(242): operator doc for the in-process indexer embed` |
| 6 — asciinema cast | T012 | `docs(242): asciinema cast + plugin wiring for api container` |
| 7 — PR ready | T013 | `chore: drop gate.sh (ready for review)` |
| 4 — container packaging | T006 + T007 | `feat(242): persistent RocksDB volume for the embedded indexer` |
| 5 — devnet smoke | T008 + T009 | `feat(242): devnet smoke proves zero-GetUTxOByAddress on the request path` |
| 6 — docs page | T010 | `docs(242): operator doc for the in-process indexer embed` |
| 6 — asciinema cast | T011 | `docs(242): asciinema cast + plugin wiring for api container` |
| 7 — PR ready | T012 | `chore: drop gate.sh (ready for review)` |

## Owned-files manifest per slice

Used by the orchestrator when briefing each driver+navigator
pair. Anything not listed is forbidden scope for that slice.

### ~~Slice 0a (T000a)~~ — cancelled
N/A — no commit produced. See Phase 0 note.

### Slice 1 (T001) — upstream
- `cardano-node-clients/lib-utxo-indexer/lib/Cardano/Node/Client/UTxOIndexer/Daemon.hs`
- `cardano-node-clients/lib-utxo-indexer/lib/Cardano/Node/Client/UTxOIndexer/Follower.hs` (NEW)
- `cardano-node-clients/lib-utxo-indexer/test/...Spec.hs` (test for the new primitive)

### Slice 2 (T002 + T003)
- `lib/Amaru/Treasury/Api/Indexer.hs` (NEW)
- `test/unit/Amaru/Treasury/Api/IndexerSpec.hs` (NEW)
- `amaru-treasury-tx.cabal` (add `exposed-modules` entry + `build-depends` on `utxo-indexer-lib`)

### Slice 3 (T004 + T005)
- `lib/Amaru/Treasury/Api/Server.hs`
- `app/amaru-treasury-tx-api/Main.hs`
- `lib/Amaru/Treasury/Constants.hs`
- `test/unit/Amaru/Treasury/Api/HandlersIndexerSpec.hs` (NEW or extend IndexerSpec)
- `amaru-treasury-tx.cabal` (executable `build-depends` if needed)

### Slice 4 (T006 + T007)
- `nix/docker.nix`
- `deploy/compose/amaru-treasury/docker-compose.yaml`
- `deploy/compose/amaru-treasury-dev/docker-compose.yaml`
- `nix/checks.nix` (RED check)

### Slice 5 (T008 + T009)
- `test/devnet/Amaru/Treasury/Api/IndexerSmokeSpec.hs` (NEW)
- `gate.sh`
- `amaru-treasury-tx.cabal` (test stanza if needed)

### Slice 6 (T010 + T011)
- `docs/api-container-indexer.md` (NEW)
- `docs/assets/asciinema/amaru-treasury-tx-api.cast` (NEW)
- `mkdocs.yml`
- `.github/workflows/deploy-docs.yml` (if `MKDOCS_SITE_URL` wiring missing)

### Slice 7 (T012)
- `gate.sh` (removal)
- GitHub issue body (via `gh issue edit`, not a file edit)
- PR body (via `gh pr edit`, not a file edit)
