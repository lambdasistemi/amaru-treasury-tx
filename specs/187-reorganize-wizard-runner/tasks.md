# Tasks: 187-reorganize-wizard-runner

**Input**: Design documents from `/specs/187-reorganize-wizard-runner/`
**Prerequisites**: `plan.md`, `spec.md`, `research.md`, `data-model.md`, `contracts/`, `quickstart.md`
**Branch**: `187-reorganize-wizard-runner`
**Issue**: #187, child of epic #189
**Depends on**: #185 (real `ReorganizeIntent` shapes — merged at `da9d65b5`) + #186 (parser scaffold + stub runner — merged at `1d99cd3b`)

**Tests**: TDD is required by the plan. Each implementation slice
starts with a RED proof, then lands GREEN in the same bisect-safe
commit.

**Organization**: Tasks are grouped by the three vertical slices
from `plan.md`. S1 and S2 are dispatched to claude driver+navigator
pairs (per the brief: `claude --dangerously-skip-permissions` +
`/effort medium`). S3 is orchestrator-owned (no driver+navigator
dispatch). Workers do not push. The orchestrator reviews the
returned commit, amends the matching checkboxes into that same
commit on acceptance, runs the gate, and then pushes.

## Format: `[ID] [P?] [Story?] Description`

- **[P]**: Can run in parallel with another task in the same phase.
- **[Story]**: User-story coverage from `spec.md` (US1..US5).
- **S1/S2/S3**: Bisect-safe slice mapping from `plan.md`.

## Phase 1: Setup

No remaining setup tasks. The branch, draft PR (#198), `gate.sh`,
specification, plan, research, data model, contracts, and
quickstart already exist on the branch.

## Phase 2: Foundational

No remaining foundational tasks. #185 already shipped the real
`ReorganizeIntent` shape, the `Build.Reorganize` runner, and the
`ReorganizeInputs` codec in `Amaru.Treasury.IntentJSON`. #186
already shipped the parser scaffold + the stub runner in
`Amaru.Treasury.{Cli,Tx}.ReorganizeWizard`. This slice extends
the two existing modules without rewriting them.

## Phase 3: S1 — Resolver + Pure Translator + Spec

**Goal**: Ship the **library half** of the runner body — extend
`Tx/ReorganizeWizard.hs` with the resolver-input record, the
record-of-functions resolver env, the resolved-env record, the
extended `ReorganizeError` variants (keeping
`ReorganizeTodoSliceC` for now), the pure-monadic
`resolveReorganize`, the pure translator `reorganizeToIntent`,
and the consolidated runner spec at
`test/unit/Amaru/Treasury/Tx/ReorganizeWizardSpec.hs` covering
User Stories 1, 2, 3, 5 via a mock `ReorganizeResolverEnv`
Identity-monad pattern. After this slice, the library types
are usable from `cabal repl`, the spec is green, the existing
parser spec still passes (no churn), and the CLI binary still
returns `ReorganizeTodoSliceC` on the happy path (S2 replaces
the stub).

**Independent Test**: `nix develop --quiet -c just unit
"ReorganizeWizard"` passes (covers both the new Tx spec and the
unchanged Cli parser spec); `nix develop --quiet -c just unit`
passes (no regressions in sibling wizards); `./gate.sh` passes.

**Owned files**:

- `lib/Amaru/Treasury/Tx/ReorganizeWizard.hs` (extend with
  resolver + translator + new `ReorganizeError` variants)
- `test/unit/Amaru/Treasury/Tx/ReorganizeWizardSpec.hs` (NEW)
- `amaru-treasury-tx.cabal` (expose the new spec module under
  `test-suite unit-tests.other-modules`)

**Forbidden in S1**:

- `lib/Amaru/Treasury/Cli/ReorganizeWizard.hs` (S2 only)
- removing `ReorganizeTodoSliceC` (S2 only)
- `test/unit/Amaru/Treasury/Cli/ReorganizeWizardParserSpec.hs`
  (S2 updates the two assertions)
- `app/amaru-treasury-tx/Main.hs` (no dispatch changes — #186
  already wired the Cmd arm)
- `lib/Amaru/Treasury/Tx/Reorganize.hs`,
  `lib/Amaru/Treasury/Build/*` (already shipped in #185)

**Commit subject**: `feat(tx): reorganize-wizard resolver + pure translator`
**Commit trailer**: `Tasks: T001, T002, T003, T004, T005, T006, T007, T008, T009, T010`

### Tests for S1 (RED)

- [X] T001 [US1] [US2] [US3] [US5] Add the RED spec skeleton at
  `test/unit/Amaru/Treasury/Tx/ReorganizeWizardSpec.hs` that
  imports `Amaru.Treasury.Tx.ReorganizeWizard
  (ReorganizeError (..), ReorganizeResolverInput (..),
  ReorganizeResolverEnv (..), ReorganizeEnv (..),
  ReorganizeWizardAnswers (..), resolveReorganize,
  reorganizeToIntent)` and exposes a `spec :: Spec` value
  discoverable by hspec auto-discovery (matching sibling
  `StakeRewardInitWizardSpec` shape). Record the compile-time
  RED failure (the new types + functions do not exist yet) in
  `WIP.md`.

### Implementation for S1 (GREEN)

- [X] T002 [US2] [US3] [US5] Extend
  `lib/Amaru/Treasury/Tx/ReorganizeWizard.hs` with the new
  `ReorganizeError` variants per `data-model.md` §2 and
  `research.md` §4:
  `ReorganizeMetadataReadError !String`,
  `ReorganizeScopeNotInMetadata !ScopeId`,
  `ReorganizeScopeOwnerMissing !ScopeId`,
  `ReorganizeInsufficientTreasuryUtxos !Int`,
  `ReorganizeWalletShortfall`,
  `ReorganizeValidityHoursZero`,
  `ReorganizeValidityOvershoot !HorizonError`,
  `ReorganizeLedgerFieldParseError !Text !String`.
  Keep `ReorganizeTodoSliceC` (S2 removes it). Add the
  required imports
  (`Cardano.Node.Client.Validity.HorizonError`) and Haddocks.
  Update the module's export list accordingly.
- [X] T003 [US1] [US2] [US3] Add the resolver-input record
  `ReorganizeResolverInput` per `data-model.md` §1
  (`rriNetwork`, `rriWalletAddrBech32`,
  `rriMetadataPath`, `rriScope`, `rriValidityHours`)
  `deriving stock (Eq, Show)`. Export it from the module.
- [X] T004 [P] [US1] [US2] [US3] Add the resolver-env record
  `ReorganizeResolverEnv m` per `data-model.md` §3 and
  `contracts/resolver-contract.md` (`sreReadMetadata`,
  `sreQueryWalletUtxos`, `sreQueryTreasuryUtxos`,
  `sreComputeUpperBound`). Lift the
  `Validity.ValidityChoice` /
  `Validity.HorizonError` imports from
  `Cardano.Node.Client.Validity`. Export the record + its
  constructor + field selectors.
- [X] T005 [P] [US1] Add the resolved-env record
  `ReorganizeEnv` per `data-model.md` §4
  (`reNetwork`, `reUpperBoundSlot`, `reMetadata`,
  `reScopeMetadata`, `reWalletSelection`, `reTreasuryUtxos
  :: NonEmpty Text`) `deriving stock (Eq, Show)`. Import
  `Amaru.Treasury.Metadata.{TreasuryMetadata, ScopeMetadata}`
  and reuse the existing `WalletSelection` from
  `Amaru.Treasury.Tx.SwapWizard`. Export the record.
- [X] T006 [US1] [US2] [US3] [US5] Implement
  `resolveReorganize :: Monad m => ReorganizeResolverEnv m
  -> ReorganizeResolverInput -> m (Either ReorganizeError
  ReorganizeEnv)` per `contracts/resolver-contract.md` and
  `data-model.md` §5. Pipeline ordering (cheap-first):
  devnet guard → metadata read → scope lookup →
  scope-owner check → wallet query + `selectWallet 1` →
  treasury query → count ≥ 2 → sort by `(TxId, TxIx)`
  ascending (parsing rows via
  `Amaru.Treasury.LedgerParse.txInFromText`; per-row parse
  failure surfaces `ReorganizeLedgerFieldParseError
  "treasuryUtxos[<n>]" e`) → upper-bound resolve →
  assemble. Reuse the `selectWallet` helper from
  `Amaru.Treasury.Tx.SwapWizard` for the wallet shortfall
  check. Use `Cardano.Ledger.TxIn.TxIn`'s default `Ord`
  instance for the sort comparator (Q-001-D1).
- [X] T007 [US1] [US5] Implement
  `reorganizeToIntent :: ReorganizeEnv ->
  ReorganizeWizardAnswers -> Either ReorganizeError
  SomeTreasuryIntent` per `data-model.md` §6 and
  `contracts/intent-payload-contract.md`. Parse the
  per-row treasury TxIns, the treasury bech32 address, the
  three deployed-at TxIns, and the scope-owner key-hash;
  derive the `permissionsRewardAccount` via the new helper
  (T008); construct the `TreasuryIntent` carrying
  `tiSAction = SReorganize`, `tiSchema = 1`,
  `tiPayload = ReorganizeInputs{…}` per
  `contracts/intent-payload-contract.md`; wrap as
  `SomeTreasuryIntent SReorganize <ti>`. Mirror the
  defensive `Just 0` guard on `rwaValidityHours` from
  sibling `stakeRewardInitScriptAccountToIntent`.
- [X] T008 [P] [US1] Implement the
  `derivePermissionsRewardAccount :: Network ->
  ScriptHash -> Either String AccountAddress` helper
  (module-internal — not exported) per
  `contracts/permissions-reward-account-contract.md`.
  Reuse `Cardano.Ledger.Address.mkRewardAccount` and the
  existing `Amaru.Treasury.IntentJSON` bech32 render
  surface. `reorganizeToIntent` (T007) calls this helper.
- [X] T009 [US1] [US2] [US3] [US5] Update
  `amaru-treasury-tx.cabal` to expose
  `Amaru.Treasury.Tx.ReorganizeWizardSpec` under the
  `test-suite unit-tests.other-modules` list,
  alphabetically ordered per existing convention.
- [X] T010 [US1] [US2] [US3] [US5] Implement the spec body
  in `test/unit/Amaru/Treasury/Tx/ReorganizeWizardSpec.hs`
  covering every scenario from
  `contracts/resolver-contract.md` § "Spec assertions
  (S1)" via mock `ReorganizeResolverEnv Identity` values.
  At minimum: happy-path scenario (US1) asserting on
  `runIdentity (resolveReorganize env input)` for `Right
  env'` AND on `reorganizeToIntent env' answers` for
  `Right (SomeTreasuryIntent SReorganize _)` AND on the
  JSON round-trip
  `decodeTreasuryIntent (encodeSomeTreasuryIntent _) ===
  Right _` (US5); negative scenarios (US2) for
  `ReorganizeMetadataReadError`,
  `ReorganizeScopeNotInMetadata`,
  `ReorganizeScopeOwnerMissing`; negative scenarios (US3)
  for `ReorganizeInsufficientTreasuryUtxos 0` and
  `ReorganizeInsufficientTreasuryUtxos 1`; one scenario
  for `ReorganizeNonDevnetNetwork`; one scenario for
  `ReorganizeValidityHoursZero`. Use the
  `Amaru.Treasury.Cli.Common.queryFlat`-shaped row tuples
  (`(Text, Integer, Bool)`) for the mock chain-query
  fields, matching the live wiring shape.

**Checkpoint**: S1 is complete when `nix develop --quiet -c
just unit "ReorganizeWizard"` is green (both Tx and Cli
specs), `nix develop --quiet -c just unit` is green (no
regressions in sibling wizards), and `./gate.sh` is green.
`ReorganizeTodoSliceC` is still in the sum (S2 removes it);
the existing parser spec's two assertions on the variant
still pass.

## Phase 4: S2 — Live Runner Wiring + Remove `ReorganizeTodoSliceC`

**Goal**: Replace the `runReorganizeWizardEither` stub body
(currently `pure (Left ReorganizeTodoSliceC)` after pre-flight
passes) with the live pipeline: require `--node-socket`, open
the N2C backend, build a `ReorganizeResolverEnv IO` from the
backend, call `resolveReorganize` + `reorganizeToIntent`,
encode via `encodeSomeTreasuryIntent`, and write the bytes to
`--out`. Add `ReorganizeMissingNodeSocket` variant. Remove
`ReorganizeTodoSliceC`. Update `exitCodeFor`. Update the two
parser-spec assertions (lines 295 + 320 of
`Cli/ReorganizeWizardParserSpec.hs`) to assert
`ReorganizeMissingNodeSocket` instead.

After this slice, an operator running
`amaru-treasury-tx reorganize-wizard --network devnet
--node-socket <socket> --metadata <path> --wallet-addr <bech32>
--funding-seed-txin <txin> --scope <name> --out <path>`
against a healthy DevNet observes a bare `SomeTreasuryIntent`
JSON at `--out`. Without `--node-socket`, the runner exits 2
with the typed missing-socket error.

**Independent Test**: `nix develop --quiet -c just unit
"ReorganizeWizard"` passes (both spec modules); `nix develop
--quiet -c just unit` passes (no regressions); `nix develop
--quiet -c just ci` passes (full all-up gate); `./gate.sh`
passes.

**Owned files**:

- `lib/Amaru/Treasury/Cli/ReorganizeWizard.hs` (replace stub;
  add `runReorganizeWizardLive` helper; update `exitCodeFor`)
- `lib/Amaru/Treasury/Tx/ReorganizeWizard.hs` (remove
  `ReorganizeTodoSliceC`; add `ReorganizeMissingNodeSocket`)
- `test/unit/Amaru/Treasury/Cli/ReorganizeWizardParserSpec.hs`
  (update the two assertions on lines 295 + 320; no other
  changes)

**Forbidden in S2**:

- `lib/Amaru/Treasury/Tx/Reorganize.hs`,
  `lib/Amaru/Treasury/Build/*` (already shipped in #185)
- new spec module from S1 (no changes — already passing)
- `app/amaru-treasury-tx/Main.hs` (no dispatch changes; #186
  already wired the Cmd arm)
- `gate.sh` (S3 only)

**Commit subject**: `feat(cli): wire reorganize-wizard live runner`
**Commit trailer**: `Tasks: T011, T012, T013, T014, T015, T016, T017, T018, T019, T020`

### RED for S2

- [ ] T011 Add `ReorganizeMissingNodeSocket` variant to the
  `ReorganizeError` sum in
  `lib/Amaru/Treasury/Tx/ReorganizeWizard.hs` (between the
  existing `ReorganizeNonDevnetNetwork` and the new
  `ReorganizeMetadataReadError`). Remove `ReorganizeTodoSliceC`
  from the sum. This breaks the existing
  `Cli/ReorganizeWizardParserSpec.hs` compile (the two
  assertions on lines 295, 320 reference the removed variant)
  → record the compile-time RED in `WIP.md`.

### GREEN for S2

- [ ] T012 Update the two parser-spec assertions in
  `test/unit/Amaru/Treasury/Cli/ReorganizeWizardParserSpec.hs`:
  - **Line ~295** (US4 "accepts a valid parent and falls
    through to the stub runner"): change
    `r \`shouldBe\` Left ReorganizeTodoSliceC` to
    `r \`shouldBe\` Left ReorganizeMissingNodeSocket`; update
    the `it` label to "accepts a valid parent and falls
    through to the missing-socket check".
  - **Line ~320** (US5 "accepts --network devnet and falls
    through to the stub runner"): same constructor swap;
    update the `it` label to "accepts --network devnet and
    falls through to the missing-socket check".
  Do not change any other assertion in the file.
- [ ] T013 [US4] Replace the stub body of
  `runReorganizeWizardEither` in
  `lib/Amaru/Treasury/Cli/ReorganizeWizard.hs` to extend the
  cheap-first pipeline per `research.md` §8: after the
  existing `validateOutPath` step, require
  `goSocketPath g` to be `Just _`; on `Nothing`, return
  `Left ReorganizeMissingNodeSocket`. Do not yet open the
  backend; the helper `runReorganizeWizardLive` (T014) is
  the next step.
- [ ] T014 [US1] [US2] [US3] Add the live-pipeline helper
  `runReorganizeWizardLive :: GlobalOpts ->
  ReorganizeWizardOpts -> ReorganizeResolverEnv IO ->
  IO (Either ReorganizeError ())` to
  `lib/Amaru/Treasury/Cli/ReorganizeWizard.hs`. The helper:
  (a) builds the `ReorganizeResolverInput` from
  `GlobalOpts` + `ReorganizeWizardOpts`;
  (b) calls `resolveReorganize` against the resolver env;
  (c) on `Right env`, builds the
  `ReorganizeWizardAnswers` via the existing
  `optsToAnswers` projection;
  (d) calls `reorganizeToIntent env answers`;
  (e) on `Right intent`, encodes via
  `Amaru.Treasury.IntentJSON.encodeSomeTreasuryIntent` and
  writes the bytes to `cfOut` via `BSL.writeFile`,
  returning `Right ()`;
  (f) any `Left e` short-circuits and propagates.
- [ ] T015 [US1] [US2] [US3] [US4] Replace the
  stub-runner branch of `runReorganizeWizardEither` (the
  one that returned `pure (Left ReorganizeTodoSliceC)`)
  with a call into the N2C backend:
  `Amaru.Treasury.Backend.N2C.withLocalNodeBackend
  (goNetworkMagic g) socket $ \backend -> do
  runReorganizeWizardLive g opts (mkLiveEnv backend)` where
  `mkLiveEnv backend = ReorganizeResolverEnv {…}` populates
  each field via `queryFlat backend` (for wallet + treasury
  UTxOs), `queryUpperBoundSlot backend` (for validity
  bound), and a `readMetadataSafely` wrapper (T016).
- [ ] T016 [P] [US2] Add the IO wrapper
  `readMetadataSafely :: FilePath -> IO (Either String
  TreasuryMetadata)` (module-internal; mirrors
  `readRegistrySafely` in sibling
  `Cli/StakeRewardInitWizard.hs`) that catches
  `IOException` from
  `Amaru.Treasury.Metadata.readMetadataFile` and reflects
  it as `Left (show ioe)`. The live `mkLiveEnv` consumes
  this in the `sreReadMetadata` field.
- [ ] T017 Update
  `Amaru.Treasury.Cli.ReorganizeWizard.exitCodeFor` per
  `contracts/exit-code-contract.md`: remove the
  `ReorganizeTodoSliceC` case; add the new variants at
  their respective tiers
  (`ReorganizeMissingNodeSocket` → 2,
  `ReorganizeMetadataReadError` → 2,
  `ReorganizeScopeNotInMetadata` → 2,
  `ReorganizeScopeOwnerMissing` → 2,
  `ReorganizeInsufficientTreasuryUtxos` → 2,
  `ReorganizeWalletShortfall` → 2,
  `ReorganizeValidityHoursZero` → 2,
  `ReorganizeValidityOvershoot` → 2,
  `ReorganizeLedgerFieldParseError` → 3). Pattern-match
  every constructor (no wildcard fallback — prevents
  silent drift if future variants are added).
- [ ] T018 [P] Update the module export list of
  `lib/Amaru/Treasury/Cli/ReorganizeWizard.hs` to include
  the new `runReorganizeWizardLive` helper (so the test
  suite + downstream callers can substitute mock resolver
  envs if needed later). Verify the import in
  `app/amaru-treasury-tx/Main.hs` still resolves
  (`runReorganizeWizard` is the IO shim and remains the
  CLI entry point — no Main.hs edit needed).
- [ ] T019 [US4] [US5] Re-run the existing
  `Cli/ReorganizeWizardParserSpec.hs` after T011–T018;
  confirm:
  - the four `us4OutPathSpec` cases still pass;
  - the four `us5NetworkGuardSpec` cases still pass
    (network guard fires before the missing-socket
    check);
  - the two updated assertions (T012) pass with
    `ReorganizeMissingNodeSocket`;
  - no other spec needs updating.
- [ ] T020 Run the full `nix develop --quiet -c just ci`
  locally; if green, record the gate evidence in the
  driver+navigator handoff. Any sibling-wizard regression
  is a stop-and-redispatch trigger (S2's owned-files list
  does NOT include sibling spec files).

**Checkpoint**: S2 is complete when `nix develop --quiet -c
just unit "ReorganizeWizard"` is green, the full
`nix develop --quiet -c just ci` is green, and
`./gate.sh` is green. The CLI binary now produces a bare
`SomeTreasuryIntent` JSON at `--out` when invoked with valid
flags + a healthy DevNet; without `--node-socket` it surfaces
`ReorganizeMissingNodeSocket` at exit code 2.

## Phase 5: S3 — Drop gate.sh + mark ready (orchestrator-owned, chore)

**Goal**: Drop `gate.sh` from the worktree and mark PR #198
ready for review. Final commit on the branch; no behavior
change.

**Owned files (S3 only)**:

- `gate.sh` — removed via `git rm gate.sh`.

**S3 is orchestrator-owned** (`chore:` exempt from `Tasks:`
trailer requirement per the commit-message gate). Before
commit: run `finalization_audit` from the `gate-script` skill;
confirm every task in `tasks.md` is `[X]`; confirm `git diff
--check` is clean; confirm full `nix develop -c just ci`
passes (the same ci `gate.sh` would have run).

**Commit subject**: `chore: drop gate.sh (ready for review)`

After commit:

- `git push`
- `gh pr ready 198`
- Append `COMPLETE` + `NOTE PR #198 marked ready for review`
  to STATUS.md.

- [ ] T021 [P] Run `finalization_audit 198` from the
  `gate-script` skill; confirm every commit on the branch
  passes the commit-message gate AND every task in
  `tasks.md` is `[X]`.
- [ ] T022 `git rm gate.sh && git commit -m "chore: drop
  gate.sh (ready for review)"`; push; `gh pr ready 198`.

## Dependencies

```text
S1 (T001..T010) ── library half (Tx/ReorganizeWizard.hs + new spec)
   │
   ▼
S2 (T011..T020) ── CLI wiring (Cli/ReorganizeWizard.hs + parser-spec assertion swap)
   │
   ▼
S3 (T021..T022) ── chore: drop gate.sh; mark ready
```

S2 depends on S1: the live runner pipeline in S2 calls into
`resolveReorganize` + `reorganizeToIntent` from S1.

S3 depends on S2: the finalization audit verifies every task
is `[X]`.

## Parallel execution within each slice

Within S1, T004 + T005 can be authored in parallel (different
fields of the same module); T008 is parallel-safe (a new
internal helper). T002 + T003 must precede T006 (resolver
implementation needs the records). T006 must precede T010
(spec depends on the resolver returning typed values).

Within S2, T011 is the RED step (must come first); T012
follows immediately (compile-fix); T013..T018 are the
implementation; T019..T020 are the verification. T013 + T014
+ T016 can be authored in parallel (different module sections
/ helpers); T015 must follow T014 (it consumes the helper).

S3 has no internal parallelism.

## Implementation strategy (MVP first)

- **MVP** = S1 → S2. S3 is finalization-only. The shipped
  command's `--out` writes a real intent JSON after S2; an
  operator can use the runner immediately after S2 lands.
- The driver+navigator pair for S1 should be dispatched FIRST.
  S2 cannot start until S1 is reviewed, accepted, and pushed
  (the resolver + translator are S2's prerequisite).
- S3 runs after S2's gate is green. The orchestrator does this
  step; no driver+navigator dispatch needed.

## Independent test per slice

- **S1 independent test**: `nix develop --quiet -c just unit
  "ReorganizeWizard"` covers both the new Tx spec (resolver +
  translator) and the unchanged Cli parser spec. A green run
  proves the library half compiles, the resolver mock-driven
  scenarios pass, and the parser spec did not regress.
- **S2 independent test**: same command. A green run after S2
  proves the parser-spec assertion swap is correct and the
  live runner compiles. The runner-level integration smoke
  (live DevNet invocation) is deferred to #87.
- **S3 independent test**: `./gate.sh` PASS + `git log
  --oneline -2` shows the `chore: drop gate.sh` commit at HEAD.
