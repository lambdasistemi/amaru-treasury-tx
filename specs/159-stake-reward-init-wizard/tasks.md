---
description: "Task list for #159 — stake-reward-init-wizard"
---

# Tasks: stake-reward-init-wizard

**Input**: Design documents from `/specs/159-stake-reward-init-wizard/`
**Prerequisites**: [spec.md](./spec.md), [plan.md](./plan.md), [research.md](./research.md)
**Tests**: Required — every behavior-changing slice ships RED + GREEN paired in one commit.

## Format: `[ID] [P?] [Story?] Description`

- **[P]**: Can run in parallel with sibling tasks within the same slice (different files, no dependencies on incomplete sibling tasks).
- **[Story]**: Maps the task to its primary user story from `spec.md` (US1 emit-intent, US2 library-core parity, US3 network safety, US4 docs alignment).
- File paths are absolute under the worktree root.

## Slice ↔ Phase ↔ Commit mapping

The plan defines 6 vertical bisect-safe slices. Each slice = one resolve-ticket subagent run = one commit on the branch. Phases below are the slices. Setup (Phase 1) and Foundational (Phase 2) are empty: `amaru-treasury-tx` already has its Haskell/Nix build infrastructure, test suites, and `./gate.sh` from prior PRs.

| Slice / Phase | Subagent brief inline | Primary US | Commit subject |
|---|---|---|---|
| 3 — Slice 1 | yes | US1 + US3 | `feat(cli): scaffold stake-reward-init-wizard parser (#159)` |
| 4 — Slice 2 | yes | US1 + US2 + US3 | `feat(tx): stake-reward-init-wizard script-account + devnet guard (#159)` |
| 5 — Slice 3 | yes | US1 + US2 | `feat(tx): stake-reward-init-wizard plain-account (#159)` |
| 6 — Slice 4 | yes | US2 + US3 | `test(tx): stake-reward-init-wizard no-simulation grep (#159)` |
| 7 — Slice 5 | orchestrator (no subagent) | US4 | `docs(159): stake-reward-init-wizard operator path` |
| 8 — Slice 6 | orchestrator (no subagent) | — | `chore: drop gate.sh (ready for review) (#159)` |

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Project initialization.

No tasks — `amaru-treasury-tx` is an existing Haskell+Nix project. `./gate.sh` is already at `gate.sh` from the bootstrap commit `94937a93`.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Core infrastructure that must be complete before any user story can be implemented.

No tasks — the build/test infra (`nix build .#checks.*`, `just ci`, `just schema-check`, hspec) is in place. The two `SomeTreasuryIntent` variants (`StakeRewardInitScriptAccount`, `StakeRewardInitPlainAccount`), the matching `Translated`/`Inputs` records, the `requireDevnet` guard at the `tx-build` dispatcher, and `Support.StakeRewardInitFixtures` (single-source-of-truth helper for the library-core goldens) were shipped by [#157 (PR #162)](https://github.com/lambdasistemi/amaru-treasury-tx/pull/162). The architectural template (`Amaru.Treasury.Tx.RegistryInitWizard` / `Amaru.Treasury.Cli.RegistryInitWizard`) was shipped by [#158 (PR #165)](https://github.com/lambdasistemi/amaru-treasury-tx/pull/165).

**Checkpoint**: Foundation ready — user story implementation begins at Phase 3 (Slice 1).

---

## Phase 3: Slice 1 — Wizard scaffolding + CLI parser + parser test (Priority: P1) 🎯

**Goal**: Ship the parser surface, the typed `Answers` records, the `StakeRewardInitError` type, and a TODO-stub runner for both subcommands. After this slice, `amaru-treasury-tx stake-reward-init-wizard --help` lists `script-account | plain-account`; each subcommand's `--help` lists its flags; invalid flags fail at parse time; the runner exits non-zero with a TODO. No translation logic yet — Slice 2 wires `script-account`.

**Independent Test**: `nix develop --quiet -c cabal run amaru-treasury-tx -- stake-reward-init-wizard --help` shows both subcommands; each subcommand's `--help` shows the documented flag set; `nix build .#checks.unit` passes.

**Subagent brief** — one bisect-safe commit, no push, exactly the owned files below. Commit subject: `feat(cli): scaffold stake-reward-init-wizard parser (#159)`. Commit body must include `Tasks: T001, T002, T003, T004, T005, T006, T007, T008`.

```text
Owned files (create or modify):
- lib/Amaru/Treasury/Tx/StakeRewardInitWizard.hs                                  (new)
- lib/Amaru/Treasury/Cli/StakeRewardInitWizard.hs                                 (new)
- lib/Amaru/Treasury/Cli.hs                                                       (wire subcommand dispatch)
- app/amaru-treasury-tx/Main.hs                                                   (wire runner case)
- amaru-treasury-tx.cabal                                                         (expose new modules)
- test/unit/Amaru/Treasury/Cli/StakeRewardInitWizardParserSpec.hs                 (new)

Forbidden scope: anything under specs/, gate.sh, README.md, docs/, package metadata
outside amaru-treasury-tx.cabal, any other wizard module, the seven SomeTreasuryIntent
variants from #157 (read-only here), the two stake-reward-init construction cores
(`buildStakeRewardScriptAccountCore`, `buildStakeRewardPlainAccountCore`) — these must
NOT appear in any wizard source (NFR-006, enforced mechanically by Slice 4's grep test).

Parser library reuse:
- TxIn parser for --funding-seed-txin MUST wrap optparse-applicative's eitherReader
  around Amaru.Treasury.LedgerParse.txInFromText. DO NOT reinvent a "txid#ix" parser.
- File-path parser for --registry MUST be a plain `strOption` (just a file path; the
  resolver in Slice 2 will read + parse it via readDevnetStakeRewardRegistry).
- #159 has NO --owner-key-hash flag (the script witnesses come from the registry
  artifact, not from operator-typed key hashes). Do not import keyHashFromHex.

Runner stub: each of the two sub-action runners is a pure `error "TODO Slice N"`
that exits non-zero; do NOT attempt any chain query or file write.

The parser MUST mirror Amaru.Treasury.Cli.RegistryInitWizard's optparse-applicative
shape (subcommands via `hsubparser`; shared `--wallet-addr`, `--out`, `--log`,
`--force`, `--validity-hours` factored into a common parser combinator). The
StakeRewardInit family does NOT carry the rationale flag set (`--description`,
`--justification`, `--destination-label`, `--event`, `--label`) that the
Withdraw/Disburse/Registry wizards do — stake-reward-init transactions are
operational, not governance, and the existing IntentJSON payload has no rationale
slots for them.
```

### Tests for Slice 1 (RED — written first, observed failing) ⚠️

- [X] T001 (commit: 51647a67) [P] [US1] Add hspec test `it "stake-reward-init-wizard --help lists script-account, plain-account"` in `/code/amaru-treasury-tx-issue-159/test/unit/Amaru/Treasury/Cli/StakeRewardInitWizardParserSpec.hs`
- [X] T002 (commit: 51647a67) [P] [US1] Add hspec tests asserting each subcommand's `--help` lists its required flags (script-account: `--wallet-addr --registry --funding-seed-txin --out [--validity-hours --log --force]`; plain-account: same flag set) in `/code/amaru-treasury-tx-issue-159/test/unit/Amaru/Treasury/Cli/StakeRewardInitWizardParserSpec.hs`
- [X] T003 (commit: 51647a67) [P] [US3] Add hspec test asserting malformed `--funding-seed-txin` (not `<txid64hex>#<word16>`) is rejected at the parser with a non-zero exit and a clear error in `/code/amaru-treasury-tx-issue-159/test/unit/Amaru/Treasury/Cli/StakeRewardInitWizardParserSpec.hs`
- [X] T004 (commit: 51647a67) [P] [US3] Add hspec test asserting a missing required `--registry` flag is rejected at the parser with a clear "missing required option" error in `/code/amaru-treasury-tx-issue-159/test/unit/Amaru/Treasury/Cli/StakeRewardInitWizardParserSpec.hs`
- [X] T005 (commit: 51647a67) [P] [US3] Add hspec test asserting `--out` pointing at a path whose parent directory does not exist surfaces a typed error before any work happens in `/code/amaru-treasury-tx-issue-159/test/unit/Amaru/Treasury/Cli/StakeRewardInitWizardParserSpec.hs`
- [X] T006 (commit: 51647a67) [P] [US3] Add hspec test asserting `--out` pointing at an existing file without `--force` surfaces a typed conflict error in `/code/amaru-treasury-tx-issue-159/test/unit/Amaru/Treasury/Cli/StakeRewardInitWizardParserSpec.hs`

### Implementation for Slice 1

- [X] T007 (commit: 51647a67) [US1] Create `StakeRewardInitScriptAccountAnswers` and `StakeRewardInitPlainAccountAnswers` (typed records with `FromJSON` instances mirroring `RegistryInitMintAnswers` shape, minus the rationale fields) and `StakeRewardInitError` ADT (variants for `StakeRewardInitNonDevnetNetwork`, `StakeRewardInitWalletShortfall`, `StakeRewardInitRegistryReadError`, `StakeRewardInitOutputParentMissing`, `StakeRewardInitOutputExistsNoForce`, plus parser-only error wrappers) in `/code/amaru-treasury-tx-issue-159/lib/Amaru/Treasury/Tx/StakeRewardInitWizard.hs`
- [X] T008 (commit: 51647a67) [US1] Create `stakeRewardInitWizardOptsP :: Parser StakeRewardInitWizardOpts` with two subcommands (`script-account`, `plain-account`), reusing `LedgerParse.txInFromText` via `eitherReader` for `--funding-seed-txin`, plus TODO-stub runner for each arm; expose the parser and runner; expose the new modules in `/code/amaru-treasury-tx-issue-159/amaru-treasury-tx.cabal`; wire the parser into the top-level dispatcher in `/code/amaru-treasury-tx-issue-159/lib/Amaru/Treasury/Cli.hs` and the runner case into `/code/amaru-treasury-tx-issue-159/app/amaru-treasury-tx/Main.hs`

**Checkpoint**: parser test suite green; `--help` works end-to-end; runner exits non-zero with TODO; `./gate.sh` green.

---

## Phase 4: Slice 2 — Resolver + script-account translation + golden + devnet guard + registry-parse error variants (Priority: P1) 🎯

**Goal**: Make `script-account` functional end-to-end; add the devnet-only resolver guard (defense-in-depth over `Build.hs:requireDevnet`); add the registry-file parse error path (missing / unparseable / wrong phase / wrong network); add the wallet-shortfall test path; introduce the shared wizard fixture helper that derives wizard `Answers + Env` from the same underlying material `Support.StakeRewardInitFixtures` uses for the library-core goldens.

**Independent Test**: `nix build .#checks.golden` runs the new `StakeRewardInitWizardScriptAccountSpec` and asserts wizard intent → `tx-build` CBOR == `buildStakeRewardScriptAccountCore` CBOR byte-for-byte; round-trip property for the script-account JSON passes; network guard rejects mainnet/preprod/preview at the resolver layer before chain query; missing/unparseable `--registry` surfaces typed errors; wallet-shortfall surfaces from the resolver.

**Subagent brief** — one bisect-safe commit, no push. Commit subject: `feat(tx): stake-reward-init-wizard script-account + devnet guard (#159)`. Commit body must include `Tasks: T009, T010, T011, T012, T013, T014, T015, T016`.

```text
Owned files (create or modify):
- lib/Amaru/Treasury/Tx/StakeRewardInitWizard.hs                                  (add resolver + script-account translation + devnet guard + registry-parse error variants)
- lib/Amaru/Treasury/Cli/StakeRewardInitWizard.hs                                 (wire script-account runner: resolve env → translate → encode → write)
- test/golden/Support/StakeRewardInitWizardFixtures.hs                            (new — derives wizard Answers + Env from Support.StakeRewardInitFixtures)
- test/golden/Amaru/Treasury/Tx/StakeRewardInitWizardScriptAccountSpec.hs         (new — CBOR-parity golden)
- test/fixtures/stake-reward-init-wizard/registry.json                            (new — shared between both sub-actions; matches a successful registry-init-wizard reference-scripts submission)
- test/fixtures/stake-reward-init-wizard/script-account-answers.json              (new)
- test/fixtures/stake-reward-init-wizard/script-account-intent.json               (new golden output)
- test/unit/Amaru/Treasury/Tx/StakeRewardInitWizardSpec.hs                        (new — round-trip property for script-account; registry-parse error cases; wallet-shortfall)
- test/unit/Amaru/Treasury/Tx/StakeRewardInitWizardNetworkGuardSpec.hs            (new — devnet guard for both subcommands; plain-account case uses placeholder Answers refined in Slice 3)

Forbidden scope: plain-account translation (Slice 3), specs/, gate.sh, README.md,
docs/, any other wizard module, Build.hs, tx-build code, the construction cores
buildStakeRewardScriptAccountCore / buildStakeRewardPlainAccountCore (NFR-006).

Reuse, don't reinvent:
- Import the shared resolver helpers directly from Amaru.Treasury.Tx.SwapWizard
  (selectWallet, addrNetwork) — NOT transitively via RegistryInitWizard or
  WithdrawWizard. Match exactly what RegistryInitWizard.hs does.
- The script-account resolver mirrors RegistryInitWizard.resolveRegistryInitEnv
  shape: devnet network check → wallet UTxO query → upper-bound slot → registry
  file parse (via readDevnetStakeRewardRegistry from Amaru.Treasury.Devnet.StakeRewardInit) → typed env record.
- The devnet-only guard is the FIRST check; on `wriNetwork /= "devnet"`, return
  Left StakeRewardInitNonDevnetNetwork BEFORE any chain query.
- The registry parse uses the EXISTING readDevnetStakeRewardRegistry function (do
  NOT re-implement). Map IO Either parse failures into StakeRewardInitRegistryReadError.
  The function already enforces `phase == "registry-init"` and `network == "devnet"`
  at the file-content level.
- The wizard does NOT call `verifyRegistry` against chain state (research D8 —
  trust the operator's --registry commitment after the readDevnetStakeRewardRegistry
  parse gate). The only chain queries are the network probe + the standard wallet
  UTxO query.
- Wallet shortfall: when selectWallet returns no pure-ADA UTxO, return
  Left StakeRewardInitWalletShortfall (analogous to WithdrawResolverEmptyWalletUtxos
  / RegistryInitWalletShortfall).
- The pure translation stakeRewardInitScriptAccountToIntent :: StakeRewardInitEnv ->
  StakeRewardInitScriptAccountAnswers -> Either StakeRewardInitError SomeTreasuryIntent
  reads only its inputs; no IO. It extracts dsrrTreasuryRef → treasuryRefTxIn and
  dsrrTreasuryScriptHash → treasuryScriptHash for the payload, and builds the wallet
  block with `wjTxIn = txInText (sasaFundingSeedTxIn answers)` (operator-typed
  override, mirroring RegistryInitWizard.hs:623's reference-scripts pattern) and
  `wjAddress = wsAddress (reWalletSelection env)`.

Fixture helper:
- test/golden/Support/StakeRewardInitWizardFixtures.hs exposes
  scriptAccountWizardFixture :: StakeRewardInitFixture -> (StakeRewardInitScriptAccountAnswers, StakeRewardInitEnv)
  so the parity proof anchors on the SAME StakeRewardInitFixture #157 uses; extend
  with plain-account in Slice 3.

Registry test fixture (registry.json):
- The shared test/fixtures/stake-reward-init-wizard/registry.json MUST parse cleanly
  via readDevnetStakeRewardRegistry. Build it from the Support.RegistryInitFixtures
  reference-scripts material if a co-derivation helper is practical; otherwise
  hand-roll the JSON with `phase: "registry-init"`, `network: "devnet"`, anchors,
  and scripts hashes consistent with what Support.StakeRewardInitFixtures derives
  treasuryRef / treasuryScriptHash / permissionsRef / permissionsScriptHash from.
  Add an assertion in the round-trip test that readDevnetStakeRewardRegistry parses
  the fixture without error.
```

### Tests for Slice 2 (RED — written first, observed failing) ⚠️

- [X] T009 (commit: f4fb6c4a) [P] [US2] Create `/code/amaru-treasury-tx-issue-159/test/golden/Support/StakeRewardInitWizardFixtures.hs` exposing `scriptAccountWizardFixture` and add a hspec golden test in `/code/amaru-treasury-tx-issue-159/test/golden/Amaru/Treasury/Tx/StakeRewardInitWizardScriptAccountSpec.hs` asserting wizard `scriptAccount` intent → `tx-build` CBOR == `buildStakeRewardScriptAccountCore` CBOR byte-for-byte (model on `test/golden/StakeRewardInitIntentSpec.hs`)
- [X] T010 (commit: f4fb6c4a) [P] [US1] Add hspec round-trip property `decodeTreasuryIntent . encodeSomeTreasuryIntent ≡ Right` for the script-account `SomeTreasuryIntent` in `/code/amaru-treasury-tx-issue-159/test/unit/Amaru/Treasury/Tx/StakeRewardInitWizardSpec.hs`
- [X] T011 (commit: f4fb6c4a) [P] [US3] Add hspec tests in `/code/amaru-treasury-tx-issue-159/test/unit/Amaru/Treasury/Tx/StakeRewardInitWizardNetworkGuardSpec.hs` asserting the script-account resolver fires `StakeRewardInitNonDevnetNetwork` for each of `mainnet`, `preprod`, `preview` BEFORE any chain query happens (use mock resolver env where `wreQueryWalletUtxos` raises); scaffold the plain-account case with placeholder Answers and a TODO marker
- [X] T012 (commit: f4fb6c4a) [P] [US1] Add hspec tests in `/code/amaru-treasury-tx-issue-159/test/unit/Amaru/Treasury/Tx/StakeRewardInitWizardSpec.hs` asserting the registry-file parse surfaces typed `StakeRewardInitRegistryReadError` for each of: (a) missing file, (b) unparseable JSON, (c) parseable JSON with `phase != "registry-init"`, (d) parseable JSON with `network != "devnet"`. Use temporary `--registry` paths created in the test setUp
- [X] T013 (commit: f4fb6c4a) [P] [US1] Add hspec test asserting the script-account resolver returns `Left StakeRewardInitWalletShortfall` when the wallet has no pure-ADA UTxOs (mock `wreQueryWalletUtxos` returns `[]`) in `/code/amaru-treasury-tx-issue-159/test/unit/Amaru/Treasury/Tx/StakeRewardInitWizardSpec.hs`

### Implementation for Slice 2

- [X] T014 (commit: f4fb6c4a) [US3] Add the devnet network guard at the top of `resolveStakeRewardInitEnv` (returns `Left StakeRewardInitNonDevnetNetwork` if `wriNetwork /= "devnet"` before any IO) plus `StakeRewardInitEnv` record (mirror `RegistryInitEnv` shape: network, upperBoundSlot, walletSelection, parsedRegistry — no simulated values; no `scopeView` since stake-reward-init is not scope-bound) in `/code/amaru-treasury-tx-issue-159/lib/Amaru/Treasury/Tx/StakeRewardInitWizard.hs`
- [X] T015 (commit: f4fb6c4a) [US1] Implement `resolveStakeRewardInitScriptAccount :: (Monad m) => StakeRewardInitResolverEnv m -> StakeRewardInitResolverInput -> m (Either StakeRewardInitError StakeRewardInitEnv)` (mirrors `resolveRegistryInitEnv` shape; imports `selectWallet`, `addrNetwork` from `Amaru.Treasury.Tx.SwapWizard`; reads `--registry` via `readDevnetStakeRewardRegistry` from `Amaru.Treasury.Devnet.StakeRewardInit` and wraps errors as `StakeRewardInitRegistryReadError`) and `stakeRewardInitScriptAccountToIntent :: StakeRewardInitEnv -> StakeRewardInitScriptAccountAnswers -> Either StakeRewardInitError SomeTreasuryIntent` (pure; extracts `dsrrTreasuryRef` → `treasuryRefTxIn` and `dsrrTreasuryScriptHash` → `treasuryScriptHash` from the parsed registry; bakes `--funding-seed-txin` into `tiWallet.wjTxIn`) in `/code/amaru-treasury-tx-issue-159/lib/Amaru/Treasury/Tx/StakeRewardInitWizard.hs`
- [X] T016 (commit: f4fb6c4a) [US1] Replace the script-account TODO stub in `runStakeRewardInitWizard` with the live path: build resolver env from CLI options → `resolveStakeRewardInitScriptAccount` → on `Right env` call `stakeRewardInitScriptAccountToIntent` → on `Right intent` call `encodeSomeTreasuryIntent` → atomically write to `--out` (honor `--force`); on any `Left` print the typed error and exit non-zero; wire the CLI runner in `/code/amaru-treasury-tx-issue-159/lib/Amaru/Treasury/Cli/StakeRewardInitWizard.hs`

**Checkpoint**: `script-account` functional; goldens green; network guard test green; registry-parse error tests green; wallet-shortfall test green; `./gate.sh` green.

---

## Phase 5: Slice 3 — Plain-account translation + golden (Priority: P1) 🎯

**Goal**: Make `plain-account` functional. Operator-typed `--registry` is parsed via the same `readDevnetStakeRewardRegistry`; `dsrrPermissionsScriptHash` is baked into the `StakeRewardInitPlainAccountInputs` payload; the operator-typed `--funding-seed-txin` is baked into the wallet block. Add the parity golden against `buildStakeRewardPlainAccountCore`.

**Independent Test**: `nix build .#checks.golden` runs `StakeRewardInitWizardPlainAccountSpec` and asserts wizard plain-account intent → `tx-build` CBOR == `buildStakeRewardPlainAccountCore` CBOR.

**Subagent brief** — one bisect-safe commit, no push. Commit subject: `feat(tx): stake-reward-init-wizard plain-account (#159)`. Commit body must include `Tasks: T017, T018, T019, T020`.

```text
Owned files (create or modify):
- lib/Amaru/Treasury/Tx/StakeRewardInitWizard.hs                                  (add plain-account translation)
- lib/Amaru/Treasury/Cli/StakeRewardInitWizard.hs                                 (wire plain-account runner)
- test/golden/Support/StakeRewardInitWizardFixtures.hs                            (extend with plainAccountWizardFixture)
- test/golden/Amaru/Treasury/Tx/StakeRewardInitWizardPlainAccountSpec.hs          (new)
- test/fixtures/stake-reward-init-wizard/plain-account-answers.json               (new)
- test/fixtures/stake-reward-init-wizard/plain-account-intent.json                (new)
- test/unit/Amaru/Treasury/Tx/StakeRewardInitWizardSpec.hs                        (extend with plain-account round-trip)
- test/unit/Amaru/Treasury/Tx/StakeRewardInitWizardNetworkGuardSpec.hs            (refine the plain-account case from placeholder to real Answers)

Forbidden scope: script-account translation (immutable from Slice 2), specs/,
gate.sh, README.md, docs/, Build.hs, tx-build code, the construction cores
(NFR-006).

Translation:
- stakeRewardInitPlainAccountToIntent :: StakeRewardInitEnv ->
    StakeRewardInitPlainAccountAnswers -> Either StakeRewardInitError SomeTreasuryIntent.
    Pure. Extracts dsrrPermissionsScriptHash from the parsed registry into
    StakeRewardInitPlainAccountInputs.permissionsScriptHash; bakes --funding-seed-txin
    into tiWallet.wjTxIn (operator-typed override, same pattern as script-account).
    No internal call to buildStakeRewardPlainAccountCore.

Reuse, don't reinvent:
- The resolver shape from Slice 2 is reused via the same StakeRewardInitEnv record.
  If a per-sub-action resolver function is needed (resolveStakeRewardInitPlainAccount),
  it should call the same internal resolver pipeline as Slice 2's; the only
  difference is which payload field is consumed downstream.

Independence:
- NFR-007: the wizard MUST NOT introduce any ordering check between script-account
  and plain-account. Specifically: do not query chain to detect "is the other
  account already registered." Slice 3's review will reject any such addition.
```

### Tests for Slice 3 (RED — written first, observed failing) ⚠️

- [ ] T017 [P] [US2] Extend `/code/amaru-treasury-tx-issue-159/test/golden/Support/StakeRewardInitWizardFixtures.hs` with `plainAccountWizardFixture` and add hspec golden test in `/code/amaru-treasury-tx-issue-159/test/golden/Amaru/Treasury/Tx/StakeRewardInitWizardPlainAccountSpec.hs` asserting wizard plain-account intent → `tx-build` CBOR == `buildStakeRewardPlainAccountCore` CBOR byte-for-byte
- [ ] T018 [P] [US1] Extend `/code/amaru-treasury-tx-issue-159/test/unit/Amaru/Treasury/Tx/StakeRewardInitWizardSpec.hs` with a round-trip property for the plain-account `SomeTreasuryIntent`
- [ ] T019 [P] [US3] Refine the plain-account network-guard case in `/code/amaru-treasury-tx-issue-159/test/unit/Amaru/Treasury/Tx/StakeRewardInitWizardNetworkGuardSpec.hs` from placeholder Answers (Slice 2 scaffold) to real Answers

### Implementation for Slice 3

- [ ] T020 [US1] Implement `stakeRewardInitPlainAccountToIntent` (pure; extracts `dsrrPermissionsScriptHash` from the parsed registry into the payload; bakes `--funding-seed-txin` into the wallet block) in `/code/amaru-treasury-tx-issue-159/lib/Amaru/Treasury/Tx/StakeRewardInitWizard.hs` and wire the plain-account runner arm in `/code/amaru-treasury-tx-issue-159/lib/Amaru/Treasury/Cli/StakeRewardInitWizard.hs`

**Checkpoint**: both subcommands functional; goldens green; `./gate.sh` green.

---

## Phase 6: Slice 4 — No-simulation grep enforcement (Priority: P1)

**Goal**: Mechanically enforce NFR-006 / SC-007: the wizard module sources contain zero references to `buildStakeRewardScriptAccountCore` and `buildStakeRewardPlainAccountCore`. One hspec unit test only — no parallel `gate.sh` grep step.

**Independent Test**: `nix build .#checks.unit` runs `StakeRewardInitWizardNoSimulationSpec` and asserts the wizard module sources contain neither of the two core symbol names (after stripping Haskell comments).

**Subagent brief** — one bisect-safe commit, no push. Commit subject: `test(tx): stake-reward-init-wizard no-simulation grep (#159)`. Commit body must include `Tasks: T021`.

```text
Owned files (create or modify):
- test/unit/Amaru/Treasury/Tx/StakeRewardInitWizardNoSimulationSpec.hs            (new — unit test only)

Forbidden scope: any wizard module (Slices 1–3), specs/, gate.sh, README.md, docs/.

The test uses Data.Text.IO.readFile on:
  lib/Amaru/Treasury/Tx/StakeRewardInitWizard.hs
  lib/Amaru/Treasury/Cli/StakeRewardInitWizard.hs
and asserts via Data.Text.isInfixOf that neither of the two core symbol names appears
in either source (after stripping Haskell line and block comments — same pattern as
#158's RegistryInitWizardNoSimulationSpec, because Slices 2/3 may legitimately mention
the core names in Haddock prose to document the no-simulation contract; the CODE form
is what matters).

The test verifies its own RED state by first patching one of the wizard sources to
include a "buildStakeRewardScriptAccountCore" code reference (not a comment),
observing the test fail, then reverting the patch before committing.
```

### Tests for Slice 4 (RED — written first, observed failing) ⚠️

- [ ] T021 [P] [US2] Create `/code/amaru-treasury-tx-issue-159/test/unit/Amaru/Treasury/Tx/StakeRewardInitWizardNoSimulationSpec.hs` with hspec tests reading each wizard source, stripping Haskell line and block comments, and asserting `Data.Text.isInfixOf` returns False for each of `buildStakeRewardScriptAccountCore`, `buildStakeRewardPlainAccountCore`. Pattern follows `test/unit/Amaru/Treasury/Tx/RegistryInitWizardNoSimulationSpec.hs`.

**Checkpoint**: grep test green; `./gate.sh` green.

---

## Phase 7: Slice 5 — Documentation alignment (Priority: P2)

**Goal**: Update `README.md` and `docs/local-devnet-smoke.md` to describe the two-subcommand operator path with operator-typed `--registry` + `--funding-seed-txin`, the explicit "unsafe inter-step carry" warning (stale funding TxIn, wrong `--registry` path, registry from an unsubmitted bootstrap), and forward-references to [#161](https://github.com/lambdasistemi/amaru-treasury-tx/issues/161) (bash smoke) and [#163](https://github.com/lambdasistemi/amaru-treasury-tx/issues/163) (resumable client state).

**Independent Test**: rendered docs show the two-subcommand path; operator-typed `--registry` and `--funding-seed-txin` visible at both steps; explicit "unsafe" warning present; #161 and #163 are linked.

**Orchestrator-owned** — no subagent. Commit subject: `docs(159): stake-reward-init-wizard operator path`. Commit body must include `Tasks: T022, T023`.

- [ ] T022 [US4] Update `/code/amaru-treasury-tx-issue-159/README.md` stake-reward-init section with the two-subcommand invocation flow, operator-typed `--registry` and `--funding-seed-txin` visible at both `script-account` and `plain-account`, a "common mistakes" call-out (stale funding TxIn, wrong `--registry` path, registry from an unsubmitted bootstrap), and forward references to [#161](https://github.com/lambdasistemi/amaru-treasury-tx/issues/161) and [#163](https://github.com/lambdasistemi/amaru-treasury-tx/issues/163)
- [ ] T023 [US4] Update `/code/amaru-treasury-tx-issue-159/docs/local-devnet-smoke.md` stake-reward-init section with the same two-subcommand flow, the unsafe inter-step carry warning (registry path + funding TxIn handed across the #158→#159 boundary by hand), and forward references to #161 and #163

**Checkpoint**: docs aligned with delivered behavior; `./gate.sh` green; PR body refreshed.

---

## Phase 8: Slice 6 — Drop gate.sh + mark PR ready (Priority: —)

**Goal**: Remove `gate.sh` from the worktree and mark PR #168 ready for review. Per the `gate-script` skill, the absence of `gate.sh` at HEAD is itself the "PR is finalized" sentinel.

**Orchestrator-owned** — no subagent. Commit subject: `chore: drop gate.sh (ready for review) (#159)`.

- [ ] T024 Run the finalization audit (`./gate.sh` green at HEAD, every previous slice commit carries `Tasks:` trailer, every `[ ]` in this file has become `[X] T### (commit: <sha>)`, README + docs + PR body aligned)
- [ ] T025 `git rm /code/amaru-treasury-tx-issue-159/gate.sh` and commit; `gh pr ready 168 -R lambdasistemi/amaru-treasury-tx`

**Checkpoint**: PR ready; CI green; awaiting external review.

---

## Dependencies & Execution Order

### Phase dependencies (= slice dependencies)

```
Slice 1 (Phase 3) ──► Slice 2 (Phase 4) ──► Slice 3 (Phase 5) ──► Slice 4 (Phase 6) ──► Slice 5 (Phase 7) ──► Slice 6 (Phase 8)
```

Strictly sequential because:

- Slice 2 imports the `Answers` records and `StakeRewardInitError` introduced in Slice 1, and replaces Slice 1's script-account TODO stub.
- Slice 3 reuses Slice 2's `StakeRewardInitEnv`, resolver shape, registry-parse path, and `StakeRewardInitWizardFixtures` helper.
- Slice 4's grep test reads the wizard source files; running it before Slices 1–3 land is meaningless (the files don't exist) but won't break anything — it's safer after.
- Slice 5 describes the delivered behavior; running it before Slices 1–3 land would write fiction.
- Slice 6 finalizes everything.

### Within each slice

- RED tasks (tests) before GREEN tasks (implementation), in the same commit. The subagent observes RED failure, then writes the minimum production code to flip it to GREEN, then runs `./gate.sh`.

### Parallel opportunities

Within a single slice, the marked `[P]` tasks operate on different files and have no inter-task dependencies; the subagent can write them in any order. Across slices: none. This PR is single-track by design.

---

## MVP scope

The minimum reviewable increment is Slices 1 + 2 + 3 together (US1 + US2 + US3 delivered end-to-end for both sub-actions). Slice 4 hardens the no-simulation invariant; Slice 5 aligns docs; Slice 6 finalizes. The PR ships all six slices together — there is no intermediate release.

---

## Notes

- [P] tasks = different files within a slice.
- [Story] label maps the task to its primary user story for traceability — many tasks contribute to multiple stories; the label is the primary one.
- Each slice = one subagent run = one bisect-safe commit. Commit body MUST include `Tasks: T###[, T###]`. After review, orchestrator amends the slice commit to mark `[X] T### (commit: <short-sha>)` in this file.
- `gate.sh` runs at every slice; `./gate.sh` green is the GREEN gate. Do NOT push from the subagent.
- Verify tests fail (RED) before implementing.
- Avoid: vague tasks, same-file conflicts within a slice (use `[P]` discipline), cross-slice edits to files an earlier slice already shipped.
- Slice 2 is the heaviest (3 RED orthogonal failure paths + golden + script-account translation). If the slice grows past ~600 added lines or the subagent's WIP.md shows scope creep, the orchestrator may split it into Slice 2a (resolver + network guard + script-account + golden) and Slice 2b (registry-parse error variants + tests). Default plan is single-slice.
