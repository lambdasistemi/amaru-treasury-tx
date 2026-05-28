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

- [X] **T007 [D]** **RED**: a `runCommand` Nix check that
  inspects the built image's manifest and asserts the volume
  mount point `/var/lib/amaru-treasury/indexer-rocksdb`
  appears in the `Volumes` directive, and asserts
  `--indexer-db /var/lib/amaru-treasury/indexer-rocksdb` is
  in the image Cmd. Add to `nix/checks.nix`. Fails before the
  image is edited.

- [X] **T008 [F][D]** **GREEN**:
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

- [X] **T009 [H]** **RED** + **GREEN** in one commit. Write
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

- [X] **T010 [F]** Extend `./gate.sh` to run the smoke. Single
  commit. Subject:
  `chore: extend gate.sh with devnet indexer smoke`.

  **Fold T009 + T010 into one bisect-safe commit.** Tasks
  trailer: `Tasks: T009, T010`. Worker pair.

## Phase 6 — Documentation + asciinema cast

- [X] **T011 [O]** Prose doc page at
  `docs/api-container-indexer.md` covering the embed model,
  CLI flags, RocksDB volume sizing, readiness probe
  semantics, operator procedure for "wipe RocksDB and
  re-sync". Add to `mkdocs.yml` nav. Commit (orchestrator-
  mechanical, no behaviour change):
  `docs(242): operator doc for the in-process indexer embed`.

- [X] **T012 [O]** Asciinema cast at
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

## Phase 8 — Live-mainnet boot bug fix (post-finalize regression)

- [ ] **T014 [H]** Fix `icByronEpochSlots = 21_600` (was `86_400`,
  caused `ApplyConflict {acSlot = 0, acExistingBlockHash =
  "89d9b5a5b8ddc802..."}` on every chain-sync reconnect — discovered
  2026-05-25T16:23Z during dev validation, container never binds warp,
  traefik 502). Mainnet Byron `EpochSlots = 10·k = 21_600` per
  `byron-genesis.json` `protocolConsts.k = 2160`; wrong value made the
  Byron CBOR decoder reconstruct a different block at slot 0 than what
  the chain-sync server returned. Add a unit test in
  `test/unit/Amaru/Treasury/Api/IndexerSpec.hs` asserting the default
  `icByronEpochSlots == 21_600`. RED: fails with current 86_400.
  GREEN: change `app/amaru-treasury-tx-api/Main.hs:278` from `86_400`
  to `21_600`; update comment at
  `lib/Amaru/Treasury/Api/Indexer.hs:149-152`.

  **Live-validation gate (mandatory before navigator NAVIGATOR-VERIFIED)**:
  Operator sequencing update (2026-05-28): run the devnet API smoke
  repair/proof in T023 first, then the transaction-inserting QA proof
  in T024, then the tx-build indexer-provider wiring proof in T025.
  Only return to this mainnet/dev endpoint E2E gate after the devnet
  proof is healthy, the build endpoints are using the embedded indexer
  for address UTxO reads, the operator is happy with that evidence, and
  Slice B
  [#243](https://github.com/lambdasistemi/amaru-treasury-tx/issues/243)
  has proved `amaru-treasury-tx history --scope X` on devnet with
  submitted disburse + reorganize entries. `#242` does not implement
  tx history; it remains a pre-reality cross-ticket gate.

  rebuild + redeploy to `/home/paolino/services/amaru-treasury-dev`
  using the dev iteration loop (per
  `deploy/compose/amaru-treasury-dev/docker-compose.yaml` header
  comment), with an upstream-shaped start point injected into the
  command list to bound the cold-sync window:
  `--indexer-start-slot 174999998` plus
  `--indexer-start-block-hash
  777668efebcac3d2d32c19a821878cc27f373ebd24dcc5bd971ea33cfd6734b3`.
  This is the nearest block at or before absolute slot `175000000`
  per Koios `blocks?abs_slot=lte.175000000&order=abs_slot.desc&limit=1`.
  URL
  `https://amaru-treasury.dev.plutimus.com/api/inspect` must
  transition `502 → 503 → 200` within 10 min, and container logs must
  show `event=connected` + `applied slot N` lines (no more
  `ApplyConflict`). On NAVIGATOR-VERIFIED, leave the new compose +
  binary in place so dev runs the fixed build going forward.

  **Fold T014 into one bisect-safe commit.** Commit:
  `fix(242): use mainnet Byron EpochSlots = 21_600`. Tasks trailer:
  `Tasks: T014`. Worker pair (re-briefed in-place).

  **Owned files**:
  - `app/amaru-treasury-tx-api/Main.hs`
  - `lib/Amaru/Treasury/Api/Indexer.hs`
  - `test/unit/Amaru/Treasury/Api/IndexerSpec.hs`

## Phase 8.5 — Bootstrap post-#165 downstream corrections

- [X] **T015 [F][H]** Adopt the post-#165
  `cardano-node-clients` tip and populate the newly-required
  `ChainSyncConfig` fields in one bisect-safe commit. Parent
  answer
  `/tmp/atx-254-blkidx/answers/A-001-bootstrap-slice-split.md`
  approved combining `cabal.project` with
  `lib/Amaru/Treasury/Api/Indexer.hs`, because the pin alone
  fails the gate and the reverse order also fails. Commit:
  `chore(api): bump cnc pin to post-#165 tip + populate ChainSyncConfig`.
  Tasks trailer: `Tasks: T015`. Worker pair:
  `bootstrap-pin-indexer-driver` / `bootstrap-pin-indexer-navigator`.

- [X] **T016 [H]** Switch the embedded indexer's interest set to
  `IndexAll` in `app/amaru-treasury-tx-api/Main.hs`, with the
  operator log explaining that wizard flows need arbitrary wallet
  UTxOs. Commit:
  `feat(api): switch indexer interest set to IndexAll`.
  Tasks trailer: `Tasks: T016`. Worker pair.

- [X] **T017 [H]** Add `hBuildDisburse` and `hBuildReorganize`
  stubs to
  `test/devnet/Amaru/Treasury/Api/IndexerSmokeSpec.hs` so the
  smoke handlers compile after the `Handlers` record grew.
  Commit:
  `test(api-smoke): add hBuildDisburse + hBuildReorganize stubs`.
  Tasks trailer: `Tasks: T017`. Worker pair.

## Phase 8.6 — Upstream block-indexer adoption

- [X] **T018 [F]** Adopt the upstream `cardano-node-clients`
  block-indexer extraction from `a8f830a99685a075fb01c9044023cf163e6a651c`.
  Bump the `cardano-node-clients` SRP sha to
  `19bswg4jy1agccrx1w1iikms0fp84jq0fp8k140z6cbd7sca70mp`; verify
  `chain-follower` already matches upstream and stays unchanged; add
  `cardano-node-clients:block-indexer` beside the existing
  `utxo-indexer-lib` dependency where needed. Commit:
  `chore(api): bump cnc pin to a8f830a + add block-indexer dep`.
  Tasks trailer: `Tasks: T018`. Worker pair.

- [X] **T019 [H]** Migrate `withApiIndexer` internals to the
  upstream `IndexerHandler` path by registering
  `liveUtxoHandler interestSet :| []` through the new indexer
  handler configuration. Preserve the public `withApiIndexer`
  surface and remove downstream dispatch code made redundant by
  upstream `BlockIndexer.Engine`. Commit:
  `refactor(api): migrate withApiIndexer to IndexerHandler`.
  Tasks trailer: `Tasks: T019`. Worker pair.

- [X] **T020 [H]** Keep the downstream readiness bridge and WAI
  lag guard, but replace local pure readiness lag math with
  `Cardano.Node.Client.BlockIndexer.Readiness` helpers. Use either
  a type alias over the upstream readiness snapshot or a thin adapter
  if the downstream API shape requires it. Commit:
  `refactor(api): use upstream BlockIndexer.Readiness pure helpers`.
  Tasks trailer: `Tasks: T020`. Worker pair.

- [X] **T021 [F]** Re-pin `cardano-node-clients` from the final
  PR #169 head `57dc17b9ba2a383211762bd473946c303ed00cf9` to the
  merged `main` commit
  `9353c889c9a531e535ed7e9d8b6b0ad4fa621ec7`. The fixed-output
  sha stays `1qcdy0wnx58v7agpzk5rjwchifld2sacxv6q8fsmgb8kwgd2q8gv`
  because the merge commit has the same source tree. Commit:
  `chore(api): repin cnc to merged handler seam`.
  Tasks trailer: `Tasks: T021`. Worker pair.

- [X] **T022 [H]** Project the API cold-boot override into the
  upstream-shaped `ChainSyncConfig.csStartPoint`.
  `cardano-node-clients` now correctly requires a concrete
  `(SlotNo, BlockHash)` start point; a slot alone is not a valid
  chain-sync intersection point. Extend the API operator/config
  surface with `--indexer-start-block-hash HASH` (and matching YAML/env
  keys where the existing start-slot setting is mirrored), fail config
  resolution when one half of the pair is supplied without the other,
  and make `toChainSyncCfg` set
  `csStartPoint = Just (icStartSlot, icStartBlockHash)` when both are
  present. RED: focused config/indexer tests prove the current code
  accepts a lone slot and projects `Nothing`. GREEN: tests prove the
  pair resolves, the lone-slot/lone-hash cases fail with a diagnostic,
  and `toChainSyncCfg` passes the pair through. Commit:
  `fix(api): project configured chain-sync start point`. Tasks trailer:
  `Tasks: T022`. Worker pair.

  **Owned files**:
  - `app/amaru-treasury-tx-api/Main.hs`
  - `lib/Amaru/Treasury/Api/Config.hs`
  - `lib/Amaru/Treasury/Api/Indexer.hs`
  - `lib/Amaru/Treasury/Config/OptEnv.hs`
  - `lib/Amaru/Treasury/Config/Resolve.hs`
  - `lib/Amaru/Treasury/Config/Types.hs`
  - `test/unit/Amaru/Treasury/Api/ConfigSpec.hs`
  - `test/unit/Amaru/Treasury/Api/HandlersIndexerSpec.hs`
  - `test/unit/Amaru/Treasury/Api/IndexerSpec.hs`
  - `test/unit/Amaru/Treasury/Config/FileSpec.hs`

## Phase 8.7 — Devnet-first proof before E2E

- [X] **T023 [H]** Repair the opt-in API devnet smoke after T022's
  start-point contract change, then run it before any further
  mainnet/dev endpoint E2E validation. `test/devnet/Amaru/Treasury/Api/IndexerSmokeSpec.hs`
  still constructs `IndexerConfig` with the retired `icStartSlot`
  field; update the smoke to the new `icStartPoint` shape. Prefer
  `Nothing` if the devnet follower should start from origin, or a real
  `(SlotNo, BlockHash)` only if the devnet harness exposes a stable
  block hash cheaply. RED: `nix develop --quiet -c cabal build
  test:devnet-tests -O0` fails on `icStartSlot`. GREEN: the same
  build succeeds, then `nix develop --quiet -c just devnet-api-smoke`
  passes. Commit:
  `test(api-smoke): update devnet smoke for start-point config`.
  Tasks trailer: `Tasks: T023`. Worker pair.

  **Owned files**:
  - `amaru-treasury-tx.cabal` (scope-widened 2026-05-28:
    `devnet-tests` threaded runtime flags only)
  - `test/devnet/Amaru/Treasury/Api/IndexerSmokeSpec.hs`

- [X] **T024 [H]** Strengthen the opt-in API devnet smoke from
  lifecycle/readiness proof to transaction-inserting QA. The smoke must
  follow the upstream `cardano-tx-generator` proof shape from
  `cardano-tx-tools:tx-generator-lib`: submit the transaction, compute
  the exact expected output `TxIn`, wait for the embedded indexer to
  observe that `TxIn` (via `awaitTxIn` or an equivalent
  `snapshotUtxosAt` poll), and only then assert the phase as detected.
  A bare HTTP 200 JSON object is not sufficient.

  **Required devnet sequence**:
  1. Boot the local `cardano-node-clients:devnet` node and the API
     harness.
  2. Before starting the API embedded indexer, wait until the devnet has
     forged more than its stability-window/security-parameter blocks
     (derive the window from the devnet genesis/harness or the indexer
     config; do not guess). Record the observed tip/stability values in
     the smoke failure/success output. This ordering is mandatory:
     `withApiIndexer` starts only after the pre-indexer stability wait.
  3. Start the API embedded indexer with `IndexAll` so arbitrary wallet
     and treasury UTxOs can be indexed.
  4. Create or reuse devnet metadata for `core_development` from the
     devnet registry artifacts, not mainnet fixture addresses.
  5. Insert a submitted disburse-phase transaction and wait for enough
     chain progress that the indexer observes the expected treasury
     continuation output and beneficiary output.
  6. Insert a submitted reorganize-phase transaction (not just an
     unsigned build/asset-preservation check) and wait for enough chain
     progress that the indexer observes the expected merged treasury
     continuation output.
  7. Assert `/v1/treasury-inspect?scope=core_development` is served from
     indexed state after each phase and carries the expected treasury
     UTxO count/value transition. Preserve the existing readiness
     `200 -> forced 503 -> restored 200` scenarios after the indexed
     state assertions.

  **Upstream reference**: mirror the generator's QA invariant from
  `/code/cardano-tx-tools/lib-tx-generator/Cardano/Tx/Generator/Daemon.hs`
  around `Submitted -> awaitTxIn expected-output`, plus the TxBuild
  composition style in
  `/code/cardano-tx-tools/lib-tx-generator/Cardano/Tx/Generator/Build.hs`.
  If importing `cardano-tx-tools:tx-generator-lib` directly is not the
  smallest reliable path, copy the invariant, not the daemon.

  **History gate remains cross-ticket**: #242 may prove indexed UTxOs
  and phase ledger effects. It must not claim tx-history readiness.
  Before T014 enters the real dev/mainnet endpoint, #243 must still
  prove `amaru-treasury-tx history --scope core_development` on devnet
  returns both submitted entries with correct `disburse` and
  `reorganize` roles.

  RED: `nix develop --quiet -c just devnet-api-smoke` on the current
  branch passes while proving only lifecycle/readiness; update the smoke
  so this old behavior fails the new assertions (missing indexed phase
  observations). GREEN: the same command submits both phase
  transactions, waits for indexer observations, asserts inspect content,
  and passes. Commit:
  `test(api-smoke): prove devnet indexed phase transactions`.
  Tasks trailer: `Tasks: T024`. Worker pair.

  **Owned files**:
  - `amaru-treasury-tx.cabal` (only if a devnet-test module or
    `cardano-tx-tools:tx-generator-lib` dependency is required)
  - `test/devnet/Amaru/Treasury/Api/IndexerSmokeSpec.hs`
  - `test/devnet/Amaru/Treasury/Devnet/SmokeSpec.hs` (only for shared
    helper extraction/reuse; do not alter unrelated devnet phases)
  - `test/devnet/Amaru/Treasury/Devnet/MixedUtxoSmoke.hs` (only for
    helper extraction/reuse; do not weaken its assertions)

- [ ] **T025 [H]** Wire the API tx-build endpoints to the embedded
  indexer-backed provider before any mainnet/reality endpoint test.
  `POST /v1/build/swap`, `/v1/build/disburse`, and
  `/v1/build/reorganize` must not receive the raw live node provider
  for address UTxO selection. Their provider must serve address UTxO
  reads from `ApiIndexer`/`snapshotUtxosAt`; the live provider may
  remain only for non-address UTxO ledger data that the indexer does
  not own, such as protocol parameters, ledger snapshots/tips,
  evaluation, rewards, votes, and governance queries.

  Preserve the existing `treasury-inspect` indexer behavior. If final
  transaction assembly still requires exact-`TxIn` lookup through
  `queryUTxOByTxIn`, handle it deliberately. Prefer serving it from
  upstream `UTxOIndexer.Indexer.awaitTxIn`/observation data (zero
  timeout for point lookup) so exact-input reads are indexer-backed too;
  otherwise document and test the narrow exact-input exception. Do not
  silently fall back to live node address queries.

  RED: add a focused unit/wiring test that proves current API build
  handler wiring passes the raw backend into `runBuildSwap`,
  `runBuildDisburse`, and `runBuildReorganize` (or otherwise would call
  live `queryUTxOs` during address selection) instead of an
  indexer-backed provider. GREEN: construct one shared
  indexer-backed build provider after `withApiIndexer` starts, pass it
  to all three build handlers, and prove with a trapped real provider
  that live `queryUTxOs` is not used by the build wiring. Keep
  `nix develop --quiet -c cabal build test:devnet-tests -O0` and
  `nix develop --quiet -c just devnet-api-smoke` green; the existing
  T024 smoke remains the devnet transaction-insertion proof for the
  indexed state after both phases. Commit:
  `fix(api): use indexer-backed provider for build UTxOs`. Tasks
  trailer: `Tasks: T025`. Worker pair.

  **Owned files**:
  - `app/amaru-treasury-tx-api/Main.hs`
  - `lib/Amaru/Treasury/Api/Indexer.hs`
  - `lib/Amaru/Treasury/Api/Server.hs`
  - `test/unit/Amaru/Treasury/Api/HandlersIndexerSpec.hs`
  - `test/unit/Amaru/Treasury/Api/ServerSpec.hs` (only if adding a
    dedicated server wiring spec is cleaner than extending
    `HandlersIndexerSpec`)
  - `test/devnet/Amaru/Treasury/Api/IndexerSmokeSpec.hs` (only if the
    smoke needs a small assertion that build handlers use the shared
    provider; do not weaken T024's transaction-insertion checks)
  - `amaru-treasury-tx.cabal` (only if a new test module or helper
    module is required)

## Phase 7 — PR finalization (re-do after T014 lands)

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
| 8.5a — post-#165 pin + ChainSyncConfig | T015 | `chore(api): bump cnc pin to post-#165 tip + populate ChainSyncConfig` — `1144cef8` |
| 8.5b — IndexAll interest set | T016 | `feat(api): switch indexer interest set to IndexAll` — `a50259bf` |
| 8.5c — devnet smoke handler stubs | T017 | `test(api-smoke): add hBuildDisburse + hBuildReorganize stubs` — `362f3eac` |
| 8.6a — a8f830a pin + block-indexer dep | T018 | `chore(api): bump cnc pin to a8f830a + add block-indexer dep` — `6baaae0b` |
| 8.6b — IndexerHandler migration | T019 | `refactor(api): migrate withApiIndexer to IndexerHandler` |
| 8.6c — upstream Readiness helpers | T020 | `refactor(api): use upstream BlockIndexer.Readiness pure helpers` |
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

### Slice 8.5a (T015)
- `cabal.project`
- `lib/Amaru/Treasury/Api/Indexer.hs`

### Slice 8.5b (T016)
- `app/amaru-treasury-tx-api/Main.hs`

### Slice 8.5c (T017)
- `test/devnet/Amaru/Treasury/Api/IndexerSmokeSpec.hs`

### Slice 8.6a (T018)
- `cabal.project`
- `amaru-treasury-tx.cabal`

### Slice 8.6b (T019)
- `lib/Amaru/Treasury/Api/Indexer.hs`

### Slice 8.6c (T020)
- `lib/Amaru/Treasury/Api/Readiness.hs`
- `lib/Amaru/Treasury/Api/Readiness/Internal.hs`
- readiness and lag-guard tests that directly depend on the readiness
  snapshot shape

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
