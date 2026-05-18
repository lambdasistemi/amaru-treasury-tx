---
description: "Task list for #158 — registry-init-wizard"
---

# Tasks: registry-init-wizard

**Input**: Design documents from `/specs/158-registry-init-wizard/`
**Prerequisites**: [spec.md](./spec.md), [plan.md](./plan.md), [research.md](./research.md)
**Tests**: Required — every behavior-changing slice ships RED + GREEN paired in one commit.

## Format: `[ID] [P?] [Story?] Description`

- **[P]**: Can run in parallel with sibling tasks within the same slice (different files, no dependencies on incomplete sibling tasks).
- **[Story]**: Maps the task to its primary user story from `spec.md` (US1 emit-intent, US2 library-core parity, US3 network safety, US4 docs alignment).
- File paths are absolute under the worktree root.

## Slice ↔ Phase ↔ Commit mapping

The plan defines 7 vertical bisect-safe slices. Each slice = one resolve-ticket subagent run = one commit on the branch. Phases below are the slices. Setup (Phase 1) and Foundational (Phase 2) are empty: `amaru-treasury-tx` already has its Haskell/Nix build infrastructure, test suites, and `./gate.sh` from prior PRs.

| Slice / Phase | Subagent brief inline | Primary US | Commit subject |
|---|---|---|---|
| 3 — Slice 1 | yes | US1 + US3 | `feat(cli): scaffold registry-init-wizard parser (#158)` |
| 4 — Slice 2 | yes | US1 + US2 + US3 | `feat(tx): registry-init-wizard seed-split + devnet guard (#158)` |
| 5 — Slice 3 | yes | US1 + US2 | `feat(tx): registry-init-wizard mint (#158)` |
| 6 — Slice 4 | yes | US1 + US2 | `feat(tx): registry-init-wizard reference-scripts (#158)` |
| 7 — Slice 5 | yes | US2 + US3 | `test(tx): registry-init-wizard no-simulation grep (#158)` |
| 8 — Slice 6 | orchestrator (no subagent) | US4 | `docs(158): registry-init-wizard operator path` |
| 9 — Slice 7 | orchestrator (no subagent) | — | `chore: drop gate.sh (ready for review) (#158)` |

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Project initialization.

No tasks — `amaru-treasury-tx` is an existing Haskell+Nix project. `./gate.sh` is already at `gate.sh` from the bootstrap commit `f0390ad6`.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Core infrastructure that must be complete before any user story can be implemented.

No tasks — the build/test infra (`nix build .#checks.*`, `just ci`, `just schema-check`, hspec) is in place. The three `SomeTreasuryIntent` variants (`RegistryInitSeedSplit`, `RegistryInitMint`, `RegistryInitReferenceScripts`) and the `requireDevnet` guard at the `tx-build` dispatcher were shipped by [#157 (PR #162)](https://github.com/lambdasistemi/amaru-treasury-tx/pull/162). `Support.RegistryInitFixtures` exists at `test/golden/Support/RegistryInitFixtures.hs`.

**Checkpoint**: Foundation ready — user story implementation begins at Phase 3 (Slice 1).

---

## Phase 3: Slice 1 — Wizard scaffolding + CLI parser + parser test (Priority: P1) 🎯

**Goal**: Ship the parser surface, the typed `Answers` records, the `RegistryInitError` type, and a TODO-stub runner for all three subcommands. After this slice, `amaru-treasury-tx registry-init-wizard --help` lists `seed-split | mint | reference-scripts`; each subcommand's `--help` lists its flags; invalid flags fail at parse time; the runner exits non-zero with a TODO. No translation logic yet — Slice 2 wires `seed-split`.

**Independent Test**: `nix develop --quiet -c cabal run amaru-treasury-tx -- registry-init-wizard --help` shows all three subcommands; each subcommand's `--help` shows the documented flag set; `nix build .#checks.unit` passes.

**Subagent brief** — one bisect-safe commit, no push, exactly the owned files below. Commit subject: `feat(cli): scaffold registry-init-wizard parser (#158)`. Commit body must include `Tasks: T001, T002, T003, T004, T005, T006, T007, T008`.

```text
Owned files (create or modify):
- lib/Amaru/Treasury/Tx/RegistryInitWizard.hs                                  (new)
- lib/Amaru/Treasury/Cli/RegistryInitWizard.hs                                 (new)
- lib/Amaru/Treasury/Cli.hs                                                    (wire subcommand dispatch)
- app/amaru-treasury-tx/Main.hs                                                (wire runner case)
- amaru-treasury-tx.cabal                                                      (expose new modules)
- test/unit/Amaru/Treasury/Cli/RegistryInitWizardParserSpec.hs                 (new)

Forbidden scope: anything under specs/, gate.sh, README.md, docs/, package metadata
outside amaru-treasury-tx.cabal, any other wizard module, the seven SomeTreasuryIntent
variants from #157 (read-only here).

Parser library reuse:
- Owner-key-hash parser MUST wrap optparse-applicative's eitherReader around
  Amaru.Treasury.LedgerParse.keyHashFromHex.
- TxIn parser MUST wrap eitherReader around Amaru.Treasury.LedgerParse.txInFromText.
- DO NOT reinvent hex-28 or "txid#ix" parsers locally.

Runner stub: each of the three sub-action runners is a pure `error "TODO Slice N"`
that exits non-zero; do NOT attempt any chain query or file write.
```

### Tests for Slice 1 (RED — written first, observed failing) ⚠️

- [X] T001 (commit: adc690f3) [P] [US1] Add hspec test `it "registry-init-wizard --help lists seed-split, mint, reference-scripts"` in `/code/amaru-treasury-tx-issue-158/test/unit/Amaru/Treasury/Cli/RegistryInitWizardParserSpec.hs`
- [X] T002 (commit: adc690f3) [P] [US1] Add hspec tests asserting each subcommand's `--help` lists its required flags (seed-split: `--wallet-addr --metadata --scope --out [--validity-hours --description --justification --destination-label --event --label --log --force]`; mint: same plus `--scopes-seed-txin --registry-seed-txin --owner-key-hash`; reference-scripts: same plus `--scopes-seed-txin --registry-seed-txin --funding-seed-txin`) in `/code/amaru-treasury-tx-issue-158/test/unit/Amaru/Treasury/Cli/RegistryInitWizardParserSpec.hs`
- [X] T003 (commit: adc690f3) [P] [US3] Add hspec test asserting malformed `--owner-key-hash` (not 56 hex chars) is rejected at the parser with a non-zero exit and a clear error in `/code/amaru-treasury-tx-issue-158/test/unit/Amaru/Treasury/Cli/RegistryInitWizardParserSpec.hs`
- [X] T004 (commit: adc690f3) [P] [US3] Add hspec test asserting malformed `--scopes-seed-txin`, `--registry-seed-txin`, `--funding-seed-txin` (not `<txid64hex>#<word16>`) are rejected at the parser in `/code/amaru-treasury-tx-issue-158/test/unit/Amaru/Treasury/Cli/RegistryInitWizardParserSpec.hs`
- [X] T005 (commit: adc690f3) [P] [US3] Add hspec test asserting `--out` pointing at a path whose parent directory does not exist surfaces a typed error before any work happens in `/code/amaru-treasury-tx-issue-158/test/unit/Amaru/Treasury/Cli/RegistryInitWizardParserSpec.hs`
- [X] T006 (commit: adc690f3) [P] [US3] Add hspec test asserting `--out` pointing at an existing file without `--force` surfaces a typed conflict error in `/code/amaru-treasury-tx-issue-158/test/unit/Amaru/Treasury/Cli/RegistryInitWizardParserSpec.hs`

### Implementation for Slice 1

- [X] T007 (commit: adc690f3) [US1] Create `RegistryInitSeedSplitAnswers`, `RegistryInitMintAnswers`, `RegistryInitReferenceScriptsAnswers` (typed records with `FromJSON` instances mirroring `WithdrawAnswers` shape) and `RegistryInitError` ADT (variants for `RegistryInitNonDevnetNetwork`, `RegistryInitWalletShortfall`, `RegistryInitOutputParentMissing`, `RegistryInitOutputExistsNoForce`, plus parser-only error wrappers) in `/code/amaru-treasury-tx-issue-158/lib/Amaru/Treasury/Tx/RegistryInitWizard.hs`
- [X] T008 (commit: adc690f3) [US1] Create `registryInitWizardOptsP :: Parser RegistryInitWizardOpts` with three subcommands (`seed-split`, `mint`, `reference-scripts`), reusing `LedgerParse.txInFromText` and `LedgerParse.keyHashFromHex` via `eitherReader`, plus TODO-stub runner for each arm; expose the parser and runner; expose the new modules in `/code/amaru-treasury-tx-issue-158/amaru-treasury-tx.cabal`; wire the parser into the top-level dispatcher in `/code/amaru-treasury-tx-issue-158/lib/Amaru/Treasury/Cli.hs` and the runner case into `/code/amaru-treasury-tx-issue-158/app/amaru-treasury-tx/Main.hs`

**Checkpoint**: parser test suite green; `--help` works end-to-end; runner exits non-zero with TODO; `./gate.sh` green.

---

## Phase 4: Slice 2 — Resolver + seed-split translation + golden + devnet guard (Priority: P1) 🎯

**Goal**: Make `seed-split` functional end-to-end; add the devnet-only resolver guard (new behavior, fail-fast UX); add the wallet-shortfall test path; introduce the shared wizard fixture helper that derives wizard `Answers + Env` from the same underlying material `Support.RegistryInitFixtures` uses for the library-core goldens.

**Independent Test**: `nix build .#checks.golden` runs the new `RegistryInitWizardSeedSplitSpec` and asserts wizard intent → `tx-build` CBOR == `buildSeedSplitCore` CBOR byte-for-byte; round-trip property for the seed-split JSON passes; network guard rejects mainnet/preprod/preview at the resolver layer before chain query; wallet-shortfall surfaces from the resolver.

**Subagent brief** — one bisect-safe commit, no push. Commit subject: `feat(tx): registry-init-wizard seed-split + devnet guard (#158)`. Commit body must include `Tasks: T009, T010, T011, T012, T013, T014, T015`.

```text
Owned files (create or modify):
- lib/Amaru/Treasury/Tx/RegistryInitWizard.hs                                  (add resolver + seed-split translation + devnet guard)
- lib/Amaru/Treasury/Cli/RegistryInitWizard.hs                                 (wire seed-split runner: resolve env → translate → encode → write)
- test/golden/Support/RegistryInitWizardFixtures.hs                            (new — derives wizard Answers + Env from Support.RegistryInitFixtures)
- test/golden/Amaru/Treasury/Tx/RegistryInitWizardSeedSplitSpec.hs             (new — CBOR-parity golden)
- test/fixtures/registry-init-wizard/seed-split-answers.json                   (new)
- test/fixtures/registry-init-wizard/seed-split-intent.json                    (new golden output)
- test/unit/Amaru/Treasury/Tx/RegistryInitWizardSpec.hs                        (new — round-trip property for seed-split)
- test/unit/Amaru/Treasury/Tx/RegistryInitWizardNetworkGuardSpec.hs            (new — devnet guard for all three subcommands; mint/reference-scripts cases use placeholder Answers refined in Slices 3 and 4)

Forbidden scope: mint translation, reference-scripts translation (those are Slices 3, 4),
specs/, gate.sh, README.md, docs/, any other wizard module, Build.hs, tx-build code.

Reuse, don't reinvent:
- Import the shared resolver helpers directly from Amaru.Treasury.Tx.SwapWizard
  (registryViewFromVerified, selectWallet, addrNetwork) — NOT transitively via
  WithdrawWizard.
- The seed-split resolver mirrors WithdrawWizard.resolveWithdrawEnv shape:
  network family check → wallet UTxO query → upper-bound slot → typed env record.
  The devnet-only guard is layered as the FIRST check; on `wriNetwork /= "devnet"`,
  return Left RegistryInitNonDevnetNetwork BEFORE any chain query.
- Wallet shortfall: when selectWallet returns no pure-ADA UTxO, return
  Left RegistryInitWalletShortfall (analogous to WithdrawResolverEmptyWalletUtxos).
- The pure translation registryInitSeedSplitToIntent :: RegistryInitEnv ->
  RegistryInitSeedSplitAnswers -> Either RegistryInitError SomeTreasuryIntent
  reads only its inputs; no IO.

Fixture helper:
- test/golden/Support/RegistryInitWizardFixtures.hs exposes seedSplitWizardFixture ::
  RegistryInitFixture -> (RegistryInitSeedSplitAnswers, RegistryInitEnv) so the
  parity proof anchors on the SAME RegistryInitFixture #157 uses; extend with mint
  and reference-scripts cases in Slices 3 and 4.
```

### Tests for Slice 2 (RED — written first, observed failing) ⚠️

- [X] T009 (commit: 1e8eb65f) [P] [US2] Create `/code/amaru-treasury-tx-issue-158/test/golden/Support/RegistryInitWizardFixtures.hs` exposing `seedSplitWizardFixture` and add a hspec golden test in `/code/amaru-treasury-tx-issue-158/test/golden/Amaru/Treasury/Tx/RegistryInitWizardSeedSplitSpec.hs` asserting wizard `seedSplit` intent → `tx-build` CBOR == `buildSeedSplitCore` CBOR byte-for-byte (model on `test/golden/RegistryInitIntentSpec.hs`)
- [X] T010 (commit: 1e8eb65f) [P] [US1] Add hspec round-trip property `decodeTreasuryIntent . encodeSomeTreasuryIntent ≡ Right` for the seed-split `SomeTreasuryIntent` in `/code/amaru-treasury-tx-issue-158/test/unit/Amaru/Treasury/Tx/RegistryInitWizardSpec.hs`
- [X] T011 (commit: 1e8eb65f) [P] [US3] Add hspec tests in `/code/amaru-treasury-tx-issue-158/test/unit/Amaru/Treasury/Tx/RegistryInitWizardNetworkGuardSpec.hs` asserting the seed-split resolver fires `RegistryInitNonDevnetNetwork` for each of `mainnet`, `preprod`, `preview` BEFORE any chain query happens (use mock resolver env where `wreQueryWalletUtxos` raises); scaffold the mint and reference-scripts cases with placeholder Answers and a TODO marker
- [X] T012 (commit: 1e8eb65f) [P] [US1] Add hspec test asserting the seed-split resolver returns `Left RegistryInitWalletShortfall` when the wallet has no pure-ADA UTxOs (mock `wreQueryWalletUtxos` returns `[]`) in `/code/amaru-treasury-tx-issue-158/test/unit/Amaru/Treasury/Tx/RegistryInitWizardSpec.hs`

### Implementation for Slice 2

- [X] T013 (commit: 1e8eb65f) [US3] Add the devnet network guard at the top of `resolveRegistryInitEnv` (returns `Left RegistryInitNonDevnetNetwork` if `wriNetwork /= "devnet"` before any IO) plus `RegistryInitEnv` record (mirror `WithdrawEnv` shape: network, upperBoundSlot, registry, scopeView, walletSelection — no simulated values) in `/code/amaru-treasury-tx-issue-158/lib/Amaru/Treasury/Tx/RegistryInitWizard.hs`
- [X] T014 (commit: 1e8eb65f) [US1] Implement `resolveRegistryInitSeedSplit :: (Monad m) => RegistryInitResolverEnv m -> RegistryInitResolverInput -> m (Either RegistryInitError RegistryInitEnv)` (mirrors `resolveWithdrawEnv` shape, imports `registryViewFromVerified`, `selectWallet`, `addrNetwork` from `Amaru.Treasury.Tx.SwapWizard`) and `registryInitSeedSplitToIntent :: RegistryInitEnv -> RegistryInitSeedSplitAnswers -> Either RegistryInitError SomeTreasuryIntent` (pure) in `/code/amaru-treasury-tx-issue-158/lib/Amaru/Treasury/Tx/RegistryInitWizard.hs`
- [X] T015 (commit: 1e8eb65f) [US1] Replace the seed-split TODO stub in `runRegistryInitWizard` with the live path: build resolver env from CLI options → `resolveRegistryInitSeedSplit` → on `Right env` call `registryInitSeedSplitToIntent` → on `Right intent` call `encodeSomeTreasuryIntent` → atomically write to `--out` (honor `--force`); on any `Left` print the typed error and exit non-zero; wire the CLI runner in `/code/amaru-treasury-tx-issue-158/lib/Amaru/Treasury/Cli/RegistryInitWizard.hs`

**Checkpoint**: `seed-split` functional; goldens green; network guard test green; `./gate.sh` green.

---

## Phase 5: Slice 3 — Mint translation + golden (Priority: P1)

**Goal**: Make `mint` functional. Operator-typed `--scopes-seed-txin`, `--registry-seed-txin`, `--owner-key-hash` are baked verbatim into the `RegistryInitMintInputs` payload. Add the parity golden against `buildRegistryNftsCore`.

**Independent Test**: `nix build .#checks.golden` runs `RegistryInitWizardMintSpec` and asserts wizard mint intent → `tx-build` CBOR == `buildRegistryNftsCore` CBOR.

**Subagent brief** — one bisect-safe commit, no push. Commit subject: `feat(tx): registry-init-wizard mint (#158)`. Commit body must include `Tasks: T016, T017, T018, T019`.

```text
Owned files (create or modify):
- lib/Amaru/Treasury/Tx/RegistryInitWizard.hs                                  (add mint translation)
- lib/Amaru/Treasury/Cli/RegistryInitWizard.hs                                 (wire mint runner)
- test/golden/Support/RegistryInitWizardFixtures.hs                            (extend with mintWizardFixture)
- test/golden/Amaru/Treasury/Tx/RegistryInitWizardMintSpec.hs                  (new)
- test/fixtures/registry-init-wizard/mint-answers.json                         (new)
- test/fixtures/registry-init-wizard/mint-intent.json                          (new)
- test/unit/Amaru/Treasury/Tx/RegistryInitWizardSpec.hs                        (extend with mint round-trip)
- test/unit/Amaru/Treasury/Tx/RegistryInitWizardNetworkGuardSpec.hs            (refine the mint case from placeholder to real Answers)

Forbidden scope: reference-scripts translation (Slice 4), seed-split translation
(immutable from Slice 2), specs/, gate.sh, README.md, docs/, Build.hs, tx-build code.

Translation:
- registryInitMintToIntent :: RegistryInitEnv -> RegistryInitMintAnswers ->
    Either RegistryInitError SomeTreasuryIntent. Pure; copies scopesSeedTxIn,
    registrySeedTxIn, ownerKeyHash from Answers into the RegistryInitMintInputs
    payload verbatim. No internal call to buildRegistryNftsCore.
```

### Tests for Slice 3 (RED — written first, observed failing) ⚠️

- [X] T016 (commit: 0453256f) [P] [US2] Extend `/code/amaru-treasury-tx-issue-158/test/golden/Support/RegistryInitWizardFixtures.hs` with `mintWizardFixture` and add hspec golden test in `/code/amaru-treasury-tx-issue-158/test/golden/Amaru/Treasury/Tx/RegistryInitWizardMintSpec.hs` asserting wizard mint intent → `tx-build` CBOR == `buildRegistryNftsCore` CBOR byte-for-byte
- [X] T017 (commit: 0453256f) [P] [US1] Extend `/code/amaru-treasury-tx-issue-158/test/unit/Amaru/Treasury/Tx/RegistryInitWizardSpec.hs` with a round-trip property for the mint `SomeTreasuryIntent`
- [X] T018 (commit: 0453256f) [P] [US3] Refine the mint network-guard case in `/code/amaru-treasury-tx-issue-158/test/unit/Amaru/Treasury/Tx/RegistryInitWizardNetworkGuardSpec.hs` from placeholder Answers (Slice 2 scaffold) to real Answers

### Implementation for Slice 3

- [X] T019 (commit: 0453256f) [US1] Implement `registryInitMintToIntent` (pure; bakes operator-typed inter-tx flags verbatim into `RegistryInitMintInputs`) in `/code/amaru-treasury-tx-issue-158/lib/Amaru/Treasury/Tx/RegistryInitWizard.hs` and wire the mint runner arm in `/code/amaru-treasury-tx-issue-158/lib/Amaru/Treasury/Cli/RegistryInitWizard.hs`

**Checkpoint**: `mint` functional; goldens green; `./gate.sh` green.

---

## Phase 6: Slice 4 — Reference-scripts translation + golden (Priority: P1)

**Goal**: Make `reference-scripts` functional. Operator-typed `--scopes-seed-txin`, `--registry-seed-txin`, `--funding-seed-txin` are baked verbatim. Add the parity golden against `buildReferenceScriptsCore`.

**Independent Test**: `nix build .#checks.golden` runs `RegistryInitWizardReferenceScriptsSpec` and asserts wizard ref-scripts intent → `tx-build` CBOR == `buildReferenceScriptsCore` CBOR.

**Subagent brief** — one bisect-safe commit, no push. Commit subject: `feat(tx): registry-init-wizard reference-scripts (#158)`. Commit body must include `Tasks: T020, T021, T022, T023`.

```text
Owned files (create or modify):
- lib/Amaru/Treasury/Tx/RegistryInitWizard.hs                                  (add reference-scripts translation)
- lib/Amaru/Treasury/Cli/RegistryInitWizard.hs                                 (wire reference-scripts runner)
- test/golden/Support/RegistryInitWizardFixtures.hs                            (extend with referenceScriptsWizardFixture)
- test/golden/Amaru/Treasury/Tx/RegistryInitWizardReferenceScriptsSpec.hs      (new)
- test/fixtures/registry-init-wizard/reference-scripts-answers.json            (new)
- test/fixtures/registry-init-wizard/reference-scripts-intent.json             (new)
- test/unit/Amaru/Treasury/Tx/RegistryInitWizardSpec.hs                        (extend with reference-scripts round-trip)
- test/unit/Amaru/Treasury/Tx/RegistryInitWizardNetworkGuardSpec.hs            (refine the reference-scripts case from placeholder to real Answers)

Forbidden scope: seed-split and mint translations (immutable from Slices 2, 3),
specs/, gate.sh, README.md, docs/, Build.hs, tx-build code.

Translation:
- registryInitReferenceScriptsToIntent :: RegistryInitEnv ->
    RegistryInitReferenceScriptsAnswers -> Either RegistryInitError SomeTreasuryIntent.
    Pure; copies the three operator-typed TxIns into RegistryInitReferenceScriptsInputs.
    No internal call to buildReferenceScriptsCore.
```

### Tests for Slice 4 (RED — written first, observed failing) ⚠️

- [X] T020 (commit: c54de054) [P] [US2] Extend `/code/amaru-treasury-tx-issue-158/test/golden/Support/RegistryInitWizardFixtures.hs` with `referenceScriptsWizardFixture` and add hspec golden test in `/code/amaru-treasury-tx-issue-158/test/golden/Amaru/Treasury/Tx/RegistryInitWizardReferenceScriptsSpec.hs` asserting wizard ref-scripts intent → `tx-build` CBOR == `buildReferenceScriptsCore` CBOR byte-for-byte
- [X] T021 (commit: c54de054) [P] [US1] Extend `/code/amaru-treasury-tx-issue-158/test/unit/Amaru/Treasury/Tx/RegistryInitWizardSpec.hs` with a round-trip property for the reference-scripts `SomeTreasuryIntent`
- [X] T022 (commit: c54de054) [P] [US3] Refine the reference-scripts network-guard case in `/code/amaru-treasury-tx-issue-158/test/unit/Amaru/Treasury/Tx/RegistryInitWizardNetworkGuardSpec.hs` from placeholder Answers to real Answers

### Implementation for Slice 4

- [X] T023 (commit: c54de054) [US1] Implement `registryInitReferenceScriptsToIntent` (pure; the operator-typed `--funding-seed-txin` is baked into the wallet block per ledger payload shape, not into `RegistryInitReferenceScriptsInputs`) in `/code/amaru-treasury-tx-issue-158/lib/Amaru/Treasury/Tx/RegistryInitWizard.hs` and wire the reference-scripts runner arm in `/code/amaru-treasury-tx-issue-158/lib/Amaru/Treasury/Cli/RegistryInitWizard.hs`

**Checkpoint**: all three subcommands functional; goldens green; `./gate.sh` green.

---

## Phase 7: Slice 5 — No-simulation grep enforcement (Priority: P1)

**Goal**: Mechanically enforce NFR-006 / SC-007: the wizard module sources contain zero references to `buildSeedSplitCore`, `buildRegistryNftsCore`, `buildReferenceScriptsCore`. One hspec unit test only — no parallel `gate.sh` grep step.

**Independent Test**: `nix build .#checks.unit` runs `RegistryInitWizardNoSimulationSpec` and asserts the wizard module sources contain none of the three core symbol names.

**Subagent brief** — one bisect-safe commit, no push. Commit subject: `test(tx): registry-init-wizard no-simulation grep (#158)`. Commit body must include `Tasks: T024`.

```text
Owned files (create or modify):
- test/unit/Amaru/Treasury/Tx/RegistryInitWizardNoSimulationSpec.hs            (new — unit test only)

Forbidden scope: any wizard module (Slices 1–4), specs/, gate.sh, README.md, docs/.

The test uses Data.Text.IO.readFile on:
  lib/Amaru/Treasury/Tx/RegistryInitWizard.hs
  lib/Amaru/Treasury/Cli/RegistryInitWizard.hs
and asserts via Data.Text.isInfixOf that none of the three core symbol names appears
in either source. The test verifies its own RED state by first patching one of the
wizard sources to include a "-- buildSeedSplitCore" comment, observing the test fail,
then reverting the patch before committing.
```

### Tests for Slice 5 (RED — written first, observed failing) ⚠️

- [X] T024 (commit: acba3a02) [P] [US2] Create `/code/amaru-treasury-tx-issue-158/test/unit/Amaru/Treasury/Tx/RegistryInitWizardNoSimulationSpec.hs` with hspec tests reading each wizard source, stripping Haskell line and block comments, and asserting `Data.Text.isInfixOf` returns False for each of `buildSeedSplitCore`, `buildRegistryNftsCore`, `buildReferenceScriptsCore`. Comment-stripping is required because Slices 2–4 added Haddock prose that names the symbols on purpose to document the no-simulation contract. The CODE form is what matters.

**Checkpoint**: grep test green; `./gate.sh` green.

---

## Phase 8: Slice 6 — Documentation alignment (Priority: P2)

**Goal**: Update `README.md` and `docs/local-devnet-smoke.md` to describe the three-subcommand operator path with operator-typed inter-tx state, the explicit "unsafe inter-step carry" warning, and forward-references to [#161](https://github.com/lambdasistemi/amaru-treasury-tx/issues/161) (bash smoke) and [#163](https://github.com/lambdasistemi/amaru-treasury-tx/issues/163) (resumable client state).

**Independent Test**: rendered docs show the three-subcommand path; operator-typed seed-TxIns and owner-key-hash visible at the `mint` and `reference-scripts` steps; explicit "unsafe" warning present; #161 and #163 are linked.

**Orchestrator-owned** — no subagent. Commit subject: `docs(158): registry-init-wizard operator path`. Commit body must include `Tasks: T025, T026`.

- [ ] T025 [US4] Update `/code/amaru-treasury-tx-issue-158/README.md` registry-init section with the three-subcommand invocation flow, operator-typed inter-tx flags visible at `mint` and `reference-scripts`, a "common mistakes" call-out (swapping `#0` and `#1`, stale txid, mismatched owner key hash), and forward references to [#161](https://github.com/lambdasistemi/amaru-treasury-tx/issues/161) and [#163](https://github.com/lambdasistemi/amaru-treasury-tx/issues/163)
- [ ] T026 [US4] Update `/code/amaru-treasury-tx-issue-158/docs/local-devnet-smoke.md` registry-init section with the same three-subcommand flow, the unsafe inter-step carry warning, and forward references to #161 and #163

**Checkpoint**: docs aligned with delivered behavior; `./gate.sh` green; PR body refreshed.

---

## Phase 9: Slice 7 — Drop gate.sh + mark PR ready (Priority: —)

**Goal**: Remove `gate.sh` from the worktree and mark PR #165 ready for review. Per the `gate-script` skill, the absence of `gate.sh` at HEAD is itself the "PR is finalized" sentinel.

**Orchestrator-owned** — no subagent. Commit subject: `chore: drop gate.sh (ready for review) (#158)`.

- [ ] T027 Run the finalization audit (`./gate.sh` green at HEAD, every previous slice commit carries `Tasks:` trailer, every `[ ]` in this file has become `[X] T### (commit: <sha>)`, README + docs + PR body aligned)
- [ ] T028 `git rm /code/amaru-treasury-tx-issue-158/gate.sh` and commit; `gh pr ready 165 -R lambdasistemi/amaru-treasury-tx`

**Checkpoint**: PR ready; CI green; awaiting external review.

---

## Dependencies & Execution Order

### Phase dependencies (= slice dependencies)

```
Slice 1 (Phase 3) ──► Slice 2 (Phase 4) ──► Slice 3 (Phase 5) ──► Slice 4 (Phase 6) ──► Slice 5 (Phase 7) ──► Slice 6 (Phase 8) ──► Slice 7 (Phase 9)
```

Strictly sequential because:

- Slice 2 imports the `Answers` records and `RegistryInitError` introduced in Slice 1, and replaces Slice 1's seed-split TODO stub.
- Slice 3 reuses Slice 2's `RegistryInitEnv`, resolver shape, and `RegistryInitWizardFixtures` helper.
- Slice 4 reuses Slices 2 and 3's foundations.
- Slice 5's grep test reads the wizard source files; running it before Slices 1–4 land is meaningless (the files don't exist) but won't break anything — it's safer after.
- Slice 6 describes the delivered behavior; running it before Slices 1–4 land would write fiction.
- Slice 7 finalizes everything.

### Within each slice

- RED tasks (tests) before GREEN tasks (implementation), in the same commit. The subagent observes RED failure, then writes the minimum production code to flip it to GREEN, then runs `./gate.sh`.

### Parallel opportunities

Within a single slice, the marked `[P]` tasks operate on different files and have no inter-task dependencies; the subagent can write them in any order. Across slices: none. This PR is single-track by design.

---

## MVP scope

The minimum reviewable increment is Slices 1 + 2 + 3 + 4 together (US1 + US2 + US3 delivered end-to-end). Slice 5 hardens the no-simulation invariant; Slice 6 aligns docs; Slice 7 finalizes. The PR ships all seven slices together — there is no intermediate release.

---

## Notes

- [P] tasks = different files within a slice.
- [Story] label maps the task to its primary user story for traceability — many tasks contribute to multiple stories; the label is the primary one.
- Each slice = one subagent run = one bisect-safe commit. Commit body MUST include `Tasks: T###[, T###]`. After review, orchestrator amends the slice commit to mark `[X] T### (commit: <short-sha>)` in this file.
- `gate.sh` runs at every slice; `./gate.sh` green is the GREEN gate. Do NOT push from the subagent.
- Verify tests fail (RED) before implementing.
- Avoid: vague tasks, same-file conflicts within a slice (use `[P]` discipline), cross-slice edits to files an earlier slice already shipped.
