# Tasks: Unified intent JSON + tx-build

**Input**: Design documents from [`specs/005-unified-tx-build/`](.)
**Prerequisites**: [plan.md](./plan.md), [spec.md](./spec.md),
[research.md](./research.md), [data-model.md](./data-model.md),
[contracts/tx-build-cli.md](./contracts/tx-build-cli.md),
[contracts/treasury-intent-json.md](./contracts/treasury-intent-json.md),
[quickstart.md](./quickstart.md)

**Tracking issue**: [#51](https://github.com/lambdasistemi/amaru-treasury-tx/issues/51)

**Tests**: Required by Constitution V (golden CBOR fixtures) and
SC-002 / SC-004. Each user-story phase contains its own tests.
The most important test is the **swap golden byte-identity gate**
(SC-004) — the `expected.cbor` bytes of the existing swap golden
MUST NOT change as a result of this feature.

**Organization**: tasks grouped by user story. The MVP gate is
Phase 3 (US3 — round-trip property on `TreasuryIntent`). Phase 4
(US1 + US2 wired end-to-end + swap golden re-record) is the
no-behaviour-change gate.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: parallelizable (different files, no dependency on
  unfinished tasks)
- **[Story]**: which user story (US1 / US2 / US3 / US4 / US5)
- File paths are absolute relative to repo root
- The owning contract for any list reproduced below is the file in
  brackets — see [data-model.md](./data-model.md),
  [contracts/tx-build-cli.md](./contracts/tx-build-cli.md), and
  [contracts/treasury-intent-json.md](./contracts/treasury-intent-json.md).
  Tasks reference the contract rather than duplicating fields.

## Path conventions

- New library modules:
  `lib/Amaru/Treasury/IntentJSON.hs`,
  `lib/Amaru/Treasury/IntentJSON/Common.hs`,
  `lib/Amaru/Treasury/Wizard/Common.hs`,
  `lib/Amaru/Treasury/TreasuryBuild.hs`,
  `lib/Amaru/Treasury/TreasuryBuild/Trace.hs`.
- Modules collapsed / removed: `Tx/SwapIntentJSON.hs`,
  `Tx/SwapBuild.hs`, `Tx/Swap/Trace.hs`.
- Subcommand wiring: `app/amaru-treasury-tx/Main.hs`.
- Unit tests: `test/unit/Amaru/Treasury/IntentJSONSpec.hs`,
  `test/unit/Amaru/Treasury/TreasuryBuildSpec.hs`.
- Re-recorded fixture: `test/fixtures/swap/intent.json` (the
  CBOR `expected.cbor` is unchanged).

---

## Phase 1: Setup (shared infrastructure)

**Purpose**: cabal/justfile plumbing for the new modules. No
production code yet.

- [ ] T001 Add the new library modules
      (`Amaru.Treasury.IntentJSON`,
      `Amaru.Treasury.IntentJSON.Common`,
      `Amaru.Treasury.Wizard.Common`,
      `Amaru.Treasury.TreasuryBuild`,
      `Amaru.Treasury.TreasuryBuild.Trace`) to the library
      `exposed-modules` list in `amaru-treasury-tx.cabal`. Mark
      `Tx/SwapIntentJSON`, `Tx/SwapBuild`, `Tx/Swap/Trace` for
      removal in T011 / T021. Run `nix develop -c just
      cabal-check` and confirm pass.
- [ ] T002 [P] Add the new unit specs
      (`Amaru.Treasury.IntentJSONSpec`,
      `Amaru.Treasury.TreasuryBuildSpec`) to the `unit-tests`
      stanza's `other-modules`. The existing
      `Amaru.Treasury.Tx.SwapWizardSpec` stays under
      `unit-tests`; the existing `SwapGoldenSpec` (under
      `golden-tests`) keeps its name but its body is rewritten in
      T024.
- [ ] T003 [P] Confirm `just ci` recipe still chains
      `build → unit → golden → format-check → hlint → smoke
       → release-check`; no recipe edit expected.

**Checkpoint**: cabal compiles; the new modules exist as empty
stubs; both test suites discover them.

---

## Phase 2: Foundational (blocking prerequisites)

**Purpose**: GADT + type-family scaffolding, shared blocks, and
the parser/encoder helpers shared across actions.

- [ ] T004 Implement `Action`, `SAction` (singleton GADT),
      `Payload` and `Translated` type families in
      `lib/Amaru/Treasury/IntentJSON.hs`. Field list per
      [data-model.md §1, §2](./data-model.md). Strict, leading
      commas, fourmolu 70-col, explicit export list. Add the
      required language pragmas (`DataKinds`, `GADTs`,
      `TypeFamilies`, `KindSignatures`).
- [ ] T005 [P] Implement the shared structural blocks
      (`WalletJSON`, `ScopeJSON`, `RationaleJSON`) in
      `lib/Amaru/Treasury/IntentJSON.hs` with `FromJSON` +
      `ToJSON`. Field list per
      [data-model.md §3](./data-model.md).
- [ ] T006 [P] Implement the per-action input records
      (`SwapInputs`, `DisburseInputs`, `WithdrawInputs`,
      `ReorganizeInputs`) in
      `lib/Amaru/Treasury/IntentJSON.hs` with `FromJSON` +
      `ToJSON`. `SwapInputs` lifts verbatim from
      [`Tx.SwapIntentJSON.SwapInputs`](https://github.com/lambdasistemi/amaru-treasury-tx/blob/main/lib/Amaru/Treasury/Tx/SwapIntentJSON.hs);
      `DisburseInputs` mirrors feature 004's
      `DisburseInputsJSON`; `WithdrawInputs` and
      `ReorganizeInputs` are placeholders (record with a single
      unit field) until [#45](https://github.com/lambdasistemi/amaru-treasury-tx/issues/45)
      and [#46](https://github.com/lambdasistemi/amaru-treasury-tx/issues/46)
      ship.
- [ ] T006a Add a placeholder
      `lib/Amaru/Treasury/Tx/Reorganize.hs` exporting
      `data ReorganizeIntent = ReorganizeIntent` (a record with a
      single unit field) so the `Translated` family in §2 of
      [data-model.md](./data-model.md) resolves on this branch.
      Mirrors the existing
      [`Tx/Withdraw.hs`](https://github.com/lambdasistemi/amaru-treasury-tx/blob/main/lib/Amaru/Treasury/Tx/Withdraw.hs)
      which already exposes a typed `WithdrawIntent`. Real
      `ReorganizeIntent` shape lands with
      [#46](https://github.com/lambdasistemi/amaru-treasury-tx/issues/46);
      this task only adds the type so the type family can name
      it. Add `Amaru.Treasury.Tx.Reorganize` to the library
      `exposed-modules` list in `amaru-treasury-tx.cabal`.
- [ ] T007 Implement the `TreasuryIntent (a :: Action)` GADT and
      the `SomeTreasuryIntent` existential in
      `lib/Amaru/Treasury/IntentJSON.hs`. Field list per
      [data-model.md §2](./data-model.md).
- [ ] T008 [P] Implement `Amaru.Treasury.IntentJSON.Common`:
      shared parser helpers (`parseAddr`, `parseTxIn`,
      `parseRewardAccount`, `parseGuardKeyHash`,
      `decodeHexBytes`, `mkHash28`, `mkHash32`). Bodies move
      verbatim from
      [`Tx.SwapIntentJSON`](https://github.com/lambdasistemi/amaru-treasury-tx/blob/main/lib/Amaru/Treasury/Tx/SwapIntentJSON.hs)
      and the (in-flight) feature 004
      [`Tx.DisburseIntentJSON`](https://github.com/lambdasistemi/amaru-treasury-tx/blob/004-disburse-wizard/lib/Amaru/Treasury/Tx/DisburseIntentJSON.hs).
      The existing copies in those modules are deleted in T011.
- [ ] T009 [P] Implement `Amaru.Treasury.Wizard.Common`: shared
      signer-resolver (`signerScopeFromText`,
      `normaliseSignerToken`, `isHex28`, `ownerForScope`) and
      the `NetworkConstants` table. Bodies move verbatim from
      [`Tx.SwapWizard`](https://github.com/lambdasistemi/amaru-treasury-tx/blob/main/lib/Amaru/Treasury/Tx/SwapWizard.hs).
      The existing copies in `Tx.SwapWizard` are deleted in
      T012.
- [ ] T010 [P] Implement
      `Amaru.Treasury.TreasuryBuild.Trace.BuildEvent` (typed
      trace events for the unified build path). Constructor list
      per
      [contracts/tx-build-cli.md §5](./contracts/tx-build-cli.md).
      Mirrors `Tx.Swap.Trace.SwapEvent` shape but adds
      `TbeIntentParsed`, `TbeNetworkOk`, `TbeNetworkMismatch`.
      The existing `Tx.Swap.Trace` module is deleted in T028
      alongside the other now-unused per-action modules.
- [ ] T011 Delete *only* the helper functions (parser /
      hex-decode) from `Tx.SwapIntentJSON` (every `parse*` helper
      now lives in `IntentJSON.Common`). The module + its
      `SwapIntentJSON` record + `translateIntent` body stay
      temporarily — T021 borrows that body verbatim into the
      unified `runSwap`. Full file deletion lands in T028.
      Update the module's import list and verify it still
      compiles standalone.
- [ ] T012 Delete the now-empty signer-resolver helpers from
      `Tx.SwapWizard` (every helper now lives in
      `Wizard.Common`). Update the module's import list and
      verify it still compiles standalone.
- [ ] T013 [P] Confirm GREEN on Phase 2: `nix develop -c just
      build` compiles all new modules; `just cabal-check` clean.

**Checkpoint**: types and shared helpers compile; no behaviour
yet — the dispatcher and the parser instances land in Phase 3.

---

## Phase 3: User Story 3 — single intent shape (Priority: P1) 🎯 MVP

> **Story label**: `[US3]` matches `spec.md` US3 ("Single intent
> shape"). The round-trip property is the MVP gate — it earns the
> downstream byte-identity test on the swap golden.

**Goal**: `decodeTreasuryIntent (encodeSomeTreasuryIntent x) ==
Right (toSome x)` holds for any wizard-shaped intent across all
four action variants. The action ↔ payload pairing is enforced
at compile time by the GADT (data-model §2), and at parse time
by the FromJSON instance (data-model §6).

**Independent test**: a small generator over each of the four
action variants produces ≥100 random `SomeTreasuryIntent` values;
the property holds byte-for-byte (modulo deterministic key
ordering).

**Test-first ordering** (Constitution V): the property lands red
before the FromJSON instance is wired.

- [ ] T014 [P] [US3] Implement the FromJSON instance for
      `SomeTreasuryIntent` in
      `lib/Amaru/Treasury/IntentJSON.hs`. Body shape per
      [data-model.md §6](./data-model.md) — schema allow-list
      check, action discriminator parse, dispatch on action to
      build the `SomeTreasuryIntent` wrapper. Each action branch
      reads its payload from the action-keyed JSON sub-object.
- [ ] T015 [P] [US3] Implement `toJSONIntent :: SAction a ->
      TreasuryIntent a -> Aeson.Value` and
      `encodeSomeTreasuryIntent :: SomeTreasuryIntent ->
      ByteString.Lazy` (stable encoder using `aeson-pretty` with
      4-space indent + alphabetical key ordering, mirroring
      [`SwapIntentJSON.encodeIntentJSON`](https://github.com/lambdasistemi/amaru-treasury-tx/blob/main/lib/Amaru/Treasury/Tx/SwapWizard.hs)).
- [ ] T016 [P] [US3] Implement `decodeTreasuryIntent ::
      ByteString.Lazy -> Either String SomeTreasuryIntent` and
      `decodeTreasuryIntentFile :: FilePath -> IO (Either String
      SomeTreasuryIntent)` in `lib/Amaru/Treasury/IntentJSON.hs`.
- [ ] T017 [US3] Author
      `test/unit/Amaru/Treasury/IntentJSONSpec.hs` with the
      round-trip property: for each of the four action variants
      generate a small `SomeTreasuryIntent`, encode, decode,
      assert equality. ≥100 shapes per variant. SC-002.
      **Note**: the withdraw and reorganize generators produce
      trivial-shape values (since `WithdrawInputs` and
      `ReorganizeInputs` are placeholder unit-records per T006).
      The property still holds for those, but the test is
      uninformative — replace these generators with real-shape
      ones when [#45](https://github.com/lambdasistemi/amaru-treasury-tx/issues/45)
      and [#46](https://github.com/lambdasistemi/amaru-treasury-tx/issues/46)
      ship.
- [ ] T018 [US3] Confirm RED before T014–T016 land: run `nix
      develop -c just unit --test-options=--match=IntentJSON`.
      (If RED isn't observed because the parsers didn't exist
      and the test won't compile, pause T014–T016 to write
      stubs returning `Left "RED"`, run, observe RED, then
      remove the stubs.)
- [ ] T019 [US3] Negative tests in the same spec:
      - `action: "frob"` → typed parse error.
      - `schema: 99` → "unknown intent schema" error.
      - `action: "swap"` with a `disburse` block but no `swap`
        block → "key not found: swap" error.
      - missing `network` field → typed parse error.
- [ ] T020 [US3] Confirm GREEN: rerun T018's command. Property +
      negative tests pass.

**Checkpoint (MVP)**: the unified intent shape parses and
encodes for all four variants, with action ↔ payload pairing
enforced at compile time + parse time. SC-002 satisfied.

---

## Phase 4: User Story 1 — single tx-build subcommand (Priority: P1)

> **Story label**: `[US1]` matches `spec.md` US1 ("One build
> command for any treasury action"). This phase wires the unified
> dispatcher and re-records the swap golden byte-identical
> (SC-004 no-behaviour-change gate).

**Goal**: `swap-wizard ... | tx-build > tx.cbor` produces the
exact same `expected.cbor` bytes as the pre-PR `swap-wizard ... |
swap` pipeline. The `swap` subcommand is removed; `tx-build` is
the sole build entry point.

- [ ] T021 [US1] Implement `Amaru.Treasury.TreasuryBuild` per
      [data-model.md §8](./data-model.md):
      `runBuild :: ChainContext -> TranslatedShared -> SAction a
       -> Translated a -> IO TreasuryBuildResult`,
      `runFromIntent :: ChainContext -> SomeTreasuryIntent ->
       IO TreasuryBuildResult`, and the per-action runners
      (`runSwap`, `runDisburse`, `runWithdraw`,
      `runReorganize`). `runSwap`'s body is the existing
      [`Tx.SwapBuild.runSwapBuild`](https://github.com/lambdasistemi/amaru-treasury-tx/blob/main/lib/Amaru/Treasury/Tx/SwapBuild.hs)
      verbatim, retyped to take `TranslatedShared` + `Translated
      'Swap`. `runDisburse` is a stub:
      `throwIO . userError $ "runDisburse: feature 004 PR #47 lands first"`
      — the disburse-side rebase commit
      ([#55](https://github.com/lambdasistemi/amaru-treasury-tx/issues/55))
      fills it in. `runWithdraw` and `runReorganize` are
      analogous stubs that `throwIO . userError $ "feature not
      yet shipped"`.
- [ ] T022 [US1] Implement `translateIntent :: SAction a ->
      TreasuryIntent a -> Either String (TranslatedShared,
      Translated a)` in `lib/Amaru/Treasury/IntentJSON.hs`. The
      shared-block lift (`TranslatedShared`) is one body; each
      action's translator dispatches on `SAction a` and produces
      the matching `Translated a`. The swap branch's body is
      [`Tx.SwapIntentJSON.translateIntent`](https://github.com/lambdasistemi/amaru-treasury-tx/blob/main/lib/Amaru/Treasury/Tx/SwapIntentJSON.hs)
      verbatim. The disburse branch returns
      `Left "translateIntent: feature 004 PR #47 lands first"`.
      Withdraw and reorganize return analogous typed "not yet
      shipped" `Left` errors.
- [ ] T023 [US1] Rewrite `app/amaru-treasury-tx/Main.hs`:
      remove the `swap` subcommand parser; remove the `--network`
      / `--network-magic` flags from the build side; add the
      `tx-build` subcommand parser per
      [contracts/tx-build-cli.md §1](./contracts/tx-build-cli.md);
      wire `runFromIntent`. The wizard subcommand `swap-wizard`
      is unchanged operator-side but its translator now writes
      the unified intent (T030).
- [ ] T024 [US1] Re-point
      [`test/golden/SwapGoldenSpec.hs`](https://github.com/lambdasistemi/amaru-treasury-tx/blob/main/test/golden/SwapGoldenSpec.hs)
      at `decodeTreasuryIntent` + `translateIntent SSwap` +
      `runBuild`. Assert the existing `expected.cbor` bytes are
      unchanged. **This is the SC-004 byte-identity gate.**
- [ ] T025 [US1] Re-record
      `test/fixtures/swap/intent.json` against the new shape:
      add `schema: 1`, `action: "swap"`, `network: "mainnet"`
      at the top level; nest the existing swap fields under a
      `swap` key. Confirm `just golden --test-options=
      --match=swap` passes (i.e. the rewired
      `SwapGoldenSpec` matches the unchanged `expected.cbor`).
- [ ] T026 [US1] Smoke script `scripts/smoke/tx-build-pipe`:
      exercise `swap-wizard | tx-build` against a fixture
      metadata.json, assert the wizard's stdout decodes as
      `SomeTreasuryIntent` and that `tx-build < intent.json`
      exits `0` with hex on stdout. Records wall-clock and
      fails > 10 s (covers feature 004 SC-002 carryover).
- [ ] T027 [US1] Add the smoke script to the `just smoke`
      recipe and to the CI workflow under
      [`.github/workflows/ci.yml`](https://github.com/lambdasistemi/amaru-treasury-tx/blob/main/.github/workflows/ci.yml).
- [ ] T028 [US1] Delete the now-unused
      `lib/Amaru/Treasury/Tx/SwapBuild.hs`,
      `lib/Amaru/Treasury/Tx/SwapIntentJSON.hs`,
      `lib/Amaru/Treasury/Tx/Swap/Trace.hs`. Remove their entries
      from `amaru-treasury-tx.cabal`. Verify `just build` passes.

**Checkpoint**: `tx-build` is the sole build subcommand;
`swap-wizard | tx-build` produces byte-identical CBOR to the
pre-PR pipeline. SC-001 + SC-004 satisfied.

---

## Phase 5: User Story 2 — network in intent (Priority: P1)

> **Story label**: `[US2]` matches `spec.md` US2 ("Network in the
> intent"). Mostly already wired (T023 removed `--network` from
> build; T030 makes the wizard write `network` into the intent);
> this phase adds the mismatch detection.

**Goal**: when the operator's `--node-socket` is for a different
network than the intent declares, `tx-build` exits 6 with a
clear "intent declares X, socket reports Y" error.

- [ ] T029 [US2] Read the N2C handshake's reported magic in
      `app/amaru-treasury-tx/Main.hs` after
      `withLocalNodeBackend` connects. Compare against
      `intent.network`'s magic
      (`networkNameToPair :: Text -> Word32`). On mismatch,
      emit `TbeNetworkMismatch (intentNet, intentMagic)
      (socketNet, socketMagic)`, write a single-line stderr
      message, and exit 6.
- [ ] T030 [US2] Refactor
      [`runWizard`](https://github.com/lambdasistemi/amaru-treasury-tx/blob/main/app/amaru-treasury-tx/Main.hs)
      in `app/amaru-treasury-tx/Main.hs` to write
      `tiSchema = 1`, `tiSAction = SSwap`, and `tiNetwork =
      <name>` into the unified intent. The wizard's flag set is
      unchanged (still takes `--network`).
- [ ] T031 [P] [US2] Unit test in
      `test/unit/Amaru/Treasury/TreasuryBuildSpec.hs`: stub
      `Provider IO` reports a network magic differing from the
      intent's; assert the runner returns `Left
      NetworkMismatch{…}` (or equivalent) with both magics in
      the error.
- [ ] T032 [P] [US2] Integration test (manual; recorded in PR
      description): build a preprod intent against a mainnet
      socket. Confirm exit 6 + stderr message names both
      networks.

**Checkpoint**: the network is single-source-of-truth in the
intent; mismatch is detected before the build attempts to
balance.

---

## Phase 6: User Story 4 — schema versioning (Priority: P2)

> **Story label**: `[US4]` matches `spec.md` US4 ("Schema
> versioning hook"). Mostly already covered by T014 + T019;
> this phase locks the contract.

- [ ] T033 [US4] Confirm the schema allow-list is exposed as
      `allowedSchemas :: [Int]` from
      `Amaru.Treasury.IntentJSON` (per data-model §6) and
      Haddock-document it as the single source of truth.
- [ ] T034 [US4] Add a Haddock note above the `allowedSchemas`
      definition explaining the bump protocol: a future schema
      change appends to the list; old binaries refuse new
      intents; new binaries accept old intents only if their
      schema is in the allow-list.

**Checkpoint**: schema gate is documented and tested.

---

## Phase 7: User Story 5 — docs migration (Priority: P2)

> **Story label**: `[US5]` matches `spec.md` US5 ("Migration of
> feature 002 swap quickstart").

**Goal**: every operator-visible doc that currently says
`swap-wizard … | swap` says `swap-wizard … | tx-build` after
this PR. `grep -r '| swap '` returns zero hits.

- [ ] T035 [US5] Update `README.md`: replace any `| swap`
      pipeline example with `| tx-build`.
- [ ] T036 [US5] Update `docs/quickstart.md` (the user-facing
      docs site): replace any `| swap` example with
      `| tx-build`. Ensure the Markdown still renders cleanly
      under `mkdocs`.
- [ ] T037 [US5] Update
      [`specs/002-swap-wizard/quickstart.md`](https://github.com/lambdasistemi/amaru-treasury-tx/blob/main/specs/002-swap-wizard/quickstart.md):
      change the famous-swap pipeline to use `| tx-build`.
- [ ] T038 [US5] Update
      [`specs/002-swap-wizard/contracts/swap-wizard-cli.md`](https://github.com/lambdasistemi/amaru-treasury-tx/blob/main/specs/002-swap-wizard/contracts/swap-wizard-cli.md)
      to reflect the new intent shape (top-level `network`,
      `schema`, `action`).
- [ ] T039 [US5] Update
      [`specs/002-swap-wizard/spec.md`](https://github.com/lambdasistemi/amaru-treasury-tx/blob/main/specs/002-swap-wizard/spec.md)
      and
      [`specs/002-swap-wizard/plan.md`](https://github.com/lambdasistemi/amaru-treasury-tx/blob/main/specs/002-swap-wizard/plan.md)
      with a "Superseded by feature 005" preface and link to
      this PR. Mark feature 002 as a contributor to the
      unified shape.
- [ ] T040 [US5] Run `grep -rE '\| swap ' README.md docs/
      specs/002-swap-wizard/`; assert zero matches. (Not
      including `| swap-wizard ` which is a different command.)

**Checkpoint**: feature 002's doc surface no longer instructs
operators to invoke `| swap`. SC-001 + SC-005 (and the doc-side
of SC-004) satisfied.

---

## Phase 8: Polish & cross-cutting concerns

- [ ] T041 [P] Update PR description with the final
      `swap-wizard | tx-build` reference and link to
      [quickstart.md](./quickstart.md). Use `gh pr edit` after
      every push to keep the description in sync with the diff.
- [ ] T042 [P] Run `nix develop -c just cabal-check`; resolve
      any new warnings to keep the package Hackage-ready
      (Constitution VI).
- [ ] T043 [P] Run `nix develop -c just hlint` and
      `nix develop -c just format-check`; resolve any new
      diagnostics.
- [ ] T044 Manual preprod E2E recorded in the PR description:
      produce `intent.json` with `swap-wizard --network preprod`,
      pipe through `tx-build` against the preprod socket,
      confirm the tx is buildable. Optionally hand-sign and
      submit.
- [ ] T045 On merge of this PR: link the post-merge follow-up
      issue
      [#55](https://github.com/lambdasistemi/amaru-treasury-tx/issues/55)
      ("Post-merge: rebase #47 + finalise feature 004 under
      unified shape") in the merge commit message. #55 owns the
      substantial work that follows — rebase #47, fill the
      `runDisburse` stub, re-record the ada-disburse golden,
      drop `blockedBy = #51` from #45/#46. Splitting that body
      out keeps this PR's task list focused; #55 runs on the
      004 branch under its own review cycle.

**Checkpoint**: ready for review and merge once #52 is green.

---

## Dependencies

```
Setup (T001-T003)
    └── Foundational (T004-T013)
            └── Phase 3 [US3] round-trip (T014-T020) ── MVP gate
                    └── Phase 4 [US1] tx-build + golden (T021-T028) ── SC-004 gate
                            └── Phase 5 [US2] network mismatch (T029-T032)
                                    └── Phase 6 [US4] schema (T033-T034)
                                            └── Phase 7 [US5] docs (T035-T040)
                                                    └── Phase 8 polish (T041-T045)
```

Phase 3 (`[US3]` round-trip) is the MVP gate — it earns the
byte-identity gate of Phase 4. Phase 4 is the no-behaviour-change
gate (SC-004) — the most important assertion in this feature.
Everything beyond Phase 4 is operator-experience polish + doc
migration.

## Parallel opportunities

- **Within Phase 1**: T002, T003 are independent of T001's
  cabal edit.
- **Within Phase 2**: T005, T006, T008, T009, T010 are
  file-disjoint and can land in any order after T004 + T007.
- **Within Phase 3**: T014, T015, T016 are file-disjoint
  (different functions in the same file but different sections).
- **Within Phase 5**: T031 + T032 (unit + integration) are
  independent.
- **Within Phase 7**: T035, T036, T037, T038, T039 are all
  file-disjoint.
- **Within Phase 8**: T041, T042, T043 are all parallel.

## MVP scope

**MVP = Phase 1 + Phase 2 + Phase 3.** Proves the unified
`SomeTreasuryIntent` shape parses and encodes round-trip for all
four action variants. Phase 4 lands the byte-identity gate.
Phase 5–8 polish the operator + docs experience.

## Out of scope for this feature

- Implementing the disburse / withdraw / reorganize build paths
  themselves — those are tracked under
  [#44](https://github.com/lambdasistemi/amaru-treasury-tx/issues/44)
  (feature 004),
  [#45](https://github.com/lambdasistemi/amaru-treasury-tx/issues/45)
  (feature 005 → 006 after renumber),
  [#46](https://github.com/lambdasistemi/amaru-treasury-tx/issues/46)
  (feature 006 → 007 after renumber). This PR provides only the
  unified shape; per-action build bodies land on their own PRs.
- A backwards-compatible `swap` alias for the old subcommand
  name. We chose to remove it (research §R6).
- Backwards-compatible parsing of feature 002's pre-unification
  swap intents (no `network`, no `schema`, no `action`). Old
  intents fail at parse time; operators re-run the wizard.
