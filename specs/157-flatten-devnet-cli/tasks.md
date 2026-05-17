---

description: "Task list for #157 — flatten devnet supercommand & add init intent encodings"
---

# Tasks: Flatten Devnet Supercommand & Add Init Intent Encodings (#157)

**Branch**: `157-flatten-devnet-cli`
**Spec**: [spec.md](./spec.md) | **Plan**: [plan.md](./plan.md) | **Research**: [research.md](./research.md) | **Data model**: [data-model.md](./data-model.md) | **Contracts**: [contracts/](./contracts) | **Quickstart**: [quickstart.md](./quickstart.md)

## Format

`- [ ] T### [P?] [Story?] description (file paths)`

- `[P]`: parallelizable (different files, no dependency on incomplete tasks).
- `[Story]`: user-story label (`US1`, `US2`, `US3`, `US4`).
- Each implementation slice is **one bisect-safe commit** (RED + GREEN fold into the same commit per resolve-ticket).
- Each behavior-changing commit body MUST carry a `Tasks: T###[, T###]` trailer; the orchestrator amends this file to `[X] T### (commit: <short-sha>)` at slice review.

## Subagent dispatch rule

Each `Subagent slice` heading below is one subagent run. The brief named there is the entire contract — the subagent does **not** load `resolve-ticket`, `speckit-implement`, or any other process skill. The orchestrator reviews the diff, reruns `./gate.sh`, and amends this file with the SHA before dispatching the next slice.

---

## Phase 1: Setup

- [X] T000 (commit: a81e53b) chore: add `gate.sh` at repo root (`gate.sh`).

**Checkpoint:** gate is committed and runnable.

---

## Phase 2: Foundational

No foundational task. The dispatch infrastructure (`Amaru.Treasury.Build.runBuildExcept`, `SomeTreasuryIntent`, `tx-build --intent`) already exists and is extended in place.

---

## Phase 3: User Story 2 — Remove `devnet` Supercommand (Priority: P1)

**Story**: Operators inspecting `amaru-treasury-tx --help` see no `devnet` command and no `registry-init` / `stake-reward-init` / `governance-withdrawal-init` / `disburse-submit` subcommands at any nesting level.

**Independent test**: `amaru-treasury-tx --help` shows no `devnet`; `amaru-treasury-tx devnet registry-init …` is rejected as unrecognized; `just ci` is green.

**Done first** because the parser flatten removes a large block of code without depending on the new intent variants — keeps subsequent slices small.

### Subagent slice 1 — Parser retirement (one commit)

- [ ] T001 [US2] RED: extend `test/unit/Amaru/Treasury/Cli/ParserSpec.hs` with cases asserting that `amaru-treasury-tx devnet …`, `amaru-treasury-tx devnet registry-init …`, `amaru-treasury-tx devnet stake-reward-init …`, `amaru-treasury-tx devnet governance-withdrawal-init …`, and `amaru-treasury-tx devnet disburse-submit …` are rejected as unrecognized subcommands; assertion of help-text non-containment of the literal `"devnet"`. (`test/unit/Amaru/Treasury/Cli/ParserSpec.hs`)
- [ ] T002 [US2] GREEN: in the same commit, drop the `"devnet"` subparser line (`lib/Amaru/Treasury/Cli.hs:167`), the `devnetCmdP` parser (`lib/Amaru/Treasury/Cli.hs:285-321`), the four `CmdDevnet*` constructors (`lib/Amaru/Treasury/Cli.hs:104-107`), the four `Amaru.Treasury.Cli.Devnet` imports (`lib/Amaru/Treasury/Cli.hs:43-51`), and the four `runDevnet*` imports + dispatch in `app/amaru-treasury-tx/Main.hs`; delete `lib/Amaru/Treasury/Cli/Devnet.hs`; remove the exposed-module entry from `amaru-treasury-tx.cabal`. (`lib/Amaru/Treasury/Cli.hs`, `lib/Amaru/Treasury/Cli/Devnet.hs`, `app/amaru-treasury-tx/Main.hs`, `amaru-treasury-tx.cabal`)
- [ ] T003 [US2] Verify `./gate.sh` is green at HEAD; `lib/Amaru/Treasury/Devnet/{RegistryInit,StakeRewardInit,GovernanceWithdrawalInit,DisburseSubmit}.hs` remain on disk and reachable from `Amaru.Treasury.Devnet.SmokeSpec`. No diff to those four files.

**Fold rule**: T001 + T002 + T003 are one commit. T001 is RED before T002 lands; T003 is the GREEN verification.

**Subagent brief** (template — orchestrator fills SHAs / final wording at dispatch):

```text
Task: T001, T002, T003

Context:
- One commit, bisect-safe, vertical. No push.
- Commit subject: `refactor(cli): drop devnet supercommand (#157)`.
- Commit body MUST include `Tasks: T001, T002, T003`.

Owned files:
- lib/Amaru/Treasury/Cli.hs
- lib/Amaru/Treasury/Cli/Devnet.hs                  (delete)
- app/amaru-treasury-tx/Main.hs
- amaru-treasury-tx.cabal
- test/unit/Amaru/Treasury/Cli/ParserSpec.hs        (new or extend)

Forbidden scope:
- specs/, gate.sh, README, docs/, PR/issue metadata
- lib/Amaru/Treasury/Devnet/{RegistryInit,StakeRewardInit,GovernanceWithdrawalInit,DisburseSubmit}.hs
  (must remain bit-identical; they are relocated *in place*, not modified)
- Any change to SmokeSpec

Required orchestrator analysis already applied:
- Cli.hs:104-107 has `CmdDevnetRegistryInit | CmdDevnetStakeRewardInit | CmdDevnetGovernanceWithdrawalInit | CmdDevnetDisburseSubmit`.
- Cli.hs:167-169 binds "devnet" -> devnetCmdP.
- Cli.hs:285-321 defines devnetCmdP with the four children.
- app/Main.hs imports `Amaru.Treasury.Cli.Devnet (runDevnet*)`.
- SmokeSpec consumes `lib/Amaru/Treasury/Devnet/*Init.hs` directly; no CLI shelling.

RED proof (write first, observe failing):
- Add `test/unit/Amaru/Treasury/Cli/ParserSpec.hs` cases that exec
  `parseArgs ["devnet"]` and the four `devnet <sub>` variants and
  assert each returns an unrecognized-subcommand failure.
- Run: `nix develop --quiet -c just unit "ParserSpec"` — must fail on the current HEAD before edits.

GREEN proof:
- Run: `nix develop --quiet -c just unit "ParserSpec"` — passes.
- Run: `./gate.sh` — passes.
- `git ls-files lib/Amaru/Treasury/Devnet/ | sort` is unchanged.

Report back:
- diff stat
- RED evidence (failing run)
- GREEN evidence (passing run + ./gate.sh tail)
- confirmation that the four Devnet runners are untouched
```

**Checkpoint:** Parser flat; `Cli/Devnet.hs` gone; SmokeSpec still compiles; help text clean.

---

## Phase 4: User Story 1 — Build Each Init Tx Via `tx-build --intent` (Priority: P1)

**Story**: For any of the seven init sub-action intents, `amaru-treasury-tx tx-build --intent <bootstrap-intent.json>` produces an unsigned tx CBOR hex byte-identical to the CBOR the corresponding sub-transaction in the library function builds for the same logical inputs.

**Independent test**: Seven golden equivalence tests (`runFromIntent ctx intent` ≡ `extractedCore ctx inputs`) and seven round-trip properties pass; `nix build .#checks.{unit,golden}` green; `just schema-check` green.

### Subagent slice 2 — Intent JSON scaffolding for the seven sub-actions (one commit)

- [ ] T010 [US1] RED: extend `test/unit/Amaru/Treasury/IntentJSONSpec.hs` with one round-trip property per new sub-action (`decode . encode ≡ Right` for each of: `registry-init-seed-split`, `registry-init-mint`, `registry-init-reference-scripts`, `stake-reward-init-script-account`, `stake-reward-init-plain-account`, `governance-withdrawal-init-proposal`, `governance-withdrawal-init-materialization`); extend `test/unit/Amaru/Treasury/IntentJSONSchemaSpec.hs` with a presence check for each new variant in the rendered schema. (`test/unit/Amaru/Treasury/IntentJSONSpec.hs`, `test/unit/Amaru/Treasury/IntentJSONSchemaSpec.hs`)
- [ ] T011 [US1] GREEN: extend `Action`, `SAction`, `Payload`, `Translated` with the seven flat constructors per `data-model.md`; introduce seven `*Inputs` records with `FromJSON` / `ToJSON` (decoder accepts any `network: Text` — no policy guard, per the dispatcher-policy rule); add seven `SomeTreasuryIntent` arms. (`lib/Amaru/Treasury/IntentJSON.hs`, `lib/Amaru/Treasury/IntentJSON/Common.hs`, `lib/Amaru/Treasury/IntentJSON/Schema.hs`)
- [ ] T012 [US1] Regenerate `docs/assets/intent-schema.json` (`just update-schema`); `just schema-check` green. (`docs/assets/intent-schema.json`, `app/amaru-treasury-intent-schema/Main.hs` if hand-rolled)

**Fold rule**: T010 + T011 + T012 are one commit.

**Subagent brief**:

```text
Task: T010, T011, T012

Context:
- One commit, bisect-safe. No push.
- Commit subject: `feat(intent): add seven init sub-action variants (#157)`.
- Commit body MUST include `Tasks: T010, T011, T012`.

Owned files:
- lib/Amaru/Treasury/IntentJSON.hs
- lib/Amaru/Treasury/IntentJSON/Common.hs
- lib/Amaru/Treasury/IntentJSON/Schema.hs
- app/amaru-treasury-intent-schema/Main.hs (only if hand-rolled)
- docs/assets/intent-schema.json
- test/unit/Amaru/Treasury/IntentJSONSpec.hs
- test/unit/Amaru/Treasury/IntentJSONSchemaSpec.hs
- amaru-treasury-tx.cabal (if a new module is added)

Forbidden scope:
- specs/, gate.sh, README, docs/local-devnet-smoke.md, PR metadata
- lib/Amaru/Treasury/Build.hs (dispatch arms land in slices 3a/3b/3c)
- lib/Amaru/Treasury/Devnet/*.hs
- Any policy/guard on `network` (deliberately deferred to slice 4)

Required orchestrator analysis already applied:
- Current Action enum: Swap | Disburse | Withdraw | Reorganize.
- Type families Payload and Translated at IntentJSON.hs:171-185.
- SomeTreasuryIntent existential at IntentJSON.hs:505-509.
- Decoders accept any `network: Text` today (IntentJSON.hs:619, 484).

RED proof:
- Add round-trip property per new variant — run
  `nix develop --quiet -c just unit "IntentJSON"` — must fail on the
  current HEAD before edits.

GREEN proof:
- `nix develop --quiet -c just unit "IntentJSON"` — passes.
- `nix develop --quiet -c just schema-check` — passes.
- `./gate.sh` — passes.

Report back:
- diff stat
- RED evidence
- GREEN evidence (unit + schema-check + ./gate.sh)
- Confirmation: no `network` guard added to any decoder.
```

### Subagent slice 3a — Registry-init dispatch + 3 CBOR-equivalence goldens (one commit)

- [ ] T020 [US1] RED: add `test/golden/Amaru/Treasury/RegistryInitIntentSpec.hs` with three goldens that materialize a fixture intent + drive `runFromIntent` and assert byte-identical CBOR vs. the extracted construction core for `registry-init-seed-split`, `registry-init-mint`, `registry-init-reference-scripts`; commit fixtures (`test/fixtures/intent/registry-init-{seed-split,mint,reference-scripts}.json`). (`test/golden/Amaru/Treasury/RegistryInitIntentSpec.hs`, `test/fixtures/intent/…`)
- [ ] T021 [US1] GREEN: extract per-sub-tx construction cores from `lib/Amaru/Treasury/Devnet/RegistryInit.hs` (seed-split, mint, reference-scripts) into pure functions reachable from `Amaru.Treasury.Build.runBuildExcept`; add three dispatch arms to `runBuildExcept`. The existing submitter code paths in `RegistryInit.hs` stay on top of the extracted cores unchanged. (`lib/Amaru/Treasury/Build.hs`, `lib/Amaru/Treasury/Devnet/RegistryInit.hs`)
- [ ] T022 [US1] Verify `nix build .#checks.golden` and `./gate.sh` green; `SmokeSpec` still compiles unchanged.

**Fold rule**: T020 + T021 + T022 are one commit. The extraction in T021 must preserve `RegistryInit.hs`'s existing semantic behavior; the golden in T020 holds that invariant byte-by-byte.

**Subagent brief**:

```text
Task: T020, T021, T022

Context:
- One commit, bisect-safe. No push.
- Commit subject: `feat(build): dispatch registry-init sub-action intents (#157)`.
- Commit body MUST include `Tasks: T020, T021, T022`.

Owned files:
- lib/Amaru/Treasury/Build.hs
- lib/Amaru/Treasury/Devnet/RegistryInit.hs        (extraction only)
- test/golden/Amaru/Treasury/RegistryInitIntentSpec.hs
- test/fixtures/intent/registry-init-seed-split.json
- test/fixtures/intent/registry-init-mint.json
- test/fixtures/intent/registry-init-reference-scripts.json
- amaru-treasury-tx.cabal (if a new test-suite component or module appears)

Forbidden scope:
- specs/, gate.sh, README, docs/, PR metadata
- lib/Amaru/Treasury/IntentJSON*.hs (frozen by slice 2)
- lib/Amaru/Treasury/Devnet/StakeRewardInit.hs (slice 3b)
- lib/Amaru/Treasury/Devnet/GovernanceWithdrawalInit.hs (slice 3c)
- lib/Amaru/Treasury/Devnet/DisburseSubmit.hs
- Any `network` policy / requireDevnet guard (slice 4)
- The submitter functions in RegistryInit.hs (`submitSeedSplit`,
  `submitRegistryNfts`, `submitReferenceScripts`,
  `publishDevnetRegistryInit`) must keep their current public
  signatures and behavior; only their internal call to the
  construction core may move.

Required orchestrator analysis already applied:
- RegistryInit.hs:339 submitSeedSplit; :377 submitRegistryNfts;
  :448 submitReferenceScripts; :495 buildSubmitAndWait.
- The extraction targets are the pre-submit body construction blocks
  inside each `submitX` — extract to top-level pure builders
  consumed by both (a) the existing submitter and (b) the new
  Build.hs dispatch arms.
- SmokeSpec consumes `publishDevnetRegistryInit` (or its caller) —
  do not change its public surface.

RED proof:
- Goldens compare `brCborBytes (runFromIntent ctx intent)` against
  `brCborBytes (extractedCore ctx inputs)`. Both must be derived
  from the same logical inputs (test-support helper or shared
  fixture builder).
- Run: `nix develop --quiet -c just golden "RegistryInitIntent"` —
  must fail on HEAD before edits.

GREEN proof:
- `nix develop --quiet -c just golden "RegistryInitIntent"` — passes.
- `nix develop --quiet -c just unit` — passes (SmokeSpec unchanged).
- `./gate.sh` — passes.

Report back:
- diff stat
- RED evidence (failing goldens)
- GREEN evidence (passing goldens + ./gate.sh)
- Explicit confirmation: `git diff origin/main -- lib/Amaru/Treasury/Devnet/RegistryInit.hs`
  shows extraction-only deltas; public submitter surface unchanged.
```

### Subagent slice 3b — Stake-reward-init dispatch + 2 CBOR-equivalence goldens (one commit)

- [ ] T030 [US1] RED: `test/golden/Amaru/Treasury/StakeRewardInitIntentSpec.hs` with two goldens (`script-account`, `plain-account`); fixtures `test/fixtures/intent/stake-reward-init-{script-account,plain-account}.json`. (`test/golden/Amaru/Treasury/StakeRewardInitIntentSpec.hs`, `test/fixtures/intent/…`)
- [ ] T031 [US1] GREEN: extract construction cores from `lib/Amaru/Treasury/Devnet/StakeRewardInit.hs` (script-account, plain-account); add two dispatch arms in `Amaru.Treasury.Build.runBuildExcept`. (`lib/Amaru/Treasury/Build.hs`, `lib/Amaru/Treasury/Devnet/StakeRewardInit.hs`)
- [ ] T032 [US1] Verify `nix build .#checks.golden` and `./gate.sh` green; SmokeSpec still compiles.

**Fold rule**: T030 + T031 + T032 are one commit. As 3a.

**Subagent brief**: mirror 3a's structure, swap `RegistryInit` for `StakeRewardInit`, two goldens not three, owned files as listed in T030/T031. Commit subject `feat(build): dispatch stake-reward-init sub-action intents (#157)`. Trailer `Tasks: T030, T031, T032`.

### Subagent slice 3c — Governance-withdrawal-init dispatch + 2 CBOR-equivalence goldens (one commit)

- [ ] T040 [US1] RED: `test/golden/Amaru/Treasury/GovernanceWithdrawalInitIntentSpec.hs` with two goldens (`proposal`, `materialization`); fixtures `test/fixtures/intent/governance-withdrawal-init-{proposal,materialization}.json`. (`test/golden/Amaru/Treasury/GovernanceWithdrawalInitIntentSpec.hs`, `test/fixtures/intent/…`)
- [ ] T041 [US1] GREEN: extract construction cores from `lib/Amaru/Treasury/Devnet/GovernanceWithdrawalInit.hs` (proposal, materialization); add two dispatch arms in `Amaru.Treasury.Build.runBuildExcept`. (`lib/Amaru/Treasury/Build.hs`, `lib/Amaru/Treasury/Devnet/GovernanceWithdrawalInit.hs`)
- [ ] T042 [US1] Verify `nix build .#checks.golden` and `./gate.sh` green; SmokeSpec still compiles.

**Fold rule**: T040 + T041 + T042 are one commit. As 3a.

**Subagent brief**: mirror 3a's structure, swap `RegistryInit` for `GovernanceWithdrawalInit`. Commit subject `feat(build): dispatch governance-withdrawal-init sub-action intents (#157)`. Trailer `Tasks: T040, T041, T042`.

**Checkpoint:** All seven sub-action intents build byte-identical CBOR through `tx-build`. US1 is independently testable end-to-end on a live socket.

---

## Phase 5: User Story 3 — `SmokeSpec` Survives Via Library Functions (Priority: P1)

**Story**: `Amaru.Treasury.Devnet.SmokeSpec` keeps compiling and passing while calling the relocated runners directly as library functions, no CLI shelling.

**Independent test**: `nix build .#checks.devnet-smoke` (or equivalent) passes; grep shows zero `amaru-treasury-tx devnet …` invocations in `test/devnet/`.

US3 has **no dedicated slice** — it is preserved as a side-effect invariant of slices 1, 3a, 3b, 3c. The verification task below confirms it.

### Verification task (orchestrator-owned, no subagent)

- [ ] T050 [US3] After slice 3c lands, run `nix develop --quiet -c grep -RnE 'amaru-treasury-tx[ ]+devnet' test/` and confirm zero matches; run `nix develop --quiet -c just unit` (covers SmokeSpec compile) and the live `just devnet-smoke` phases that exist for the four runners; record the verification output in the slice-3c review note (no new commit needed unless a regression appears).

**Checkpoint:** SmokeSpec proven unchanged in behavior; library proof survives.

---

## Phase 6: Cross-Cutting — Network Policy In The Dispatcher

Not a user story; covers the parent #156 invariant *"every CLI bootstrap path refuses non-DevNet networks (fail-closed)"*.

### Subagent slice 4 — `requireDevnet` helper + regression suite (one commit)

- [ ] T060 RED: add `test/unit/Amaru/Treasury/Build/NetworkGuardSpec.hs` with seven cases — for each of the seven init sub-action intents, build a fixture with `network: mainnet` and assert that `runFromIntentEither` returns a typed `BuildError` *before* any N2C connection (use a dummy `ChainContext` that fails loudly if touched). (`test/unit/Amaru/Treasury/Build/NetworkGuardSpec.hs`, `test/fixtures/intent/…-mainnet.json` as needed)
- [ ] T061 GREEN: introduce `requireDevnet :: Text -> ExceptT BuildError IO ()` (or equivalent) in `Amaru.Treasury.Build` (or a sibling module) and call it as the first action in each of the seven init dispatch arms in `runBuildExcept`. The decoder remains untouched. (`lib/Amaru/Treasury/Build.hs`)
- [ ] T062 Verify the existing seven happy-path goldens from slices 3a/3b/3c still pass (no regression from the guard insertion). `./gate.sh` green.

**Fold rule**: T060 + T061 + T062 are one commit.

**Subagent brief**:

```text
Task: T060, T061, T062

Context:
- One commit, bisect-safe. No push.
- Commit subject: `feat(build): reject non-devnet networks for init intents (#157)`.
- Commit body MUST include `Tasks: T060, T061, T062`.

Owned files:
- lib/Amaru/Treasury/Build.hs
- test/unit/Amaru/Treasury/Build/NetworkGuardSpec.hs
- test/fixtures/intent/*-mainnet.json (if a separate fixture is preferred)
- amaru-treasury-tx.cabal (if a new test module appears)

Forbidden scope:
- lib/Amaru/Treasury/IntentJSON*.hs — the decoder MUST NOT enforce
  this policy (asymmetry vs. swap/disburse/withdraw decoders).
  See specs/157-flatten-devnet-cli/research.md "Network safety in
  the Build.hs dispatcher arm".
- lib/Amaru/Treasury/Devnet/*.hs (no change)
- specs/, gate.sh, docs/, PR metadata

Required orchestrator analysis already applied:
- Existing dispatch shape: runBuildExcept at lib/Amaru/Treasury/Build.hs:96
  cases by SAction. Add the call to requireDevnet before each init arm.
- BuildError types live alongside; the guard surfaces a typed error.
- A dummy ChainContext can be constructed by the test that throws on
  any field access — this proves no N2C touch happens before rejection.

RED proof:
- The seven mainnet-intent test cases run runFromIntentEither against
  the dummy context — must fail (no guard yet) before T061 lands.
- Run: `nix develop --quiet -c just unit "NetworkGuardSpec"` — must fail.

GREEN proof:
- `nix develop --quiet -c just unit "NetworkGuardSpec"` — passes.
- `nix develop --quiet -c just golden` — the seven equivalence goldens
  from slices 3a/3b/3c still pass (no regression).
- `./gate.sh` — passes.

Report back:
- diff stat
- RED evidence
- GREEN evidence
- Confirmation: no edits to lib/Amaru/Treasury/IntentJSON*.hs.
```

**Checkpoint:** Mainnet/preprod fails closed at the dispatcher before any effect; decoders remain symmetric across all intent variants.

---

## Phase 7: User Story 4 — Docs Reflect The New Operator Path (Priority: P2)

**Story**: `README.md`, `docs/local-devnet-smoke.md`, and PR body describe `tx-build --intent <bootstrap-intent.json>` as the operator path; old `devnet <action>` references are gone; wizards (#158–#160) and bash smoke (#161) are forward-referenced.

**Independent test**: `grep -RnE 'devnet[ ]+(registry-init|stake-reward-init|governance-withdrawal-init|disburse-submit)' README.md docs/` returns zero matches; the new operator path is documented end-to-end.

### Orchestrator slice 5 — Documentation alignment (one commit, orchestrator-owned)

- [ ] T070 [US4] Update `README.md`: replace any `amaru-treasury-tx devnet …` invocation with the `tx-build --intent <bootstrap-intent.json>` operator path; add a short forward reference to #158–#160 (wizards) and #161 (bash smoke). (`README.md`)
- [ ] T071 [US4] Update `docs/local-devnet-smoke.md`: bootstrap section describes the intent → `tx-build` operator path; identify `SmokeSpec` as library proof and note `smoke.sh` arrives in #161; remove stale `devnet <action>` references. (`docs/local-devnet-smoke.md`)
- [ ] T072 [US4] Update PR #162 body to mark the docs phase ready and refresh the status block.

**Fold rule**: T070 + T071 are one commit (`docs(157): update operator path for intent-driven bootstrap`). T072 is a `gh pr edit` action, not a commit.

**Checkpoint:** Docs and metadata agree with delivered behavior; PR can be reviewed.

---

## Phase 8: Polish & Ready

### Orchestrator slice 6 — Drop `gate.sh` & mark ready (one commit + one `gh` action)

- [ ] T080 chore: `git rm gate.sh` and commit (`chore: drop gate.sh (ready for review) (#157)`). (`gate.sh`)
- [ ] T081 `gh pr ready 162`; do not self-approve.

**Checkpoint:** `gate.sh` absent from HEAD; PR is ready for external review; orchestrator does NOT merge.

---

## Dependencies

```text
T000 (done)
  → Slice 1 [US2]         (T001-T003)
  → Slice 2 [US1]         (T010-T012)
       → Slice 3a [US1]   (T020-T022)
       → Slice 3b [US1]   (T030-T032)   } 3a/3b/3c can be parallel after slice 2
       → Slice 3c [US1]   (T040-T042)   } if the user authorizes parallel subagents
            → Slice 4 (T060-T062)        (requires the seven init arms to exist)
                 → T050 [US3]            (verification only)
                 → Slice 5 [US4] (T070-T072)
                      → Slice 6 (T080-T081)
```

Slice 1 (parser) and Slice 2 (intent JSON) can also run in parallel if you authorize — they touch disjoint files (`Cli*.hs` vs. `IntentJSON*.hs`). Default to sequential per resolve-ticket "one subagent at a time unless explicitly allowed".

## Parallel execution opportunities

- After slice 2 lands, slices 3a / 3b / 3c are independent at the file level (different `Devnet/*Init.hs` modules, different golden specs, different fixture files; shared edits to `Build.hs` would conflict — orchestrator must serialize the `Build.hs` arms across the three slices, OR pre-stage the three arms as empty `case` branches in slice 2's extension to remove the conflict).
- Slice 1 and Slice 2 touch disjoint trees and can be parallel under explicit user approval.
- Slices 4, 5, 6 are strictly sequential.

## Implementation strategy

- **MVP increment**: Slice 1 (parser flat) + Slice 2 (intent JSON scaffold). At this point the CLI no longer exposes `devnet …`, the seven intent variants round-trip, and the schema is up to date — but `tx-build` cannot yet *build* any of them. This is a reviewable "API shape" milestone.
- **Functional increment**: + Slice 3a/3b/3c (all seven dispatch arms with CBOR-equivalence proof). At this point a fixture intent yields the same CBOR the library would, byte-for-byte.
- **Safety increment**: + Slice 4 (`requireDevnet`). Mainnet/preprod fail closed.
- **Ship increment**: + Slice 5 (docs) + Slice 6 (drop gate, ready).

## Format validation

- Every task above starts with `- [ ]` (or `- [X]` for T000), has a `T###` id, a `[Story]` label where applicable, and a file path.
- Behavior-changing slice commits MUST carry `Tasks: T###[, T###]` trailers; the orchestrator amends `[X] T### (commit: <sha>)` at slice review (resolve-ticket two-sided link).
