---
description: "Task list for 007-aggregate-wallet-utxos"
---

# Tasks: Aggregate Multiple Wallet UTxOs as Fuel in swap-wizard

**Input**: Design documents from `/specs/007-aggregate-wallet-utxos/`
**Prerequisites**: [spec.md](./spec.md), [plan.md](./plan.md), [research.md](./research.md), [data-model.md](./data-model.md), [contracts/intent-schema.diff](./contracts/intent-schema.diff), [quickstart.md](./quickstart.md)

**Tests**: included. Constitution principle V (test-first golden CBOR fixtures, non-negotiable) requires them.

**Organization**: tasks are grouped by user story to enable independent implementation and testing of each story.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: parallelizable — different files, no dependencies on incomplete tasks.
- **[Story]**: user-story label (US1, US2, US3) — required for user-story phase tasks.
- File paths are absolute or repo-relative as appropriate.

## Path Conventions

Single Haskell cabal package at the repository root (per plan.md). Sources under `lib/` and `app/`; tests under `test/unit/` and `test/golden/`; fixtures under `test/fixtures/`; spec assets under `docs/assets/`.

---

## Phase 1: Setup

No new project scaffolding is needed; the cabal package, nix flake, justfile, and test runner are already in place from feature 005.

- [ ] T001 Confirm working tree at `/code/amaru-treasury-tx-swap-wallet-fee` is on branch `007-aggregate-wallet-utxos` and based on `origin/main` HEAD with no committed delta (sanity check; one stgit-style status command, no edits).

---

## Phase 2: Foundational (blocking prerequisites for all user stories)

Additive type and schema scaffolding. After this phase the codebase compiles and existing tests pass with `extras = []` everywhere; no behavior change yet. This phase is the layer that the three user stories then exercise.

- [ ] T010 Extend `WalletJSON` in `lib/Amaru/Treasury/IntentJSON.hs` with `wjExtraTxIns :: ![Text]`. `FromJSON` reads `extraTxIns` with `.!= []` default; `ToJSON` always emits the field (canonical empty list).
- [ ] T011 Extend `WalletSelection` in `lib/Amaru/Treasury/Tx/SwapWizard.hs` with `wsExtraTxIns :: ![Text]` and update its `FromJSON` instance to read `extraTxIns` with `.!= []` default.
- [ ] T012 Extend `SwapIntent` in `lib/Amaru/Treasury/Tx/Swap.hs` with `siExtraWalletInputs :: ![TxIn]` (placed adjacent to `siWalletUtxo` for cohesion). Update Haddock to describe head-vs-extras semantics.
- [ ] T013 Update `translateSwap` in `lib/Amaru/Treasury/IntentJSON.hs` to parse `wjExtraTxIns` into `siExtraWalletInputs` (each `Text` parsed via `parseTxIn`, accumulating errors).
- [ ] T014 Update `wizardToTreasuryIntent` in `lib/Amaru/Treasury/Tx/SwapWizard.hs` to project `wsExtraTxIns ws` into `wjExtraTxIns`.
- [ ] T015 Update `walletSchema` in `lib/Amaru/Treasury/IntentJSON/Schema.hs` to declare an optional `extraTxIns: array<txIn>` property. Adjust `objectSchema` (or its `properties` arg shape) so the property is allowed but not required.
- [ ] T016 Regenerate `docs/assets/intent-schema.json` from the updated `intentJsonSchema` generator (`nix run .#regenerate-intent-schema` if a recipe exists, otherwise dump via a small ghci/cabal one-liner). Confirm `IntentJSONSchemaSpec` passes the asset-equality test.
- [ ] T017 Update `app/swap-probe/Main.hs` to construct `SwapIntent` with `siExtraWalletInputs = []` (back-compat for the manual probe path).
- [ ] T018 Update unit-test constructors of `SwapIntent` (`test/unit/Amaru/Treasury/Tx/SwapSpec.hs:149`) and any other `SwapIntent` literals to include `siExtraWalletInputs = []`. Same for `WalletJSON` constructors in `test/unit/Amaru/Treasury/IntentJSONSpec.hs` (`genWallet`).
- [ ] T019 Add `"extraTxIns": []` under `wallet` in `test/fixtures/swap/intent.json` and under `walletSelection` in `test/fixtures/swap-wizard/env.json` and under `wallet` in `test/fixtures/swap-wizard/expected.intent.json`. Confirm all golden + schema tests still pass.
- [ ] T020 Run `just unit && just lint` (or the project's full local CI) and confirm the gate is green at the foundational point.

---

## Phase 3: User Story 1 — Operator funds a swap from a wallet with multiple small UTxOs (P1) 🎯 MVP

**Goal**: aggregate largest-first pure-ADA UTxOs at the wallet address until cumulative ADA ≥ wallet target, thread the selection through the resolver and `swapProgram` so every UTxO becomes an input and the head doubles as collateral.

**Independent Test**: pipe `swap-wizard` into `tx-build` against a fake wallet whose largest pure-ADA UTxO is below target but whose total covers it; assert the emitted intent.json's `wallet.extraTxIns` is non-empty and the builder produces an unsigned Conway tx whose body inputs contain every selected UTxO with collateral set to the head.

### Tests for User Story 1 ⚠️ MUST be written first and MUST fail before T040+

- [ ] T030 [P] [US1] Add `selectWallet` cases to `test/unit/Amaru/Treasury/Tx/SwapWizardSpec.hs`: (a) two UTxOs needed → returns `(largest, [smaller], sum)`; (b) three UTxOs and only top two cover target → returns `(largest, [second], sum)` and stops before the third; (c) single UTxO covers target → returns `(largest, [], sum)`; (d) sorting is by ADA descending (input order doesn't matter).
- [ ] T031 [P] [US1] Add `swapProgram` case to `test/unit/Amaru/Treasury/Tx/SwapSpec.hs`: with `siExtraWalletInputs = [mkTxIn 6, mkTxIn 7]` and `siWalletUtxo = mkTxIn 0`, assert `body ^. inputsTxBodyL == Set.fromList [mkTxIn 0, mkTxIn 1, mkTxIn 6, mkTxIn 7]` (treasury + wallet head + extras) and `body ^. collateralInputsTxBodyL == Set.singleton (mkTxIn 0)` (head only).
- [ ] T032 [P] [US1] Update `genWallet` in `test/unit/Amaru/Treasury/IntentJSONSpec.hs` to roll 0–3 extras from `genTxId`. Add a property assertion that `wjExtraTxIns` round-trips through `ToJSON`/`FromJSON` unchanged (already covered by `roundTripProp`, but verify the generator surfaces both empty and non-empty cases).
- [ ] T033 [P] [US1] Add a positive case to `test/unit/Amaru/Treasury/IntentJSONSchemaSpec.hs`: synthesize an intent JSON with `wallet.extraTxIns = [valid txIn ref]`, validate against `intentJsonSchema`, assert `True`. Add a negative case with `extraTxIns: 3` (wrong type) → `False`.

### Implementation for User Story 1

- [ ] T040 [US1] Rewrite `selectWallet` in `lib/Amaru/Treasury/Tx/SwapWizard.hs` to the new signature: `Integer -> [(Text, Integer, Bool)] -> Either WalletSelectionError ([Text], Integer)`. Algorithm: filter to `not hasNa`, sort by lovelace descending, accumulate until cumulative ≥ target, return `Right (refs, sum)` or `Left (WalletShortfall available target)`. If no eligible UTxOs at all, `Left WalletNoPureAda`. Update the export list.
- [ ] T041 [US1] Add `riChunkSizeLovelace :: !Integer` to `ResolverInput` in the same file. Update `Eq`/`Show` derived instances; no JSON instances on `ResolverInput`.
- [ ] T042 [US1] Add `walletFeeSlackLovelace :: Integer = 2_000_000` constant with Haddock referencing `research.md` D2.
- [ ] T043 [US1] Update `resolveWizardEnv` to:
  1. Compute `chunkCount = let (full, rem') = riAmountLovelace ri \`divMod\` riChunkSizeLovelace ri in fromInteger full + (if rem' > 0 then 1 else 0)`.
  2. Compute `walletTarget = chunkCount * ncExtraPerChunkLovelace nc + walletFeeSlackLovelace`.
  3. Call new `selectWallet walletTarget walletUtxos`. On `Right (refs, _)`, populate `WalletSelection` with `wsTxIn = head refs`, `wsExtraTxIns = tail refs`. On `Left WalletShortfall`, return `Left (ResolverWalletShortfall available walletTarget)`. On `Left WalletNoPureAda`, return `Left ResolverEmptyWalletUtxos` (existing).
- [ ] T044 [US1] Update `app/amaru-treasury-tx/Main.hs` swap-wizard subcommand to pass `riChunkSizeLovelace = chunkSize` in the `ResolverInput` literal.
- [ ] T045 [US1] Update `runSwap` in `lib/Amaru/Treasury/TreasuryBuild.hs`:
  1. Add `siExtraWalletInputs intent` references to the `required` UTxO presence check.
  2. Add `[(i, utxoMap Map.! i) | i <- siExtraWalletInputs intent]` to `inputUtxos`.
  3. Update the Haddock to describe wallet aggregation.
- [ ] T046 [US1] Update `swapProgram` in `lib/Amaru/Treasury/Tx/Swap.hs`: after the existing `_ <- spend (siWalletUtxo si)` and `collateral (siWalletUtxo si)`, add `forM_ (siExtraWalletInputs si) (void . spend)`.
- [ ] T047 [US1] Run T030–T033 + the existing test suite. They MUST all pass now (T030–T031 went red on T040 stubs and turn green here).

---

## Phase 4: User Story 2 — Operator gets a clear shortfall error before the builder runs (P2)

**Goal**: surface `ResolverWalletShortfall` as a typed wizard error rendered to the operator with available/required figures, the wallet address, and the target breakdown — and keep the wizard from emitting any intent.json bytes on stdout in that failure mode.

**Independent Test**: invoke the wizard against a wallet whose pure-ADA total is < target. Assert (a) wizard exit code is non-zero (existing `exit 3`), (b) stderr contains a single-line shortfall message naming both ADA figures and the wallet address, (c) stdout is empty (no intent bytes).

### Tests for User Story 2 ⚠️ MUST be written first

- [ ] T050 [P] [US2] Add `selectWallet` shortfall cases to `test/unit/Amaru/Treasury/Tx/SwapWizardSpec.hs`: (a) total available equal to target → `Right`, (b) total available = target − 1 → `Left (WalletShortfall (target-1) target)`, (c) wallet has only native-asset UTxOs → `Left WalletNoPureAda`.
- [ ] T051 [P] [US2] Add `resolveWizardEnv` shortfall cases to `test/unit/Amaru/Treasury/Tx/SwapWizardSpec.hs`: stub `reEnvQueryWalletUtxos` to return UTxOs whose ADA sums to less than the target; assert resolver returns `Left (ResolverWalletShortfall ...)` with the right (available, requested).

### Implementation for User Story 2

- [ ] T060 [US2] Add `ResolverWalletShortfall !Integer !Integer` to `ResolverError` in `lib/Amaru/Treasury/Tx/SwapWizard.hs` (between existing constructors; preserve `Eq`/`Show` derivations).
- [ ] T061 [US2] Update `app/amaru-treasury-tx/Main.hs` `WeAborted` rendering or the `abortTr tr ("resolve: " <> ...)` branch to format a shortfall as a single-line human-readable message: `wallet shortfall at <addr>: available=<lovelace> required=<lovelace> (chunks=<N>, perChunk=<lovelace>, slack=<lovelace>)`. Other `ResolverError` variants keep their existing rendering.
- [ ] T062 [US2] Run T050–T051. They MUST pass.

---

## Phase 5: User Story 3 — Existing intent.json files keep working (P3)

**Goal**: prove backward compatibility by exercising the legacy intent.json shape (no `extraTxIns`) through the post-feature builder without regenerating golden bytes.

**Independent Test**: feed the existing `test/fixtures/swap/intent.json` (after removing the `extraTxIns: []` line that T019 added — i.e. simulate a stale file) into `decodeTreasuryIntent`; assert it parses; assert the resulting `SwapIntent` has `siExtraWalletInputs = []`; assert the produced tx bytes equal today's golden CBOR.

### Tests for User Story 3 ⚠️ MUST be written first

- [ ] T070 [P] [US3] Add a unit test to `test/unit/Amaru/Treasury/IntentJSONSpec.hs` (or a new `LegacyWalletShapeSpec`) that decodes an in-line JSON literal lacking `extraTxIns` and asserts `wjExtraTxIns == []` post-decode and round-trip-encoded form contains `extraTxIns: []`.
- [ ] T071 [P] [US3] Add a golden test in `test/golden/SwapGoldenSpec.hs` (creating it if absent) that parses a fixture intent.json without `extraTxIns`, builds the tx, and asserts the body CBOR (less ExUnits) matches a checked-in `test/fixtures/swap/expected.cbor`. If `SwapGoldenSpec` already exists and uses the post-T019 fixture, add a sibling fixture under `test/fixtures/swap/legacy/intent.json` (no `extraTxIns`) and assert byte-equality with the post-T019 golden.

### Implementation for User Story 3

- [ ] T080 [US3] No production-code change is required if T010–T013 used the right `.!= []` defaults; T070–T071 verify it. If a test fails, fix the optional-decoding default in `WalletJSON.FromJSON` and re-run.
- [ ] T081 [US3] Update `README.md` (or `docs/operator-guide.md` if it exists for swap) with one line noting that `wallet.extraTxIns` is an optional field defaulting to `[]`. (Targeted edit, not a rewrite.)

---

## Phase 6: Polish & Cross-Cutting

- [ ] T090 [P] Run `just ci` (build + unit + format + hlint) and confirm green. Capture the run in the PR description.
- [ ] T091 [P] Update `CHANGELOG.md` with a single bullet under the next-release section: `add: swap-wizard aggregates multiple wallet UTxOs as fuel; intent.json gains optional wallet.extraTxIns array (#65)`.
- [ ] T092 Manual smoke per `quickstart.md`: a wallet with 3 small pure-ADA UTxOs, a 10-chunk swap, end-to-end pipe, verify the produced CBOR. Capture transcript under `llm/reviews/<PR>/smoke.md`.
- [ ] T093 Run the failure-mode smoke per `quickstart.md`: a wallet with insufficient pure-ADA, verify the wizard exits 3 with the shortfall single-line message and no stdout bytes.
- [ ] T094 Confirm the JSON-Schema asset under `docs/assets/intent-schema.json` validates the existing committed fixtures both with and without `extraTxIns` (covered by `IntentJSONSchemaSpec`; this is a final cross-check).

---

## Dependencies

```
Phase 1 (Setup) ── T001
        │
Phase 2 (Foundational) ── T010 → T011 → T012 → T013, T014, T015 → T016 → T017, T018 → T019 → T020
        │
        ├──> Phase 3 (US1)  ── T030–T033 [P all] → T040 → T041, T042, T043 → T044, T045, T046 → T047
        │
        ├──> Phase 4 (US2)  ── T050, T051 [P] → T060 → T061 → T062         (parallelizable with US1 after T020)
        │
        └──> Phase 5 (US3)  ── T070, T071 [P] → T080 → T081                (parallelizable with US1+US2 after T020)
                          │
Phase 6 (Polish) ── T090–T094       (after Phase 3+4+5 complete)
```

**Story independence after T020**: US1, US2, US3 all build directly on the foundational schema additions and are otherwise independent. They can ship as separate commits or even as separate PRs — but per the spec all three are bundled in this feature, so we ship them as a single PR with a vertical commit per story.

## Parallel execution examples

Within Phase 2, T013 / T014 / T015 touch different modules and are parallelizable. Within each story phase, the test-writing tasks (T030–T033, T050–T051, T070–T071) all touch different test files and are parallelizable.

## MVP scope

The minimum shippable increment is **Phase 1 + Phase 2 + Phase 3 (US1)**. That delivers aggregation end-to-end and resolves the operator pain point. US2 (typed shortfall) and US3 (back-compat regression coverage) are strongly recommended on top because they're cheap once Phase 2 lands and they prevent regressions, but they could in principle be split off if review feedback demands it.

## Format validation

Every task above:

- [x] starts with `- [ ]`
- [x] has a sequential ID (T001, T010–T020, T030–T033, T040–T047, T050–T051, T060–T062, T070–T071, T080–T081, T090–T094)
- [x] uses `[P]` only when parallelizable
- [x] uses `[USn]` only inside Phase 3+ user-story tasks
- [x] names a concrete file path or runnable command
