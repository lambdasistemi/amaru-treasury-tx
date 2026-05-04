# Tasks: Treasury Transaction CLI

**Input**: [`spec.md`](./spec.md), [`plan.md`](./plan.md), [`research.md`](./research.md), [`data-model.md`](./data-model.md), [`contracts/`](./contracts/), [`quickstart.md`](./quickstart.md)

**Tests**: Required — Constitution V mandates TDD with rebuild golden CBOR fixtures.

**Organization**: One vertical phase per user story (P1 → P2 → P3). Each phase is independently testable and deliverable.

## Format

`- [ ] T### [P?] [Story?] Description with absolute file path`

- **[P]**: parallelizable (different file, no dependency on incomplete tasks).
- **[USn]**: maps to a user story in [`spec.md`](./spec.md).
- File paths are repository-root-relative; the worktree root is `/code/amaru-treasury-tx-issue-6`.

---

## Phase 1: Setup (Shared infrastructure)

**Purpose**: Bootstrap the nix flake, cabal package, justfile, and CI; replace the stub workflow.

- [ ] T001 Add `flake.nix` with `haskell.nix` + IOG cache, mirroring the layout of [`/code/cardano-node-clients/flake.nix`](https://github.com/lambdasistemi/cardano-node-clients/blob/main/flake.nix). Path: `/code/amaru-treasury-tx-issue-6/flake.nix`.
- [ ] T002 [P] Add `nix/project.nix` (haskell.nix `cabalProject'` with CHaP, dev-shell tools `cabal`, `cabal-fmt`, `fourmolu`, `hlint`, `haskell-language-server`, `hoogle`, `just`, `nixfmt-classic`, `shellcheck`). Path: `/code/amaru-treasury-tx-issue-6/nix/project.nix`.
- [ ] T003 [P] Add `nix/fix-libs.nix` mirroring [`/code/cardano-node-clients/nix/fix-libs.nix`](https://github.com/lambdasistemi/cardano-node-clients/blob/main/nix/fix-libs.nix) (cardano crypto pkgconfig overrides). Path: `/code/amaru-treasury-tx-issue-6/nix/fix-libs.nix`.
- [ ] T004 [P] Add `nix/checks.nix` exporting `library`, `exe`, `unit`, `golden`, `lint`. Path: `/code/amaru-treasury-tx-issue-6/nix/checks.nix`.
- [ ] T005 [P] Add `nix/apps.nix` wrapping the runnable checks via `pkgs.lib.getExe`. Path: `/code/amaru-treasury-tx-issue-6/nix/apps.nix`.
- [ ] T006 Add `cabal.project` with the `index-state` block plus the SRP pin recorded in [`research.md` R1](./research.md#r1--cardano-node-clients-pin) (`8cc0605…`, nix32 `0hg02m3qn7v08w6w7bvy391nasvsl3i4lm0pq8pm01j1ikl5hzvd`). Path: `/code/amaru-treasury-tx-issue-6/cabal.project`.
- [ ] T007 Add `amaru-treasury-tx.cabal` (library + exe `amaru-treasury-tx` + `unit-tests` + `golden-tests` test-suites; `common warnings` block per [`/haskell` skill](https://github.com/paolino/llm-settings/tree/main/shared/skills/haskell)). Path: `/code/amaru-treasury-tx-issue-6/amaru-treasury-tx.cabal`.
- [ ] T008 [P] Add `justfile` recipes (`build`, `unit`, `golden`, `format`, `format-check`, `hlint`, `ci`). Path: `/code/amaru-treasury-tx-issue-6/justfile`.
- [ ] T009 Replace the CI stub with a real workflow that builds `.#checks.x86_64-linux.{library,exe,unit,golden,lint}` in the `Build Gate` job and runs `unit`, `golden`, `lint` apps in downstream jobs. Path: `/code/amaru-treasury-tx-issue-6/.github/workflows/ci.yml`.
- [ ] T010 Add minimal `lib/Amaru/Treasury.hs` library entry-point exporting nothing yet (so `cabal build` and `nix build .#checks.x86_64-linux.library` succeed before any feature work). Path: `/code/amaru-treasury-tx-issue-6/lib/Amaru/Treasury.hs`.

**Checkpoint**: `nix develop -c just ci` passes on this branch with an empty library and a stub `Main`.

---

## Phase 2: Foundational (Blocking prerequisites for ALL user stories)

**Purpose**: Pure types, parsers, and the `Backend` alias that every user story depends on. No user story work can start until this phase is green.

- [ ] T011 [P] Implement `Amaru.Treasury.Scope` (`ScopeId` sum, `Bounded`/`Enum`, `scopeText`, `scopeFromText`, `Aeson` instance) per [`data-model.md` §1](./data-model.md). Path: `lib/Amaru/Treasury/Scope.hs`.
- [ ] T012 [P] `ScopeSpec` — golden round-trip of all five scope identifiers. Path: `test/unit/Amaru/Treasury/ScopeSpec.hs`.
- [ ] T013 [P] Implement `Amaru.Treasury.Constants` (`Unit ADA | USDM`, `usdmPolicy`, `usdmAsset` from [`defaults.sh`](https://github.com/pragma-org/amaru-treasury/blob/main/journal/2026/defaults.sh)). Path: `lib/Amaru/Treasury/Constants.hs`.
- [ ] T014 [P] Implement `Amaru.Treasury.Metadata` (`ScriptRef`, `ScopeMetadata`, `TreasuryMetadata`, `readMetadataFile`, Aeson `FromJSON`/`ToJSON` matching [`metadata-schema.json`](./contracts/metadata-schema.json)) per [`data-model.md` §2](./data-model.md). Path: `lib/Amaru/Treasury/Metadata.hs`.
- [ ] T015 [P] `MetadataSpec` — parse the checked-in fixture `test/fixtures/metadata.json` and assert all five scopes resolve with the expected hashes. Path: `test/unit/Amaru/Treasury/MetadataSpec.hs`.
- [ ] T016 Add fixture `test/fixtures/metadata.json` (verbatim copy of [`pragma-org/amaru-treasury/journal/2026/metadata.json`](https://github.com/pragma-org/amaru-treasury/blob/main/journal/2026/metadata.json)). Path: `test/fixtures/metadata.json`.
- [ ] T017 [P] Implement `Amaru.Treasury.Redeemer` with hand-written `ToData` for `TreasurySpendRedeemer` (constructors per [`research.md` R2](./research.md#r2--sundae-redeemer-constructor-numbers)) and the empty-list permissions/withdraw redeemers. Path: `lib/Amaru/Treasury/Redeemer.hs`.
- [ ] T018 [P] `RedeemerSpec` — assert the CBOR bytes for `DisburseValue 1_000_000` (lovelace) and `Reorganize` match expected hex strings recorded by running [`make_redeemer_disburse.sh`](https://github.com/pragma-org/amaru-treasury/blob/main/journal/2026/lib/make_redeemer_disburse.sh) and [`make_redeemer_reorganize.sh`](https://github.com/pragma-org/amaru-treasury/blob/main/journal/2026/lib/make_redeemer_reorganize.sh) once locally. Path: `test/unit/Amaru/Treasury/RedeemerSpec.hs`.
- [ ] T019 Implement `Amaru.Treasury.Backend` as a thin alias around `Cardano.Node.Client.Provider` (`type Backend = Provider IO`). Path: `lib/Amaru/Treasury/Backend.hs`.
- [ ] T020 Implement `Amaru.Treasury.Backend.N2C` (`mkLocalNodeBackend :: FilePath -> NetworkMagic -> IO Backend` via `mkN2CProvider` and the existing N2C `Connection`). Path: `lib/Amaru/Treasury/Backend/N2C.hs`.
- [ ] T021 Implement `Amaru.Treasury.UtxoSelect` (newtypes `WalletUtxo`, `TreasuryUtxo`; `selectByLovelace`, `selectByUsdm`, `loadBlacklist`) per [`spec.md` FR-013…FR-015](./spec.md#functional-requirements). Path: `lib/Amaru/Treasury/UtxoSelect.hs`.
- [ ] T022 [P] `UtxoSelectSpec` — property tests: selection terminates, blacklist is honoured, leftover preserves all non-target assets. Path: `test/unit/Amaru/Treasury/UtxoSelectSpec.hs`.
- [ ] T023 Implement `Amaru.Treasury.AuxData` — port [`treasury_instance_metadata.sh`](https://github.com/pragma-org/amaru-treasury/blob/main/journal/2026/lib/treasury_instance_metadata.sh) to a `Metadatum` builder. Path: `lib/Amaru/Treasury/AuxData.hs`.
- [ ] T024 [P] `AuxDataSpec` — assert the produced auxiliary-data CBOR matches a recorded hex from running the bash once. Path: `test/unit/Amaru/Treasury/AuxDataSpec.hs`.
- [ ] T025 Implement `Amaru.Treasury.Validity` — `computeUpperBound :: Provider IO -> Word64 -> IO SlotNo` (wall-clock + `posixMsToSlot` + `--ttl-seconds`) per [`research.md` R4](./research.md#r4--provider-capability-gap-analysis). Path: `lib/Amaru/Treasury/Validity.hs`.
- [ ] T026 Implement `Amaru.Treasury.Summary` (`TxSummary`, `RedeemerSummary`, `RedeemerPurpose`, `ToJSON` matching [`summary-schema.json`](./contracts/summary-schema.json)). Path: `lib/Amaru/Treasury/Summary.hs`.
- [ ] T027 [P] `SummarySpec` — round-trip a sample `TxSummary` against the schema. Path: `test/unit/Amaru/Treasury/SummarySpec.hs`.
- [ ] T028 Add the **golden harness**: a Hspec helper that takes `(metadata.json, intent.json, utxos.json, pparams.json, slotNo)` → builds the tx via the chosen `TxBuild` program → strips ExUnits → compares body CBOR to a checked-in `body.cbor`. Path: `test/golden/Amaru/Treasury/Tx/GoldenHarness.hs`.
- [ ] T029 Add `pparams.json` fixture frozen against the local mainnet node (`/code/cardano-mainnet/ipc/node.socket`) — recorded once via `cardano-cli query protocol-parameters`. Path: `test/fixtures/pparams.json`.

**Checkpoint**: every unit test file above is red-failing or trivially passing; library compiles; golden harness builds without any specific golden yet.

---

## Phase 3: User Story 1 — Disburse ADA to a vendor (P1) 🎯 MVP

**Goal**: end-to-end ADA disbursement: parse CLI, build CBOR, emit summary, golden test against local mainnet.

**Independent test**: `nix develop -c just golden -- --match "ada-disburse"` rebuilds the tx from `test/fixtures/ada-disburse/{intent,utxos,pparams}.json` against `test/fixtures/metadata.json`, strips ExUnits, and compares to `test/fixtures/ada-disburse/body.cbor`. Pass = green.

- [ ] T030 [P] [US1] Write `Amaru.Treasury.Tx.Disburse.DisburseSpec` golden — fails red until T034 lands. Path: `test/golden/Amaru/Treasury/Tx/DisburseSpec.hs`.
- [ ] T031 [US1] Add fixture inputs for ADA disburse: synthesized `(TxIn, TxOut)` set, intent JSON, recorded `pparams.json` reference. Path: `test/fixtures/ada-disburse/{intent.json,utxos.json,pparams.json}`.
- [ ] T032 [US1] Generate the golden body once: run a one-shot helper that uses the local mainnet node + the unimplemented builder from T034 to produce `body.cbor`. Commit the result. Path: `test/fixtures/ada-disburse/body.cbor`.
- [ ] T033 [US1] Implement `Amaru.Treasury.Tx.Disburse.DisburseIntent` data type (per [`data-model.md` §6](./data-model.md)) plus a smart constructor that validates the witness keyhashes are configured scope owners. Path: `lib/Amaru/Treasury/Tx/Disburse.hs`.
- [ ] T034 [US1] Implement `Amaru.Treasury.Tx.Disburse.disburseProgram` as a pure `TxBuild q e ()` mirroring [`build_transaction.sh`](https://github.com/pragma-org/amaru-treasury/blob/main/journal/2026/lib/build_transaction.sh) for ADA only: spend treasury UTxOs (script witness with `DisburseValue`), wallet fuel input + collateral, registry/scope-owners read-only refs, treasury+permissions deployed-script refs, withdraw-zero on permissions reward account, beneficiary output, leftover treasury output, required signers, validity bound, aux-data. Path: `lib/Amaru/Treasury/Tx/Disburse.hs`.
- [ ] T035 [US1] Wire `app/amaru-treasury-tx/Main.hs` `disburse` subcommand: `optparse-applicative` parser (positional args per [`contracts/cli.md`](./contracts/cli.md)), backend wiring, intent construction, builder call, CBOR + summary emission. Path: `app/amaru-treasury-tx/Main.hs`.
- [ ] T036 [US1] E2E happy-path test in `test/golden/Amaru/Treasury/Tx/DisburseSpec.hs`: run the binary against the fixtures and verify CBOR equals `body.cbor` and summary equals `summary.json`. Path: `test/golden/Amaru/Treasury/Tx/DisburseSpec.hs`.
- [ ] T037 [US1] E2E error-path test: insufficient treasury ADA → non-zero exit, single-line stderr. Path: `test/golden/Amaru/Treasury/Tx/DisburseSpec.hs`.
- [ ] T038 [US1] E2E error-path test: witness keyhash not configured → non-zero exit. Path: `test/golden/Amaru/Treasury/Tx/DisburseSpec.hs`.

**Checkpoint**: `just ci` green; ada-disburse fixture round-trips; CLI usable end-to-end against a real node.

---

## Phase 4: User Story 2 — Disburse USDM to a vendor (P1)

**Goal**: extend Phase 3 to cover the USDM unit (different selection rule, different leftover semantics, beneficiary output carries USDM + min-ADA).

**Independent test**: `--match "usdm-disburse"` rebuilds the tx from `test/fixtures/usdm-disburse/`. Pass = green.

- [ ] T039 [P] [US2] `UsdmDisburseSpec` golden — fails red until T041 lands. Path: `test/golden/Amaru/Treasury/Tx/UsdmDisburseSpec.hs`.
- [ ] T040 [US2] Add USDM disburse fixture set (USDM-bearing treasury UTxO, intent with `usdm` unit). Path: `test/fixtures/usdm-disburse/{intent.json,utxos.json,body.cbor}`.
- [ ] T041 [US2] Extend `disburseProgram` to handle `Unit = USDM`: select by USDM quantity, beneficiary output carries `usdmPolicy.usdmAsset` plus `getMinCoinTxOut` lovelace, leftover treasury output carries leftover USDM and all spent ADA. Reuse the existing `disburseProgram` body. Path: `lib/Amaru/Treasury/Tx/Disburse.hs`.
- [ ] T042 [US2] Extend the `Main.hs` `disburse` subcommand parser to accept the `usdm` literal and route to the USDM path. Path: `app/amaru-treasury-tx/Main.hs`.
- [ ] T043 [US2] E2E: build a USDM disburse against the fixtures and assert body CBOR and summary. Path: `test/golden/Amaru/Treasury/Tx/UsdmDisburseSpec.hs`.

**Checkpoint**: `just ci` green; both ADA and USDM disburse fixtures round-trip.

---

## Phase 5: User Story 3 — Reorganize fragmented treasury UTxOs (P2)

**Goal**: merge multiple treasury UTxOs into a single output back to the treasury, signed only by the scope owner.

**Independent test**: `--match "reorganize"` rebuilds from `test/fixtures/reorganize/`. Pass = green.

- [ ] T044 [P] [US3] `ReorganizeSpec` golden — fails red until T047 lands. Path: `test/golden/Amaru/Treasury/Tx/ReorganizeSpec.hs`.
- [ ] T045 [US3] Add reorganize fixture set (three treasury UTxOs of distinct sizes). Path: `test/fixtures/reorganize/{intent.json,utxos.json,body.cbor}`.
- [ ] T046 [US3] Implement `Amaru.Treasury.Tx.Reorganize.reorganizeProgram` as a pure `TxBuild q e ()` per [`reorganize.sh`](https://github.com/pragma-org/amaru-treasury/blob/main/journal/2026/bin/reorganize.sh): spend selected treasury UTxOs with `Reorganize` redeemer, withdraw-zero on permissions reward account (redeemer `[]`), single merged output back to treasury, required signers = `[scopeOwner]` only. Path: `lib/Amaru/Treasury/Tx/Reorganize.hs`.
- [ ] T047 [US3] Wire `app/amaru-treasury-tx/Main.hs` `reorganize` subcommand. Path: `app/amaru-treasury-tx/Main.hs`.
- [ ] T048 [US3] E2E: build a reorganize against the fixtures and assert body CBOR + summary. Path: `test/golden/Amaru/Treasury/Tx/ReorganizeSpec.hs`.

**Checkpoint**: `just ci` green; three of four supported actions covered.

---

## Phase 6: User Story 4 — Withdraw treasury rewards into the contract (P3)

**Goal**: pull rewards from the treasury reward account into the contract address. Requires an upstream Provider extension.

**Independent test**: `--match "withdraw"` rebuilds from `test/fixtures/withdraw/`. Pass = green.

- [ ] T049 [US4] **Upstream**: open a PR on [`lambdasistemi/cardano-node-clients`](https://github.com/lambdasistemi/cardano-node-clients) extending `Cardano.Node.Client.Provider.Provider` with `queryStakeRewards :: Set RewardAccount -> m (Map RewardAccount Coin)`, backed by `GetFilteredDelegationsAndRewardAccounts` Conway query in `mkN2CProvider`. Tracked on its own issue; this CLI's PR does **not** land until that upstream merges. Result: a new commit on `cardano-node-clients` `main`.
- [ ] T050 [US4] Re-pin `cabal.project` to the bumped `cardano-node-clients` SHA (nix32 sha refreshed). Path: `/code/amaru-treasury-tx-issue-6/cabal.project`.
- [ ] T051 [P] [US4] `WithdrawSpec` golden — fails red until T053 lands. Path: `test/golden/Amaru/Treasury/Tx/WithdrawSpec.hs`.
- [ ] T052 [US4] Add withdraw fixture set (recorded reward-account balance, single fuel UTxO). Path: `test/fixtures/withdraw/{intent.json,utxos.json,rewards.json,body.cbor}`.
- [ ] T053 [US4] Implement `Amaru.Treasury.Tx.Withdraw.withdrawProgram` as a pure `TxBuild q e ()` per [`withdraw.sh`](https://github.com/pragma-org/amaru-treasury/blob/main/journal/2026/bin/withdraw.sh): single withdrawal entry against the treasury stake address (redeemer `[]`), treasury reference UTxO as withdrawal-tx-in-reference, registry reference as read-only, single output of rewards lovelace to the treasury contract address, no permissions, no witness scope owners. Path: `lib/Amaru/Treasury/Tx/Withdraw.hs`.
- [ ] T054 [US4] Wire `app/amaru-treasury-tx/Main.hs` `withdraw` subcommand: query rewards via the new `queryStakeRewards`; if zero, exit 0 with `nothing to withdraw` on stderr (no CBOR emitted). Path: `app/amaru-treasury-tx/Main.hs`.
- [ ] T055 [US4] E2E happy path: build a withdraw against the fixtures and assert body CBOR + summary. Path: `test/golden/Amaru/Treasury/Tx/WithdrawSpec.hs`.
- [ ] T056 [US4] E2E zero-rewards path: assert exit 0, stderr message, no stdout. Path: `test/golden/Amaru/Treasury/Tx/WithdrawSpec.hs`.

**Checkpoint**: all four supported actions covered; MVP complete.

---

## Phase 7: User Story 5 — Inspect tx summary before signing (P3)

**Goal**: ensure the JSON summary sidecar emitted by every subcommand is a stable, schema-conforming contract.

**Independent test**: parse the summary JSON written by each of the four golden runs and validate against [`contracts/summary-schema.json`](./contracts/summary-schema.json).

- [ ] T057 [P] [US5] Add `SummaryGoldenSpec` that runs each of the four binaries against their fixtures and validates the emitted JSON against the schema (using the `aeson-schemas` lib or hand-rolled validator). Path: `test/golden/Amaru/Treasury/SummaryGoldenSpec.hs`.
- [ ] T058 [P] [US5] Verify `redeemers[].index` matches the canonical sorted-input / sorted-withdrawal index for each action. Path: `test/golden/Amaru/Treasury/SummaryGoldenSpec.hs`.

**Checkpoint**: schema-validated summary across all subcommands.

---

## Phase 8: Polish & cross-cutting

- [ ] T059 [P] Add `--blacklist-file <path>` and repeated `--exclude <txid#ix>` flags to all three subcommands; thread through `UtxoSelect`. Path: `app/amaru-treasury-tx/Main.hs`, `lib/Amaru/Treasury/UtxoSelect.hs`.
- [ ] T060 [P] Add `--ttl-seconds <N>` flag (default 3600); thread through `Validity.computeUpperBound`. Path: `app/amaru-treasury-tx/Main.hs`.
- [ ] T061 [P] Add `--summary-out <path>` flag (default `<action>.summary.json`). Path: `app/amaru-treasury-tx/Main.hs`.
- [ ] T062 [P] Add `--help`/`--version` text matching the contract examples in [`contracts/cli.md`](./contracts/cli.md). Path: `app/amaru-treasury-tx/Main.hs`.
- [ ] T063 [P] `cabal check` clean (Haddock on every export, license, synopsis ≤ 80 chars, base upper bound). Path: `amaru-treasury-tx.cabal`.
- [ ] T064 [P] Add `README.md` with quickstart from [`quickstart.md`](./quickstart.md). Path: `/code/amaru-treasury-tx-issue-6/README.md`.
- [ ] T065 [P] `hlint` clean across `lib`, `app`, `test`. Path: workspace-wide.
- [ ] T066 [P] `fourmolu -m check` clean across `lib`, `app`, `test`. Path: workspace-wide.
- [ ] T067 Tag `v0.1.0` once all four user stories are green and `just ci` passes. Path: `/code/amaru-treasury-tx-issue-6/CHANGELOG.md` + git tag.

---

## Dependency graph (story completion order)

```
Phase 1 (Setup)        ──► Phase 2 (Foundational)
                                │
                                ├─► US1 ada-disburse   (P1, MVP)
                                ├─► US2 usdm-disburse  (P1)
                                ├─► US3 reorganize     (P2)
                                └─► US4 withdraw       (P3)  [blocked by upstream T049]
                                                │
                                                └─► US5 summary inspection (P3)
                                                        │
                                                        └─► Phase 8 polish
```

## Parallel-execution opportunities

- T002, T003, T004, T005 are file-disjoint and can land in one PR or four.
- T011, T013, T014, T017, T019, T021, T023, T026 are file-disjoint inside Phase 2.
- T030, T039, T044, T051 are independent goldens once their phases unblock.
- T059, T060, T061, T062, T063, T064, T065, T066 in Phase 8 are all parallel.

## MVP scope

User stories US1 + US2 (`ada disburse` + `usdm disburse`) deliver the core "pay a vendor" flow, which is what the upstream bash recipes are most-frequently used for ([`journal/2025/marketing.md`](https://github.com/pragma-org/amaru-treasury/blob/main/journal/2025/marketing.md)). Ship those, validate on preprod, then iterate to US3 and US4.

## Implementation strategy

1. Land Phase 1 + Phase 2 as a single PR — sets up the entire scaffolding and is `cabal check`-clean before any feature work.
2. Land each user-story phase as its own PR, in priority order (P1 → P1 → P2 → P3).
3. The upstream `queryStakeRewards` PR (T049) is its own PR on `cardano-node-clients`; the US4 phase PR includes only T050…T056 and depends on the upstream commit landing first.
4. Phase 7 lands alongside the last user-story PR.
5. Phase 8 is a separate cleanup PR before the v0.1.0 tag.

---

## Format validation

Every task above:

- [x] Starts with `- [ ]`.
- [x] Carries a `T###` ID.
- [x] Carries `[P]` if and only if file-disjoint from same-phase incomplete work.
- [x] Carries `[USn]` if and only if it lives in a user-story phase.
- [x] Names an absolute file path (worktree root: `/code/amaru-treasury-tx-issue-6`).
